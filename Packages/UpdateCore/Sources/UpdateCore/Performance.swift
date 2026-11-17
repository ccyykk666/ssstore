import Foundation

public struct PerformanceProcess: Codable, Equatable, Sendable, Identifiable {
    public let pid: String
    public var id: String { pid }
    public let name: String
    /// Percent of one core. Multi-threaded processes can exceed 100%.
    public let cpuPercent: Double?
    public let memoryBytes: Double?
    public let bundleID: String?
    public let executablePath: String?
    public let networkReceived: Double?
    public let networkSent: Double?
    public let diskRead: Double?
    public let diskWritten: Double?
    public init(pid: String, name: String, cpuPercent: Double? = nil, memoryBytes: Double? = nil,
                bundleID: String? = nil, executablePath: String? = nil,
                networkReceived: Double? = nil, networkSent: Double? = nil,
                diskRead: Double? = nil, diskWritten: Double? = nil) {
        self.pid = pid; self.name = name; self.cpuPercent = cpuPercent; self.memoryBytes = memoryBytes
        self.bundleID = bundleID; self.executablePath = executablePath
        self.networkReceived = networkReceived; self.networkSent = networkSent
        self.diskRead = diskRead; self.diskWritten = diskWritten
    }
}

public struct PerformanceSnapshot: Codable, Equatable, Sendable {
    public let capturedAt: Date
    public let uptime: Double
    public var cpuPercent: Double?
    public var corePercent: [Double?]
    public var memoryTotal: Double?
    public var memoryFree: Double?
    public var memoryUsed: Double?
    public var memoryEstimated: Bool
    public var memoryPressure: String?
    public var networkReceived: Double?
    public var networkSent: Double?
    public var diskRead: Double?
    public var diskWritten: Double?
    public var thermalState: String?
    public var processes: [PerformanceProcess]
    public var applications: [PerformanceApplication]? = nil
    public var localMetrics: LocalPerformanceMetrics? = nil
    public var summary: Self { var value = self; value.processes = []; value.applications = nil; return value }
}

public struct PerformanceRecording: Codable, Sendable {
    public let capturedAt: Date
    public let latest: PerformanceSnapshot?
    public let history: [PerformanceSnapshot]
    public let rawSample: InspectionValue?
    public let scope: PerformanceScope?
    public let readings: [PerformanceReading]?
    public let currentReading: PerformanceReading?
    public init(capturedAt: Date, latest: PerformanceSnapshot?, history: [PerformanceSnapshot], rawSample: InspectionValue?,
                scope: PerformanceScope? = nil, readings: [PerformanceReading]? = nil, currentReading: PerformanceReading? = nil) {
        self.capturedAt = capturedAt; self.latest = latest; self.history = history; self.rawSample = rawSample
        self.scope = scope; self.readings = readings
        self.currentReading = currentReading
    }
}

/// A counter has no rate until two valid samples arrive. Resets, non-finite
/// values and non-positive time differences never turn into spikes or zeroes.
public struct PerformanceCounter: Sendable {
    private var previous: (value: Double, uptime: Double)?
    public init() {}
    public mutating func rate(value: Double?, uptime: Double) -> Double? {
        guard let value, value.isFinite, value >= 0, uptime.isFinite else { previous = nil; return nil }
        defer { previous = (value, uptime) }
        guard let previous, uptime > previous.uptime, value >= previous.value else { return nil }
        let result = (value - previous.value) / (uptime - previous.uptime)
        return result.isFinite ? result : nil
    }
}

public struct PerformanceReducer: Sendable {
    private struct Wire: Decodable {
        let timestamp: Double
        let uptime: Double
        let system: [String: InspectionValue]
        let cpu: InspectionValue
        let hardware: InspectionValue
        let hasProcesses: Bool
        let processes: [Process]
        let applications: [PerformanceApplication]?
        struct Process: Decodable { let pid: String; let values: [String: InspectionValue] }
    }
    private var system: [String: InspectionValue] = [:]
    private var cpu: [String: InspectionValue] = [:]
    private var processes: [PerformanceProcess] = []
    private var systemAt = -Double.infinity, cpuAt = -Double.infinity, processesAt = -Double.infinity
    private var sawCPU = false
    private struct ProcessRates: Sendable {
        var identity: String
        var age: Double?
        var receive = PerformanceCounter(), send = PerformanceCounter()
        var read = PerformanceCounter(), write = PerformanceCounter()
    }
    private var processRates: [String: ProcessRates] = [:]
    private var receive = PerformanceCounter(), send = PerformanceCounter()
    private var read = PerformanceCounter(), write = PerformanceCounter()
    private var rates: (Double?, Double?, Double?, Double?) = (nil, nil, nil, nil)
    public init() {}

