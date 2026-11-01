import XCTest
@testable import UpdateCore

final class PairingBackgroundIdentifierTests: XCTestCase {
    func testUsesConcreteRunIdentifierCoveredByThePlistWildcard() throws {
        let result = try PairingBackgroundIdentifier.make(bundleID: "dev.personal.ssstore",
            permitted: ["dev.personal.ssstore.pairing.*"], runID: "run-1")
        XCTAssertEqual(result, "dev.personal.ssstore.pairing.run-1")
        XCTAssertFalse(result.contains("*"))
    }

    func testResigningRequiresMatchingBackgroundConfiguration() throws {
        XCTAssertThrowsError(try PairingBackgroundIdentifier.make(bundleID: "dev.personal.ssstore.team",
            permitted: ["dev.personal.ssstore.pairing.*"]))
        XCTAssertNoThrow(try PairingBackgroundIdentifier.make(bundleID: "dev.personal.ssstore.team",
            permitted: ["dev.personal.ssstore.team.pairing.*"]))
        XCTAssertThrowsError(try PairingBackgroundIdentifier.make(bundleID: nil, permitted: []))
    }
}
