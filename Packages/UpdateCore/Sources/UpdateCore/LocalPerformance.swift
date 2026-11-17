import Foundation

/// A current-value projection. Retains only counter baselines, never recordings
/// or a history of samples. No transport, pairing, device process or task handles.
public struct LocalPerformanceReducer: Sendable {
    private struct Wire: Decodable {
        let timestamp: Double
        let uptime: Double
        let cpuTicks: [[UInt64]]?
        let memoryTotal: Double?
        let memoryFree: Double?
        let networkReceived: Double?
        let networkSent: Double?
        let networkIdentity: String?
        let diskRead: Double?
        let diskWritten: Double?
        let thermal: String?
        let pid: Int?
        let processCPUTime: Double?
        let processMemory: Double?
        let processStarted: UInt64?
        let issues: [String: String]
        let metrics: LocalPerformanceMetrics?
    }
    private var previousScope: PerformanceScope?
    private var previousCPU: [[UInt64]]?
    private var processCPU = PerformanceCounter()
    private var received = PerformanceCounter(), sent = PerformanceCounter()
    private var read = PerformanceCounter(), written = PerformanceCounter()
    private var networkIdentity: String?
    private var processIdentity: String?
    public private(set) var issues: [String: String] = [:]
    public init() {}

    public mutating func consume(_ data: Data, scope: PerformanceScope) throws -> PerformanceSnapshot {
        let value = try JSONDecoder().decode(Wire.self, from: data)
        if previousScope != scope { self = Self(); previousScope = scope }
        issues = value.issues
        var cores: [Double?] = []
        var totalTicks = 0.0, busyTicks = 0.0, validTicks = true
        if let ticks = value.cpuTicks {
            if let previousCPU, ticks.count == previousCPU.count {
                for (now, before) in zip(ticks, previousCPU) {
                    guard now.count == 4, before.count == 4, zip(now, before).allSatisfy({ $0 >= $1 }) else {
                        cores.append(nil); validTicks = false; continue
                    }
                    let delta = zip(now, before).map { Double($0 - $1) }
                    let total = delta.reduce(0, +), busy = total - delta[2]
                    totalTicks += total; busyTicks += busy
                    cores.append(total > 0 ? min(100, max(0, busy / total * 100)) : nil)
                }
            }
            previousCPU = ticks
        } else { previousCPU = nil }
        // A parked core may not advance its ticks. It contributes no elapsed
        // CPU ticks; never discard the valid aggregate or invent a core load.
        let cpu: Double? = validTicks && totalTicks > 0 ? min(100, max(0, busyTicks / totalTicks * 100)) : nil
        if networkIdentity != value.networkIdentity {
            received = PerformanceCounter(); sent = PerformanceCounter(); networkIdentity = value.networkIdentity
        }
        let networkIn = received.rate(value: value.networkReceived, uptime: value.uptime)
        let networkOut = sent.rate(value: value.networkSent, uptime: value.uptime)
        var processes: [PerformanceProcess] = []
        switch scope {
        case .device: break
        case .application(let bundleID, let name):
            let identity = value.pid.map { "\(bundleID)|\($0)|\(value.processStarted ?? 0)" }
            if identity != processIdentity {
                processCPU = PerformanceCounter(); read = PerformanceCounter(); written = PerformanceCounter()
                processIdentity = identity
            }
            let rate = processCPU.rate(value: value.processCPUTime, uptime: value.uptime)
            if let pid = value.pid {
                processes = [PerformanceProcess(pid: String(pid), name: name,
                    cpuPercent: rate.map { $0 / 1_000_000_000 * 100 }, memoryBytes: value.processMemory,
                    bundleID: bundleID, diskRead: read.rate(value: value.diskRead, uptime: value.uptime),
                    diskWritten: written.rate(value: value.diskWritten, uptime: value.uptime))]
            }
        }
        let free = value.memoryFree.flatMap { free in
            guard free.isFinite, free >= 0, let total = value.memoryTotal, free <= total else { return nil as Double? }
            return free
        }
        let used: Double? = free.flatMap { free in value.memoryTotal.map { $0 - free } }
        let diskIn = scope.isDevice ? read.rate(value: value.diskRead, uptime: value.uptime) : nil
        let diskOut = scope.isDevice ? written.rate(value: value.diskWritten, uptime: value.uptime) : nil
        return PerformanceSnapshot(capturedAt: Date(timeIntervalSince1970: value.timestamp), uptime: value.uptime,
            cpuPercent: cpu, corePercent: cores, memoryTotal: value.memoryTotal, memoryFree: free,
            memoryUsed: used, memoryEstimated: used != nil, memoryPressure: nil,
            networkReceived: networkIn, networkSent: networkOut, diskRead: diskIn, diskWritten: diskOut,
            thermalState: value.thermal, processes: processes, localMetrics: value.metrics)
    }
}
