import Foundation
import XCTest
@testable import UpdateCore

final class PerformanceTests: XCTestCase {
    private func wire(time: Double, system: [String: Any] = [:], cpu: Any = NSNull(),
                      processes: [[String: Any]] = [], hasProcesses: Bool = false,
                      hardware: [String: Any] = [:]) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["timestamp": 1_800_000_000 + time, "uptime": time,
            "system": system, "cpu": cpu, "processes": processes, "hasProcesses": hasProcesses, "hardware": hardware])
    }
    func testRatesRequireTwoSamplesAndResetSafely() {
        var counter = PerformanceCounter()
        XCTAssertNil(counter.rate(value: 1000, uptime: 1))
        XCTAssertEqual(counter.rate(value: 1600, uptime: 3), 300)
        XCTAssertNil(counter.rate(value: 10, uptime: 4))
        XCTAssertNil(counter.rate(value: 20, uptime: 4))
        XCTAssertNil(counter.rate(value: .infinity, uptime: 5))
        XCTAssertNil(counter.rate(value: 40, uptime: 6))
        XCTAssertNil(counter.rate(value: -1, uptime: 7))
    }
    func testCPUUsesPercentWithoutLowLoadHeuristicAndSkipsUninitializedFirstRow() throws {
        var reducer = PerformanceReducer()
        XCTAssertNil(try reducer.consume(wire(time: 1, cpu: ["CPU_TotalLoad": 100])).cpuPercent)
        XCTAssertEqual(try reducer.consume(wire(time: 2, cpu: ["CPU_TotalLoad": 0.5])).cpuPercent, 0.5)
        XCTAssertNil(try reducer.consume(wire(time: 8)).cpuPercent)
    }
    func testUnknownPageSizeAndMissingCountersStayUnavailable() throws {
        var reducer = PerformanceReducer()
        let result = try reducer.consume(wire(time: 1, system: ["physMemSize": 1024, "vmFreeCount": 12]))
        XCTAssertEqual(result.memoryTotal, 1024)
        XCTAssertNil(result.memoryFree)
        XCTAssertNil(result.memoryUsed)
        XCTAssertNil(result.networkReceived)
        XCTAssertNil(result.diskRead)
        XCTAssertNil(result.thermalState)
    }
    func testPageConversionsAndCounterDeltasUseMonotonicTime() throws {
        var reducer = PerformanceReducer()
        _ = try reducer.consume(wire(time: 10, system: ["netBytesIn": 1000, "diskBytesRead": 2000]))
        let sample = try reducer.consume(wire(time: 12, system: ["physMemSize": 16384,
            "vmFreeCount": 2, "vmPageSize": 4096, "netBytesIn": 4000, "diskBytesRead": 6000]))
        XCTAssertEqual(sample.memoryFree, 8192)
        XCTAssertEqual(sample.memoryUsed, 8192)
        XCTAssertTrue(sample.memoryEstimated)
        XCTAssertEqual(sample.networkReceived, 1500)
        XCTAssertEqual(sample.diskRead, 2000)
        let missing = try reducer.consume(wire(time: 13, system: ["physMemSize": 16384]))
        XCTAssertNil(missing.memoryFree)
        XCTAssertNil(missing.networkReceived)
    }
    func testPartialRowsKeepOnlyFreshIndependentComponents() throws {
        var reducer = PerformanceReducer()
        let processes: [[String: Any]] = [["pid": "7", "values": ["name": "Example", "cpuUsage": 245.5, "physFootprint": 4096]]]
        let first = try reducer.consume(wire(time: 1, processes: processes, hasProcesses: true))
        XCTAssertNil(first.processes.first?.cpuPercent)
        let second = try reducer.consume(wire(time: 2, processes: processes, hasProcesses: true))
        XCTAssertEqual(second.processes.first?.cpuPercent, 245.5)
        let systemOnly = try reducer.consume(wire(time: 3, system: ["physMemSize": 10000]))
        XCTAssertEqual(systemOnly.processes.first?.name, "Example")
        XCTAssertTrue(systemOnly.summary.processes.isEmpty)
        XCTAssertTrue(try reducer.consume(wire(time: 9)).processes.isEmpty)
        let empty = try reducer.consume(wire(time: 10, hasProcesses: true))
        XCTAssertTrue(empty.processes.isEmpty)
    }
    func testBooleansAndNullAreNotNumericMetrics() throws {
        var reducer = PerformanceReducer()
        _ = try reducer.consume(wire(time: 1, cpu: ["CPU_TotalLoad": 100]))
        let result = try reducer.consume(wire(time: 2, system: ["physMemSize": true, "vmFreeCount": NSNull()],
            cpu: ["CPU_TotalLoad": false]))
        XCTAssertNil(result.memoryTotal)
        XCTAssertNil(result.cpuPercent)
    }
}
