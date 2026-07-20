import XCTest
@testable import Viking

final class RecorderAndTrackerTests: XCTestCase {
    private var tempDir: URL!
    private var store: SQLiteEventStore!
    private var queue: EventQueue!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("viking-recorder-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        store = try SQLiteEventStore(path: tempDir.appendingPathComponent("q.sqlite").path)
        queue = EventQueue(
            store: store,
            sender: ScriptedSender(results: []),
            apiKey: "vik_pub_t",
            config: testConfig(),
            logger: VikingLogger(enabled: false)
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func testConfig(llmApiEnabled: Bool = true, llmLocalEnabled: Bool = true) -> RemoteConfig {
        let base = RemoteConfig.embeddedDefaults(projectId: "prj_t")
        return RemoteConfig(
            schemaVersion: 1,
            configVersion: 5,
            projectId: "prj_t",
            environment: "test",
            collectors: RemoteConfig.Collectors(
                llmApi: .init(
                    enabled: llmApiEnabled,
                    interceptHosts: ["api.openai.com", "api.anthropic.com"],
                    capturePromptContent: false,
                    estimateTokensOnMissingUsage: true
                ),
                llmLocal: .init(enabled: llmLocalEnabled, frameworks: ["coreml"], captureEnergy: true),
                gpuSampling: .init(enabled: false, intervalMs: nil),
                ocr: .init(enabled: false)
            ),
            transport: RemoteConfig.Transport(
                endpoint: base.transport.endpoint,
                batchMaxEvents: 100,
                flushIntervalS: 3600,
                samplingRate: 1.0,
                maxQueueBytes: 5_242_880
            ),
            privacy: base.privacy
        )
    }

    private func storedEvents() throws -> [VikingEvent] {
        queue._drainForTesting()
        return try store.oldest(limit: 100).map {
            try JSONDecoder().decode(VikingEvent.self, from: $0.payload)
        }
    }

    private func fixture(_ name: String) throws -> Data {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: nil))
        return try Data(contentsOf: url)
    }

    // MARK: - Host matching (bounds the URLProtocol's invasiveness)

    func testMatchesOnlyConfiguredHostsWhileEnabled() {
        let recorder = LLMCallRecorder(queue: queue, config: testConfig(), logger: VikingLogger(enabled: false))

        XCTAssertTrue(recorder.matches(host: "api.openai.com"))
        XCTAssertTrue(recorder.matches(host: "api.anthropic.com"))
        XCTAssertFalse(recorder.matches(host: "api.example.com"))
        XCTAssertFalse(recorder.matches(host: nil))

        recorder.apply(testConfig(llmApiEnabled: false))
        XCTAssertFalse(recorder.matches(host: "api.openai.com"), "disabled collector must match nothing")
    }

    // MARK: - Recording provider responses

    func testRecordsAnthropicResponseWithCachedTokens() throws {
        let recorder = LLMCallRecorder(queue: queue, config: testConfig(), logger: VikingLogger(enabled: false))

        recorder.record(
            host: "api.anthropic.com",
            requestBodyChars: 1200,
            responseBody: try fixture("anthropic-message.json"),
            contentType: "application/json",
            durationMs: 3200
        )

        let events = try storedEvents()
        XCTAssertEqual(events.count, 1)
        let event = try XCTUnwrap(events.first)
        XCTAssertEqual(event.category, .llmInference)
        XCTAssertEqual(event.execution, .api)
        XCTAssertEqual(event.resource, "claude-sonnet-5")
        XCTAssertEqual(event.units?["input_tokens"], 412)
        XCTAssertEqual(event.units?["output_tokens"], 850)
        XCTAssertEqual(event.units?["cached_input_tokens"], 2048)
        XCTAssertEqual(event.compute?.durationMs, 3200)
        XCTAssertNil(event.estimated, "provider-reported usage is not estimated")
        // Contract parity: provider reported usage -> stream complete.
        XCTAssertEqual(event.attrs?["stream_status"], .string("complete"))
    }

