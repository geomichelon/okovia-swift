import XCTest
@testable import Viking

final class RedactionTests: XCTestCase {
    private func config(redacting fields: [String]) -> RemoteConfig {
        let base = RemoteConfig.embeddedDefaults(projectId: "prj_t")
        return RemoteConfig(
            schemaVersion: base.schemaVersion,
            configVersion: 1,
            projectId: base.projectId,
            environment: "test",
            collectors: base.collectors,
            transport: base.transport,
            privacy: RemoteConfig.Privacy(redactFields: fields, hashUserIds: true)
        )
    }

    func testConfiguredFieldsAreRedacted() {
        let redactor = Redactor(config: config(redacting: ["customer_email"]))

        let result = redactor.redact([
            "feature": .string("chat"),
            "customer_email": .string("jane@example.com")
        ])

        XCTAssertEqual(result?["feature"], .string("chat"))
        XCTAssertNil(result?["customer_email"])
    }

    func testHardcodedBlocklistCannotBeDisabled() {
        // Even with an empty redact_fields config, prompt/completion
        // content never survives.
        let redactor = Redactor(config: config(redacting: []))

        let result = redactor.redact([
            "prompt": .string("secret user question"),
            "completion": .string("secret answer"),
            "messages": .string("[...]"),
            "feature": .string("chat")
        ])

        XCTAssertEqual(result?.count, 1)
        XCTAssertNotNil(result?["feature"])
    }

    func testRedactionIsCaseInsensitive() {
        let redactor = Redactor(config: config(redacting: ["Tenant_Secret"]))

        let result = redactor.redact([
            "PROMPT": .string("x"),
            "tenant_secret": .string("y"),
            "ok": .bool(true)
        ])

        XCTAssertEqual(result?.count, 1)
        XCTAssertNotNil(result?["ok"])
    }

    func testAllAttrsRedactedYieldsNil() {
        let redactor = Redactor(config: config(redacting: []))
        XCTAssertNil(redactor.redact(["prompt": .string("x")]))
        XCTAssertNil(redactor.redact(nil))
    }
}

final class GzipTests: XCTestCase {
    func testRoundTrip() throws {
        let original = Data(String(repeating: "viking event payload ", count: 500).utf8)

        let compressed = try Gzip.compress(original)
        let restored = try Gzip.decompress(compressed)

        XCTAssertEqual(restored, original)
        XCTAssertLessThan(compressed.count, original.count / 2, "repetitive payloads must actually shrink")
    }

    func testEmitsGzipContainer() throws {
        let compressed = try Gzip.compress(Data("hello".utf8))
        XCTAssertEqual(compressed.prefix(2), Data([0x1f, 0x8b]), "RFC 1952 magic bytes")
    }
}
