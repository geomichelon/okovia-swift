// swift-tools-version: 5.9
import PackageDescription

// A minimal iOS + macOS quick-start showing how to integrate the OkOvia
// (Viking) Swift SDK. Built as a library so the integration code and the
// SwiftUI view compile for both platforms; drop them into an Xcode app with
// a tiny @main App (see README) to run on a device or simulator.
let package = Package(
    name: "OkOviaQuickStart",
    platforms: [.macOS(.v13), .iOS(.v16)],
    dependencies: [
        .package(path: "../..")
    ],
    targets: [
        .target(
            name: "OkOviaQuickStart",
            dependencies: [.product(name: "Viking", package: "viking-swift")]
        )
    ]
)
