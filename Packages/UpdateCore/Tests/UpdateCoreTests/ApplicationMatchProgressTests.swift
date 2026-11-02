import XCTest
@testable import UpdateCore

final class ApplicationMatchProgressTests: XCTestCase {
    private func record(_ id: String, local: String? = "1", remote: String? = "1",
                        error: String? = nil, system: Bool = false) -> AppRecord {
        var record = AppRecord(installed: InstalledApp(bundleID: id, name: id, version: "1.0",
            isSystem: system, externalVersionID: local))
        record.release = StoreRelease(bundleID: id, name: id, version: "2.0",
            country: "cn", externalVersionID: remote)
        record.error = error
        return record
    }

    private func assertValid(_ stats: ApplicationMatchStatistics, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertGreaterThanOrEqual(stats.applications, 0, file: file, line: line)
        XCTAssertGreaterThanOrEqual(stats.updates, 0, file: file, line: line)
        XCTAssertGreaterThanOrEqual(stats.pending, 0, file: file, line: line)
        XCTAssertGreaterThanOrEqual(stats.failures, 0, file: file, line: line)
        XCTAssertLessThanOrEqual(stats.updates + stats.pending + stats.failures, stats.applications, file: file, line: line)
    }

    func testCachedUpdateIsNotShownBeforeFreshMatchIsRevealed() {
        let stale = record("a", remote: "2")
        XCTAssertEqual(stale.status(country: "cn"), .different)
        var progress = ApplicationMatchProgress(scope: "cn")
        let ids: Set<String> = ["a"]
        XCTAssertEqual(progress.statistics(visibleIDs: ids).applications, 0)
        XCTAssertEqual(progress.statistics(visibleIDs: ids).updates, 0)
        progress.complete(record("a")) // Fresh response says it is current.
        XCTAssertEqual(progress.statistics(visibleIDs: ids).applications, 0)
        progress.revealNext(hidingSystemApps: false)
        let stats = progress.statistics(visibleIDs: ids)
        XCTAssertEqual(stats.applications, 1)
        XCTAssertEqual(stats.updates, 0)
        assertValid(stats)
    }

    func testAllCountersUseTheSameCompletionOrderedPrefixAcrossBatches() {
        var progress = ApplicationMatchProgress(scope: "cn")
        progress.complete(record("b", remote: "2"))
        progress.complete(record("a", local: nil))
        let ids: Set<String> = ["a", "b", "c", "d"]
        progress.revealNext(hidingSystemApps: false)
        XCTAssertEqual(progress.revealedMatches.map(\.id), ["b"])
        XCTAssertEqual(progress.statistics(visibleIDs: ids).updates, 1)
        progress.complete(record("d", error: "network"))
        progress.complete(record("c"))
        while progress.hasUnrevealed {
            progress.revealNext(hidingSystemApps: false)
            let stats = progress.statistics(visibleIDs: ids)
            XCTAssertEqual(stats.applications, progress.revealedCount)
            assertValid(stats)
        }
        let stats = progress.statistics(visibleIDs: ids)
        XCTAssertEqual(stats.applications, 4)
        XCTAssertEqual(stats.updates, 1)
        XCTAssertEqual(stats.pending, 1)
        XCTAssertEqual(stats.failures, 1)
    }

    func testStoppingDoesNotRevealUnprocessedCachedResultsAndRestartResetsEverything() {
        var progress = ApplicationMatchProgress(scope: "cn")
        for index in 0..<25 { progress.complete(record(String(index), remote: "2")) }
        let ids = Set((0..<50).map { String($0) })
        for _ in 0..<8 { progress.revealNext(hidingSystemApps: false) }
        // Cancellation leaves the cursor where it stopped, rather than counting
        // the remaining cached inventory as freshly matched.
        XCTAssertEqual(progress.statistics(visibleIDs: ids).applications, 8)
        XCTAssertEqual(progress.statistics(visibleIDs: ids).updates, 8)
        let replacement = ApplicationMatchProgress(scope: "cn")
        XCTAssertNotEqual(progress.id, replacement.id)
        let reset = replacement.statistics(visibleIDs: ids)
        XCTAssertEqual(reset.applications, 0)
        XCTAssertEqual(reset.updates, 0)
        XCTAssertEqual(reset.pending, 0)
        assertValid(reset)
    }

    func testHiddenSystemsAndRemovedApplicationsCannotDistortCounts() {
        var progress = ApplicationMatchProgress(scope: "cn")
        for index in 0..<100 { progress.complete(record("system\(index)", local: nil, system: true)) }
        progress.complete(record("app", local: nil))
        progress.revealNext(hidingSystemApps: true)
        let stats = progress.statistics(visibleIDs: ["app"])
        XCTAssertEqual(stats.applications, 1)
        XCTAssertEqual(stats.pending, 1)
        XCTAssertFalse(progress.hasUnrevealed)
        let removed = progress.statistics(visibleIDs: [])
        XCTAssertEqual(removed.applications, 0)
        XCTAssertEqual(removed.pending, 0)
        assertValid(removed)
    }

    func testDuplicateMatchUpdatesOutcomeWithoutAddingAnotherApplication() {
        var progress = ApplicationMatchProgress(scope: "cn")
        progress.complete(record("a", local: nil))
        progress.complete(record("a", remote: "2"))
        XCTAssertEqual(progress.matches.count, 1)
        progress.revealNext(hidingSystemApps: false)
        for _ in 0..<100 { XCTAssertFalse(progress.revealNext(hidingSystemApps: false)) }
        let stats = progress.statistics(visibleIDs: ["a"])
        XCTAssertEqual(stats.applications, 1)
        XCTAssertEqual(stats.updates, 1)
        XCTAssertEqual(stats.pending, 0)
        assertValid(stats)
    }
}
