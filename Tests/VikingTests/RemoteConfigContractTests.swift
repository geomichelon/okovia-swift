import XCTest
@testable import Viking

/// Decodes the shared contract fixtures from packages/event-schema.
/// The backend validates these same files against the JSON Schemas, so a
/// contract change that breaks Swift decoding fails here first.
final class RemoteConfigContractTests: XCTestCase {
    private func fixtureData(_ name: String) throws -> Data {
        // .../viking-swift/Tests/VikingTests/ThisFile.swift -> repo root
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let fixture = repoRoot
            .appendingPathComponent("packages/event-schema/fixtures/valid")
            .appendingPathComponent(name)
        return try Data(contentsOf: fixture)
    }

    func testDecodesContractExample() throws {
        let config = try RemoteConfig.decode(from: fixtureData("sdk-config--example.json"))

        XCTAssertEqual(config.schemaVersion, 1)
        XCTAssertEqual(config.configVersion, 42)
        XCTAssertEqual(config.projectId, "prj_x9k2")
        XCTAssertEqual(config.environment, "production")
        XCTAssertEqual(config.collectors.llmApi?.enabled, true)
        XCTAssertEqual(
            config.collectors.llmApi?.interceptHosts,
            ["api.openai.com", "api.anthropic.com"]
        )
        XCTAssertEqual(config.collectors.llmApi?.capturePromptContent, false)
        XCTAssertEqual(config.collectors.llmLocal?.frameworks, ["coreml", "mlx"])
        XCTAssertEqual(config.collectors.gpuSampling?.enabled, false)
        XCTAssertEqual(config.transport.endpoint.absoluteString, "https://ingest.viking.io/v1/ingest")
        XCTAssertEqual(config.transport.batchMaxEvents, 50)
        XCTAssertEqual(config.transport.samplingRate, 1.0)
        XCTAssertEqual(config.privacy.redactFields, ["prompt", "completion"])
    }

    func testIgnoresUnknownAdditiveFields() throws {
        // Compat rule: config only ever adds fields; the SDK must decode
        // configs that contain sections and flags it has never heard of.
        let config = try RemoteConfig.decode(
            from: fixtureData("sdk-config--future-additive-fields.json")
        )

        XCTAssertEqual(config.configVersion, 43)
        XCTAssertEqual(config.collectors.llmApi?.enabled, true)
        XCTAssertEqual(config.transport.samplingRate, 0.25)
    }

    func testEmbeddedDefaultsAreSafe() {
        let defaults = RemoteConfig.embeddedDefaults(projectId: "prj_test")

        XCTAssertEqual(defaults.configVersion, 0, "config_version 0 is reserved for embedded defaults")
        XCTAssertEqual(defaults.collectors.llmApi?.capturePromptContent, false)
        XCTAssertEqual(defaults.collectors.gpuSampling?.enabled, false)
        XCTAssertEqual(defaults.privacy.redactFields, ["prompt", "completion"])
        XCTAssertEqual(defaults.transport.endpoint.scheme, "https")
    }

    func testEmbeddedDefaultsRoundTripThroughContractCoding() throws {
        let defaults = RemoteConfig.embeddedDefaults(projectId: "prj_test")
        let encoded = try JSONEncoder().encode(defaults)
        let decoded = try RemoteConfig.decode(from: encoded)

        XCTAssertEqual(decoded, defaults)
    }
}
