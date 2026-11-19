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

enum StoreHistorySupport {
    static func removeLegacyCache(in directory: URL) throws {
        guard FileManager.default.fileExists(atPath: directory.path),
              try directory.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else { return }
        let manager = FileManager.default
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey]
        let files = try manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys)
        let suffixes = ["versions", "versionNumbers", "versionIndexFetchedAt", "catalogHistoryFetchedAt"]
        for file in files {
            let name = file.pathExtension == "corrupt" ? file.deletingPathExtension() : file
            let prefix = name.deletingPathExtension().lastPathComponent
            // Older history keys used the bundle ID twice, followed by the
            // storefront country and device type.
            guard suffixes.contains(name.pathExtension),
                  prefix.range(of: #"^([a-z0-9.-]+)\1[a-z]{2}(?:iphone|ipad|appletv)$"#,
                               options: .regularExpression) != nil
            else { continue }
            let values = try file.resourceValues(forKeys: Set(keys))
            guard values.isRegularFile == true, values.isSymbolicLink != true else { continue }
            do { try manager.removeItem(at: file) }
            catch CocoaError.fileNoSuchFile { continue }
        }
    }

    struct Metadata: Codable, Equatable, Sendable {
        let displayVersion: String
        let releaseDate: Date?
        let releaseNotes: String?
        private let dateSource: String?
        var version: String { displayVersion }

        init(version: String, catalogDate: Date? = nil, releaseNotes: String? = nil) {
            displayVersion = version
            releaseDate = catalogDate
            self.releaseNotes = releaseNotes.flatMap {
                $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0
            }
            dateSource = catalogDate == nil ? nil : "apple-catalog-history-v1"
        }

        func fillingMissingFields(from fallback: Metadata?) -> Metadata {
            guard let fallback, fallback.displayVersion == displayVersion else { return self }
            return Metadata(version: displayVersion, catalogDate: releaseDate ?? fallback.releaseDate,
                            releaseNotes: releaseNotes ?? fallback.releaseNotes)
        }

        private enum CodingKeys: String, CodingKey { case displayVersion, releaseDate, releaseNotes, dateSource }
        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            displayVersion = try values.decode(String.self, forKey: .displayVersion)
            releaseNotes = try values.decodeIfPresent(String.self, forKey: .releaseNotes)
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
              let families = attributes["deviceFamilies"] as? [String],
              platform == "appletv" ? families.contains("appletv") : families.contains(where: { $0 == "iphone" || $0 == "ipad" }),
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
            let metadata = Metadata(version: version, catalogDate: timestamp, releaseNotes: row["releaseNotes"] as? String)
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

    static func pageHistory(_ data: Data, appID: Int64, bundleID: String, region: String) throws -> [String: Metadata] {
        guard let html = String(data: data, encoding: .utf8),
              let marker = html.range(of: "id=\"serialized-server-data\""),
              let opening = html[marker.upperBound...].firstIndex(of: ">"),
              let end = html.range(of: "</script>", range: opening..<html.endIndex),
              let root = try JSONSerialization.jsonObject(with: Data(html[html.index(after: opening)..<end.lowerBound].utf8)) as? [String: Any],
              let pages = root["data"] as? [[String: Any]],
              let page = pages.first(where: {
                  let intent = $0["intent"] as? [String: Any]
                  return StoreProtocol.string(intent?["id"]) == String(appID) && intent?["storefront"] as? String == region.lowercased()
              }),
              let product = page["data"] as? [String: Any],
              let offer = product["titleOfferDisplayProperties"] as? [String: Any],
              StoreProtocol.string(offer["adamId"]) == String(appID), offer["bundleId"] as? String == bundleID,
              let devices = product["appPlatforms"] as? [String], devices.contains(where: { $0 == "phone" || $0 == "pad" }),
              let shelves = product["shelfMapping"] as? [String: Any],
              let recent = shelves["mostRecentVersion"] as? [String: Any],
              let action = recent["seeAllAction"] as? [String: Any],
              let history = action["pageData"] as? [String: Any],
              let historyShelves = history["shelves"] as? [[String: Any]]
        else { throw StoreDownloadError.catalogUnavailable }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "EEE MMM dd yyyy HH:mm:ss 'GMT'Z"
        let rows = historyShelves.flatMap { $0["items"] as? [[String: Any]] ?? [] }
        let labels = Dictionary(grouping: rows.compactMap { row -> Metadata? in
            guard row["$kind"] as? String == "TitledParagraph",
                  let version = row["primarySubtitle"] as? String, !version.isEmpty else { return nil }
            let timestamp = (row["secondarySubtitle"] as? String).flatMap { stamp in
                date(stamp) ?? formatter.date(from: stamp.components(separatedBy: " (").first ?? stamp)
            }
            return Metadata(version: version, catalogDate: timestamp, releaseNotes: row["text"] as? String)
        }, by: \.displayVersion)
        return labels.compactMapValues { entries in
            guard entries.count == 1, let entry = entries.first,
                  entry.releaseDate != nil || entry.releaseNotes != nil else { return nil }
            return entry
        }
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
