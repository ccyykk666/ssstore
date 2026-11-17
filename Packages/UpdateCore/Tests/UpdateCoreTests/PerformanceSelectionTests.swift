import Foundation
import XCTest
@testable import UpdateCore

final class PerformanceSelectionTests: XCTestCase {
    private let apps = [PerformanceApplication(bundleID: "app.target", name: "Target", path: "/var/containers/A/Target.app"),
                        PerformanceApplication(bundleID: "app.other", name: "Target", path: "/var/containers/B/Other.app")]
    private func wire(_ time: Double, processes: [[String: Any]]) throws -> Data {
        let applicationRows = apps.map { ["bundleID": $0.bundleID, "name": $0.name, "path": $0.path] }
        return try JSONSerialization.data(withJSONObject: ["timestamp": 1_800_000_000 + time, "uptime": time,
            "system": ["physMemSize": 16384, "memUsedBytes": 15000, "netBytesIn": time * 1000],
            "cpu": ["CPU_TotalLoad": 99], "hardware": [:], "hasProcesses": true,
            "processes": processes, "applications": applicationRows])
    }
    private func process(_ pid: String, path: String, cpu: Any = 150.0, age: Double = 100,
                         received: Double = 1000) -> [String: Any] {
        ["pid": pid, "values": ["name": "Target", "executablePath": path, "cpuUsage": cpu,
                                  "physFootprint": 4096, "procAge": age, "netBytesIn": received]]
    }
    func testFilePickerUsesInstallationIdentifiersAndDeduplicates() throws {
        let rows: [[String: Any]] = [
            ["CFBundleIdentifier": "com.example.Installed", "CFBundleDisplayName": "Example", "Path": "/var/App.app"],
            ["CFBundleIdentifier": "com.example.Fallback", "CFBundleName": "Fallback"],
            ["CFBundleIdentifier": "com.example.Installed", "CFBundleDisplayName": "Duplicate"],
            ["bundleIdentifier": "com.example.Internal", "name": "CoreDevice-only row"],
            ["CFBundleIdentifier": ""], ["CFBundleIdentifier": "com.example.NoName"]
        ]
        let value = try JSONDecoder().decode(InspectionValue.self, from: JSONSerialization.data(withJSONObject: rows))
        let installed = PerformanceApplication.fromInstalledApplications(value)
        XCTAssertEqual(installed.map(\.bundleID), ["com.example.Installed", "com.example.Fallback", "com.example.NoName"])
        XCTAssertEqual(installed.map(\.name), ["Example", "Fallback", "com.example.NoName"])
        XCTAssertEqual(installed[0].path, "/var/App.app")
        XCTAssertTrue(PerformanceApplication.fromInstalledApplications(.null).isEmpty)
    }
    func testPathAssociationUsesExactBundleBoundariesAndAliases() {
        XCTAssertEqual(PerformanceApplication.bundleID(forExecutable: "file:///private/var/containers/A/Target.app/Target", applications: apps), "app.target")
        XCTAssertNil(PerformanceApplication.bundleID(forExecutable: "/var/containers/A/Target.app-copy/Target", applications: apps))
        XCTAssertNil(PerformanceApplication.bundleID(forExecutable: "Target", applications: apps))
        XCTAssertNil(PerformanceApplication.bundleID(forExecutable: "file://other-host/var/containers/A/Target.app/Target", applications: apps))
        let nested = PerformanceApplication(bundleID: "nested", name: "Nested", path: "/var/containers/A/Target.app/Embedded.app")
        XCTAssertEqual(PerformanceApplication.bundleID(forExecutable: nested.path + "/Run", applications: apps + [nested]), "nested")
    }
    func testApplicationReadingNeverFallsBackToSystemOrSameNameProcess() throws {
        var reducer = PerformanceReducer()
        let values = [process("11", path: apps[0].path + "/Run"), process("22", path: apps[1].path + "/Run")]
        _ = try reducer.consume(wire(1, processes: values))
        let snapshot = try reducer.consume(wire(2, processes: values))
        let reading = PerformanceReading(snapshot: snapshot, scope: .application(bundleID: "app.target", name: "Target"))
        XCTAssertEqual(reading.cpuPercent, 150)
        XCTAssertEqual(reading.memoryBytes, 4096)
        XCTAssertNil(reading.memoryTotal)
        XCTAssertNil(reading.networkSent)
        XCTAssertEqual(reading.processes.map(\.pid), ["11"])
        let unknown = PerformanceReading(snapshot: snapshot, scope: .application(bundleID: "missing", name: "Target"))
        XCTAssertNil(unknown.cpuPercent); XCTAssertNil(unknown.memoryBytes); XCTAssertNil(unknown.networkReceived)
        XCTAssertEqual(PerformanceReading(snapshot: snapshot, scope: .device).cpuPercent, 99)
    }
    func testAggregationRequiresAllAssociatedValuesAndPreservesOver100Percent() throws {
        var reducer = PerformanceReducer()
        let values = [process("11", path: apps[0].path + "/Run"), process("12", path: apps[0].path + "/PlugIns/Helper.appex/Run", cpu: 75.0)]
        _ = try reducer.consume(wire(1, processes: values))
        var snapshot = try reducer.consume(wire(2, processes: values))
        XCTAssertEqual(PerformanceReading(snapshot: snapshot, scope: .application(bundleID: "app.target", name: "Target")).cpuPercent, 225)
        let partial = [values[0], process("12", path: apps[0].path + "/PlugIns/Helper.appex/Run", cpu: NSNull())]
        snapshot = try reducer.consume(wire(3, processes: partial))
        let reading = PerformanceReading(snapshot: snapshot, scope: .application(bundleID: "app.target", name: "Target"))
        XCTAssertNil(reading.cpuPercent); XCTAssertEqual(reading.memoryBytes, 8192)
    }
    func testPIDReuseAndProcessRestartResetApplicationCounterBaselines() throws {
        var reducer = PerformanceReducer()
        _ = try reducer.consume(wire(1, processes: [process("11", path: apps[0].path + "/Run")]))
        var sample = try reducer.consume(wire(2, processes: [process("11", path: apps[0].path + "/Run", received: 2000)]))
        XCTAssertEqual(sample.processes[0].networkReceived, 1000)
        sample = try reducer.consume(wire(3, processes: [process("11", path: apps[1].path + "/Run", received: 1_000_000)]))
        XCTAssertNil(sample.processes[0].networkReceived); XCTAssertNil(sample.processes[0].cpuPercent)
        XCTAssertTrue(PerformanceReading(snapshot: sample, scope: .application(bundleID: "app.target", name: "Target")).processes.isEmpty)
        sample = try reducer.consume(wire(4, processes: [process("11", path: apps[1].path + "/Run", age: 1, received: 1_001_000)]))
        XCTAssertNil(sample.processes[0].networkReceived)
        sample = try reducer.consume(wire(5, processes: []))
        XCTAssertTrue(sample.processes.isEmpty)
    }
    func testMissingCoreSamplePreservesCoreIndices() throws {
        var reducer = PerformanceReducer()
        let data = try JSONSerialization.data(withJSONObject: ["timestamp": 10, "uptime": 10, "system": [:],
            "cpu": ["CPU_TotalLoad": 20, "CPU_CoreLoads": [NSNull(), 40] as [Any]], "hardware": [:], "hasProcesses": false, "processes": []])
        _ = try reducer.consume(data)
        let sample = try reducer.consume(data)
        XCTAssertEqual(sample.corePercent.count, 2)
        XCTAssertNil(sample.corePercent[0]); XCTAssertEqual(sample.corePercent[1], 40)
    }
}
