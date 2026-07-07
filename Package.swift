// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "VikingSDK",
    platforms: [
        .macOS(.v13),
        .iOS(.v16)
    ],
    products: [
        .library(name: "Viking", targets: ["Viking"])
    ],
    targets: [
        .target(name: "Viking"),
        .testTarget(name: "VikingTests", dependencies: ["Viking"])
    ]
)
