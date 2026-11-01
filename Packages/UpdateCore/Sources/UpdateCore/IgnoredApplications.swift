import Foundation

public struct IgnoredApplications: Codable, Equatable, Sendable {
    public private(set) var names: [String: String]
    public private(set) var applications: [String: InstalledApp]?
    public private(set) var iconURLs: [String: URL]?
    public var bundleIDs: Set<String> { Set(names.keys) }

    public init(names: [String: String] = [:]) { self.names = names }

    public mutating func ignore(_ app: InstalledApp, iconURL: URL? = nil) {
        guard !app.bundleID.isEmpty else { return }
        names[app.bundleID] = app.name
        if applications == nil { applications = [:] }
        applications?[app.bundleID] = app
        if let iconURL {
            if iconURLs == nil { iconURLs = [:] }
            iconURLs?[app.bundleID] = iconURL
        }
    }

    public mutating func restore(_ bundleID: String) {
        names.removeValue(forKey: bundleID)
        applications?.removeValue(forKey: bundleID)
        iconURLs?.removeValue(forKey: bundleID)
    }

    public mutating func captureMetadata(from apps: [InstalledApp]) {
        for app in apps where names[app.id] != nil && applications?[app.id] == nil {
            if applications == nil { applications = [:] }
            applications?[app.id] = app
        }
    }

    public func application(for bundleID: String) -> InstalledApp {
        applications?[bundleID] ?? InstalledApp(bundleID: bundleID, name: names[bundleID] ?? bundleID, version: nil)
    }

    public func visible(_ records: [AppRecord]) -> [AppRecord] {
        records.filter { names[$0.id] == nil }
    }
}

