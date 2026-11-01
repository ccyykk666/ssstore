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
        guard error == nil, let release, release.matches(scope: country) else { return .unknown }
        if let localID = installed.externalVersionID, let remoteID = release.externalVersionID,
           installed.storeID == release.storeID, installed.storeID != nil {
            if localID == remoteID { return .current }
            return comparableOrder(country: country, latest: release.version) == .update ? .update : .different
        }
        return comparableOrder(country: country, latest: release.version)
    }

    private func comparableOrder(country: String, latest: String) -> UpdateStatus {
        let local = displayedVersion(country: country)
        let order = VersionOrder.status(installed: local, latest: latest)
        if order == .ahead { return .different }
        // Real apps can retain historical bundle versions (e.g. ICBC). Without
        // store identity or metadata, a different major number is not proof of
        // an installed public release being older. Keep it for explicit review.
        if order == .update, let local, !VersionOrder.sameMajor(local, latest) { return .different }
        if order != .current, let native = installed.coreDeviceVersion, let bundle = installed.version,
           native != bundle, installed.metadataVersion == nil { return .different }
        return order
    }

    public func displayedVersion(country: String) -> String? {
        guard let release, release.matches(scope: country) else { return installed.version }
        if let localID = installed.externalVersionID, localID == release.externalVersionID,
           installed.storeID == release.storeID, installed.storeID != nil { return release.version }
        if let metadata = installed.metadataVersion { return metadata }
        if let native = installed.coreDeviceVersion,
           VersionOrder.status(installed: native, latest: release.version) == .current { return native }
        if let browse = installed.browseVersion,
           VersionOrder.status(installed: browse, latest: release.version) == .current { return browse }
        return usesBuildAsDisplay(release) ? installed.build : installed.version
    }

    private func usesBuildAsDisplay(_ release: StoreRelease) -> Bool {
        guard let short = installed.version, !short.isEmpty, let build = installed.build else { return false }
        // Quark Drive appends its release counter to the short version, and the
        // store displays that full build. Compare the same shape on both sides.
        if build.hasPrefix(short + "."),
           build.split(separator: ".").count == release.version.split(separator: ".").count,
           VersionOrder.status(installed: build, latest: release.version) != .unknown {
            return true
        }
        // Some apps (e.g. JD) put an integer counter in ShortVersionString and
        // the dotted public release in BundleVersion. Other apps require an
        // exact match; JD's documented convention also covers future updates.
        guard short.utf8.allSatisfy({ (48...57).contains($0) }), build.contains(".") else { return false }
        // JD has independently documented this field convention for years.
        // Keep comparing the build field when a newer store version arrives.
        return installed.bundleID == "com.360buy.jdmobile" ||
            VersionOrder.status(installed: installed.build, latest: release.version) == .current
    }

    public func versionExplanation(country: String) -> String? {
        guard let release, release.matches(scope: country) else { return nil }
        if let localID = installed.externalVersionID, localID == release.externalVersionID,
           installed.storeID == release.storeID, installed.storeID != nil {
            return "本机与商店的版本标识一致。列表采用此标识对应的商店展示版本，原始安装字段仍保留。"
        }
        if displayedVersion(country: country) != installed.version {
            if installed.metadataVersion != nil { return "列表采用设备返回的安装元数据版本；原始 Bundle 字段与 CoreDevice 字段均保留，便于核对。" }
            if displayedVersion(country: country) == installed.coreDeviceVersion {
                return "CoreDevice 返回的本机版本与商店展示一致，列表使用该字段；原始 Bundle 字段仍保留。"
            }
            if displayedVersion(country: country) == installed.browseVersion {
                return "InstallationProxy Browse 返回的本机版本与商店展示一致，列表使用该字段；原始 Lookup 字段仍保留。"
            }
            if let short = installed.version, installed.build?.hasPrefix(short + ".") == true {
                return "商店采用带末尾发布编号的完整版本，本机 CFBundleVersion 提供同格式编号。列表使用构建字段进行比较，两个原始字段仍保留。"
            }
            return installed.bundleID == "com.360buy.jdmobile" ?
                "京东的设备清单将内部计数放在短版本字段、公开版本放在构建字段。列表按 CFBundleVersion 比较；两个原始字段仍保留。" :
                "本机短版本为整数计数，且 CFBundleVersion 与商店展示版本一致，列表采用此字段；原始字段仍保留。"
        }
        if status(country: country) == .different {
            return "本机字段与商店格式、主版本或版本标识不一致。仅凭这些数字无法证明需要更新，暂不计入可更新。请查看下方本机数据来源；没有安装版本标识时，跨主版本的真实更新也需核对。"
        }
        return nil
    }
}

public enum UpdateStatus: String, Sendable {
    case update = "可更新"
    case current = "版本相同"
    case ahead = "本机版本较新"
    case unknown = "待确认"
    case different = "版本需核对"
}

public enum VersionOrder {
    public static func sameMajor(_ lhs: String, _ rhs: String) -> Bool {
        guard let a = components(lhs), let b = components(rhs) else { return false }
        return a.first == b.first
    }
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
