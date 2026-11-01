import XCTest
@testable import UpdateCore

final class PairingRecordTests: XCTestCase {
    private func encode(_ value: Any, format: PropertyListSerialization.PropertyListFormat = .xml) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: value, format: format, options: 0)
    }

    func testGeneratedAndImportedRemoteRecordsWithExtraFields() throws {
        let record: [String: Any] = [
            "identifier": "test-host", "private_key": Data(repeating: 1, count: 32),
            "public_key": Data(repeating: 2, count: 32), "alt_irk": Data(repeating: 3, count: 16),
            "ssstoreHostAltIRK": Data(repeating: 4, count: 16)
        ]
        for format in [PropertyListSerialization.PropertyListFormat.xml, .binary] {
            XCTAssertEqual(try PairingRecord.kind(of: encode(record, format: format)), .remote)
        }
    }

    func testRejectsTruncatedKeysAndEmptyIdentity() throws {
        var record: [String: Any] = ["identifier": "host", "private_key": Data(count: 31), "public_key": Data(count: 32)]
        XCTAssertThrowsError(try PairingRecord.kind(of: encode(record)))
        record["private_key"] = Data(count: 32)
        record["identifier"] = "  "
        XCTAssertThrowsError(try PairingRecord.kind(of: encode(record)))
        XCTAssertThrowsError(try PairingRecord.kind(of: Data("not a plist".utf8)))
    }

    func testRejectsLockdownWithoutTreatingItAsRemote() throws {
        XCTAssertThrowsError(try PairingRecord.kind(of: encode(["HostID": "host", "HostPrivateKey": Data([1])]))) { error in
            XCTAssertEqual(error as? PairingRecordError, .unsupported)
        }
        XCTAssertThrowsError(try PairingRecord.kind(of: encode(["HostID": "host", "HostPrivateKey": Data()])))
    }
}

