import Foundation

/// Optional current values from local read-only APIs. Missing fields stay
/// unavailable; no previous reading or another process is used as a fallback.
public struct LocalPerformanceMetrics: Codable, Equatable, Sendable {
    public var hardwareProduct: String?
    public var hardwareModel: String?
    public var hardwarePlatform: String?
    public var cpuArchitecture: String?
    public var deviceClass: String?
    public var osBuild: String?
    public var darwinVersion: String?
    public var gpuPercent: Double?
    public var gpuRenderer: Double?
    public var gpuTiler: Double?
    public var gpuMemory: Double?
    public var batteryTemperature: Double?
    public var batteryVoltage: Double?
    public var batteryCurrent: Double?
    public var batteryPower: Double?
    public var batteryCycles: Double?
    public var batteryPercent: Double?
    public var adapterWatts: Double?
    public var batteryCharging: Bool?
    public var batteryExternal: Bool?
    public var batteryFull: Bool?
    public var memoryAvailablePercent: Double?
    public var memoryActive: Double?
    public var memoryInactive: Double?
    public var memoryWired: Double?
    public var memoryCompressed: Double?
    public var memoryPurgeable: Double?
    public var processorCount: Double?
    public var activeProcessorCount: Double?
    public var lowPowerMode: Bool?
    public var load1: Double?
    public var load5: Double?
    public var load15: Double?
    public var storageTotal: Double?
    public var storageFree: Double?
    public var processResident: Double?
    public var processWired: Double?
    public var processVirtual: Double?
    public var processThreads: Double?
    public var processRunningThreads: Double?
    public var processFaults: Double?
    public var processContextSwitches: Double?
    public var processIdleWakeups: Double?
    public var processInterruptWakeups: Double?
    public var processPageins: Double?
}

public struct LocalSensorSnapshot: Decodable, Sendable {
    public let timestamp: Double
    public let sensors: [LocalHardwareSensor]
    public let status: String
    public let unavailableCount: Int
}

public struct LocalHardwareSensor: Decodable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let key: String
    public let kind: String
    public let value: Double
    public let unit: String
}
