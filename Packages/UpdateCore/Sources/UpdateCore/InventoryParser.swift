import Foundation

public enum InventoryParser {
    public static func parse(_ data: Data) throws -> [InstalledApp] {
        let root: Any
        if let json = try? JSONSerialization.jsonObject(with: data) { root = json }
        else { root = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) }
        let rows: [[String: Any]]
        if let array = root as? [[String: Any]] { rows = array }
        else if let dict = root as? [String: Any], let array = dict["apps"] as? [[String: Any]] { rows = array }
        else if let dict = root as? [String: Any], let lookup = dict["LookupResult"] as? [String: [String: Any]] {
            rows = lookup.map { key, value in var row = value; row["CFBundleIdentifier"] = key; return row }
        } else { throw InventoryError.invalidFormat }

        var unique: [String: InstalledApp] = [:]
        for row in rows {
            guard let id = text(row, ["bundleID", "CFBundleIdentifier"]), !id.isEmpty else { continue }
            let metadata = row["iTunesMetadata"] as? [String: Any] ?? [:]
            unique[id] = InstalledApp(
                bundleID: id,
                name: text(row, ["name", "CFBundleDisplayName", "CFBundleName"]) ?? id,
                version: text(row, ["version", "CFBundleShortVersionString"]),
                build: text(row, ["build", "CFBundleVersion"]),
                isSystem: (row["isSystem"] as? Bool) ?? (row["ApplicationType"] as? String == "System"),
                localIconKey: text(row, ["LocalIconKey"]),
                storeID: identifier(row["storeID"] ?? row["itemID"] ?? metadata["itemId"]),
                externalVersionID: identifier(row["externalVersionID"] ?? metadata["softwareVersionExternalIdentifier"])
            )
            unique[id]?.coreDeviceVersion = text(row, ["CoreDeviceVersion"])
            unique[id]?.coreDeviceBuild = text(row, ["CoreDeviceBuild"])
            unique[id]?.browseVersion = text(row, ["BrowseVersion"])
            unique[id]?.browseBuild = text(row, ["BrowseBuild"])
            unique[id]?.metadataVersion = text(row, ["MetadataVersion"]) ?? text(metadata, ["bundleShortVersionString"])
            unique[id]?.metadataBuild = text(row, ["MetadataBuild"]) ?? text(metadata, ["bundleVersion"])
            unique[id]?.versionReadNote = text(row, ["VersionReadNote"])
        }
        guard !unique.isEmpty else { throw InventoryError.empty }
        return unique.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private static func identifier(_ value: Any?) -> String? {
        let string = (value as? String) ?? (value as? NSNumber)?.stringValue
        guard let string, !string.isEmpty, string != "0", string.utf8.allSatisfy({ (48...57).contains($0) }) else { return nil }
        return string
    }

    private static func text(_ row: [String: Any], _ keys: [String]) -> String? {
        for key in keys {
            if let value = row[key] as? String, !value.isEmpty { return value }
        }
        return nil
    }
}

public enum InventoryError: LocalizedError {
    case invalidFormat, empty
    public var errorDescription: String? {
        switch self {
        case .invalidFormat: return "不支持此清单格式。请导入应用 JSON 或 LookupResult plist。"
        case .empty: return "清单中没有有效的 Bundle ID，原清单已保留。"
        }
    }
}
