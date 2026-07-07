import XCTest
@testable import Viking

final class VikingStartTests: XCTestCase {
    override func tearDown() {
        Viking._resetForTesting()
        super.tearDown()
    }

    func testStartAcceptsCanonicalPublicKey() throws {
        try Viking.start(apiKey: "vik_pub_abc123")
        XCTAssertEqual(Viking.currentConfig?.configVersion, 0)
    }

    func testStartAcceptsTransitionalPublicKeyPrefix() throws {
        try Viking.start(apiKey: "vk_pub_local_dev")
        XCTAssertNotNil(Viking.currentConfig)
    }

    func testStartRejectsSecretKey() {
        // A secret key embedded in an app is a credential leak; fail fast.
        XCTAssertThrowsError(try Viking.start(apiKey: "vik_sec_abc123")) { error in
            guard case VikingError.invalidAPIKey = error else {
                return XCTFail("expected invalidAPIKey, got \(error)")
            }
        }
        XCTAssertNil(Viking.currentConfig)
    }

    func testStartRejectsGarbageKey() {
        XCTAssertThrowsError(try Viking.start(apiKey: "banana"))
    }

    func testSecondStartIsIgnored() throws {
        try Viking.start(apiKey: "vik_pub_first", options: VikingOptions(projectId: "prj_a"))
        try Viking.start(apiKey: "vik_pub_second", options: VikingOptions(projectId: "prj_b"))

        XCTAssertEqual(Viking.currentConfig?.projectId, "prj_a")
    }

    func testSdkInfoMatchesNamingContract() {
        XCTAssertEqual(VikingSDKInfo.name, "viking-swift")
        XCTAssertEqual(VikingSDKInfo.versionHeader, "X-SDK-Version")
    }
}