    public mutating func consume(_ data: Data) throws -> PerformanceSnapshot {
        let sample = try JSONDecoder().decode(Wire.self, from: data)
        guard sample.timestamp.isFinite, sample.uptime.isFinite else {
            throw CocoaError(.coderInvalidValue)
        }
        let time = sample.uptime
        if !sample.system.isEmpty {
            // Replace the dictionary: fields disappearing in a new sample are unavailable.
            system = sample.system; systemAt = time
            rates = (receive.rate(value: system.numeric("netBytesIn"), uptime: time),
                     send.rate(value: system.numeric("netBytesOut"), uptime: time),
                     read.rate(value: system.numeric("diskBytesRead"), uptime: time),
                     write.rate(value: system.numeric("diskBytesWritten"), uptime: time))
        }
        if case .object(let fields) = sample.cpu, !fields.isEmpty {
            // The first CPU row is uninitialized (commonly 0 or 100).
            if sawCPU { cpu = fields; cpuAt = time }
            sawCPU = true
        }
        if sample.hasProcesses {
            let active = Set(sample.processes.map(\.pid))
            processRates = processRates.filter { active.contains($0.key) }
            processes = sample.processes.map { entry in
                let path = entry.values["executablePath"]?.string
                let identity = (path ?? "") + "|" + (entry.values["procStartAbsTime"]?.text ?? "")
                let age = entry.values.numeric("procAge")
                let previous = processRates[entry.pid]
                let ageReset: Bool
                if let age, let previousAge = previous?.age { ageReset = age < previousAge } else { ageReset = false }
                let same = previous?.identity == identity && !ageReset
                var counters = same ? previous! : ProcessRates(identity: identity, age: age)
                counters.age = age
                let received = counters.receive.rate(value: entry.values.numeric("netBytesIn"), uptime: time)
                let sent = counters.send.rate(value: entry.values.numeric("netBytesOut"), uptime: time)
                let read = counters.read.rate(value: entry.values.numeric("diskBytesRead"), uptime: time)
                let written = counters.write.rate(value: entry.values.numeric("diskBytesWritten"), uptime: time)
                processRates[entry.pid] = counters
                let direct = entry.values["bundleIdentifier"]?.string
                let bundle = (direct?.isEmpty == false ? direct : nil) ??
                    PerformanceApplication.bundleID(forExecutable: path, applications: sample.applications ?? [])
                return PerformanceProcess(pid: entry.pid,
                    name: entry.values["name"]?.string ?? entry.values["procName"]?.string ?? "PID \(entry.pid)",
                    cpuPercent: same ? entry.values.numeric("cpuUsage") : nil,
                    memoryBytes: entry.values.numeric("physFootprint", "memResidentSize"),
                    bundleID: bundle, executablePath: path,
                    networkReceived: received, networkSent: sent, diskRead: read, diskWritten: written)
            }
            processesAt = time
        }
        let freshSystem = time - systemAt <= 3 ? system : [:]
        let freshCPU = time - cpuAt <= 3 ? cpu : [:]
        let hardware: [String: InspectionValue]
        if case .object(let values) = sample.hardware { hardware = values } else { hardware = [:] }
        let total = (freshSystem.numeric("physMemSize") ?? hardware.numeric("physicalMemory", "physicalMemorySize")).flatMap { $0 > 0 ? $0 : nil }
        let pageSize = freshSystem.numeric("vmPageSize") ?? hardware.numeric("pageSize")
        var free = freshSystem.numeric("memFreeBytes")
        if free == nil, let count = freshSystem.numeric("vmFreeCount"), let pageSize, pageSize > 0 { free = count * pageSize }
        if let value = free, let total, value > total { free = nil }
        var used = freshSystem.numeric("memUsedBytes")
        var estimated = false
        if used == nil, let total, let free { used = max(0, total - free); estimated = true }
        let pressure = freshSystem["memoryPressure"]?.displayValue
        let thermal = freshSystem["thermalState"]?.displayValue ?? freshSystem["thermalPressure"]?.displayValue
        let cores: [Double?]
        if case .array(let values)? = freshCPU["CPU_CoreLoads"] {
            cores = values.map(\.finiteNumber)
        } else { cores = [] }
        let fresh = time - systemAt <= 3
        return PerformanceSnapshot(capturedAt: Date(timeIntervalSince1970: sample.timestamp), uptime: time,
            cpuPercent: freshCPU.numeric("CPU_TotalLoad"), corePercent: cores,
            memoryTotal: total, memoryFree: free, memoryUsed: used, memoryEstimated: estimated,
            memoryPressure: pressure, networkReceived: fresh ? rates.0 : nil, networkSent: fresh ? rates.1 : nil,
            diskRead: fresh ? rates.2 : nil, diskWritten: fresh ? rates.3 : nil, thermalState: thermal,
            processes: time - processesAt <= 3 ? processes : [], applications: sample.applications)
    }
}

private extension InspectionValue {
    var finiteNumber: Double? {
        if case .number(let value) = self, value.isFinite, value >= 0 { return value }
        return nil
    }
    var displayValue: String? {
        switch self {
        case .string(let value): return value.isEmpty ? nil : value
        case .number(let value): return value.isFinite ? value.formatted(.number.grouping(.never)) : nil
        default: return nil
        }
    }
}
private extension Dictionary where Key == String, Value == InspectionValue {
    func numeric(_ keys: String...) -> Double? { keys.lazy.compactMap { self[$0]?.finiteNumber }.first }
}
