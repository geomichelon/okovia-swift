import SwiftUI

/// A three-button screen that exercises the SDK's touch-points and logs
/// what happened. Watch the Xcode console too — `debug: true` prints each
/// captured event (metadata only, never content).
struct ContentView: View {
    @State private var log: [String] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header

            if DemoConfig.isPlaceholder {
                banner
            }

            HStack(spacing: 10) {
                Button("Send LLM call") {
                    Task {
                        append("→ sending LLM call to \(DemoConfig.llmEndpoint.host ?? "?")…")
                        await OkoviaIntegration.sendLLMCall()
                        append("✓ LLM call done — token usage captured automatically.")
                    }
                }
                Button("Run local inference") {
                    let result = OkoviaIntegration.runLocalInference(feature: "demo_local")
                    append("✓ on-device inference → \(result) (duration + tokens measured).")
                }
                Button("Flush") {
                    OkoviaIntegration.flush()
                    append("✓ queued events flushed.")
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(DemoConfig.isPlaceholder)

            Divider()

            Text("Activity").font(.headline)
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    if log.isEmpty {
                        Text("Tap a button. Events appear here and in the Xcode console.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    ForEach(Array(log.enumerated()), id: \.offset) { _, line in
                        Text(line).font(.system(.caption, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("OkOvia Swift demo").font(.title2).bold()
            Text("Start once, then code normally. LLM calls are captured automatically; on-device inference is wrapped. Usage metadata only — no prompts or content leave the device.")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }

    private var banner: some View {
        Text("Edit DemoConfig.swift (publicKey, projectID, apiBaseURL) to enable the buttons.")
            .font(.callout)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.yellow.opacity(0.25), in: RoundedRectangle(cornerRadius: 8))
    }

    private func append(_ line: String) { log.insert(line, at: 0) }
}

#Preview {
    ContentView()
}
