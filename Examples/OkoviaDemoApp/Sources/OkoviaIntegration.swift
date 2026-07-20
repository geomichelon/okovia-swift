import Foundation
import Okovia   // the OkOvia umbrella module (re-exports the SDK)

/// The entire OkOvia integration for this app lives in this one file — read
/// it top to bottom to understand what a real integration looks like.
///
/// The model: call ``start()`` once at launch, then keep writing your app
/// normally. Outgoing LLM API calls are captured automatically; on-device
/// inference is measured by wrapping it in ``runLocalInference(feature:)``.
/// The SDK only ever sends *usage metadata* (tokens, timing, model name) —
/// never prompts, responses, or any content.
enum OkoviaIntegration {

    // MARK: 1. Start once at launch

    /// Boots the SDK with your PUBLIC key. Safe to call from the App's init.
    static func start() {
        guard !DemoConfig.isPlaceholder else {
            print("[demo] Fill in DemoConfig before starting OkOvia.")
            return
        }
        do {
            try Viking.start(
                apiKey: DemoConfig.publicKey,
                options: VikingOptions(
                    debug: true,                                   // logs captured events to the console (never content)
                    configURL: URL(string: DemoConfig.apiBaseURL), // where the SDK fetches its remote config
                    projectId: DemoConfig.projectID
                )
            )
            // Auto-capture LLM API calls made through URLSession.shared.
            // Custom URLSessions? Call Viking.instrument(configuration)
            // on their URLSessionConfiguration instead.
            Viking.instrument(.default)
            print("[demo] OkOvia started (SDK \(VikingSDKInfo.version)).")
        } catch {
            print("[demo] OkOvia.start failed: \(error)")
        }
    }

    // MARK: 2. An instrumented LLM API call

    /// Just ordinary networking — there is nothing OkOvia-specific here.
    /// Because the shared session is instrumented, the SDK reads token
    /// usage from the response and queues a content-free usage event.
    static func sendLLMCall() async {
        var request = URLRequest(url: DemoConfig.llmEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "model": "gpt-4o",
            "messages": [["role": "user", "content": "Summarize today's sales."]]
        ])
        _ = try? await URLSession.shared.data(for: request)
    }

    // MARK: 3. Measure on-device inference

    /// Wrap Core ML / MLX / llama.cpp runs so OkOvia records duration,
    /// compute unit, thermal state, energy (when the platform reports it),
    /// and the token counts you declare. Return your model's real output.
    @discardableResult
    static func runLocalInference(feature: String) -> String {
        Viking.inference(
            model: "coreml:demo-sentiment-v1",
            computeUnit: .ane,          // .cpu / .gpu / .ane
            feature: feature
        ) { measurement in
            // ── run your real model here ──
            measurement.setTokens(input: 128, output: 16)
            return "positive"
        }
    }

    // MARK: 4. Flush (optional)

    /// Events also flush automatically on a timer, at batch size, and when
    /// the app backgrounds. Call this to force a send (e.g. before logout).
    static func flush() { Viking.flush() }
}
