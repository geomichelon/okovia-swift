import SwiftUI

@main
struct OkoviaDemoApp: App {
    init() {
        // Start the SDK once, at launch. That's the only required call.
        OkoviaIntegration.start()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        #if os(macOS)
        .defaultSize(width: 560, height: 620)
        #endif
    }
}
