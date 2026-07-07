# Viking Swift SDK

Cost observability SDK for AI workloads on Apple platforms
(macOS 13+ / iOS 16+). Measures LLM API calls, on-device inference
(Core ML, MLX), OCR, and GPU compute - and ships raw usage events to
Viking, where cost is calculated server-side from your cost rules.

Package: `VikingSDK` · library target: `Viking` · `sdk.name`: `viking-swift`

## Install

Add the package to your project:

```swift
.package(path: "../viking-swift") // Swift Package Manager
```

## Usage

```swift
import Viking

try Viking.start(apiKey: "vik_pub_your_key")
```

`Viking.start` requires the project's **public** key (`vik_pub_...`).
Secret keys (`vik_sec_...`) are server-side only and are rejected at
startup so a leaked secret fails fast in development.

Optional settings:

```swift
try Viking.start(
    apiKey: "vik_pub_your_key",
    options: VikingOptions(debug: true)
)
```

`debug: true` logs each captured event to the console. Debug logs never
include prompt or completion content.

## How configuration works

The SDK boots on embedded safe defaults (`config_version` 0), then
downloads the project's published config (ETag/304, cached on disk) and
applies it - collectors turn on and off remotely from the dashboard,
without an app release. Config evolution is additive-only and the SDK
ignores fields it does not know.

The contract lives in `packages/event-schema/schemas/sdk-config.schema.json`;
this SDK's `RemoteConfig` decodes the same shared fixtures the backend
validates, so drift is caught by tests on both sides.

## Measuring local inference

```swift
let output = try Viking.inference(model: "coreml:sentiment-v2", computeUnit: .ane, feature: "inbox_triage") { m in
    let result = try model.prediction(input: input)
    m.setTokens(input: 96, output: 1)
    return result
}
```

Duration, declared compute unit, and thermal state are captured
automatically; energy is reported when the platform can measure it
(otherwise `energy_mj` is null).

## Intercepting LLM API calls

Calls made through `URLSession.shared` to hosts listed in the remote
config's `intercept_hosts` are captured automatically after
`Viking.start`. For a custom session:

```swift
let configuration = URLSessionConfiguration.default
Viking.instrument(configuration)
let session = URLSession(configuration: configuration)
```

Usage is parsed from OpenAI and Anthropic responses, including SSE
streaming (for OpenAI streams, set `stream_options: {"include_usage": true}`
to get exact counts; otherwise Viking estimates tokens and flags the
event `estimated: true`). Anthropic `stop_reason: "refusal"` becomes its
own `llm_refusal` event.

## Status

Phase 2: remote config (ETag/304, disk cache, foreground + 15 min
refresh), SQLite-backed event queue (batching, gzip, exponential
backoff, byte-cap trimming, config-driven sampling), LLM API
interception, local inference tracking, and debug logging. Backend
publish/ingest endpoints are next.

## Development

```bash
swift test
# with Command Line Tools only, point at a full Xcode:
DEVELOPER_DIR=/Applications/Xcode26.app/Contents/Developer swift test
```