    func testStreamStatusAndPromptHashOnRecordedEvent() throws {
        let recorder = LLMCallRecorder(queue: queue, config: testConfig(), logger: VikingLogger(enabled: false))

        // No usage in the body -> estimation fallback -> usage_missing.
        recorder.record(
            host: "api.openai.com",
            path: "/v1/chat/completions",
            requestBodyChars: 800,
            responseBody: Data("hello".utf8),
            contentType: "application/json",
            durationMs: 500,
            promptPrefixHash: "pfx_abc123"
        )

        let event = try XCTUnwrap(try storedEvents().first)
        XCTAssertEqual(event.attrs?["stream_status"], .string("usage_missing"))
        XCTAssertEqual(event.attrs?["prompt_prefix_hash"], .string("pfx_abc123"))
        XCTAssertEqual(event.estimated, true)
    }

    func testAnthropicRefusalBecomesItsOwnEventCategory() throws {
        let recorder = LLMCallRecorder(queue: queue, config: testConfig(), logger: VikingLogger(enabled: false))

        recorder.record(
            host: "api.anthropic.com",
            requestBodyChars: 300,
            responseBody: try fixture("anthropic-message-refusal.json"),
            contentType: "application/json",
            durationMs: 900
        )

        let event = try XCTUnwrap(try storedEvents().first)
        XCTAssertEqual(event.category, .llmRefusal)
        XCTAssertEqual(event.attrs?["stop_reason"], .string("refusal"))
    }

    func testStreamingWithoutUsageFallsBackToEstimation() throws {
        let recorder = LLMCallRecorder(queue: queue, config: testConfig(), logger: VikingLogger(enabled: false))

        recorder.record(
            host: "api.openai.com",
            requestBodyChars: 400,
            responseBody: try fixture("openai-chat-stream-no-usage.sse"),
            contentType: "text/event-stream; charset=utf-8",
            durationMs: 1500
        )

        let event = try XCTUnwrap(try storedEvents().first)
        XCTAssertEqual(event.estimated, true, "missing provider usage must be flagged as estimated")
        XCTAssertEqual(event.units?["input_tokens"], 100, "400 chars at ~4 chars/token")
        XCTAssertNotNil(event.units?["output_tokens"])
    }

    // MARK: - Local inference tracker

    func testInferenceTrackerMeasuresAndEnqueues() throws {
        let tracker = LocalInferenceTracker(
            queue: queue,
            config: testConfig(),
            energySampler: UnavailableEnergySampler()
        )

        let result = tracker.track(model: "coreml:sentiment-v2", computeUnit: .ane, feature: "inbox_triage") { measurement in
            measurement.setTokens(input: 96, output: 1)
            return "positive"
        }

        XCTAssertEqual(result, "positive")
        let event = try XCTUnwrap(try storedEvents().first)
        XCTAssertEqual(event.category, .llmInference)
        XCTAssertEqual(event.execution, .onDevice)
        XCTAssertEqual(event.resource, "coreml:sentiment-v2")
        XCTAssertEqual(event.units?["input_tokens"], 96)
        XCTAssertEqual(event.compute?.computeUnit, .ane)
        XCTAssertNil(event.compute?.energyMj, "energy unavailable -> null")
        XCTAssertNotNil(event.compute?.thermalState)
        XCTAssertEqual(event.attrs?["feature"], .string("inbox_triage"))
    }

    func testInferenceTrackerDisabledRunsBodyWithoutEvents() throws {
        let tracker = LocalInferenceTracker(
            queue: queue,
            config: testConfig(llmLocalEnabled: false),
            energySampler: UnavailableEnergySampler()
        )

        let result = tracker.track(model: "coreml:x", computeUnit: .cpu, feature: nil) { _ in 41 + 1 }

        XCTAssertEqual(result, 42, "customer code must run even with the collector off")
        XCTAssertEqual(try storedEvents().count, 0)
    }
}
