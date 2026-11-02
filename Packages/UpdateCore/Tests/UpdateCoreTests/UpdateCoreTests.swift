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
        XCTAssertEqual(record.status(country: "cn"), .unknown) // Display-only Lookup lacks version identifiers.
        XCTAssertEqual(record.status(country: "us"), .unknown)
        record.error = "网络失败"
        XCTAssertEqual(record.status(country: "cn"), .unknown)
    }
    func testInspectedAppBuildSDKUsesItsOwnMetadata() throws {
        let data = Data(#"[{"CFBundleIdentifier":"test.app","DTXcode":"1640","DTXcodeBuild":"16F6","DTSDKName":"iphoneos18.5","MinimumOSVersion":"13.0","CFBundleVersion":"999"}]"#.utf8)
        let app = try InventoryParser.parse(data)[0]
        XCTAssertEqual(app.buildSDKDescription, "16.4")
        let restored = try JSONDecoder().decode(InstalledApp.self, from: JSONEncoder().encode(app))
        XCTAssertEqual(restored.buildSDKDescription, app.buildSDKDescription)
        let patch = try InventoryParser.parse(Data(#"[{"bundleID":"test.app","DTXcode":1531}]"#.utf8))[0]
        XCTAssertEqual(patch.buildSDKDescription, "15.3.1")
        let legacy = try JSONDecoder().decode(InstalledApp.self, from: Data(#"{"bundleID":"old.app","name":"Old","version":"1","build":"2700","isSystem":false}"#.utf8))
        XCTAssertNil(legacy.buildSDKDescription)
        let unavailable = try InventoryParser.parse(Data(#"[{"bundleID":"test.app","DTXcode":"unknown","MinimumOSVersion":"13.0"}]"#.utf8))[0]
        XCTAssertNil(unavailable.buildSDKDescription)
        let sdkOnly = try InventoryParser.parse(Data(#"[{"bundleID":"test.app","DTSDKName":"iphoneos18.5"}]"#.utf8))[0]
        XCTAssertEqual(sdkOnly.buildSDKDescription, "18.5")
    }

}

