import Foundation

public struct IgnoredApplications: Codable, Equatable, Sendable {
    public private(set) var names: [String: String]
    public private(set) var applications: [String: InstalledApp]?
    public private(set) var iconURLs: [String: URL]?
    /// Only updated from a successful complete inventory, never a failed read.
    public private(set) var installedIgnoredIDs: Set<String>?
    public var bundleIDs: Set<String> { Set(names.keys) }
    public var visibleBundleIDs: Set<String> { installedIgnoredIDs.map { $0.intersection(bundleIDs) } ?? bundleIDs }

    public init(names: [String: String] = [:]) { self.names = names }

    public mutating func ignore(_ app: InstalledApp, iconURL: URL? = nil) {
        guard !app.bundleID.isEmpty else { return }
        names[app.bundleID] = app.name
        installedIgnoredIDs?.insert(app.bundleID)
        if applications == nil { applications = [:] }
        applications?[app.bundleID] = app
        if let iconURL {
            if iconURLs == nil { iconURLs = [:] }
            iconURLs?[app.bundleID] = iconURL
        }
    }

    public mutating func restore(_ bundleID: String) {
        names.removeValue(forKey: bundleID)
        installedIgnoredIDs?.remove(bundleID)
        applications?.removeValue(forKey: bundleID)
        iconURLs?.removeValue(forKey: bundleID)
    }

    public mutating func captureMetadata(from apps: [InstalledApp]) {
        for app in apps where names[app.id] != nil {
            if applications == nil { applications = [:] }
            var refreshed = app
            // A sparse response must not discard a previously known local icon.
            if refreshed.localIconKey == nil { refreshed.localIconKey = applications?[app.id]?.localIconKey }
            if applications?[app.id] != refreshed { applications?[app.id] = refreshed }
        }
    }

    public mutating func reconcileInstalledApps(_ apps: [InstalledApp]) {
        installedIgnoredIDs = Set(apps.map(\.id)).intersection(bundleIDs)
        for id in bundleIDs.subtracting(installedIgnoredIDs ?? []) {
            applications?.removeValue(forKey: id)
            iconURLs?.removeValue(forKey: id)
        }
        captureMetadata(from: apps)
    }

    public func application(for bundleID: String) -> InstalledApp {
        applications?[bundleID] ?? InstalledApp(bundleID: bundleID, name: names[bundleID] ?? bundleID, version: nil)
    }

    public func visible(_ records: [AppRecord]) -> [AppRecord] {
        records.filter { names[$0.id] == nil }
    }
}

