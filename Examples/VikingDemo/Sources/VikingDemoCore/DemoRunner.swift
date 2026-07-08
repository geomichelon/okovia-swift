import Foundation
import Viking

/// The demo's actual behavior, shared between the SwiftUI app (for a
/// human to click through) and the headless CLI (for scripted
/// verification) - no UI framework dependency, so it runs identically
/// in both. Every call here is a real Viking SDK call; nothing is
/// simulated except the LLM provider's network endpoint (see
/// mock-llm-server.py) and the Core ML prediction itself.
public final class DemoRunner {
    public var onLog: (@Sendable (String) -> Void)?

    private let publicKey: String
    private let configBaseURL: String
    private let mockProviderURL: String

    public init(
        publicKey: String = ProcessInfo.processInfo.environment["VIKING_DEMO_PUBLIC_KEY"] ?? "",
        configBaseURL: String = ProcessInfo.processInfo.environment["VIKING_DEMO_CONFIG_URL"]
            ?? "http://localhost:58000",
        mockProviderURL: String = ProcessInfo.processInfo.environment["VIKING_DEMO_MOCK_LLM_URL"]
            ?? "http://localhost:8899/v1/chat/completions"
    ) {
        self.publicKey = publicKey
        self.configBaseURL = configBaseURL
        self.mockProviderURL = mockProviderURL
    }

    public func start() -> Bool {
        guard !publicKey.isEmpty else {
            log("VIKING_DEMO_PUBLIC_KEY is not set. Run scripts/demo_sdk_stack.sh first.")
            return false
        }
        log("Viking.start(apiKey: \(publicKey.prefix(12))...)")
        do {
            try Viking.start(
                apiKey: publicKey,
                options: VikingOptions(
                    debug: true,
                    configURL: URL(string: configBaseURL),
                    projectId: "demo"
                )
            )
        } catch {
            log("Viking.start failed: \(error)")
            return false
        }
        log("SDK started (embedded defaults until remote config loads).")
        return true
    }

    public func waitForRemoteConfig() async {
        for _ in 0..<25 {
            if let version = Viking.currentConfig?.configVersion, version > 0 {
                log("Remote config loaded: version \(version).")
                return
            }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        log("Remote config not loaded yet - continuing with embedded defaults.")
    }

    public func sendLLMCall() async {
        guard let url = URL(string: mockProviderURL) else { return }
        log("Sending LLM API call to \(url.absoluteString)...")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "model": "gpt-4.1-mock",
            "messages": [["role": "user", "content": "Summarize this quarter's revenue."]]
        ])

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            log("LLM call completed (HTTP \(status)) - Viking captured usage automatically.")
        } catch {
            log("LLM call failed: \(error). Is mock-llm-server.py running?")
        }
    }

    @discardableResult
    public func runLocalInference() -> String {
        log("Running local inference (mocked Core ML)...")
        let sentiment = Viking.inference(
            model: "coreml:demo-sentiment-v1",
            computeUnit: .ane,
            feature: "demo_local_inference"
        ) { measurement -> String in
            // Stand-in for a real MLModel.prediction(from:) call.
            Thread.sleep(forTimeInterval: 0.05)
            measurement.setTokens(input: 96, output: 1)
            return "positive"
        }
        log("Local inference result: \(sentiment).")
        return sentiment
    }

    public func flushAndFinish() async {
        log("Flushing the event queue...")
        Viking.flush()
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        log("Done. Open the dashboard's Live Events tab to see both events.")
    }

    public func runAutomatically() async {
        guard start() else { return }
        await waitForRemoteConfig()
        await sendLLMCall()
        runLocalInference()
        await flushAndFinish()
    }

    private func log(_ message: String) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let line = "[\(timestamp)] \(message)"
        onLog?(line)
        print("[VikingDemo] \(message)")
    }
}
