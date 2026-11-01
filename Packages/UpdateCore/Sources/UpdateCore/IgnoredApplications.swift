import Foundation

public struct IgnoredApplications: Codable, Equatable, Sendable {
    public private(set) var names: [String: String]
    public var bundleIDs: Set<String> { Set(names.keys) }

    public init(names: [String: String] = [:]) { self.names = names }

    public mutating func ignore(_ app: InstalledApp) {
        guard !app.bundleID.isEmpty else { return }
        names[app.bundleID] = app.name
    }

    public mutating func restore(_ bundleID: String) { names.removeValue(forKey: bundleID) }

    public func visible(_ records: [AppRecord]) -> [AppRecord] {
        records.filter { names[$0.id] == nil }
    }
}
