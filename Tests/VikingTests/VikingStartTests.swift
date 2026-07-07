import XCTest
@testable import Viking

final class VikingStartTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("viking-start-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        Viking._resetForTesting()
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func options(projectId: String = "prj_test") -> VikingOptions {
        VikingOptions(
            debug: false,
            // Unroutable local port: config fetch fails fast and the SDK
            // must keep working on embedded defaults.
            configURL: URL(string: "https://127.0.0.1:1"),
            projectId: projectId,
            interceptSharedSession: false,
            storageDirectory: tempDir
        )
    }

    func testStartAcceptsCanonicalPublicKey() throws {
        try Viking.start(apiKey: "vik_pub_abc123", options: options())
        XCTAssertEqual(Viking.currentConfig?.configVersion, 0)
    }

    func testStartAcceptsTransitionalPublicKeyPrefix() throws {
        try Viking.start(apiKey: "vk_pub_local_dev", options: options())
        XCTAssertNotNil(Viking.currentConfig)
    }

    func testStartRejectsSecretKey() {
        // A secret key embedded in an app is a credential leak; fail fast.
        XCTAssertThrowsError(try Viking.start(apiKey: "vik_sec_abc123", options: options())) { error in
            guard case VikingError.invalidAPIKey = error else {
                return XCTFail("expected invalidAPIKey, got \(error)")
            }
        }
        XCTAssertNil(Viking.currentConfig)
    }

    func testStartRejectsGarbageKey() {
        XCTAssertThrowsError(try Viking.start(apiKey: "banana", options: options()))
    }

    func testSecondStartIsIgnored() throws {
        try Viking.start(apiKey: "vik_pub_first", options: options(projectId: "prj_a"))
        try Viking.start(apiKey: "vik_pub_second", options: options(projectId: "prj_b"))

        XCTAssertEqual(Viking.currentConfig?.projectId, "prj_a")
    }

    func testInferenceWorksWithoutStart() {
        // Instrumentation must never break customer code paths.
        let result = Viking.inference(model: "coreml:x") { _ in "ran" }
        XCTAssertEqual(result, "ran")
    }

    func testInferenceProducesEventAfterStart() throws {
        try Viking.start(apiKey: "vik_pub_abc123", options: options())

        let result = Viking.inference(model: "coreml:sentiment", computeUnit: .ane, feature: "triage") { m in
            m.setTokens(input: 10, output: 2)
            return 7
        }

        XCTAssertEqual(result, 7)
    }

    func testInstrumentInsertsProtocolOnce() {
        let configuration = URLSessionConfiguration.default

        Viking.instrument(configuration)
        Viking.instrument(configuration)

        let installed = (configuration.protocolClasses ?? []).filter {
            ObjectIdentifier($0) == ObjectIdentifier(VikingURLProtocol.self)
        }
        XCTAssertEqual(installed.count, 1)
        XCTAssertTrue(configuration.protocolClasses?.first == VikingURLProtocol.self)
    }

    func testSdkInfoMatchesNamingContract() {
        XCTAssertEqual(VikingSDKInfo.name, "viking-swift")
        XCTAssertEqual(VikingSDKInfo.versionHeader, "X-SDK-Version")
    }
}
