import XCTest
@testable import Viking

/// Scriptable fetcher: each call pops the next scripted result.
final class ScriptedFetcher: ConfigFetching {
    enum Step {
        case success(config: RemoteConfig, etag: String?)
        case notModified
        case failure
    }

    private var steps: [Step]
    private var etags: [String?] = []
    private let syncQueue = DispatchQueue(label: "scripted-fetcher")

    init(steps: [Step]) {
        self.steps = steps
    }

    var receivedEtags: [String?] { syncQueue.sync { etags } }

    func fetch(url: URL, etag: String?) async throws -> ConfigFetchResult {
        let step: Step? = syncQueue.sync {
            etags.append(etag)
            return steps.isEmpty ? nil : steps.removeFirst()
        }
        switch step {
        case nil, .notModified:
            return .notModified
        case .success(let config, let etag):
            let body = try JSONEncoder().encode(config)
            return .success(body: body, etag: etag)
        case .failure:
            throw URLError(.notConnectedToInternet)
        }
    }
}

final class RecordingSubscriber: ConfigApplying {
    private(set) var applied: [Int] = []

    func apply(_ config: RemoteConfig) {
        applied.append(config.configVersion)
    }
}

final class RemoteConfigManagerTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("viking-config-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func makeConfig(version: Int) -> RemoteConfig {
        let base = RemoteConfig.embeddedDefaults(projectId: "prj_remote")
        return RemoteConfig(
            schemaVersion: base.schemaVersion,
            configVersion: version,
            projectId: base.projectId,
            environment: "production",
            collectors: base.collectors,
            transport: base.transport,
            privacy: base.privacy
        )
    }

    private func makeManager(fetcher: ScriptedFetcher) -> RemoteConfigManager {
        RemoteConfigManager(
            apiKey: "vik_pub_t",
            options: VikingOptions(projectId: "prj_local"),
            fetcher: fetcher,
            cacheDirectory: tempDir,
            logger: VikingLogger(enabled: false)
        )
    }

    private func waitForRefresh(_ manager: RemoteConfigManager) {
        // performRefresh hops fetch (async) -> workQueue; poll briefly.
        for _ in 0..<50 {
            manager._drainForTesting()
            usleep(10_000)
        }
    }

    func testBootsOnEmbeddedDefaultsWithoutCache() {
        let manager = makeManager(fetcher: ScriptedFetcher(steps: []))

        XCTAssertEqual(manager.current.configVersion, 0)
        XCTAssertEqual(manager.current.projectId, "prj_local")
    }

    func testSuccessfulFetchAdoptsPersistsAndNotifies() {
        let fetcher = ScriptedFetcher(steps: [.success(config: makeConfig(version: 42), etag: "\"v42\"")])
        let manager = makeManager(fetcher: fetcher)
        let subscriber = RecordingSubscriber()
        manager.subscribe(subscriber)
        manager._drainForTesting()

        manager.refresh(reason: "test")
        waitForRefresh(manager)

        XCTAssertEqual(manager.current.configVersion, 42)
        // subscriber saw defaults (0) on subscribe, then 42 on adopt
        XCTAssertEqual(subscriber.applied, [0, 42])
        // cache + etag persisted for the next boot / conditional GET
        XCTAssertTrue(FileManager.default.fileExists(atPath: tempDir.appendingPathComponent("config.json").path))
        XCTAssertEqual(
            try String(contentsOf: tempDir.appendingPathComponent("config.etag"), encoding: .utf8),
            "\"v42\""
        )
    }

    func testSecondManagerBootsFromDiskCache() {
        let fetcher = ScriptedFetcher(steps: [.success(config: makeConfig(version: 42), etag: "\"v42\"")])
        let first = makeManager(fetcher: fetcher)
        first.refresh(reason: "test")
        waitForRefresh(first)
        XCTAssertEqual(first.current.configVersion, 42)

        // New process simulation: fresh manager, same cache directory.
        let second = makeManager(fetcher: ScriptedFetcher(steps: []))
        XCTAssertEqual(second.current.configVersion, 42, "disk cache must beat embedded defaults")
    }

    func testEtagIsSentOnSubsequentFetch() {
        let fetcher = ScriptedFetcher(steps: [
            .success(config: makeConfig(version: 42), etag: "\"v42\""),
            .notModified
        ])
        let manager = makeManager(fetcher: fetcher)

        manager.refresh(reason: "first")
        waitForRefresh(manager)
        manager.refresh(reason: "second")
        waitForRefresh(manager)

        XCTAssertEqual(fetcher.receivedEtags.count, 2)
        XCTAssertNil(fetcher.receivedEtags[0])
        XCTAssertEqual(fetcher.receivedEtags[1], "\"v42\"", "second fetch must send If-None-Match")
        XCTAssertEqual(manager.current.configVersion, 42, "304 must keep the cached config")
    }

    func testSameVersionIsNotReappliedToSubscribers() {
        // Config dedup: applying an identical config_version twice must
        // not churn collectors.
        let fetcher = ScriptedFetcher(steps: [
            .success(config: makeConfig(version: 42), etag: nil),
            .success(config: makeConfig(version: 42), etag: nil)
        ])
        let manager = makeManager(fetcher: fetcher)
        let subscriber = RecordingSubscriber()
        manager.subscribe(subscriber)
        manager._drainForTesting()

        manager.refresh(reason: "first")
        waitForRefresh(manager)
        manager.refresh(reason: "second")
        waitForRefresh(manager)

        XCTAssertEqual(subscriber.applied, [0, 42], "version 42 must be applied exactly once")
    }

    func testFetchFailureKeepsLastKnownGoodConfig() {
        let fetcher = ScriptedFetcher(steps: [
            .success(config: makeConfig(version: 42), etag: nil),
            .failure
        ])
        let manager = makeManager(fetcher: fetcher)

        manager.refresh(reason: "first")
        waitForRefresh(manager)
        manager.refresh(reason: "second")
        waitForRefresh(manager)

        XCTAssertEqual(manager.current.configVersion, 42, "failures must never downgrade the config")
    }
}
