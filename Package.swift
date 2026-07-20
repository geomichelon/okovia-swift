// swift-tools-version: 5.9
import PackageDescription

// OkOvia is the public brand. `Okovia` is the umbrella product/target you
// `import`; it re-exports everything from `Viking`, which stays a product
// for back-compat so existing integrations keep compiling unchanged.
let package = Package(
    name: "OkoviaSDK",
    platforms: [
        .macOS(.v13),
        .iOS(.v16)
    ],
    products: [
        .library(name: "Okovia", targets: ["Okovia"]),
        .library(name: "Viking", targets: ["Viking"])
    ],
    targets: [
        .target(name: "Viking"),
        .target(name: "Okovia", dependencies: ["Viking"]),
        .testTarget(
            name: "VikingTests",
            dependencies: ["Viking"],
            resources: [.copy("Fixtures")]
        )
    ]
)
