# OkOvia — iOS & macOS quick-start

The smallest possible integration of the OkOvia (Viking) Swift SDK. The same
code runs on **iOS** and **macOS**: call `OkOvia.start(...)` once at launch,
then keep writing your app normally.

- [`OkOviaQuickStart.swift`](./Sources/OkOviaQuickStart/OkOviaQuickStart.swift)
  — the three touch-points (start + auto-instrument, an example LLM call, and
  a wrapped local-inference run) plus a ready-made `OkOviaQuickStartView`
  (SwiftUI, iOS + macOS).

This folder is a Swift Package (library), so the integration code and the
SwiftUI view **compile for both platforms**:

```bash
cd viking-swift/Examples/OkOviaQuickStart
DEVELOPER_DIR=/Applications/Xcode26.app/Contents/Developer swift build
```

## Run it in an app

SwiftUI apps need an Xcode app target (SPM can't launch an iOS app). Create
one and drop in a tiny `@main`:

1. **Xcode → New → App** (iOS or macOS), SwiftUI lifecycle.
2. **File → Add Package Dependencies…** and add the Viking SDK
   (this repo's `viking-swift`, or the published package once it ships).
3. Copy `OkOviaQuickStart.swift` into your app target (or add this package),
   then use the view:

```swift
import SwiftUI
import OkOviaQuickStart   // or paste OkOviaQuickStart.swift into your target

@main
struct MyApp: App {
    init() {
        OkOvia.start(
            publicKey: "vik_pub_xxx",           // mint in OkOvia → SDK Setup
            configURL: "https://api.<domain>",  // your OkOvia API
            projectId: "your-project"
        )
    }

    var body: some Scene {
        WindowGroup { OkOviaQuickStartView() }
    }
}
```

That's it. Outgoing LLM API calls are captured automatically; local inference
is measured via `OkOvia.trackInference`. Everything shows up in OkOvia priced
into cost and margin.

## Full-featured demo

For an end-to-end demo with a local stack and a mock LLM provider, see the
sibling [`VikingDemo`](../VikingDemo) example.
