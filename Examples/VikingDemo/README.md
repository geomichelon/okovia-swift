# Viking SDK - Integration Demo

This is what integrating Viking looks like from a customer's point of
view: one line to start the SDK, then keep writing your app normally.
Viking captures LLM API calls and local inference automatically.

## What you're looking at

- `VikingDemo` - a real SwiftUI app (`swift run VikingDemo`, no Xcode
  project needed). Buttons let you trigger each step by hand.
- `VikingDemoCLI` - the same steps, headless, used to verify this demo
  end to end without a GUI (useful in CI or a background shell).
- `VikingDemoCore` - the actual integration code, shared by both. Read
  `Sources/VikingDemoCore/DemoRunner.swift` - that's the part that
  matters; the SwiftUI/CLI shells around it are just presentation.

## 1. Start the local stack (one command)

From the repo root:

```bash
scripts/demo_sdk_stack.sh
```

This brings up Postgres/Redis/API/worker/web via Docker, migrates the
database, creates a demo project, mints a public SDK key, publishes an
SDK config pointed at your local API, and starts a local mock LLM
provider (`Examples/mock-llm-server.py`) so the demo works without a
real OpenAI/Anthropic API key. It prints the environment variables the
demo app needs - export them as shown.

## 2. Add Viking to your app

```swift
// Package.swift
dependencies: [
    .package(path: "path/to/viking-swift")
]
// target dependencies: [.product(name: "Viking", package: "viking-swift")]
```

```swift
import Viking

try Viking.start(apiKey: "vik_pub_your_key") // one line, as early as possible
```

That's it for setup. From here on:

- **LLM API calls you make through `URLSession.shared`** to a host in
  your published config's `intercept_hosts` (e.g. `api.openai.com`,
  `api.anthropic.com`) are captured automatically - no code changes to
  your networking calls.
- **Local inference** (Core ML, MLX, your own runtime) is measured
  with one wrapper:

  ```swift
  let result = try Viking.inference(model: "my-model", computeUnit: .ane) { measurement in
      let output = try model.prediction(from: input)
      measurement.setTokens(input: 96, output: 1)
      return output
  }
  ```

Nothing else changes. No manual batching, no manual network calls -
the SDK queues, batches, and flushes on its own schedule (or call
`Viking.flush()` to force it, e.g. before your app backgrounds).

## 3. Run the demo

```bash
cd viking-swift/Examples/VikingDemo
swift run VikingDemo
```

Click the four buttons in order, or set `VIKING_DEMO_AUTO=1` to run
the whole sequence automatically on launch (this is what the CLI
target and the timed verification below use).

## 4. Watch it arrive

Open the dashboard, sign in, and go to **SDK → Live Events**
(`/sdk/live`). Both events - the "API call" and the local inference
run - appear within about a second of `Viking.flush()`.

## Acceptance criterion

> `Viking.start` to the event visible in Live Events, in under 2 minutes.

Measured with a fresh event queue (no leftover local backlog) against
the running local stack, using the headless `VikingDemoCLI` (so the
SDK's actual behavior is what's timed, not a human clicking buttons)
and a Playwright browser watching `/sdk/live`:

```
T0 = process launch (first line of DemoRunner.start())
T1 = both events rendered in the Live Events feed
ELAPSED: 0.768s
```

Well under the 2-minute bar. The dominant cost in a real first
integration is a developer reading these four lines, not the SDK.

## Notes on this demo specifically

- The "real" LLM API call goes to a local mock server
  (`../mock-llm-server.py`) instead of the actual OpenAI/Anthropic
  APIs, since this demo ships without paid provider credentials. The
  exact same interception and response-parsing code runs either way -
  point `intercept_hosts` at the real `api.openai.com` /
  `api.anthropic.com` in production and nothing else changes.
- The Core ML step is a mocked prediction (`Thread.sleep` + fixed
  output) rather than a bundled `.mlmodel`, so the demo has no binary
  model asset to ship - swap in a real `MLModel` call and the
  `Viking.inference` wrapper around it is unchanged.
