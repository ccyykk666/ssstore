import Foundation
import XCTest
@testable import UpdateCore

final class CacheCleanupTests: XCTestCase {
    func testKeepsReferencedInspectionFilesAndRecentWork() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let reference = root.appendingPathComponent("current-report")
        let report = try write(reference.appendingPathComponent("report.json"), old: true)
        let payload = try write(reference.appendingPathComponent("icon.png"), old: true)
        let obsolete = try write(root.appendingPathComponent("unused.bin"), old: true)
        let recent = try write(root.appendingPathComponent("new-work.bin"), old: false)
        let removed = try CacheCleanup.removeUnusedFiles(in: root, keeping: [reference], olderThan: Date().addingTimeInterval(-86400))
        XCTAssertEqual(removed, 4)
        for file in [report, payload, recent] { XCTAssertTrue(FileManager.default.fileExists(atPath: file.path)) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: obsolete.path))
    }

    func testPreservesPausedAndActiveDownloadFilesButCleansOldOrphans() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let paused = UUID(), active = UUID(), orphan = UUID()
        var retained: [URL] = []
        for id in [paused, active] {
            for suffix in ["resume", "partial", "ranges", "download"] {
                retained.append(try write(root.appendingPathComponent("\(id).\(suffix)"), old: true))
            }
        }
        let stale = try write(root.appendingPathComponent("\(orphan).partial"), old: true)
        let unknown = try write(root.appendingPathComponent("unrecognized.data"), old: true)
        _ = try CacheCleanup.removeUnusedFiles(in: root, keeping: [], olderThan: Date().addingTimeInterval(-86400),
                                              downloadIdentifiers: [paused, active])
        for file in retained + [unknown] { XCTAssertTrue(FileManager.default.fileExists(atPath: file.path)) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: stale.path))
    }

    func testDoesNotFollowSymlinkIntoUserData() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let userData = try write(base.appendingPathComponent("Documents/account.data"), old: true)
        let root = base.appendingPathComponent("Caches/owned")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let link = root.appendingPathComponent("outside")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: userData.deletingLastPathComponent())
        _ = try CacheCleanup.removeUnusedFiles(in: root, keeping: [], olderThan: Date())
        _ = try CacheCleanup.removeUnusedFiles(in: link, keeping: [], olderThan: Date())
        XCTAssertEqual(try Data(contentsOf: userData), Data("data".utf8))
    }

    private func write(_ url: URL, old: Bool) throws -> URL {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("data".utf8).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(old ? -172800 : 0)], ofItemAtPath: url.path)
        return url
    }
}
