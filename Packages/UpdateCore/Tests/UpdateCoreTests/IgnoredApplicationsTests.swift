import XCTest
@testable import UpdateCore

final class IgnoredApplicationsTests: XCTestCase {
    func testUninstalledAppIsHiddenWithoutLosingItsIgnorePreference() throws {
        var ignored = IgnoredApplications()
        let installed = record("installed").installed, removed = record("removed").installed
        ignored.ignore(installed); ignored.ignore(removed)
        ignored.reconcileInstalledApps([installed, record("other").installed])
        XCTAssertEqual(ignored.visibleBundleIDs, ["installed"])
        XCTAssertEqual(ignored.bundleIDs, ["installed", "removed"])
        let saved = try JSONDecoder().decode(IgnoredApplications.self, from: JSONEncoder().encode(ignored))
        XCTAssertEqual(saved.visibleBundleIDs, ["installed"])
        ignored.reconcileInstalledApps([removed])
        XCTAssertEqual(ignored.visibleBundleIDs, ["removed"])
        XCTAssertTrue(ignored.visible([AppRecord(installed: removed)]).isEmpty)
        ignored.reconcileInstalledApps([])
        XCTAssertTrue(ignored.visibleBundleIDs.isEmpty)
        XCTAssertEqual(ignored.bundleIDs.count, 2)
    }
    func testPartialMetadataDoesNotEraseVerifiedInstallationState() {
        var ignored = IgnoredApplications()
        let app = record("a").installed
        ignored.ignore(app); ignored.reconcileInstalledApps([app])
        ignored.captureMetadata(from: [])
        XCTAssertEqual(ignored.visibleBundleIDs, ["a"])
        ignored.reconcileInstalledApps([])
        ignored.captureMetadata(from: [app])
        XCTAssertTrue(ignored.visibleBundleIDs.isEmpty)
        ignored.ignore(record("b").installed)
        XCTAssertEqual(ignored.visibleBundleIDs, ["b"])
        ignored.restore("b")
        XCTAssertTrue(ignored.visibleBundleIDs.isEmpty)
    }
    func testRefreshRepairsExistingIgnoredMetadataWithoutRestoringOrDroppingRemoteIcon() throws {
        var ignored = IgnoredApplications()
        let old = InstalledApp(bundleID: "hidden", name: "Hidden", version: "1")
        let remote = URL(string: "https://example.com/icon.png")!
        ignored.ignore(old, iconURL: remote)
        var refreshed = old; refreshed.version = "2"; refreshed.localIconKey = String(repeating: "a", count: 64)
        ignored.captureMetadata(from: [refreshed, record("visible").installed])
        XCTAssertEqual(ignored.application(for: "hidden").localIconKey, refreshed.localIconKey)
        XCTAssertEqual(ignored.application(for: "hidden").version, "2")
        XCTAssertEqual(ignored.iconURLs?["hidden"], remote)
        XCTAssertEqual(ignored.visible([AppRecord(installed: refreshed), record("visible")]).map(\.id), ["visible"])
        ignored.captureMetadata(from: [old])
        XCTAssertEqual(ignored.application(for: "hidden").localIconKey, refreshed.localIconKey)
        XCTAssertEqual(ignored.bundleIDs, ["hidden"])
        XCTAssertNil(ignored.applications?["visible"])
    }
    func testEvictedLocalIconAllowsStoreFallbackAndRepairedFileBecomesAvailable() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let key = String(repeating: "b", count: 64)
        let app = InstalledApp(bundleID: "hidden", name: "Hidden", version: "1", localIconKey: key)
        let remote = URL(string: "https://example.com/icon.png")!
        XCTAssertEqual(LocalAppIcon.url(for: app, in: directory) ?? remote, remote)
        let local = directory.appendingPathComponent(key).appendingPathExtension("png")
        try Data([1, 2, 3]).write(to: local)
        XCTAssertEqual(LocalAppIcon.url(for: app, in: directory), local)
        try FileManager.default.removeItem(at: local)
        XCTAssertNil(LocalAppIcon.url(for: app, in: directory))
        var invalid = app; invalid.localIconKey = "../" + key
        XCTAssertNil(LocalAppIcon.url(for: invalid, in: directory))
    }
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

