import XCTest
@testable import Viking

final class UsageParserTests: XCTestCase {
    private func fixture(_ name: String) throws -> Data {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: nil),
            "missing fixture \(name)"
        )
        return try Data(contentsOf: url)
    }

    private func fixtureText(_ name: String) throws -> String {
        String(decoding: try fixture(name), as: UTF8.self)
    }

    // MARK: - OpenAI non-streaming

    func testOpenAINonStreamingUsage() throws {
        let usage = try XCTUnwrap(OpenAIUsageParser.parse(json: fixture("openai-chat-completion.json")))

        XCTAssertEqual(usage.model, "gpt-4.1-2025-04-14")
        XCTAssertEqual(usage.inputTokens, 412)
        XCTAssertEqual(usage.outputTokens, 850)
        XCTAssertEqual(usage.cachedInputTokens, 256)
        XCTAssertEqual(usage.stopReason, "stop")
        XCTAssertFalse(usage.estimated)
        XCTAssertEqual(usage.units["cached_input_tokens"], 256)
    }

    // MARK: - OpenAI streaming

    func testOpenAIStreamingWithIncludeUsage() throws {
        let usage = try XCTUnwrap(OpenAIUsageParser.parse(sse: fixtureText("openai-chat-stream.sse")))

        XCTAssertEqual(usage.model, "gpt-4.1-2025-04-14")
        XCTAssertEqual(usage.inputTokens, 128)
        XCTAssertEqual(usage.outputTokens, 74)
        XCTAssertEqual(usage.stopReason, "stop")
        // cached_tokens 0 must not produce a units entry
        XCTAssertNil(usage.units["cached_input_tokens"])
    }

    func testOpenAIStreamingWithoutIncludeUsageHasNoTokenCounts() throws {
        // Without stream_options.include_usage, the stream never carries
        // usage - the interceptor must fall back to estimation.
        let usage = try XCTUnwrap(
            OpenAIUsageParser.parse(sse: fixtureText("openai-chat-stream-no-usage.sse"))
        )

        XCTAssertEqual(usage.model, "gpt-4.1-2025-04-14")
        XCTAssertNil(usage.inputTokens)
        XCTAssertNil(usage.outputTokens)
    }

    // MARK: - Anthropic non-streaming

    func testAnthropicNonStreamingUsageWithCacheReads() throws {
        let usage = try XCTUnwrap(AnthropicUsageParser.parse(json: fixture("anthropic-message.json")))

        XCTAssertEqual(usage.model, "claude-sonnet-5")
        XCTAssertEqual(usage.inputTokens, 412)
        XCTAssertEqual(usage.outputTokens, 850)
        XCTAssertEqual(usage.cachedInputTokens, 2048)
        XCTAssertEqual(usage.stopReason, "end_turn")
        XCTAssertFalse(usage.isRefusal)
    }

    func testAnthropicRefusalIsDetected() throws {
        let usage = try XCTUnwrap(
            AnthropicUsageParser.parse(json: fixture("anthropic-message-refusal.json"))
        )

        XCTAssertEqual(usage.stopReason, "refusal")
        XCTAssertTrue(usage.isRefusal)
        XCTAssertEqual(usage.model, "claude-fable-5")
    }

    // MARK: - Anthropic streaming

    func testAnthropicStreamingMergesMessageStartAndDelta() throws {
        // input_tokens arrive on message_start; the FINAL output_tokens
        // and stop_reason arrive on message_delta.
        let usage = try XCTUnwrap(
            AnthropicUsageParser.parse(sse: fixtureText("anthropic-message-stream.sse"))
        )

        XCTAssertEqual(usage.model, "claude-sonnet-5")
        XCTAssertEqual(usage.inputTokens, 355)
        XCTAssertEqual(usage.outputTokens, 642, "must use the final message_delta count, not message_start's 2")
        XCTAssertEqual(usage.cachedInputTokens, 1024)
        XCTAssertEqual(usage.stopReason, "end_turn")
    }

    // MARK: - Provider host mapping

    func testProviderForHost() {
        XCTAssertEqual(LLMProvider.forHost("api.openai.com"), .openai)
        XCTAssertEqual(LLMProvider.forHost("api.anthropic.com"), .anthropic)
        XCTAssertNil(LLMProvider.forHost("api.example.com"))
    }

    // MARK: - Token estimation fallback

    func testTokenEstimatorBaseRate() {
        // ~4 chars/token
        XCTAssertEqual(TokenEstimator.estimateTokens(charCount: 400, model: nil), 100)
        XCTAssertEqual(TokenEstimator.estimateTokens(charCount: 0, model: nil), 0)
        XCTAssertEqual(TokenEstimator.estimateTokens(charCount: 2, model: nil), 1, "at least 1 token for non-empty text")
    }

    func testTokenEstimatorPerFamilyFactor() {
        XCTAssertEqual(TokenEstimator.charsPerToken(model: "claude-sonnet-5"), 3.8)
        XCTAssertEqual(TokenEstimator.charsPerToken(model: "gpt-4.1"), 4.0)
        XCTAssertEqual(TokenEstimator.charsPerToken(model: nil), 4.0)
        // claude estimates more tokens for the same text
        let claudeTokens = TokenEstimator.estimateTokens(charCount: 380, model: "claude-sonnet-5")
        XCTAssertEqual(claudeTokens, 100)
    }
}

extension UsageParserTests {
    func testForRequestInfersProviderFromPathOnLoopbackOnly() {
        XCTAssertEqual(LLMProvider.forRequest(host: "localhost", path: "/v1/chat/completions"), .openai)
        XCTAssertEqual(LLMProvider.forRequest(host: "127.0.0.1", path: "/v1/messages"), .anthropic)
        XCTAssertNil(LLMProvider.forRequest(host: "localhost", path: "/unrelated"))
        // Real hosts are never inferred from path - only from the host itself.
        XCTAssertNil(LLMProvider.forRequest(host: "example.com", path: "/v1/chat/completions"))
        XCTAssertEqual(LLMProvider.forRequest(host: "api.openai.com", path: "/anything"), .openai)
    }
}
