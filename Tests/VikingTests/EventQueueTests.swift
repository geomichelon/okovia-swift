import XCTest
@testable import Viking

/// Test double: scriptable transport for offline/retry scenarios.
final class ScriptedSender: IngestSending {
    private var results: [Bool]
    private var bodies: [Data] = []
    private let syncQueue = DispatchQueue(label: "scripted-sender")

    init(results: [Bool]) {
        self.results = results
    }

    var sentBodies: [Data] { syncQueue.sync { bodies } }

    func send(body: Data, endpoint: URL, apiKey: String) async -> Bool {
        syncQueue.sync {
            bodies.append(body)
            return results.isEmpty ? true : results.removeFirst()
        }
    }
}

final class EventQueueTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("viking-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func makeStore() throws -> SQLiteEventStore {
        try SQLiteEventStore(path: tempDir.appendingPathComponent("queue.sqlite").path)
    }

    private func makeConfig(
        batchMax: Int = 50,
        samplingRate: Double = 1.0,
        maxQueueBytes: Int = 5_242_880
    ) -> RemoteConfig {
        RemoteConfig(
            schemaVersion: 1,
            configVersion: 7,
            projectId: "prj_test",
            environment: "test",
            collectors: RemoteConfig.Collectors(
                llmApi: .init(
                    enabled: true,
                    interceptHosts: ["api.openai.com", "api.anthropic.com"],
                    capturePromptContent: false,
                    estimateTokensOnMissingUsage: true
                ),
                llmLocal: .init(enabled: true, frameworks: nil, captureEnergy: false),
                gpuSampling: .init(enabled: false, intervalMs: nil),
                ocr: .init(enabled: false)
            ),
            transport: RemoteConfig.Transport(
                endpoint: URL(string: "https://ingest.viking.io/v1/ingest")!,
                batchMaxEvents: batchMax,
                flushIntervalS: 3600,
                samplingRate: samplingRate,
                maxQueueBytes: maxQueueBytes
            ),
            privacy: RemoteConfig.Privacy(redactFields: ["tenant_secret"], hashUserIds: true)
        )
    }

    private func makeEvent(feature: String = "chat") -> VikingEvent {
        VikingEvent(
            category: .llmInference,
            execution: .api,
            resource: "claude-sonnet-5",
            units: ["input_tokens": 10, "output_tokens": 20],
            compute: .init(durationMs: 120),
            attrs: ["feature": .string(feature)]
        )
    }

    // MARK: - Offline durability

    func testEventsSurviveFailedFlushForRetry() throws {
        let store = try makeStore()
        let sender = ScriptedSender(results: [false, true])
        let queue = EventQueue(
            store: store, sender: sender, apiKey: "vik_pub_t",
            config: makeConfig(), logger: VikingLogger(enabled: false)
        )

        queue.enqueue(makeEvent())
        queue._drainForTesting()
        queue.flush(reason: "test")
        queue._drainForTesting()

        // Send failed: event must still be on disk.
        XCTAssertEqual(try store.count(), 1, "failed flush must keep events for retry")

        // Force past the backoff window by resetting failure clock via a
        // fresh queue over the SAME database (also proves crash survival).
        let queue2 = EventQueue(
            store: store, sender: sender, apiKey: "vik_pub_t",
            config: makeConfig(), logger: VikingLogger(enabled: false)
        )
        queue2.flush(reason: "retry")
        queue2._drainForTesting()

        XCTAssertEqual(try store.count(), 0, "successful retry must clear the queue")
        XCTAssertEqual(sender.sentBodies.count, 2)
    }

    func testFlushSendsGzippedContractEnvelope() throws {
        let store = try makeStore()
        let sender = ScriptedSender(results: [true])
        let queue = EventQueue(
            store: store, sender: sender, apiKey: "vik_pub_t",
            config: makeConfig(), logger: VikingLogger(enabled: false)
        )

        queue.enqueue(makeEvent())
        queue._drainForTesting()
        queue.flush(reason: "test")
        queue._drainForTesting()

        let body = try XCTUnwrap(sender.sentBodies.first)
        // gzip magic bytes prove Content-Encoding is honest
        XCTAssertEqual(body.prefix(2), Data([0x1f, 0x8b]))

        let json = try Gzip.decompress(body)
        let envelope = try JSONSerialization.jsonObject(with: json) as? [String: Any]
        XCTAssertEqual((envelope?["sdk"] as? [String: Any])?["name"] as? String, "viking-swift")
        XCTAssertEqual(envelope?["config_version"] as? Int, 7)
        let events = envelope?["events"] as? [[String: Any]]
        XCTAssertEqual(events?.count, 1)
        XCTAssertEqual(events?.first?["category"] as? String, "llm_inference")
        XCTAssertNotNil((envelope?["device"] as? [String: Any])?["install_id"])
    }

    // MARK: - Batch trigger

    func testReachingBatchSizeTriggersFlush() throws {
        let store = try makeStore()
        let sender = ScriptedSender(results: [true])
        let queue = EventQueue(
            store: store, sender: sender, apiKey: "vik_pub_t",
            config: makeConfig(batchMax: 3), logger: VikingLogger(enabled: false)
        )

        for _ in 0..<3 {
            queue.enqueue(makeEvent())
        }
        queue._drainForTesting()

        XCTAssertEqual(sender.sentBodies.count, 1, "hitting batch_max_events must flush")
        XCTAssertEqual(try store.count(), 0)
    }

    // MARK: - Queue byte cap

    func testTrimDropsOldestWhenOverMaxQueueBytes() throws {
        let store = try makeStore()
        // Enqueue directly to the store to control sizes precisely.
        for index in 0..<10 {
            let payload = Data(repeating: UInt8(index), count: 1000)
            try store.insert(eventId: "evt-\(index)", payload: payload)
        }
        XCTAssertEqual(try store.totalBytes(), 10_000)

        let dropped = try store.trim(toMaxBytes: 4000)

        XCTAssertGreaterThan(dropped, 0)
        XCTAssertLessThanOrEqual(try store.totalBytes(), 4000)
        // Oldest must be gone, newest kept.
        let remaining = try store.oldest(limit: 100)
        XCTAssertTrue(remaining.allSatisfy { $0.payload.first! >= 6 }, "oldest events must be dropped first")
    }

    // MARK: - Dedup

    func testDuplicateEventIdIsIgnoredLocally() throws {
        let store = try makeStore()
        try store.insert(eventId: "same-id", payload: Data([1]))
        let insertedAgain = try store.insert(eventId: "same-id", payload: Data([2]))

        XCTAssertFalse(insertedAgain)
        XCTAssertEqual(try store.count(), 1)
    }

    // MARK: - Sampling

    func testSamplingRateZeroDropsEverything() throws {
        let store = try makeStore()
        let queue = EventQueue(
            store: store, sender: ScriptedSender(results: []), apiKey: "vik_pub_t",
            config: makeConfig(samplingRate: 0.0), logger: VikingLogger(enabled: false),
            random: { 0.5 }
        )

        queue.enqueue(makeEvent())
        queue._drainForTesting()

        XCTAssertEqual(try store.count(), 0)
    }

    func testSamplingRateAppliesDeterministically() throws {
        let store = try makeStore()
        var rolls: [Double] = [0.2, 0.8] // first passes (< 0.5), second dropped
        let queue = EventQueue(
            store: store, sender: ScriptedSender(results: []), apiKey: "vik_pub_t",
            config: makeConfig(samplingRate: 0.5), logger: VikingLogger(enabled: false),
            random: { rolls.removeFirst() }
        )

        queue.enqueue(makeEvent())
        queue.enqueue(makeEvent())
        queue._drainForTesting()

        XCTAssertEqual(try store.count(), 1)
    }

    // MARK: - Redaction on the way in

    func testRedactionHappensBeforePersistence() throws {
        let store = try makeStore()
        let queue = EventQueue(
            store: store, sender: ScriptedSender(results: []), apiKey: "vik_pub_t",
            config: makeConfig(), logger: VikingLogger(enabled: false)
        )

        let event = VikingEvent(
            category: .llmInference,
            execution: .api,
            resource: "claude-sonnet-5",
            attrs: [
                "feature": .string("chat"),
                "prompt": .string("NEVER-PERSIST-THIS"),
                "tenant_secret": .string("NEVER-PERSIST-THIS-EITHER")
            ]
        )
        queue.enqueue(event)
        queue._drainForTesting()

        let stored = try XCTUnwrap(try store.oldest(limit: 1).first)
        let persisted = String(decoding: stored.payload, as: UTF8.self)
        XCTAssertFalse(persisted.contains("NEVER-PERSIST-THIS"))
        XCTAssertTrue(persisted.contains("feature"))
    }

    // MARK: - Backoff

    func testBackoffDelayGrowsExponentiallyAndCaps() throws {
        let queue = EventQueue(
            store: try makeStore(), sender: ScriptedSender(results: []), apiKey: "vik_pub_t",
            config: makeConfig(), logger: VikingLogger(enabled: false)
        )

        XCTAssertEqual(queue.backoffDelay(failures: 1), 2)
        XCTAssertEqual(queue.backoffDelay(failures: 3), 8)
        XCTAssertEqual(queue.backoffDelay(failures: 20), 300, "backoff must cap")
    }
}
