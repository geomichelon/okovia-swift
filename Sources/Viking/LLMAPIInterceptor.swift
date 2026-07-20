import Foundation

/// Turns a completed LLM API call into VikingEvents on the queue.
final class LLMCallRecorder: ConfigApplying {
    private let queue: EventQueue
    private let logger: VikingLogger
    private var config: RemoteConfig

    init(queue: EventQueue, config: RemoteConfig, logger: VikingLogger) {
        self.queue = queue
        self.config = config
        self.logger = logger
    }

    func apply(_ config: RemoteConfig) {
        self.config = config
    }

    var isEnabled: Bool { config.collectors.llmApi?.enabled ?? false }

    func matches(host: String?) -> Bool {
        guard isEnabled, let host else { return false }
        let hosts = config.collectors.llmApi?.interceptHosts ?? []
        return hosts.contains { host == $0 || host.hasSuffix(".\($0)") }
    }

    func record(
        host: String,
        path: String = "",
        requestBodyChars: Int,
        responseBody: Data,
        contentType: String?,
        durationMs: Int,
        // Salted on-device hash of the request-body prefix (never the
        // content). Feeds the cache-off recommendation rule.
        promptPrefixHash: String? = nil
    ) {
        guard let provider = LLMProvider.forRequest(host: host, path: path) else { return }

        var usage = parseUsage(provider: provider, body: responseBody, contentType: contentType)
        let providerReportedUsage = usage?.inputTokens != nil

        // Fallback estimation (~4 chars/token with a per-model-family
        // factor) when the provider reported no usage - e.g. OpenAI
        // streams without stream_options.include_usage. Only text
        // LENGTHS are used; content is never stored.
        let estimateEnabled = config.collectors.llmApi?.estimateTokensOnMissingUsage ?? true
        if usage?.inputTokens == nil, estimateEnabled {
            var estimatedUsage = usage ?? ParsedLLMUsage()
            estimatedUsage.inputTokens = TokenEstimator.estimateTokens(
                charCount: requestBodyChars, model: estimatedUsage.model
            )
            if estimatedUsage.outputTokens == nil {
                let responseChars = SSE.isEventStream(contentType: contentType)
                    ? responseBody.count / 4  // rough visible-text share of SSE framing
                    : responseBody.count
                estimatedUsage.outputTokens = TokenEstimator.estimateTokens(
                    charCount: responseChars, model: estimatedUsage.model
                )
            }
            estimatedUsage.estimated = true
            usage = estimatedUsage
        }

        guard let usage else { return }

        // Anthropic stop_reason "refusal" becomes its own event so
        // refusal cost/frequency is analyzable per feature.
        let category: VikingEvent.Category = usage.isRefusal ? .llmRefusal : .llmInference

        // Contract parity with the other SDKs: whether the provider
        // reported usage (complete) or we had to estimate (usage_missing).
        var attrs: [String: VikingEvent.AttrValue] = [:]
        if let stopReason = usage.stopReason {
            attrs["stop_reason"] = .string(stopReason)
        }
        attrs["stream_status"] = .string(providerReportedUsage ? "complete" : "usage_missing")
        if let promptPrefixHash {
            attrs["prompt_prefix_hash"] = .string(promptPrefixHash)
        }

        let event = VikingEvent(
            category: category,
            execution: .api,
            resource: usage.model ?? provider.rawValue,
            units: usage.units.isEmpty ? nil : usage.units,
            compute: .init(durationMs: durationMs),
            attrs: attrs.isEmpty ? nil : attrs,
            estimated: usage.estimated ? true : nil
        )
        queue.enqueue(event)
    }

    private func parseUsage(
        provider: LLMProvider,
        body: Data,
        contentType: String?
    ) -> ParsedLLMUsage? {
        if SSE.isEventStream(contentType: contentType) {
            let text = String(decoding: body, as: UTF8.self)
            switch provider {
            case .openai: return OpenAIUsageParser.parse(sse: text)
            case .anthropic: return AnthropicUsageParser.parse(sse: text)
            }
        }
        switch provider {
        case .openai: return OpenAIUsageParser.parse(json: body)
        case .anthropic: return AnthropicUsageParser.parse(json: body)
        }
    }
}

