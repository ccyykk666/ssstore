import Foundation

enum HistorySupportChecks {
    private enum Failure: Error { case example }
    private actor Counter {
        private(set) var calls = 0
        func increment() { calls += 1 }
    }

    static func run() async throws {
        let prepared = StorePreparedDownloadCache<String>(lifetime: 10)
        typealias Key = StorePreparedDownloadCache<String>.Key
        let identity = Key(account: "first", token: "token", guid: "device", store: "store", app: "app", platform: "iPhone", version: "old")
        let otherAccount = Key(account: "second", token: "token", guid: "device", store: "store", app: "app", platform: "iPhone", version: "old")
        let rotatedToken = Key(account: "first", token: "new", guid: "device", store: "store", app: "app", platform: "iPhone", version: "old")
        let preparedAt = Date(timeIntervalSince1970: 1000)
        await prepared.insert("signed reply", for: identity, now: preparedAt)
        let wrongAccount = await prepared.take(for: otherAccount, now: preparedAt)
        let wrongSession = await prepared.take(for: rotatedToken, now: preparedAt)
        precondition(wrongAccount == nil && wrongSession == nil, "History replies cannot cross accounts or rotated sessions")
        let ready = await prepared.take(for: identity, now: preparedAt.addingTimeInterval(9))
        let consumed = await prepared.take(for: identity, now: preparedAt.addingTimeInterval(9))
        precondition(ready == "signed reply" && consumed == nil, "A history reply may start one download without another store request")
        await prepared.insert("expired reply", for: identity, now: preparedAt)
        let expired = await prepared.take(for: identity, now: preparedAt.addingTimeInterval(10))
        precondition(expired == nil, "Expired asset URLs must be fetched again")

        let url = URL(string: "https://downloaddispatch.itunes.apple.com" + StoreDownloadProtocol.entPath)!
        let count = Counter()
        let cache = StoreBagCache(lifetime: 10)
        let now = Date(timeIntervalSince1970: 1000)
        let load: @Sendable () async throws -> URL? = {
            await count.increment()
            try await Task.sleep(nanoseconds: 20_000_000)
            return url
        }
        async let first = cache.endpoint(for: "AABB", now: now, load: load)
        async let second = cache.endpoint(for: "aabb", now: now, load: load)
        let results = try await (first, second)
        precondition(results.0 == url && results.1 == url)
        var calls = await count.calls
        precondition(calls == 1, "Concurrent bag requests must coalesce")
        _ = try await cache.endpoint(for: "aabb", now: now.addingTimeInterval(9), load: load)
        calls = await count.calls
        precondition(calls == 1)
        _ = try await cache.endpoint(for: "aabb", now: now.addingTimeInterval(10), load: load)
        _ = try await cache.endpoint(for: "different", now: now, load: load)
        calls = await count.calls
        precondition(calls == 3, "Expiry and device keys must be respected")

        let noEndpoint = StoreBagCache()
        let legacyCalls = Counter()
        for _ in 0..<2 {
            let result = try await noEndpoint.endpoint(for: "legacy") {
                await legacyCalls.increment()
                return nil
            }
            precondition(result == nil)
        }
        calls = await legacyCalls.calls
        precondition(calls == 1, "A valid legacy bag without ent/download is cacheable")

        let failureCache = StoreBagCache()
        do {
            _ = try await failureCache.endpoint(for: "retry") { throw Failure.example }
            fatalError("Expected bag failure")
        } catch Failure.example {}
        let recovered = try await failureCache.endpoint(for: "retry") { url }
        precondition(recovered == url, "A failed bag must not poison its cache")

        let cancellationCache = StoreBagCache()
        let pendingCount = Counter()
        let pendingLoad: @Sendable () async throws -> URL? = {
            await pendingCount.increment()
            try await Task.sleep(nanoseconds: 40_000_000)
            return url
        }
        let cancelled = Task { try await cancellationCache.endpoint(for: "shared", load: pendingLoad) }
        // Wait for the shared fetch to exist; cancellation of one waiter must
        // not cancel another request using the same bag.
        while await pendingCount.calls == 0 { await Task.yield() }
        cancelled.cancel()
        let surviving = try await cancellationCache.endpoint(for: "shared", load: pendingLoad)
        do { _ = try await cancelled.value; fatalError("Cancelled waiter returned success") }
        catch is CancellationError {}
        precondition(surviving == url)
        calls = await pendingCount.calls
        precondition(calls == 1)

        let identifiers = StoreHistorySupport.uniqueIdentifiers(["9", "", "2", "9", "opaque", "10"])
        precondition(identifiers == ["9", "2", "opaque", "10"], "Do not sort opaque version IDs")
        let missing = StoreHistorySupport.missingIdentifiers(["a", "b"], loaded: ["a", "stale"])
        precondition(missing == ["b"], "Equal cache counts do not imply matching IDs")

        func item(returned: String, date: String = "2026-01-01T00:00:00Z") -> [String: Any] {
            ["metadata": ["softwareVersionExternalIdentifiers": [1, 2, 2, "opaque", ""],
                          "softwareVersionExternalIdentifier": returned,
                          "bundleShortVersionString": "2.0", "releaseDate": date]]
        }
        let seeded = try StoreHistorySupport.index(item(returned: "2"))
        precondition(seeded.identifiers == ["1", "2", "opaque"])
        precondition(seeded.metadata.count == 1 && seeded.metadata["2"]?.version == "2.0")
        let mismatched = try StoreHistorySupport.index(item(returned: "other"))
        precondition(mismatched.metadata.isEmpty, "Latest metadata must not label another version")
        let invalidDate = try StoreHistorySupport.index(item(returned: "2", date: "invalid"))
        precondition(invalidDate.metadata["2"]?.releaseDate == nil && !invalidDate.identifiers.isEmpty)
        let fractional = try StoreHistorySupport.index(item(returned: "2", date: "2026-01-01T00:00:00.123Z"))
        precondition(fractional.metadata["2"] != nil)
        do {
            _ = try StoreHistorySupport.index(["metadata": ["softwareVersionExternalIdentifiers": []]])
            fatalError("Accepted empty history")
        } catch StoreDownloadError.noVersions {}

        // Regression: a syntactically valid app-level release date must never
        // be labelled as the release date of a historical version.
        let downloadMetadata = try StoreHistorySupport.details([
            "bundleShortVersionString": "9.04.66", "releaseDate": "2011-09-09T02:02:04Z"])
        precondition(downloadMetadata.releaseDate == nil)
        let legacy = Data(#"{"displayVersion":"9.04.66","releaseDate":337684924}"#.utf8)
        let migrated = try JSONDecoder().decode(StoreHistorySupport.Metadata.self, from: legacy)
        precondition(migrated.displayVersion == "9.04.66" && migrated.releaseDate == nil)

        let versions: [[String: Any]] = [
            ["externalVersionId": 893919123, "versionDisplay": "9.04.70",
             "releaseDate": "2026-10-27", "releaseTimestamp": "2026-10-27T11:28:26Z"],
            ["externalVersionId": 893599338, "versionDisplay": "9.04.66",
             "releaseDate": "2026-10-22", "releaseTimestamp": "2026-10-22T02:27:46Z"],
            ["externalVersionId": 893256306, "versionDisplay": "9.04.65",
             "releaseDate": "2026-10-21", "releaseTimestamp": "2026-10-21T09:15:51.123Z"],
            ["externalVersionId": "892756980", "versionDisplay": "9.04.60", "releaseDate": "2026-10-12"],
            ["externalVersionId": "0", "versionDisplay": "invalid"],
        ]
        func catalogData(id: String = "458318329", bundle: String = "com.tencent.live4iphone",
                         families: [String] = ["iphone", "ipad"], platformKey: String = "ios",
                         rows: [[String: Any]]? = nil) throws -> Data {
            try JSONSerialization.data(withJSONObject: ["data": [
                ["id": id, "type": "apps", "attributes": [
                    "deviceFamilies": families, "platformAttributes": [
                        platformKey: ["bundleId": bundle, "versionHistory": rows ?? versions]]]]]])
        }
        let catalog = try StoreHistorySupport.catalogIndex(catalogData(), appID: 458318329,
            bundleID: "com.tencent.live4iphone", platform: "iphone")
        precondition(catalog.identifiers == ["893919123", "893599338", "893256306", "892756980"])
        precondition(catalog.metadata["893599338"]?.displayVersion == "9.04.66")
        precondition(catalog.metadata["893599338"]?.releaseDate == StoreHistorySupport.date("2026-10-22T02:27:46Z"))
        precondition(catalog.metadata["893256306"]?.releaseDate != nil)
        precondition(catalog.metadata["892756980"]?.releaseDate == StoreHistorySupport.date("2026-10-12"))
        let trusted = catalog.metadata["893599338"]!
        let roundTrip = try JSONDecoder().decode(StoreHistorySupport.Metadata.self, from: JSONEncoder().encode(trusted))
        precondition(roundTrip == trusted, "Trusted dates survive cache reload")
        for invalid in try [
            catalogData(id: "999"),
            catalogData(bundle: "other.app"),
            catalogData(families: ["appletv"], platformKey: "appletvos"),
            catalogData(rows: [versions[0], ["externalVersionId": 893919123, "versionDisplay": "different"]]),
        ] {
            do {
                _ = try StoreHistorySupport.catalogIndex(invalid, appID: 458318329,
                    bundleID: "com.tencent.live4iphone", platform: "iphone")
                fatalError("Accepted a mismatched catalog response")
            } catch StoreDownloadError.invalidPackage {}
        }
        let unknownDate = try StoreHistorySupport.catalogIndex(
            catalogData(rows: [["externalVersionId": 123, "versionDisplay": "1.0", "releaseDate": "invalid"]]),
            appID: 458318329, bundleID: "com.tencent.live4iphone", platform: "iphone")
        precondition(unknownDate.metadata["123"]?.releaseDate == nil)
        precondition(StoreHistorySupport.date("2026-02-30") == nil)
        let request = try StoreCatalogHistoryService.request(appID: 458318329, region: "CN", platform: "iphone")
        precondition(request.url?.host == "apps.apple.com" && request.url?.scheme == "https")
        precondition(request.url?.path == "/api/apps/v1/catalog/cn/apps/458318329")
        let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
        precondition(query.contains(URLQueryItem(name: "extend", value: "versionHistory")))
        for header in ["Cookie", "Authorization", "X-Token", "X-Dsid", "iCloud-DSID"] {
            precondition(request.value(forHTTPHeaderField: header) == nil)
        }
        for region in ["", "cn/other", "c1"] {
            do {
                _ = try StoreCatalogHistoryService.request(appID: 458318329, region: region, platform: "iphone")
                fatalError("Accepted an invalid catalog region")
            } catch StoreDownloadError.invalidPackage {}
        }

        struct Cookie: Equatable {
            let name: String
            let value: String
            let domain: String
            var identity: [String] { [name, StoreProtocol.storeCookieDomain(domain) ?? ""] }
        }
        let a = Cookie(name: "a", value: "old", domain: ".itunes.apple.com")
        let b = Cookie(name: "b", value: "old", domain: "itunes.apple.com")
        let newerA = Cookie(name: "a", value: "other-response", domain: "itunes.apple.com")
        let newerB = Cookie(name: "b", value: "this-response", domain: "itunes.apple.com")
        let c = Cookie(name: "c", value: "concurrent", domain: "itunes.apple.com")
        let merged = StoreHistorySupport.mergingChanges(current: [newerA, b, c],
            original: [a, b], updated: [a, newerB], key: { $0.identity })
        precondition(Set(merged.map(\.value)) == ["other-response", "this-response", "concurrent"])
        let deleted = StoreHistorySupport.mergingChanges(current: [newerA, b, c],
            original: [a, b], updated: [a], key: { $0.identity })
        precondition(deleted == [newerA, c], "Deletions must not erase concurrent unrelated cookies")
        print("History catalog, date provenance, cache, and concurrent-cookie regression checks passed.")
    }
}
