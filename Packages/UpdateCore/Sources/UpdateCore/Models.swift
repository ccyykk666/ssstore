import Foundation

public struct InstalledApp: Codable, Identifiable, Equatable, Sendable {
    public var id: String { bundleID }
    public var bundleID: String
    public var name: String
    public var version: String?
    public var build: String?
    public var isSystem: Bool
    public var localIconKey: String?
    public var storeID: String?
    public var externalVersionID: String?
    public var coreDeviceVersion: String?
    public var coreDeviceBuild: String?
    public var browseVersion: String?
    public var browseBuild: String?
    public var metadataVersion: String?
    public var metadataBuild: String?
    public var versionReadNote: String?

    public init(bundleID: String, name: String, version: String?, build: String? = nil, isSystem: Bool = false,
                localIconKey: String? = nil, storeID: String? = nil, externalVersionID: String? = nil) {
        self.bundleID = bundleID
        self.name = name
        self.version = version
        self.build = build
        self.isSystem = isSystem
        self.localIconKey = localIconKey
        self.storeID = storeID
        self.externalVersionID = externalVersionID
    }
}

public struct StoreRelease: Codable, Equatable, Sendable {
    public var bundleID: String
    public var name: String
    public var version: String
    public var notes: String?
    public var releasedAt: String?
    public var minimumOS: String?
    public var iconURL: URL?
    public var storeURL: URL?
    public var country: String
    public var fetchedAt: Date
    public var storeID: String?
    public var externalVersionID: String?
    public var source: String?
    public var lookupScope: String?

    public init(bundleID: String, name: String, version: String, notes: String? = nil,
                releasedAt: String? = nil, minimumOS: String? = nil, iconURL: URL? = nil,
                storeURL: URL? = nil, country: String, fetchedAt: Date = Date(), storeID: String? = nil,
                externalVersionID: String? = nil, source: String? = nil) {
        self.bundleID = bundleID
        self.name = name
        self.version = version
        self.notes = notes
        self.releasedAt = releasedAt
        self.minimumOS = minimumOS
        self.iconURL = iconURL
        self.storeURL = storeURL
        self.country = country
        self.fetchedAt = fetchedAt
        self.storeID = storeID
        self.externalVersionID = externalVersionID
        self.source = source
    }

    public func matches(scope: String) -> Bool {
        if scope == StoreQueryPolicy.chinaThenUS {
            return country == "cn" || (country == "us" && lookupScope == scope)
        }
        return country == scope
    }
}

public struct AppRecord: Codable, Identifiable, Sendable {
    public var id: String { installed.id }
    public var installed: InstalledApp
    public var lookupBundleID: String?
    public var release: StoreRelease?
    public var checkedAt: Date?
    public var error: String?

    public init(installed: InstalledApp) { self.installed = installed }
    public var effectiveBundleID: String { lookupBundleID ?? installed.bundleID }

    public func status(country: String) -> UpdateStatus {
        guard error == nil, let release, release.matches(scope: country),
              identityMatches(release), let local = versionIdentifier(installed.externalVersionID),
              let remote = versionIdentifier(release.externalVersionID) else { return .unknown }
        return local == remote ? .current : .different
    }

    private func identityMatches(_ release: StoreRelease) -> Bool {
        guard release.bundleID == effectiveBundleID else { return false }
        if let local = versionIdentifier(installed.storeID), let remote = versionIdentifier(release.storeID) {
            return local == remote
        }
        // Exact bundle identity is sufficient when the device omits its store ID.
        // A rewritten sideload identifier requires matching numeric store IDs.
        return installed.bundleID == release.bundleID
    }

    private func versionIdentifier(_ value: String?) -> String? {
        guard let value, !value.isEmpty, value.utf8.allSatisfy({ (48...57).contains($0) }) else { return nil }
        let normalized = value.drop(while: { $0 == "0" })
        return normalized.isEmpty ? nil : String(normalized)
    }

    public func displayedVersion(country: String) -> String? {
        if status(country: country) == .current { return release?.version }
        return installed.version
    }

    public func versionExplanation(country: String) -> String? {
        guard let release, release.matches(scope: country), error == nil else { return nil }
        guard identityMatches(release) else {
            return "无法确认应用身份，请核对 Bundle ID 和商店 ID。"
        }
        guard versionIdentifier(installed.externalVersionID) != nil else {
            return "缺少有效的本机版本标识，请重新读取应用。"
        }
        guard versionIdentifier(release.externalVersionID) != nil else {
            return "缺少有效的商店版本标识，请重新查询。"
        }
        if status(country: country) == .current {
            return "版本标识一致，显示对应的商店版本。"
        }
        return "本机与商店的版本标识不同，无法判断更新方向。"
    }

}

public enum UpdateStatus: String, Sendable {
    case update = "可更新"
    case current = "版本相同"
    case ahead = "本机版本较新"
    case unknown = "待核对"
    case different = "版本标识不同"
}

public enum VersionOrder {
    // Only compare decimal release components. A build number is a separate field;
    // prerelease/custom version schemes require human review instead of guessing.
    public static func status(installed: String?, latest: String) -> UpdateStatus {
        guard let installed, let a = components(installed), let b = components(latest) else { return .unknown }
        for index in 0..<max(a.count, b.count) {
            let x = index < a.count ? a[index] : "0"
            let y = index < b.count ? b[index] : "0"
            if x.count != y.count { return x.count < y.count ? .update : .ahead }
            if x != y { return x.lexicographicallyPrecedes(y) ? .update : .ahead }
        }
        return .current
    }

    private static func components(_ value: String) -> [String]? {
        let parts = value.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ".", omittingEmptySubsequences: false)
        guard !parts.isEmpty, parts.allSatisfy({ !$0.isEmpty && $0.utf8.allSatisfy { (48...57).contains($0) } }) else { return nil }
        return parts.map { let digits = $0.drop(while: { $0 == "0" }); return digits.isEmpty ? "0" : String(digits) }
    }
}
