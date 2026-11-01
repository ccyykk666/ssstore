import Foundation

public struct InstalledApp: Codable, Identifiable, Equatable, Sendable {
    public var id: String { bundleID }
    public var bundleID: String
    public var name: String
    public var version: String?
    public var build: String?
    public var isSystem: Bool

    public init(bundleID: String, name: String, version: String?, build: String? = nil, isSystem: Bool = false) {
        self.bundleID = bundleID
        self.name = name
        self.version = version
        self.build = build
        self.isSystem = isSystem
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

    public init(bundleID: String, name: String, version: String, notes: String? = nil,
                releasedAt: String? = nil, minimumOS: String? = nil, iconURL: URL? = nil,
                storeURL: URL? = nil, country: String, fetchedAt: Date = Date()) {
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
        guard error == nil, let release, release.country == country else { return .unknown }
        return VersionOrder.status(installed: installed.version, latest: release.version)
    }
}

public enum UpdateStatus: String, Sendable {
    case update = "可更新"
    case current = "版本相同"
    case ahead = "本机版本较新"
    case unknown = "待确认"
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
