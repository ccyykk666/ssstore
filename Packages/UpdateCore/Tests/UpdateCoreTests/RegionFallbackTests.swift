import XCTest
@testable import UpdateCore

final class RegionFallbackTests: XCTestCase {
    private static func release(_ id: String, country: String, version: String = "2.0") -> StoreRelease {
        StoreRelease(bundleID: id, name: id, version: version, country: country, source: "Apple Catalog")
    }

    func testDefaultMigrationAndManualSelection() {
        XCTAssertEqual(StoreQueryPolicy.initialScope(saved: nil, migrated: false), "cn-us")
        XCTAssertEqual(StoreQueryPolicy.initialScope(saved: "cn", migrated: false), "cn-us")
        XCTAssertEqual(StoreQueryPolicy.initialScope(saved: "us", migrated: false), "us")
        XCTAssertEqual(StoreQueryPolicy.initialScope(saved: "cn", migrated: true), "cn")
    }

    func testAllFoundInChinaSkipsUS() async throws {
        let trace = RequestTrace()
        let result = try await AppleLookup.resolveScope(bundleIDs: ["a"], scope: "cn-us") { ids, region, _ in
            await trace.append(region, ids: ids)
            return LookupBatch(releases: ["a": Self.release("a", country: region)])
        }
        let calls = await trace.regions
        XCTAssertEqual(calls, ["cn"])
        XCTAssertEqual(result.releases["a"]?.country, "cn")
        XCTAssertEqual(result.releases["a"]?.lookupScope, "cn-us")
    }

    func testOnlyMissingAppsRetryInUSAndChinaWins() async throws {
        let trace = RequestTrace()
        let result = try await AppleLookup.resolveScope(bundleIDs: ["a", "b", "b"], scope: "cn-us") { ids, region, _ in
            await trace.append(region, ids: ids)
            if region == "cn" { return LookupBatch(releases: ["a": Self.release("a", country: region)]) }
            return LookupBatch(releases: ["b": Self.release("b", country: region)])
        }
        let calls = await trace.regions
        let requests = await trace.ids
        XCTAssertEqual(calls, ["cn", "us"])
        XCTAssertEqual(requests.last, ["b"])
        XCTAssertEqual(result.releases["a"]?.country, "cn")
        XCTAssertEqual(result.releases["b"]?.country, "us")
        var app = AppRecord(installed: InstalledApp(bundleID: "b", name: "b", version: "1.0"))
        app.release = result.releases["b"]
        XCTAssertEqual(app.status(country: "cn-us"), .update)
        XCTAssertEqual(app.status(country: "cn"), .unknown)
    }

    func testChinaNetworkFailureDoesNotTriggerUS() async {
        let trace = RequestTrace()
        do {
            _ = try await AppleLookup.resolveScope(bundleIDs: ["a"], scope: "cn-us") { ids, region, _ in
                await trace.append(region, ids: ids)
                throw LookupError.http(503)
            }
            XCTFail("CN failure must propagate")
        } catch { }
        let calls = await trace.regions
        XCTAssertEqual(calls, ["cn"])
    }

    func testUSRateLimitKeepsChineseResultsAndStopsBatch() async throws {
        let result = try await AppleLookup.resolveScope(bundleIDs: ["a", "b"], scope: "cn-us") { _, region, _ in
            if region == "cn" { return LookupBatch(releases: ["a": Self.release("a", country: region)]) }
            throw LookupError.http(429)
        }
        XCTAssertEqual(result.releases["a"]?.country, "cn")
        XCTAssertNil(result.releases["b"])
        XCTAssertNotNil(result.errors["b"])
        XCTAssertTrue(result.stopAfterBatch)
    }

    func testManualUSDoesNotQueryChina() async throws {
        let trace = RequestTrace()
        _ = try await AppleLookup.resolveScope(bundleIDs: ["a"], scope: "us") { ids, region, _ in
            await trace.append(region, ids: ids)
            return LookupBatch(releases: [:])
        }
        let calls = await trace.regions
        XCTAssertEqual(calls, ["us"])
    }

    func testFallbackCacheRequiresPriorChinaMiss() {
        var us = Self.release("a", country: "us")
        XCTAssertFalse(AppleLookup.isFresh(us, country: "cn-us"))
        us.lookupScope = "cn-us"
        XCTAssertTrue(AppleLookup.isFresh(us, country: "cn-us"))
        XCTAssertFalse(AppleLookup.isFresh(us, country: "cn"))
        XCTAssertTrue(AppleLookup.isFresh(Self.release("a", country: "cn"), country: "cn-us"))
    }

    func testBothStoresMissingAndOldInventoryCompatibility() async throws {
        let result = try await AppleLookup.resolveScope(bundleIDs: ["a"], scope: "cn-us") { _, _, _ in
            LookupBatch(releases: [:])
        }
        XCTAssertTrue(result.releases.isEmpty)
        XCTAssertTrue(StoreQueryPolicy.notFoundMessage(scope: "cn-us").contains("中国区和美区"))
        let old = Data(#"{"bundleID":"a","name":"a","version":"1","country":"cn","fetchedAt":0}"#.utf8)
        let release = try JSONDecoder().decode(StoreRelease.self, from: old)
        XCTAssertNil(release.lookupScope)
        XCTAssertTrue(release.matches(scope: "cn-us"))
    }
}

private actor RequestTrace {
    var regions: [String] = []
    var ids: [[String]] = []
    func append(_ region: String, ids: [String]) {
        regions.append(region)
        self.ids.append(ids)
    }
}
