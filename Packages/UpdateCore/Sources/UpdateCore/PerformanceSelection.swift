import Foundation

public struct PerformanceApplication: Codable, Equatable, Sendable, Identifiable {
    public var id: String { bundleID }
    public let bundleID: String
    public let name: String
    public let path: String
    public init(bundleID: String, name: String, path: String = "") {
        self.bundleID = bundleID; self.name = name; self.path = path
    }
    public static func fromInspection(_ value: InspectionValue) -> [Self] {
        guard case .array(let rows) = value else { return [] }
        return rows.compactMap { row in
            guard let id = row["bundleIdentifier"]?.string, !id.isEmpty else { return nil }
            return Self(bundleID: id, name: row["name"]?.string ?? id, path: row["path"]?.string ?? "")
        }
    }
    public static func bundleID(forExecutable executable: String?, applications: [Self]) -> String? {
        guard let executable, let path = canonicalPath(executable) else { return nil }
        // Full bundle path boundaries, not substring/name guesses. Prefer a
        // nested application's own identity over its enclosing application.
        return applications.compactMap { app -> (String, String)? in
            guard !app.bundleID.isEmpty, let root = canonicalPath(app.path),
                  (root as NSString).pathExtension.lowercased() == "app", path.hasPrefix(root + "/") else { return nil }
            return (root, app.bundleID)
        }.max(by: { $0.0.count < $1.0.count })?.1
    }
    private static func canonicalPath(_ value: String) -> String? {
        let path: String
        if value.hasPrefix("file:") {
            guard let url = URL(string: value), url.isFileURL,
                  url.host == nil || url.host == "" || url.host == "localhost" else { return nil }
            path = url.path
        } else { path = value }
        guard path.hasPrefix("/") else { return nil }
        let normalized = URL(fileURLWithPath: path).standardizedFileURL.path
        if normalized.hasPrefix("/private/var/") { return String(normalized.dropFirst("/private".count)) }
        return normalized
    }
}

public enum PerformanceScope: Codable, Equatable, Sendable {
    case device
    case application(bundleID: String, name: String)
    public var isDevice: Bool { self == .device }
    public var title: String {
        switch self {
        case .device: return "整机"
        case .application(_, let name): return name.isEmpty ? "选择应用" : name
        }
    }
}

public struct PerformanceReading: Codable, Equatable, Sendable {
    public let capturedAt: Date
    public let uptime: Double
    public let cpuPercent: Double?
    public let memoryBytes: Double?
    public let memoryTotal: Double?
    public let memoryEstimated: Bool
    public let networkReceived: Double?
    public let networkSent: Double?
    public let diskRead: Double?
    public let diskWritten: Double?
    public var processes: [PerformanceProcess]
    public var summary: Self { var value = self; value.processes = []; return value }
    public init(snapshot: PerformanceSnapshot, scope: PerformanceScope) {
        capturedAt = snapshot.capturedAt; uptime = snapshot.uptime
        switch scope {
        case .device:
            cpuPercent = snapshot.cpuPercent; memoryBytes = snapshot.memoryUsed
            memoryTotal = snapshot.memoryTotal; memoryEstimated = snapshot.memoryEstimated
            networkReceived = snapshot.networkReceived; networkSent = snapshot.networkSent
            diskRead = snapshot.diskRead; diskWritten = snapshot.diskWritten; processes = snapshot.processes
        case .application(let bundleID, _):
            let matching = bundleID.isEmpty ? [] : snapshot.processes.filter { $0.bundleID == bundleID }
            cpuPercent = Self.sum(matching.map(\.cpuPercent))
            memoryBytes = Self.sum(matching.map(\.memoryBytes)); memoryTotal = nil; memoryEstimated = false
            networkReceived = Self.sum(matching.map(\.networkReceived)); networkSent = Self.sum(matching.map(\.networkSent))
            diskRead = Self.sum(matching.map(\.diskRead)); diskWritten = Self.sum(matching.map(\.diskWritten))
            processes = matching
        }
    }
    private static func sum(_ values: [Double?]) -> Double? {
        guard !values.isEmpty, values.allSatisfy({ $0 != nil && $0!.isFinite && $0! >= 0 }) else { return nil }
        let value = values.reduce(0) { $0 + $1! }
        return value.isFinite ? value : nil
    }
}
