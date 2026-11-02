import Foundation

/// Public endpoint configuration only; never retains account headers or replies.
actor StoreBagCache {
    private struct Entry {
        let endpoint: URL?
        let expires: Date
    }
    private struct Pending {
        let id: UUID
        let task: Task<URL?, Error>
    }
    private var entries: [String: Entry] = [:]
    private var pending: [String: Pending] = [:]
    private let lifetime: TimeInterval

    init(lifetime: TimeInterval = 900) { self.lifetime = lifetime }

    func endpoint(for guid: String, now: Date = Date(),
                  load: @escaping @Sendable () async throws -> URL?) async throws -> URL? {
        let key = guid.lowercased()
        if let entry = entries[key], entry.expires > now {
            try Task.checkCancellation()
            return entry.endpoint
        }
        let job: Pending
        if let existing = pending[key] { job = existing }
        else {
            job = Pending(id: UUID(), task: Task { try await load() })
            pending[key] = job
        }
        let result = await job.task.result
        if pending[key]?.id == job.id {
            pending.removeValue(forKey: key)
            if case let .success(endpoint) = result {
                entries[key] = Entry(endpoint: endpoint, expires: now.addingTimeInterval(lifetime))
            }
        }
        try Task.checkCancellation()
        return try result.get()
    }
}

enum StoreHistorySupport {
    struct Metadata: Sendable {
        let version: String
        let releaseDate: Date
    }
    struct Index: Sendable {
        let identifiers: [String]
        let metadata: [String: Metadata]
    }

    static func details(_ metadata: [String: Any]) throws -> Metadata {
        guard let version = metadata["bundleShortVersionString"] as? String, !version.isEmpty,
              let dateString = metadata["releaseDate"] as? String
        else { throw StoreDownloadError.invalidPackage }
        let formatter = ISO8601DateFormatter()
        let ordinary = formatter.date(from: dateString)
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let releaseDate = ordinary ?? formatter.date(from: dateString)
        else { throw StoreDownloadError.invalidPackage }
        return Metadata(version: version, releaseDate: releaseDate)
    }

    static func index(_ item: [String: Any]) throws -> Index {
        guard let metadata = item["metadata"] as? [String: Any],
              let values = metadata["softwareVersionExternalIdentifiers"] as? [Any]
        else { throw StoreDownloadError.noVersions }
        let identifiers = uniqueIdentifiers(values.map { StoreProtocol.string($0) })
        guard !identifiers.isEmpty else { throw StoreDownloadError.noVersions }
        let returned = StoreProtocol.string(metadata["softwareVersionExternalIdentifier"])
        var known: [String: Metadata] = [:]
        if identifiers.contains(returned), let details = try? details(metadata) { known[returned] = details }
        return Index(identifiers: identifiers, metadata: known)
    }

    static func uniqueIdentifiers(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        return values.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    static func missingIdentifiers(_ identifiers: [String], loaded: Set<String>) -> [String] {
        identifiers.filter { !loaded.contains($0) }
    }

    /// Apply only this response's cookie changes. A concurrent metadata response
    /// must not replace newer credentials or erase other responses' cookies.
    static func mergingChanges<Value: Equatable, Key: Hashable>(
        current: [Value], original: [Value], updated: [Value], key: (Value) -> Key
    ) -> [Value] {
        let before = original.reduce(into: [Key: Value]()) { $0[key($1)] = $1 }
        let after = updated.reduce(into: [Key: Value]()) { $0[key($1)] = $1 }
        let changed = Set(before.keys).union(after.keys).filter { before[$0] != after[$0] }
        var merged = current.filter { !changed.contains(key($0)) }
        for value in updated where changed.contains(key(value)) {
            merged.removeAll { key($0) == key(value) }
            merged.append(value)
        }
        return merged
    }
}
