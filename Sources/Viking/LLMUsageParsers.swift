import Foundation

/// Provider-reported usage extracted from an LLM API response.
struct ParsedLLMUsage: Equatable {
    var model: String?
    var inputTokens: Int?
    var outputTokens: Int?
    var cachedInputTokens: Int?
    var stopReason: String?
    var estimated: Bool = false

    var isRefusal: Bool { stopReason == "refusal" }

    var units: [String: Int] {
        var units: [String: Int] = [:]
        if let inputTokens { units["input_tokens"] = inputTokens }
        if let outputTokens { units["output_tokens"] = outputTokens }
        if let cachedInputTokens, cachedInputTokens > 0 {
            units["cached_input_tokens"] = cachedInputTokens
        }
        return units
    }
}

enum LLMProvider: String {
    case openai
    case anthropic

    /// Host matching for the interceptor. The config's intercept_hosts
    /// decides WHICH hosts to touch; this decides HOW to parse them.
    static func forHost(_ host: String) -> LLMProvider? {
        if host.contains("openai") { return .openai }
        if host.contains("anthropic") { return .anthropic }
        return nil
    }
}

// MARK: - OpenAI

/// Parses chat.completions responses.
/// Non-streaming: `usage.prompt_tokens` / `usage.completion_tokens`,
/// cached tokens in `usage.prompt_tokens_details.cached_tokens`.
/// Streaming SSE: usage arrives in a final chunk only when the caller
/// set `stream_options: {"include_usage": true}` - without it the
/// stream has no usage and the caller must fall back to estimation.
enum OpenAIUsageParser {
    static func parse(json data: Data) -> ParsedLLMUsage? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return nil
        }
        return parse(object: root)
    }

    static func parse(sse text: String) -> ParsedLLMUsage? {
        var merged: ParsedLLMUsage?
        for payload in SSE.dataPayloads(in: text) {
            guard payload != "[DONE]",
                  let data = payload.data(using: .utf8),
                  let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            else { continue }

            if let chunk = parse(object: object) {
                var current = merged ?? ParsedLLMUsage()
                if chunk.model != nil { current.model = chunk.model }
                if chunk.inputTokens != nil { current.inputTokens = chunk.inputTokens }
                if chunk.outputTokens != nil { current.outputTokens = chunk.outputTokens }
                if chunk.cachedInputTokens != nil { current.cachedInputTokens = chunk.cachedInputTokens }
                if chunk.stopReason != nil { current.stopReason = chunk.stopReason }
                merged = current
            }
        }
        return merged
    }

    private static func parse(object: [String: Any]) -> ParsedLLMUsage? {
        var usage = ParsedLLMUsage()
        usage.model = object["model"] as? String

        if let choices = object["choices"] as? [[String: Any]],
           let finish = choices.first?["finish_reason"] as? String {
            usage.stopReason = finish
        }

        if let usageObject = object["usage"] as? [String: Any] {
            usage.inputTokens = usageObject["prompt_tokens"] as? Int
            usage.outputTokens = usageObject["completion_tokens"] as? Int
            if let details = usageObject["prompt_tokens_details"] as? [String: Any] {
                usage.cachedInputTokens = details["cached_tokens"] as? Int
            }
        }

        let hasSignal = usage.model != nil || usage.inputTokens != nil
            || usage.outputTokens != nil || usage.stopReason != nil
        return hasSignal ? usage : nil
    }
}

// MARK: - Anthropic

/// Parses Messages API responses.
/// Non-streaming: `usage.input_tokens` / `usage.output_tokens`, cache
/// reads in `usage.cache_read_input_tokens`, and `stop_reason` - where
/// "refusal" must become its own llm_refusal event.
/// Streaming SSE: input tokens arrive on `message_start`; the FINAL
/// output_tokens and stop_reason arrive on `message_delta`.
enum AnthropicUsageParser {
    static func parse(json data: Data) -> ParsedLLMUsage? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return nil
        }
        var usage = ParsedLLMUsage()
        usage.model = root["model"] as? String
        usage.stopReason = root["stop_reason"] as? String
        apply(usageObject: root["usage"] as? [String: Any], to: &usage)

        let hasSignal = usage.model != nil || usage.inputTokens != nil || usage.stopReason != nil
        return hasSignal ? usage : nil
    }

    static func parse(sse text: String) -> ParsedLLMUsage? {
        var merged: ParsedLLMUsage?
        for payload in SSE.dataPayloads(in: text) {
            guard let data = payload.data(using: .utf8),
                  let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let type = object["type"] as? String
            else { continue }

            var current = merged ?? ParsedLLMUsage()
            switch type {
            case "message_start":
                if let message = object["message"] as? [String: Any] {
                    current.model = message["model"] as? String
                    apply(usageObject: message["usage"] as? [String: Any], to: &current)
                }
            case "message_delta":
                if let delta = object["delta"] as? [String: Any],
                   let stop = delta["stop_reason"] as? String {
                    current.stopReason = stop
                }
                // message_delta usage carries the FINAL cumulative
                // output_tokens; later deltas override earlier ones.
                apply(usageObject: object["usage"] as? [String: Any], to: &current)
            default:
                continue
            }
            merged = current
        }
        return merged
    }

    private static func apply(usageObject: [String: Any]?, to usage: inout ParsedLLMUsage) {
        guard let usageObject else { return }
        if let input = usageObject["input_tokens"] as? Int { usage.inputTokens = input }
        if let output = usageObject["output_tokens"] as? Int { usage.outputTokens = output }
        if let cached = usageObject["cache_read_input_tokens"] as? Int {
            usage.cachedInputTokens = cached
        }
    }
}

// MARK: - SSE

enum SSE {
    /// Extracts the payload of every `data:` line in an SSE stream.
    static func dataPayloads(in text: String) -> [String] {
        text.split(separator: "\n", omittingEmptySubsequences: true).compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("data:") else { return nil }
            return String(trimmed.dropFirst(5)).trimmingCharacters(in: .whitespaces)
        }
    }

    static func isEventStream(contentType: String?) -> Bool {
        contentType?.lowercased().contains("text/event-stream") ?? false
    }
}

// MARK: - Token estimation fallback

/// Fallback when the provider response carries no usage (e.g. OpenAI
/// streams without include_usage). ~4 chars per token, adjusted by a
/// per-model-family factor. Events built from estimates always carry
/// `estimated: true`.
///
/// Only LENGTHS of request/response text are used - the content itself
/// is never stored or logged.
enum TokenEstimator {
    static let baseCharsPerToken = 4.0

    static func charsPerToken(model: String?) -> Double {
        guard let model = model?.lowercased() else { return baseCharsPerToken }
        if model.contains("claude") { return 3.8 }
        if model.contains("gpt") || model.contains("o1") || model.contains("o3") {
            return 4.0
        }
        return baseCharsPerToken
    }

    static func estimateTokens(charCount: Int, model: String?) -> Int {
        guard charCount > 0 else { return 0 }
        return max(1, Int((Double(charCount) / charsPerToken(model: model)).rounded()))
    }
}
