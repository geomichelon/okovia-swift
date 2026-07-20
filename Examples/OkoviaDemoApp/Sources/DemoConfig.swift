import Foundation

/// ─────────────────────────────────────────────────────────────────────
///  EDIT THESE THREE VALUES, then run the app.
/// ─────────────────────────────────────────────────────────────────────
///
/// Where to get them:
///  • publicKey  — OkOvia console → your project → API Keys → a PUBLIC
///    key (starts with `vik_pub_`). NEVER ship a secret key in an app.
///  • projectID  — OkOvia console → your project (the UUID).
///  • apiBaseURL — your OkOvia API base URL. Use the local mock while you
///    explore (see README → "Mock LLM server"); switch to
///    https://api.okovia.com for the real backend.
enum DemoConfig {
    static let publicKey = "vik_pub_REPLACE_ME"
    static let projectID = "REPLACE_WITH_PROJECT_UUID"
    static let apiBaseURL = "https://api.okovia.com"

    /// The LLM endpoint the "Send LLM call" button hits. Points at the
    /// bundled mock server by default so you can see interception work
    /// with zero real spend. Swap for a real provider URL when ready.
    static let llmEndpoint = URL(string: "http://localhost:8899/v1/chat/completions")!

    /// True until you replace the placeholders above.
    static var isPlaceholder: Bool {
        publicKey.hasSuffix("REPLACE_ME") || projectID.hasPrefix("REPLACE")
    }
}
