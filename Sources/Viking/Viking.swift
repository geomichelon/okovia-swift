import Foundation

/// Public entry point of the Viking SDK.
public enum Viking {
    private static let stateLock = NSLock()
    private static var state: VikingState?

    /// Initializes the SDK. Call once, as early as possible in app launch.
    ///
    /// Boots on embedded safe defaults, then downloads the project's
    /// published remote config (ETag/304, disk cache) and applies it to
    /// every collector - collectors toggle dynamically on config changes.
    ///
    /// - Parameters:
    ///   - apiKey: the project's PUBLIC key (`vik_pub_...`). Secret keys
    ///     (`vik_sec_...`) are server-side only and are rejected so a
    ///     leaked-into-app secret fails fast in development.
    ///   - options: debug logging and endpoint/storage overrides.
    public static func start(apiKey: String, options: VikingOptions = VikingOptions()) throws {
        guard isPublicKey(apiKey) else {
            throw VikingError.invalidAPIKey(
                "Viking.start requires a public API key (vik_pub_...). "
                + "Never embed a secret key in an app."
            )
        }

        stateLock.lock()
        defer { stateLock.unlock() }

        if state != nil {
            VikingLogger(enabled: options.debug).debug("Viking.start called more than once; ignoring.")
            return
        }

        let logger = VikingLogger(enabled: options.debug)
        let storageDirectory = options.storageDirectory ?? Self.defaultStorageDirectory()

        let configManager = RemoteConfigManager(
            apiKey: apiKey,
            options: options,
            fetcher: URLSessionConfigFetcher(),
            cacheDirectory: storageDirectory,
            logger: logger
        )

        let store: SQLiteEventStore
        do {
            store = try SQLiteEventStore(
                path: storageDirectory.appendingPathComponent("queue.sqlite").path
            )
        } catch {
            throw VikingError.storageUnavailable(String(describing: error))
        }

        let queue = EventQueue(
            store: store,
            sender: URLSessionIngestSender(),
            apiKey: apiKey,
            config: configManager.current,
            logger: logger
        )
        let recorder = LLMCallRecorder(queue: queue, config: configManager.current, logger: logger)
        let tracker = LocalInferenceTracker(
            queue: queue,
            config: configManager.current,
            energySampler: UnavailableEnergySampler()
        )

        configManager.subscribe(queue)
        configManager.subscribe(recorder)
        configManager.subscribe(tracker)
        configManager.start()

        VikingURLProtocol.recorder = recorder
        if options.interceptSharedSession {
            // Global registration reaches URLSession.shared traffic with
            // zero integration. Invasiveness is bounded in canInit: only
            // hosts in the remote config's intercept_hosts are claimed.
            URLProtocol.registerClass(VikingURLProtocol.self)
        }

        state = VikingState(
            apiKey: apiKey,
            options: options,
            configManager: configManager,
            queue: queue,
            recorder: recorder,
            tracker: tracker
        )
        logger.debug("Viking started (config_version \(configManager.current.configVersion)).")
    }

    /// Adds Viking's interception to a custom URLSessionConfiguration.
    /// Use when your LLM client builds its own URLSession:
    /// `let config = URLSessionConfiguration.default; Viking.instrument(config)`
    public static func instrument(_ configuration: URLSessionConfiguration) {
        var protocols = configuration.protocolClasses ?? []
        let alreadyInstalled = protocols.contains {
            ObjectIdentifier($0) == ObjectIdentifier(VikingURLProtocol.self)
        }
        guard !alreadyInstalled else { return }
        protocols.insert(VikingURLProtocol.self, at: 0)
        configuration.protocolClasses = protocols
    }

    /// Measures a local inference run (Core ML, MLX, llama.cpp):
    /// duration, declared compute unit, thermal state, energy when the
    /// platform can measure it (otherwise null), and tokens reported
    /// through the measurement handle.
    ///
    /// ```swift
    /// let output = try Viking.inference(model: "coreml:sentiment-v2", computeUnit: .ane) { m in
    ///     let result = try model.prediction(input: input)
    ///     m.setTokens(input: 96, output: 1)
    ///     return result
    /// }
    /// ```
    public static func inference<T>(
        model: String,
        computeUnit: InferenceComputeUnit = .cpu,
        feature: String? = nil,
        _ body: (InferenceMeasurement) throws -> T
    ) rethrows -> T {
        guard let tracker = currentState()?.tracker else {
            return try body(InferenceMeasurement())
        }
        return try tracker.track(
            model: model, computeUnit: computeUnit, feature: feature, body: body
        )
    }

    /// Forces a queue flush (also happens on batch size, interval, and
    /// app backgrounding).
    public static func flush() {
        currentState()?.queue.flush(reason: "manual")
    }

    /// Current effective config (embedded defaults until a remote config
    /// has been fetched).
    public static var currentConfig: RemoteConfig? {
        currentState()?.configManager.current
    }

    // MARK: - Internals

    private static func currentState() -> VikingState? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return state
    }

    /// Test hook: resets the singleton between test cases.
    internal static func _resetForTesting() {
        stateLock.lock()
        defer { stateLock.unlock() }
        if state != nil {
            URLProtocol.unregisterClass(VikingURLProtocol.self)
            VikingURLProtocol.recorder = nil
        }
        state = nil
    }

    private static func isPublicKey(_ key: String) -> Bool {
        // vik_pub_ is the canonical prefix; vk_pub_ is accepted during the
        // credential-prefix transition and will be removed.
        key.hasPrefix("vik_pub_") || key.hasPrefix("vk_pub_")
    }

    private static func defaultStorageDirectory() -> URL {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("Viking", isDirectory: true)
    }
}

public struct VikingOptions: Sendable {
    /// Enables console logging of captured events. Never logs prompt or
    /// completion content, even in debug mode.
    public var debug: Bool
    /// Overrides the config endpoint base (defaults to Viking Cloud).
    public var configURL: URL?
    /// Project identifier used while running on embedded defaults.
    public var projectId: String?
    /// Registers interception for URLSession.shared traffic (default
    /// true). Custom sessions use `Viking.instrument(_:)` either way.
    public var interceptSharedSession: Bool
    /// Overrides where the SDK persists its queue and config cache.
    public var storageDirectory: URL?

    public init(
        debug: Bool = false,
        configURL: URL? = nil,
        projectId: String? = nil,
        interceptSharedSession: Bool = true,
        storageDirectory: URL? = nil
    ) {
        self.debug = debug
        self.configURL = configURL
        self.projectId = projectId
        self.interceptSharedSession = interceptSharedSession
        self.storageDirectory = storageDirectory
    }
}

public enum VikingError: Error, Equatable {
    case invalidAPIKey(String)
    case storageUnavailable(String)
}

struct VikingState {
    let apiKey: String
    let options: VikingOptions
    let configManager: RemoteConfigManager
    let queue: EventQueue
    let recorder: LLMCallRecorder
    let tracker: LocalInferenceTracker
}

/// Constants shared by every transport request (compat rule: the
/// X-SDK-Version header goes on every request).
public enum VikingSDKInfo {
    public static let name = "viking-swift"
    public static let version = "0.1.0"
    public static let versionHeader = "X-SDK-Version"
}
