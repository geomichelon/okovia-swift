import SwiftUI
import Viking
import VikingDemoCore

/// Example macOS app: Viking.start, a real intercepted LLM API call,
/// and a mocked Core ML inference run. Runs as a plain SwiftUI App via
/// `swift run` - no Xcode project needed.
///
/// The LLM call hits a local mock server (Examples/mock-llm-server.py)
/// instead of the real OpenAI/Anthropic endpoints, since this demo
/// ships without paid provider credentials. The exact same
/// interception + parsing code runs either way - LLMProvider.forHost
/// matches api.openai.com/api.anthropic.com in production, and its
/// forRequest loopback fallback (documented in the SDK) infers the
/// same shape from the mock server's path for local testing.
///
/// The actual SDK calls live in VikingDemoCore.DemoRunner, shared with
/// the headless VikingDemoCLI target used for scripted verification -
/// this file is presentation only.
@main
struct VikingDemoApp: App {
    @StateObject private var model = DemoViewModel()

    var body: some Scene {
        WindowGroup {
            DemoContentView().environmentObject(model)
        }
    }
}

@MainActor
final class DemoViewModel: ObservableObject {
    @Published var log: [String] = []
    private let runner = DemoRunner()

    init() {
        runner.onLog = { [weak self] line in
            Task { @MainActor in self?.log.append(line) }
        }
    }

    func start() { _ = runner.start() }
    func sendLLMCall() async { await runner.sendLLMCall() }
    func runLocalInference() { runner.runLocalInference() }
    func flushAndFinish() async { await runner.flushAndFinish() }

    func runAutomatically() async {
        await runner.runAutomatically()
    }
}

struct DemoContentView: View {
    @EnvironmentObject private var model: DemoViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Viking SDK Demo").font(.title).bold()
            Text("macOS example app - init, a real intercepted LLM call, and a mocked local inference run.")
                .foregroundStyle(.secondary)

            HStack {
                Button("1. Start Viking") { model.start() }
                Button("2. Send LLM call") { Task { await model.sendLLMCall() } }
                Button("3. Run local inference") { model.runLocalInference() }
                Button("4. Flush") { Task { await model.flushAndFinish() } }
            }

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(model.log.enumerated()), id: \.offset) { _, line in
                        Text(line).font(.system(.caption, design: .monospaced))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(24)
        .frame(minWidth: 560, minHeight: 360)
        .task {
            if ProcessInfo.processInfo.environment["VIKING_DEMO_AUTO"] == "1" {
                await model.runAutomatically()
            }
        }
    }
}
