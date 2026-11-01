import XCTest
@testable import UpdateCore

final class CatalogTests: XCTestCase {
    func testScreenshotAppsAllUseVersionIdentifiers() {
        let cases = [
            ("com.360buy.jdmobile", "171195", "16.1.81", "16.1.81"),
            ("com.tongcheng.iphone", "11.5.20", "11.5.20.25936", "11.5.2"),
            ("com.tencent.smoba", "12.1.10103", "unknown", "12.1.1.1"),
            ("com.quark.clouddrive", "10.19.5", "10.19.5.1091", "10.19.5.1091"),
            ("com.icbc.iphoneclient", "3.1.40", "1.2", "11.1.0.9.0")
        ]
        for (bundle, local, build, remote) in cases {
            var app = AppRecord(installed: InstalledApp(bundleID: bundle, name: bundle, version: local,
                build: build, storeID: "123", externalVersionID: "456"))
            app.release = StoreRelease(bundleID: bundle, name: bundle, version: remote, country: "cn",
                storeID: "123", externalVersionID: "456")
            XCTAssertEqual(app.status(country: "cn-us"), .current)
            XCTAssertEqual(app.displayedVersion(country: "cn-us"), remote)
            XCTAssertEqual(app.installed.version, local)
            app.release?.externalVersionID = "457"
            XCTAssertEqual(app.status(country: "cn-us"), .different)
            app.installed.externalVersionID = nil
            XCTAssertEqual(app.status(country: "cn-us"), .unknown)
            XCTAssertEqual(app.displayedVersion(country: "cn-us"), local)
        }
    }

    func testNoStringOrSupplementalFieldCanReplaceMissingIdentifiers() {
        var app = AppRecord(installed: InstalledApp(bundleID: "normal", name: "应用", version: "2.0", build: "1.0"))
        app.release = StoreRelease(bundleID: "normal", name: "应用", version: "1.0", country: "cn")
        app.installed.coreDeviceVersion = "1.0"
        app.installed.browseVersion = "1.0"
        app.installed.metadataVersion = "1.0"
        XCTAssertEqual(app.status(country: "cn"), .unknown)
        XCTAssertEqual(app.displayedVersion(country: "cn"), "2.0")
        app.installed.version = "1.0"
        XCTAssertEqual(app.status(country: "cn"), .unknown)
    }

    func testQuarkVersionStringsNeverOverrideDifferentOrMissingIdentifiers() {
        var app = AppRecord(installed: InstalledApp(bundleID: "com.quark.clouddrive", name: "夸克网盘",
            version: "10.19.5", build: "10.19.5.1091", storeID: "123", externalVersionID: "11"))
        app.release = StoreRelease(bundleID: app.id, name: "夸克网盘", version: "10.19.5.1091", country: "cn",
            storeID: "123", externalVersionID: "11")
        app.installed.metadataVersion = "10.19.5"
        XCTAssertEqual(app.status(country: "cn-us"), .current)
        XCTAssertEqual(app.displayedVersion(country: "cn-us"), "10.19.5.1091")
        app.release?.version = "10.19.5.1092"
        app.release?.externalVersionID = "12"
        XCTAssertEqual(app.status(country: "cn-us"), .different)
        app.installed.externalVersionID = "20"
        XCTAssertEqual(app.status(country: "cn-us"), .different)
        app.release?.externalVersionID = nil
        XCTAssertEqual(app.status(country: "cn-us"), .unknown)
    }

    func testVersionIdentifierRequiresMatchingAppIdentityAndRegion() {
        var app = AppRecord(installed: InstalledApp(bundleID: "a", name: "应用", version: "11.5.20", storeID: "123", externalVersionID: "456"))
        app.release = StoreRelease(bundleID: "a", name: "应用", version: "11.5.2", country: "cn", storeID: "123", externalVersionID: "456")
        XCTAssertEqual(app.status(country: "cn"), .current)
        XCTAssertEqual(app.displayedVersion(country: "cn"), "11.5.2")
        XCTAssertNotNil(app.versionExplanation(country: "cn"))
        app.release?.externalVersionID = "457"
        app.release?.version = app.installed.version ?? ""
        XCTAssertEqual(app.status(country: "cn"), .different)
        app.release?.storeID = "999"
        XCTAssertEqual(app.status(country: "cn"), .unknown)
        app.release?.storeID = "123"
        XCTAssertEqual(app.status(country: "us"), .unknown)
        app.error = "网络失败"
        XCTAssertEqual(app.status(country: "cn"), .unknown)
    }

