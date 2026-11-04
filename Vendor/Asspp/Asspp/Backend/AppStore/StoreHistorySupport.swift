import Foundation

/// Briefly reuse authenticated history replies without persisting signed URLs.
actor StorePreparedDownloadCache<Value> {
    struct Key: Hashable, Sendable {
        let account: String
        let token: String
        let guid: String
        let store: String
        let app: String
        let platform: String
        let version: String
    }
    private var entries: [Key: (value: Value, expires: Date)] = [:]
    private let lifetime: TimeInterval
    init(lifetime: TimeInterval = 60) { self.lifetime = lifetime }

    func insert(_ value: Value, for key: Key, now: Date = Date()) {
        entries = entries.filter { $0.value.expires > now }
        entries[key] = (value, now.addingTimeInterval(lifetime))
    }

    func take(for key: Key, now: Date = Date()) -> Value? {
        guard let entry = entries.removeValue(forKey: key), entry.expires > now else { return nil }
        return entry.value
    }
}

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
    struct Metadata: Codable, Equatable, Sendable {
        let displayVersion: String
        let releaseDate: Date?
        private let dateSource: String?
        var version: String { displayVersion }

        init(version: String, catalogDate: Date? = nil) {
            displayVersion = version
            releaseDate = catalogDate
            dateSource = catalogDate == nil ? nil : "apple-catalog-history-v1"
        }

        private enum CodingKeys: String, CodingKey { case displayVersion, releaseDate, dateSource }
        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            displayVersion = try values.decode(String.self, forKey: .displayVersion)
            dateSource = try values.decodeIfPresent(String.self, forKey: .dateSource)
            // Older caches used the download reply's app-level releaseDate.
            // Preserve version labels, but never display that date as a build date.
            if dateSource == "apple-catalog-history-v1" {
                releaseDate = try values.decodeIfPresent(Date.self, forKey: .releaseDate)
            } else { releaseDate = nil }
        }
    }

    struct Index: Sendable {
        let identifiers: [String]
        let metadata: [String: Metadata]
    }

    static func date(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        if let value = formatter.date(from: text) { return value }
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let value = formatter.date(from: text) { return value }
        let day = DateFormatter()
        day.locale = Locale(identifier: "en_US_POSIX")
        day.timeZone = TimeZone(secondsFromGMT: 0)
        day.dateFormat = "yyyy-MM-dd"
        day.isLenient = false
        guard text.count == 10, let value = day.date(from: text), day.string(from: value) == text else { return nil }
        return value
    }

    static func details(_ metadata: [String: Any]) throws -> Metadata {
        guard let version = metadata["bundleShortVersionString"] as? String, !version.isEmpty
        else { throw StoreDownloadError.invalidPackage }
        // This API's releaseDate can refer to the app's first release, even when
        // externalVersionId is pinned. It is not a historical-version date.
        return Metadata(version: version)
    }

    static func catalogIndex(_ data: Data, appID: Int64, bundleID: String, platform: String) throws -> Index {
        guard ["iphone", "ipad", "appletv"].contains(platform), !bundleID.isEmpty,
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = root["data"] as? [[String: Any]], items.count == 1,
              let item = items.first, StoreProtocol.string(item["id"]) == String(appID),
              item["type"] as? String == "apps",
              let attributes = item["attributes"] as? [String: Any],
              let families = attributes["deviceFamilies"] as? [String], families.contains(platform),
              let platforms = attributes["platformAttributes"] as? [String: Any],
              let details = platforms[platform == "appletv" ? "appletvos" : "ios"] as? [String: Any],
              details["bundleId"] as? String == bundleID,
              let history = details["versionHistory"] as? [[String: Any]]
        else { throw StoreDownloadError.invalidPackage }
        var identifiers: [String] = []
        var known: [String: Metadata] = [:]
        for row in history {
            let id = StoreProtocol.string(row["externalVersionId"])
            guard !id.isEmpty, id.utf8.allSatisfy({ (48...57).contains($0) }),
                  id.contains(where: { $0 != "0" }),
                  let version = row["versionDisplay"] as? String, !version.isEmpty else { continue }
            let timestamp = (row["releaseTimestamp"] as? String).flatMap(date)
                ?? (row["releaseDate"] as? String).flatMap(date)
            let metadata = Metadata(version: version, catalogDate: timestamp)
            if let previous = known[id] {
                guard previous == metadata else { throw StoreDownloadError.invalidPackage }
                continue
            }
            identifiers.append(id)
            known[id] = metadata
        }
        guard !identifiers.isEmpty else { throw StoreDownloadError.noVersions }
        return Index(identifiers: identifiers, metadata: known)
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
