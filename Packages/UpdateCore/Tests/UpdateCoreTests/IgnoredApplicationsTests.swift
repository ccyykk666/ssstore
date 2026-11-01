import XCTest
@testable import UpdateCore

final class IgnoredApplicationsTests: XCTestCase {
    func testLegacyIgnoredListKeepsEntriesWhenIconMetadataIsMissing() throws {
        let data = Data(#"{"names":{"com.example.hidden":"Hidden"}}"#.utf8)
        var ignored = try JSONDecoder().decode(IgnoredApplications.self, from: data)
        var app = record("com.example.hidden").installed
        app.localIconKey = String(repeating: "a", count: 64)
        ignored.captureMetadata(from: [app, record("com.example.visible").installed])
        XCTAssertEqual(ignored.application(for: app.id).localIconKey, app.localIconKey)
        XCTAssertEqual(ignored.bundleIDs, ["com.example.hidden"])
        XCTAssertNil(ignored.applications?["com.example.visible"])
    }

    func testIconMetadataPersistsAndIsRemovedWhenRestored() throws {
        var ignored = IgnoredApplications()
        var app = record("com.example.hidden").installed
        app.localIconKey = String(repeating: "b", count: 64)
        let url = URL(string: "https://example.com/icon.png")!
        ignored.ignore(app, iconURL: url)
        var restored = try JSONDecoder().decode(IgnoredApplications.self, from: JSONEncoder().encode(ignored))
        XCTAssertEqual(restored.application(for: app.id), app)
        XCTAssertEqual(restored.iconURLs?[app.id], url)
        restored.restore(app.id)
        XCTAssertTrue(restored.names.isEmpty)
        XCTAssertNil(restored.applications?[app.id])
        XCTAssertNil(restored.iconURLs?[app.id])
    }
    private func record(_ id: String, name: String = "App", version: String = "1") -> AppRecord {
        AppRecord(installed: InstalledApp(bundleID: id, name: name, version: version))
    }

    func testIgnoreSurvivesRelaunchAndAppChanges() throws {
        var ignored = IgnoredApplications()
        ignored.ignore(record("com.example.hidden", name: "Hidden").installed)
        let restored = try JSONDecoder().decode(IgnoredApplications.self, from: JSONEncoder().encode(ignored))
        let nextScan = [record("com.example.hidden", name: "Renamed", version: "2"), record("com.example.visible")]
        XCTAssertEqual(restored.visible(nextScan).map(\.id), ["com.example.visible"])
        XCTAssertEqual(restored.names["com.example.hidden"], "Hidden")
        XCTAssertEqual(restored.bundleIDs, ["com.example.hidden"])
    }

    func testRestoreOnlyTheSelectedApp() {
        var ignored = IgnoredApplications()
        ignored.ignore(record("com.example.one").installed)
        ignored.ignore(record("com.example.two").installed)
        ignored.restore("com.example.one")
        XCTAssertEqual(ignored.visible([record("com.example.one"), record("com.example.two")]).map(\.id), ["com.example.one"])
    }

    func testIgnoreUsesExactBundleIdentityAndIsIdempotent() {
        var ignored = IgnoredApplications()
        let app = record("com.example.app")
        ignored.ignore(app.installed)
        ignored.ignore(app.installed)
        ignored.ignore(record("").installed)
        XCTAssertEqual(ignored.names.count, 1)
        XCTAssertEqual(ignored.visible([app, record("com.example.app.other")]).map(\.id), ["com.example.app.other"])
    }
}

