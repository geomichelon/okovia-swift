import Foundation
import Viking

/// Minimal OkOvia (Viking) SDK integration for an iOS or macOS app.
///
/// The whole point of the SDK: call `OkOvia.start(...)` once at launch, then
/// keep writing your app normally. Outgoing LLM API calls are captured
/// automatically, and local (on-device) inference is measured by wrapping it
/// in `OkOvia.trackInference`.
public enum OkOvia {
    /// Call once at app launch with your PUBLIC key (vik_pub_…). `configURL`
    /// is your OkOvia API base URL (the SDK fetches remote config from it).
    public static func start(publicKey: String, configURL: String, projectId: String) {
        do {
            try Viking.start(
                apiKey: publicKey,
                options: VikingOptions(
                    debug: true,
                    configURL: URL(string: configURL),
                    projectId: projectId
                )
            )
            // Auto-instrument URLSession.shared so LLM API calls to the
            // configured hosts are captured with zero per-call code.
            Viking.instrument(.default)
        } catch {
            print("OkOvia.start failed: \(error)")
        }
    }

    /// Example of an instrumented outgoing LLM API call. In a real app this
    /// is just your normal networking code — the SDK captures token usage
    /// from the response automatically; nothing here is OkOvia-specific.
    public static func exampleLLMCall(endpoint: URL) async {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "model": "gpt-4o",
            "messages": [["role": "user", "content": "Summarize today's sales."]]
        ])
        _ = try? await URLSession.shared.data(for: request)
    }

    /// Wrap on-device inference so OkOvia measures duration, compute unit,
    /// thermal state, energy (when available), and the tokens you report.
    @discardableResult
    public static func trackInference(feature: String) -> String {
        Viking.inference(
            model: "coreml:demo-sentiment-v1",
            computeUnit: .ane,
            feature: feature
        ) { measurement in
            // ... run your Core ML / MLX / llama.cpp model here ...
            measurement.setTokens(input: 128, output: 16)
            return "positive"
        }
    }

    /// Flush queued events (also happens automatically on a timer and when
    /// the app backgrounds).
    public static func flush() {
        Viking.flush()
    }
}

#if canImport(SwiftUI)
import SwiftUI

/// A ready-made SwiftUI screen demonstrating the three touch-points. Add it
/// to your iOS/macOS app (see README) — it works on both.
@available(iOS 16.0, macOS 13.0, *)
public struct OkOviaQuickStartView: View {
    private let llmEndpoint: URL
    @State private var log: [String] = []

    public init(llmEndpoint: URL = URL(string: "http://localhost:8899/v1/chat/completions")!) {
        self.llmEndpoint = llmEndpoint
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("OkOvia quick-start").font(.title2).bold()
            Text("LLM calls are captured automatically; local inference is wrapped. iOS + macOS.")
                .font(.footnote)
                .foregroundStyle(.secondary)

            HStack {
                Button("Send LLM call") {
                    Task {
                        append("Sending LLM call…")
                        await OkOvia.exampleLLMCall(endpoint: llmEndpoint)
                        append("LLM call done — usage captured automatically.")
                    }
                }
                Button("Run local inference") {
                    let result = OkOvia.trackInference(feature: "quickstart_local")
                    append("Local inference → \(result) (measured by OkOvia).")
                }
                Button("Flush") {
                    OkOvia.flush()
                    append("Flushed queued events.")
                }
            }

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(log.enumerated()), id: \.offset) { _, line in
                        Text(line).font(.system(.caption, design: .monospaced))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(20)
    }

    private func append(_ line: String) { log.insert(line, at: 0) }
}
#endif
