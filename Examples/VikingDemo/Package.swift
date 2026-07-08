// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "VikingDemo",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(path: "../..")
    ],
    targets: [
        .target(
            name: "VikingDemoCore",
            dependencies: [.product(name: "Viking", package: "viking-swift")]
        ),
        .executableTarget(
            name: "VikingDemo",
            dependencies: ["VikingDemoCore", .product(name: "Viking", package: "viking-swift")]
        ),
        .executableTarget(
            name: "VikingDemoCLI",
            dependencies: ["VikingDemoCore", .product(name: "Viking", package: "viking-swift")]
        )
    ]
)