    func testBatchPlanningDeduplicatesMappings() {
        let ids = (0..<61).map { "app.\($0)" }
        let batches = AppleLookup.batches(bundleIDs: ids + ["app.0", ""])
        XCTAssertEqual(batches.map(\.count), [25, 25, 11])
        XCTAssertEqual(batches.flatMap { $0 }, ids)
        XCTAssertEqual(AppleLookup.batches(bundleIDs: []).count, 0)
        let query = URLComponents(url: AppleLookup.request(bundleIDs: ["a", "b"], country: "cn").url!, resolvingAgainstBaseURL: false)!.queryItems!
        XCTAssertEqual(query.first { $0.name == "bundleId" }?.value, "a,b")
    }

    func testBatchDecodeMatchesIdentifiersInsteadOfResponseOrder() throws {
        let data = Data(#"{"results":[{"bundleId":"b","trackId":123,"version":"2.0","artworkUrl100":"https://example.com/icon.png"},{"bundleId":"unrequested","version":"9"},{"bundleId":"a","version":"1"}]}"#.utf8)
        let result = try AppleLookup.decodeBatch(data, bundleIDs: ["a", "b", "missing"], country: "hk")
        XCTAssertEqual(Set(result.keys), ["a", "b"])
        XCTAssertEqual(result["b"]?.storeID, "123")
        XCTAssertEqual(result["b"]?.iconURL?.absoluteString, "https://example.com/icon.png")
        XCTAssertEqual(result["b"]?.country, "hk")
    }

    func testCatalogPublicMetadataAndWrongBundleRejection() throws {
        let data = Data(#"{"results":{"123":{"bundleId":"a","name":"应用","whatsNew":"修复问题","minimumOSVersion":"15.0","artwork":{"url":"https://example.com/{w}x{h}{c}.{f}"},"offers":[{"version":{"display":"1.2","externalId":456}}]},"124":{"bundleId":"wrong","offers":[{"version":{"display":"9","externalId":"999"}}]},"125":{"bundleId":"c","offers":[{"version":{"display":"3"},"buyParams":"appExtVrsId=789&price=0"}]}}}"#.utf8)
        let result = try AppleLookup.decodeCatalog(data, expected: ["a": "123", "b": "124", "c": "125"], country: "cn")
        XCTAssertEqual(result["a"]?.version, "1.2")
        XCTAssertEqual(result["a"]?.externalVersionID, "456")
        XCTAssertEqual(result["a"]?.notes, "修复问题")
        XCTAssertEqual(result["a"]?.iconURL?.absoluteString, "https://example.com/128x128bb.png")
        XCTAssertEqual(result["c"]?.externalVersionID, "789")
        XCTAssertNil(result["b"])
    }

    func testCacheExpiryAndRegion() {
        let now = Date()
        var release = StoreRelease(bundleID: "a", name: "a", version: "1", country: "cn", fetchedAt: now.addingTimeInterval(-299), source: "Apple Catalog")
        XCTAssertTrue(AppleLookup.isFresh(release, country: "cn", now: now))
        XCTAssertFalse(AppleLookup.isFresh(release, country: "us", now: now))
        release.fetchedAt = now.addingTimeInterval(-301)
        XCTAssertFalse(AppleLookup.isFresh(release, country: "cn", now: now))
        release.fetchedAt = now
        release.source = nil
        XCTAssertFalse(AppleLookup.isFresh(release, country: "cn", now: now))
    }

    func testOldSavedInventoryRemainsDecodable() throws {
        let data = Data(#"{"installed":{"bundleID":"a","name":"a","version":"1.0","isSystem":false},"release":{"bundleID":"a","name":"a","version":"1.1","country":"cn","fetchedAt":0}}"#.utf8)
        let app = try JSONDecoder().decode(AppRecord.self, from: data)
        XCTAssertEqual(app.status(country: "cn"), .unknown)
        XCTAssertNil(app.installed.localIconKey)
        XCTAssertNil(app.release?.externalVersionID)
    }

    func testOptionalDeviceMetadata() throws {
        let data = Data(#"[{"CFBundleIdentifier":"a","CFBundleShortVersionString":"11.5.20","CFBundleVersion":"11.5.20.25936","LocalIconKey":"abc","iTunesMetadata":{"itemId":123,"softwareVersionExternalIdentifier":"456"}}]"#.utf8)
        let app = try XCTUnwrap(InventoryParser.parse(data).first)
        XCTAssertEqual(app.storeID, "123")
        XCTAssertEqual(app.externalVersionID, "456")
        XCTAssertEqual(app.localIconKey, "abc")
        XCTAssertEqual(app.version, "11.5.20")
    }

    func testICBCUsesActualScreenshotIdentifier() {
        var app = AppRecord(installed: InstalledApp(bundleID: "com.icbc.iphoneclient", name: "中国工商银行", version: "3.1.40", build: "1.2"))
        app.release = StoreRelease(bundleID: app.id, name: "中国工商银行", version: "11.1.0.9.0", country: "cn",
            storeID: "423514795", externalVersionID: "891257769")
        app.installed.coreDeviceVersion = "11.1.0.9.0"
        XCTAssertEqual(app.status(country: "cn-us"), .unknown)
        app.installed.storeID = "423514795"
        app.installed.externalVersionID = "891257769"
        XCTAssertEqual(app.status(country: "cn-us"), .current)
        XCTAssertEqual(app.displayedVersion(country: "cn-us"), "11.1.0.9.0")
        XCTAssertEqual(app.installed.version, "3.1.40")
    }

    func testOriginalMetadataDoesNotDetermineUpdateDirection() {
        var app = AppRecord(installed: InstalledApp(bundleID: "a", name: "a", version: "1.0", build: "999"))
        app.installed.metadataVersion = "10.0.0"
        app.release = StoreRelease(bundleID: "a", name: "a", version: "11.1.0.9.0", country: "cn")
        XCTAssertEqual(app.status(country: "cn"), .unknown)
        app.installed.version = "11.1.0.9.0"
        XCTAssertEqual(app.status(country: "cn"), .unknown)
    }

    func testEnrichedDeviceFieldsPreserveOriginalValues() throws {
        let data = Data(#"[{"CFBundleIdentifier":"a","CFBundleShortVersionString":"3.1.40","CFBundleVersion":"1.2","CoreDeviceVersion":"11.0.9.0","CoreDeviceBuild":"456","BrowseVersion":"3.1.40","BrowseBuild":"1.2","MetadataVersion":"11.0.9.0","MetadataBuild":"456","VersionReadNote":"系统提供了安装版本标识"}]"#.utf8)
        let app = try XCTUnwrap(InventoryParser.parse(data).first)
        XCTAssertEqual(app.version, "3.1.40")
        XCTAssertEqual(app.build, "1.2")
        XCTAssertEqual(app.coreDeviceVersion, "11.0.9.0")
        XCTAssertEqual(app.browseVersion, "3.1.40")
        XCTAssertEqual(app.metadataVersion, "11.0.9.0")
        XCTAssertNotNil(app.versionReadNote)
    }
    func testExactBundleSupportsOmittedStoreIDButRewrittenBundleRequiresStoreID() {
        var app = AppRecord(installed: InstalledApp(bundleID: "a", name: "a", version: "1", externalVersionID: "123"))
        app.release = StoreRelease(bundleID: "a", name: "a", version: "2", country: "cn", externalVersionID: "123")
        XCTAssertEqual(app.status(country: "cn"), .current)
        app.installed.bundleID = "a.sideloaded"
        app.lookupBundleID = "a"
        XCTAssertEqual(app.status(country: "cn"), .unknown)
        app.installed.storeID = "100"
        app.release?.storeID = "100"
        XCTAssertEqual(app.status(country: "cn"), .current)
        app.release?.bundleID = "another.app"
        XCTAssertEqual(app.status(country: "cn"), .unknown)
    }

    func testIdentifiersMustBePositiveDecimalValues() {
        var app = AppRecord(installed: InstalledApp(bundleID: "a", name: "a", version: "1", externalVersionID: "00123"))
        app.release = StoreRelease(bundleID: "a", name: "a", version: "1", country: "cn", externalVersionID: "123")
        XCTAssertEqual(app.status(country: "cn"), .current)
        for invalid in ["", "0", "000", "abc", "-1"] {
            app.installed.externalVersionID = invalid
            app.release?.externalVersionID = invalid
            XCTAssertEqual(app.status(country: "cn"), .unknown)
        }
    }

}
