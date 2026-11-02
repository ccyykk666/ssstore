import Foundation

enum HistorySupportChecks {
    private enum Failure: Error { case example }
    private actor Counter {
        private(set) var calls = 0
        func increment() { calls += 1 }
    }

    static func run() async throws {
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
        precondition(invalidDate.metadata.isEmpty && !invalidDate.identifiers.isEmpty)
        let fractional = try StoreHistorySupport.index(item(returned: "2", date: "2026-01-01T00:00:00.123Z"))
        precondition(fractional.metadata["2"] != nil)
        do {
            _ = try StoreHistorySupport.index(["metadata": ["softwareVersionExternalIdentifiers": []]])
            fatalError("Accepted empty history")
        } catch StoreDownloadError.noVersions {}

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
        print("History cache, response reuse, and concurrent-cookie regression checks passed.")
    }
}
