import Foundation
import XCTest
@testable import UpdateCore

final class LocalPerformanceTests: XCTestCase {
    private func frame(_ time: Double, _ values: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: values.merging(["timestamp": time, "uptime": time, "issues": [:]]) { a, _ in a })
    }
    func testCPUUsesTwoSnapshotsAndKeepsIdleCoreAtZero() throws {
        var reducer = LocalPerformanceReducer()
        let first = try reducer.consume(frame(1, ["cpuTicks": [[10, 10, 80, 0], [0, 0, 100, 0]]]), scope: .device)
        XCTAssertNil(first.cpuPercent)
        let second = try reducer.consume(frame(2, ["cpuTicks": [[30, 10, 160, 0], [0, 0, 200, 0]]]), scope: .device)
        XCTAssertEqual(second.cpuPercent, 10)
        XCTAssertEqual(second.corePercent, [20, 0])
        let reset = try reducer.consume(frame(3, ["cpuTicks": [[1, 1, 10, 0]]]), scope: .device)
        XCTAssertNil(reset.cpuPercent)
    }
    func testInterfaceChangesAndCounterWrapNeverProduceSpikes() throws {
        var reducer = LocalPerformanceReducer()
        _ = try reducer.consume(frame(1, ["networkIdentity":"en0", "networkReceived":1000]), scope: .device)
        let second = try reducer.consume(frame(2, ["networkIdentity":"en0", "networkReceived":2000]), scope: .device)
        XCTAssertEqual(second.networkReceived, 1000)
        XCTAssertNil(try reducer.consume(frame(3, ["networkIdentity":"pdp_ip0", "networkReceived":1_000_000]), scope: .device).networkReceived)
        XCTAssertNil(try reducer.consume(frame(4, ["networkIdentity":"pdp_ip0", "networkReceived":10]), scope: .device).networkReceived)
    }
    func testApplicationDenialNeverUsesDeviceOrOwnProcessNumbers() throws {
        var reducer = LocalPerformanceReducer()
        let scope = PerformanceScope.application(bundleID: "other.app", name: "Other")
        let snapshot = try reducer.consume(frame(1, ["memoryTotal":10000, "memoryFree":1000,
            "issues":["application":"EPERM"]]), scope: scope)
        let reading = PerformanceReading(snapshot: snapshot, scope: scope)
        XCTAssertNil(reading.memoryBytes); XCTAssertNil(reading.cpuPercent)
        XCTAssertNil(reading.networkReceived); XCTAssertTrue(reading.processes.isEmpty)
        XCTAssertEqual(reducer.issues["application"], "EPERM")
    }
    func testProcessCPUAndDiskResetWhenPIDIsReusedOrScopeChanges() throws {
        var reducer = LocalPerformanceReducer()
        let scope = PerformanceScope.application(bundleID: "app", name: "App")
        _ = try reducer.consume(frame(1, ["pid":123, "processStarted":100, "processCPUTime":1_000_000_000, "diskRead":100]), scope: scope)
        let second = try reducer.consume(frame(2, ["pid":123, "processStarted":100, "processCPUTime":2_500_000_000, "diskRead":1100, "processMemory":4096]), scope: scope)
        let reading = PerformanceReading(snapshot: second, scope: scope)
        XCTAssertEqual(reading.cpuPercent, 150); XCTAssertEqual(reading.diskRead, 1000); XCTAssertEqual(reading.memoryBytes, 4096)
        let reused = try reducer.consume(frame(3, ["pid":123, "processStarted":200, "processCPUTime":5_000_000_000, "diskRead":10000]), scope: scope)
        XCTAssertNil(reused.processes.first?.cpuPercent); XCTAssertNil(reused.processes.first?.diskRead)
        let other = try reducer.consume(frame(4, ["pid":123, "processStarted":200, "processCPUTime":6_000_000_000]), scope: .application(bundleID: "new", name: "New"))
        XCTAssertNil(other.processes.first?.cpuPercent)
    }
    func testMemoryIsExplicitlyEstimatedAndInvalidFreeIsUnavailable() throws {
        var reducer = LocalPerformanceReducer()
        let value = try reducer.consume(frame(1, ["memoryTotal":1000, "memoryFree":200]), scope: .device)
        XCTAssertEqual(value.memoryUsed, 800); XCTAssertTrue(value.memoryEstimated)
        let invalid = try reducer.consume(frame(2, ["memoryTotal":1000, "memoryFree":2000]), scope: .device)
        XCTAssertNil(invalid.memoryUsed)
    }
}
