import XCTest
@testable import UpdateCore

final class CatalogTests: XCTestCase {
    func testScreenshotVersions() {
        var jd = AppRecord(installed: InstalledApp(bundleID: "com.360buy.jdmobile", name: "京东", version: "171195", build: "16.1.81"))
        jd.release = StoreRelease(bundleID: jd.id, name: "京东", version: "16.1.81", country: "cn")
        XCTAssertEqual(jd.status(country: "cn"), .current)
        XCTAssertEqual(jd.displayedVersion(country: "cn"), "16.1.81")
        jd.release?.version = "16.1.82"
        XCTAssertEqual(jd.status(country: "cn"), .update)
        XCTAssertEqual(jd.installed.version, "171195")

        for (bundle, local, build, remote) in [
            ("com.tongcheng.iphone", "11.5.20", "11.5.20.25936", "11.5.2"),
            ("com.tencent.smoba", "12.1.10103", "unknown", "12.1.1.1")
        ] {
            var app = AppRecord(installed: InstalledApp(bundleID: bundle, name: bundle, version: local, build: build))
            app.release = StoreRelease(bundleID: bundle, name: bundle, version: remote, country: "cn")
            XCTAssertEqual(app.status(country: "cn"), .different)
            XCTAssertEqual(app.displayedVersion(country: "cn"), local)
            XCTAssertNotNil(app.versionExplanation(country: "cn"))
        }
    }

    func testBuildCoincidenceDoesNotOverrideNormalMarketingVersion() {
        var app = AppRecord(installed: InstalledApp(bundleID: "normal", name: "应用", version: "2.0", build: "1.0"))
        app.release = StoreRelease(bundleID: "normal", name: "应用", version: "1.0", country: "cn")
        XCTAssertEqual(app.status(country: "cn"), .different)
        XCTAssertEqual(app.displayedVersion(country: "cn"), "2.0")
    }

    func testMatchingExternalIDResolvesDifferentDisplayFormats() {
        var app = AppRecord(installed: InstalledApp(bundleID: "a", name: "应用", version: "11.5.20", storeID: "123", externalVersionID: "456"))
        app.release = StoreRelease(bundleID: "a", name: "应用", version: "11.5.2", country: "cn", storeID: "123", externalVersionID: "456")
        XCTAssertEqual(app.status(country: "cn"), .current)
        app.release?.externalVersionID = "457"
        XCTAssertEqual(app.status(country: "cn"), .different)
        app.release?.storeID = "999"
        XCTAssertEqual(app.status(country: "cn"), .different)
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
        let data = Data(#"{"installed":{"bundleID":"a","name":"a","version":"1","isSystem":false},"release":{"bundleID":"a","name":"a","version":"2","country":"cn","fetchedAt":0}}"#.utf8)
        let app = try JSONDecoder().decode(AppRecord.self, from: data)
        XCTAssertEqual(app.status(country: "cn"), .update)
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
}
