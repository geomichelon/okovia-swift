import Foundation

/// Public entry point of the Viking SDK.
///
/// Phase 1 scope: one-line initialization with API-key validation and the
/// embedded-defaults config state. RemoteConfigManager (ETag fetch, disk
/// cache, foreground refresh), the event queue, and collectors arrive in
/// Phase 2 behind this same facade.
public enum Viking {
    private static let stateLock = NSLock()
    private static var state: VikingState?

    /// Initializes the SDK. Call once, as early as possible in app launch.
    ///
    /// - Parameters:
    ///   - apiKey: the project's PUBLIC key (`vik_pub_...`). Secret keys
    ///     (`vik_sec_...`) are server-side only and are rejected here so a
    ///     leaked-into-app secret fails fast in development.
    ///   - options: optional overrides (debug logging, endpoints).
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
            log(options: options, "Viking.start called more than once; ignoring.")
            return
        }

        let projectId = options.projectId ?? "unconfigured"
        state = VikingState(
            apiKey: apiKey,
            options: options,
            config: .embeddedDefaults(projectId: projectId)
        )
        log(options: options, "Viking started with embedded defaults (config_version 0).")
    }

    /// Current effective config (embedded defaults until a remote config
    /// has been fetched - Phase 2).
    public static var currentConfig: RemoteConfig? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return state?.config
    }

    /// Test hook: resets the singleton between test cases.
    internal static func _resetForTesting() {
        stateLock.lock()
        defer { stateLock.unlock() }
        state = nil
    }

    private static func isPublicKey(_ key: String) -> Bool {
        // vik_pub_ is the canonical prefix; vk_pub_ is accepted during the
        // credential-prefix transition and will be removed.
        key.hasPrefix("vik_pub_") || key.hasPrefix("vk_pub_")
    }

    private static func log(options: VikingOptions, _ message: String) {
        guard options.debug else { return }
        // Debug logs never include prompt/completion content or payloads.
        print("[Viking] \(message)")
    }
}

public struct VikingOptions: Sendable {
    /// Enables console logging of captured events. Never logs prompt or
    /// completion content, even in debug mode.
    public var debug: Bool
    /// Overrides the config endpoint (defaults to Viking Cloud).
    public var configURL: URL?
    /// Project identifier used while running on embedded defaults.
    public var projectId: String?

    public init(debug: Bool = false, configURL: URL? = nil, projectId: String? = nil) {
        self.debug = debug
        self.configURL = configURL
        self.projectId = projectId
    }
}

public enum VikingError: Error, Equatable {
    case invalidAPIKey(String)
}

struct VikingState {
    let apiKey: String
    let options: VikingOptions
    let config: RemoteConfig
}

/// Constants shared by every transport request (compat rule: the
/// X-SDK-Version header goes on every request).
public enum VikingSDKInfo {
    public static let name = "viking-swift"
    public static let version = "0.1.0"
    public static let versionHeader = "X-SDK-Version"
}
