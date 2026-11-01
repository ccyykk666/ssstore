import XCTest
@testable import UpdateCore

final class UpdateCoreTests: XCTestCase {
    func testReleaseVersionOrdering() {
        XCTAssertEqual(VersionOrder.status(installed: "8.9", latest: "8.10"), .update)
        XCTAssertEqual(VersionOrder.status(installed: "1.2", latest: "1.2.0"), .current)
        XCTAssertEqual(VersionOrder.status(installed: "2.0", latest: "1.99"), .ahead)
        XCTAssertEqual(VersionOrder.status(installed: "01.002", latest: "1.2"), .current)
        XCTAssertEqual(VersionOrder.status(installed: "1.0-beta", latest: "1.0"), .unknown)
        XCTAssertEqual(VersionOrder.status(installed: nil, latest: "1.0"), .unknown)
        XCTAssertEqual(VersionOrder.status(installed: "", latest: "1.0"), .unknown)
        XCTAssertEqual(VersionOrder.status(installed: "1..0", latest: "1.0"), .unknown)
        XCTAssertEqual(VersionOrder.status(installed: "999999999999999999999", latest: "1000000000000000000000"), .update)
    }

    func testBuildNumberIsNeverUsedAsMarketingVersion() throws {
        let apps = try InventoryParser.parse(Data(#"[{"CFBundleIdentifier":"test.app","CFBundleVersion":"9000"}]"#.utf8))
        XCTAssertNil(apps[0].version)
        XCTAssertEqual(apps[0].build, "9000")
    }

    func testLockdownLookupPlistAndDuplicateIDs() throws {
        let root: [String: Any] = ["LookupResult": ["test.app": ["CFBundleDisplayName": "应用", "CFBundleShortVersionString": "1.2", "ApplicationType": "System"]]]
        let data = try PropertyListSerialization.data(fromPropertyList: root, format: .binary, options: 0)
        let apps = try InventoryParser.parse(data)
        XCTAssertEqual(apps[0].bundleID, "test.app")
        XCTAssertEqual(apps[0].version, "1.2")
        XCTAssertTrue(apps[0].isSystem)
        let duplicates = Data(#"[{"bundleID":"a","name":"旧","version":"1"},{"bundleID":"a","name":"新","version":"2"}]"#.utf8)
        XCTAssertEqual(try InventoryParser.parse(duplicates).count, 1)
        XCTAssertThrowsError(try InventoryParser.parse(Data("[]".utf8)))
    }

    func testAppleResultRequiresExactBundleIDAndRegion() throws {
        let data = Data(#"{"results":[{"bundleId":"test.app","trackName":"应用","version":"3.2","releaseNotes":"修复问题"}]}"#.utf8)
        let release = try AppleLookup.decode(data, bundleID: "test.app", country: "cn")
        XCTAssertEqual(release.notes, "修复问题")
        XCTAssertEqual(release.country, "cn")
        XCTAssertThrowsError(try AppleLookup.decode(data, bundleID: "other.app", country: "cn"))
        XCTAssertThrowsError(try AppleLookup.decode(Data(#"{"results":[]}"#.utf8), bundleID: "a", country: "us"))
        var record = AppRecord(installed: InstalledApp(bundleID: "test.app", name: "应用", version: "1.0"))
        record.release = release
        XCTAssertEqual(record.status(country: "cn"), .update)
        XCTAssertEqual(record.status(country: "us"), .unknown)
        record.error = "网络失败"
        XCTAssertEqual(record.status(country: "cn"), .unknown)
    }
}