/// Interception mechanism: URLProtocol, chosen over a URLSession
/// delegate wrapper. Trade-off, evaluated per the spec:
///
/// - URLProtocol (chosen): zero integration for URLSession.shared
///   callers - Viking.start alone captures the common case - and
///   `Viking.instrument(_:)` covers custom sessions with one line.
///   Invasiveness is bounded at `canInit`: the protocol claims ONLY
///   requests whose host matches the remote config's intercept_hosts
///   while the llm_api collector is enabled; every other request is
///   untouched. Risk: proxying re-issues the request on an internal
///   session, so exotic per-task delegate behaviors on intercepted
///   LLM calls may differ; bodies are buffered with a hard cap.
/// - URLSession delegate wrapper (rejected): no proxying and no global
///   registration, but the developer must route every LLM call through
///   a Viking-provided session - invasive to THEIR code, easy to
///   forget, and impossible for calls made inside third-party SDKs.
public final class VikingURLProtocol: URLProtocol {
    static var recorder: LLMCallRecorder?
    private static let handledKey = "io.viking.handled"
    private static let maxBufferedBytes = 4 * 1024 * 1024

    private var proxySession: URLSession?
    private var proxyTask: URLSessionDataTask?
    private var buffer = Data()
    private var response: URLResponse?
    private var startedAt = Date()

    override public class func canInit(with request: URLRequest) -> Bool {
        guard URLProtocol.property(forKey: handledKey, in: request) == nil else { return false }
        guard let recorder = Self.recorder else { return false }
        return recorder.matches(host: request.url?.host)
    }

    override public class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override public func startLoading() {
        startedAt = Date()
        guard let mutableRequest = (request as NSURLRequest).mutableCopy() as? NSMutableURLRequest else {
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
            return
        }
        URLProtocol.setProperty(true, forKey: Self.handledKey, in: mutableRequest)

        let session = URLSession(
            configuration: .ephemeral,
            delegate: ProxyDelegate(owner: self),
            delegateQueue: nil
        )
        proxySession = session
        proxyTask = session.dataTask(with: mutableRequest as URLRequest)
        proxyTask?.resume()
    }

    override public func stopLoading() {
        proxyTask?.cancel()
        proxySession?.invalidateAndCancel()
    }

    // MARK: - Proxy callbacks

    fileprivate func received(response: URLResponse) {
        self.response = response
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    }

    fileprivate func received(data: Data) {
        // Forward immediately so SSE streaming stays incremental for
        // the caller; buffer (capped) for usage parsing at the end.
        client?.urlProtocol(self, didLoad: data)
        if buffer.count < Self.maxBufferedBytes {
            buffer.append(data.prefix(Self.maxBufferedBytes - buffer.count))
        }
    }

    fileprivate func completed(error: Error?) {
        defer { proxySession?.finishTasksAndInvalidate() }

        if let error {
            client?.urlProtocol(self, didFailWithError: error)
            return
        }

        if let http = response as? HTTPURLResponse, let host = request.url?.host {
            let durationMs = Int(Date().timeIntervalSince(startedAt) * 1000)
            if (200...299).contains(http.statusCode) {
                Self.recorder?.record(
                    host: host,
                    path: request.url?.path ?? "",
                    requestBodyChars: requestBodyCharCount(),
                    responseBody: buffer,
                    contentType: http.value(forHTTPHeaderField: "Content-Type"),
                    durationMs: durationMs,
                    promptPrefixHash: promptPrefixHash()
                )
            }
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    /// Salted on-device hash of the request-body prefix. Only computed
    /// from an in-memory httpBody (Data); a streamed body is read once
    /// for the char count, so we skip hashing it rather than consume the
    /// stream twice. The content is hashed and immediately discarded -
    /// only the digest is emitted.
    private func promptPrefixHash() -> String? {
        guard let body = request.httpBody, !body.isEmpty else { return nil }
        return PromptHasher.prefixHash(of: body, salt: DeviceIdentity.installId())
    }

    /// Character count only - the body content is never retained.
    private func requestBodyCharCount() -> Int {
        if let body = request.httpBody { return body.count }
        if let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var count = 0
            let bufferSize = 16_384
            var chunk = [UInt8](repeating: 0, count: bufferSize)
            while stream.hasBytesAvailable {
                let read = stream.read(&chunk, maxLength: bufferSize)
                if read <= 0 { break }
                count += read
            }
            return count
        }
        return 0
    }

    private final class ProxyDelegate: NSObject, URLSessionDataDelegate {
        weak var owner: VikingURLProtocol?

        init(owner: VikingURLProtocol) {
            self.owner = owner
        }

        func urlSession(
            _ session: URLSession,
            dataTask: URLSessionDataTask,
            didReceive response: URLResponse,
            completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
        ) {
            owner?.received(response: response)
            completionHandler(.allow)
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            owner?.received(data: data)
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            owner?.completed(error: error)
        }
    }
}
