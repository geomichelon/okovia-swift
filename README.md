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

## Status

Phase 1: package skeleton, `Viking.start`, config contract model, and
embedded defaults. Remote config fetch, the event queue (SQLite,
batching, gzip, backoff), and collectors are next.

## Development

```bash
swift test
# with Command Line Tools only, point at a full Xcode:
DEVELOPER_DIR=/Applications/Xcode26.app/Contents/Developer swift test
```
