# OkOvia Swift demo (Xcode app)

A tiny SwiftUI app — **iOS and macOS** — that shows a real OkOvia SDK
integration end to end. Open it, fill in three values, and press buttons to
watch LLM calls and on-device inference get measured.

> The one file worth reading is **[`Sources/OkoviaIntegration.swift`](Sources/OkoviaIntegration.swift)** —
> the entire integration lives there, top to bottom.

## Requirements

- Xcode 16 or later (tested with Xcode 26)
- iOS 16+ / macOS 13+

## Run it

1. Open **`OkoviaDemoApp.xcodeproj`** (double-click).
2. Edit **`Sources/DemoConfig.swift`** — set:
   - `publicKey` — a **public** key (`vik_pub_…`) from OkOvia console → your project → API Keys
   - `projectID` — your project's UUID
   - `apiBaseURL` — your OkOvia API base URL (e.g. `https://api.okovia.com`)
3. Pick a scheme — **`OkoviaDemoApp_iOS`** (a simulator) or **`OkoviaDemoApp_macOS`** — and press ▶.
4. Tap the buttons. Activity shows in the app; with `debug: true` each captured
   event (metadata only, never content) also prints to the Xcode console.

## What each button does

| Button | SDK touch-point |
|---|---|
| **Send LLM call** | ordinary `URLSession.shared` request — captured automatically because the session is instrumented |
| **Run local inference** | `Viking.inference { … }` — measures duration, compute unit, thermal state, energy, and the tokens you declare |
| **Flush** | `Viking.flush()` — force-send the queue (also automatic on timer / batch / backgrounding) |

## Mock LLM server (see interception with zero spend)

The demo points `llmEndpoint` at a local mock so you don't spend anything.
From the SDK repo root, run the bundled server:

```bash
python3 viking-swift/Examples/mock-llm-server.py   # serves http://localhost:8899
```

Then "Send LLM call" returns a canned OpenAI-shaped response and the SDK reads
its token usage. Point `llmEndpoint` at a real provider (https) when ready and
remove the `NSAllowsLocalNetworking` note in the project (App Transport
Security).

## Using OkOvia in *your* app

This example links the SDK by **local path** (`../..`) because it lives inside
the SDK repo. In your own project you add the published package instead:

**Xcode →** File → Add Package Dependencies… → paste
`https://github.com/geomichelon/okovia-swift.git` → Up to Next Major `0.1.0`
→ add the **`Okovia`** product to your app target.

Then the code in `OkoviaIntegration.swift` works unchanged (`import Okovia`).

## Regenerating the project

The `.xcodeproj` is generated from `project.yml` with
[XcodeGen](https://github.com/yonaskolb/XcodeGen):

```bash
brew install xcodegen   # once
cd viking-swift/Examples/OkoviaDemoApp
xcodegen generate
```
