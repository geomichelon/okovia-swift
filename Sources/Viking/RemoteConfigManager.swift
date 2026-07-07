import Foundation
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Anything that reacts to config changes (collectors, the event
/// queue). apply is invoked once at startup and again whenever a NEW
/// config_version arrives - never twice for the same version.
protocol ConfigApplying: AnyObject {
    func apply(_ config: RemoteConfig)
}

/// Abstracts the conditional GET so tests can script 200/304/failure.
protocol ConfigFetching {
    /// Returns (body, etag) on 200, .notModified on 304, throws on error.
    func fetch(url: URL, etag: String?) async throws -> ConfigFetchResult
}

enum ConfigFetchResult {
    case success(body: Data, etag: String?)
    case notModified
}

/// Owns the config lifecycle, per architecture decision #1:
/// embedded defaults -> disk cache -> conditional GET with ETag (304 =
/// keep cache), refresh on foreground and every 15 minutes. A config
/// download failure NEVER breaks the SDK - the last known good config
/// (or the embedded defaults) stays active.
final class RemoteConfigManager {
    static let refreshInterval: TimeInterval = 15 * 60

    private let fetcher: ConfigFetching
    private let configURL: URL
    private let cacheFileURL: URL
    private let etagFileURL: URL
    private let logger: VikingLogger
    private let workQueue = DispatchQueue(label: "io.viking.remote-config")

    private var subscribers: [ConfigApplying] = []
    private var refreshTimer: DispatchSourceTimer?
    private(set) var current: RemoteConfig

    init(
        apiKey: String,
        options: VikingOptions,
        fetcher: ConfigFetching,
        cacheDirectory: URL,
        logger: VikingLogger
    ) {
        self.fetcher = fetcher
        self.logger = logger
        let base = options.configURL ?? URL(string: "https://config.viking.io")!
        self.configURL = base
            .appendingPathComponent("v1/projects")
            .appendingPathComponent(apiKey)
            .appendingPathComponent("config")
        self.cacheFileURL = cacheDirectory.appendingPathComponent("config.json")
        self.etagFileURL = cacheDirectory.appendingPathComponent("config.etag")

        // Boot order: disk cache beats embedded defaults; defaults are
        // only used when the SDK has never successfully downloaded.
        if let cached = try? Data(contentsOf: cacheFileURL),
           let config = try? RemoteConfig.decode(from: cached) {
            current = config
            logger.debug("config loaded from disk cache (version \(config.configVersion))")
        } else {
            current = .embeddedDefaults(projectId: options.projectId ?? "unconfigured")
            logger.debug("config using embedded defaults (version 0)")
        }
    }

    func subscribe(_ subscriber: ConfigApplying) {
        workQueue.async { [weak self] in
            guard let self else { return }
            self.subscribers.append(subscriber)
            subscriber.apply(self.current)
        }
    }

    func start() {
        refresh(reason: "startup")
        scheduleTimer()
        observeForeground()
    }

    func refresh(reason: String) {
        Task { [weak self] in
            await self?.performRefresh(reason: reason)
        }
    }

    private func performRefresh(reason: String) async {
        let storedEtag = try? String(contentsOf: etagFileURL, encoding: .utf8)
        do {
            let result = try await fetcher.fetch(url: configURL, etag: storedEtag)
            switch result {
            case .notModified:
                logger.debug("config refresh (\(reason)): 304, cache still current")
            case .success(let body, let etag):
                let config = try RemoteConfig.decode(from: body)
                workQueue.async { [weak self] in
                    self?.adopt(config: config, body: body, etag: etag, reason: reason)
                }
            }
        } catch {
            // Keep last known good config; failures never disable the SDK.
            logger.debug("config refresh (\(reason)) failed: \(error); keeping version \(current.configVersion)")
        }
    }

    /// Adoption is version-deduped: re-applying the same config_version
    /// is a no-op so collectors are not churned by identical configs.
    private func adopt(config: RemoteConfig, body: Data, etag: String?, reason: String) {
        guard config.configVersion != current.configVersion else {
            logger.debug("config refresh (\(reason)): same version \(config.configVersion), not re-applied")
            return
        }
        current = config
        try? body.write(to: cacheFileURL, options: .atomic)
        if let etag {
            try? etag.write(to: etagFileURL, atomically: true, encoding: .utf8)
        }
        logger.debug("config updated to version \(config.configVersion) (\(reason))")
        for subscriber in subscribers {
            subscriber.apply(config)
        }
    }

    private func scheduleTimer() {
        let timer = DispatchSource.makeTimerSource(queue: workQueue)
        timer.schedule(
            deadline: .now() + Self.refreshInterval,
            repeating: Self.refreshInterval
        )
        timer.setEventHandler { [weak self] in
            self?.refresh(reason: "interval")
        }
        timer.resume()
        refreshTimer = timer
    }

    private func observeForeground() {
        #if canImport(UIKit)
        NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.refresh(reason: "foreground")
        }
        #elseif canImport(AppKit)
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.refresh(reason: "foreground")
        }
        #endif
    }

    /// Test hook: waits for queued adoption work.
    func _drainForTesting() {
        workQueue.sync {}
    }
}

/// Production fetcher: plain conditional GET, designed so the endpoint
/// can live behind a CDN (the public key is in the URL path - the URL
/// itself is the cache key; no Authorization header to vary on).
struct URLSessionConfigFetcher: ConfigFetching {
    let session: URLSession

    init(session: URLSession = URLSession(configuration: .ephemeral)) {
        self.session = session
    }

    func fetch(url: URL, etag: String?) async throws -> ConfigFetchResult {
        var request = URLRequest(url: url)
        if let etag {
            request.setValue(etag, forHTTPHeaderField: "If-None-Match")
        }
        request.setValue(VikingSDKInfo.version, forHTTPHeaderField: VikingSDKInfo.versionHeader)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        switch http.statusCode {
        case 304:
            return .notModified
        case 200...299:
            let responseEtag = http.value(forHTTPHeaderField: "ETag")
            return .success(body: data, etag: responseEtag)
        default:
            throw URLError(.badServerResponse)
        }
    }
}
