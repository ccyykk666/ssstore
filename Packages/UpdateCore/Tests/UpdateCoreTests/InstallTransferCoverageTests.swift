import XCTest
@testable import UpdateCore

final class InstallTransferCoverageTests: XCTestCase {
    func testReportsProgressDuringOneResponseBeforeAnyCompletionCallback() throws {
        var transfer = InstallTransferCoverage(totalBytes: 100)
        let range = try XCTUnwrap(transfer.responseRange(method: "GET", status: 200, contentLength: 100, contentRange: nil))
        XCTAssertEqual(range, 0..<100)
        for end in [Int64(20), 40, 60, 80] {
            transfer.recordWritten(0..<end)
            XCTAssertEqual(transfer.completedBytes, end)
            XCTAssertFalse(transfer.isComplete)
        }
        transfer.recordWritten(0..<100)
        XCTAssertTrue(transfer.isComplete)
    }

    func testInterruptedPrefixAndRetriedRangesAreCombinedWithoutFalseCompletion() throws {
        var transfer = InstallTransferCoverage(totalBytes: 100)
        // First request stops after 40 successful bytes; no onCompleted arrives.
        transfer.recordWritten(0..<40)
        let retry = try XCTUnwrap(transfer.responseRange(method: "GET", status: 206, contentLength: 80, contentRange: "bytes 20-99/100"))
        transfer.recordWritten(retry.lowerBound..<60)
        XCTAssertEqual(transfer.completedBytes, 60)
        XCTAssertFalse(transfer.isComplete)
        transfer.recordWritten(retry)
        XCTAssertEqual(transfer.completedBytes, 100)
        XCTAssertTrue(transfer.isComplete)
        XCTAssertNil(transfer.responseRange(method: "HEAD", status: 200, contentLength: 100, contentRange: nil))
        XCTAssertFalse(transfer.recordWritten(0..<101))
        XCTAssertFalse(transfer.recordWritten(-1..<20))
        XCTAssertEqual(transfer.completedBytes, 100)
    }

    func testProbesAndOverlapsDoNotPrematurelyComplete() {
        var transfer = InstallTransferCoverage(totalBytes: 100)
        XCTAssertFalse(transfer.record(method: "HEAD", status: 200, contentLength: 100, contentRange: nil))
        XCTAssertTrue(transfer.record(method: "GET", status: 206, contentLength: 1, contentRange: "bytes 0-0/100"))
        XCTAssertFalse(transfer.isComplete)
        transfer.record(method: "GET", status: 206, contentLength: 50, contentRange: "bytes 50-99/100")
        transfer.record(method: "GET", status: 206, contentLength: 25, contentRange: "bytes 75-99/100")
        XCTAssertEqual(transfer.completedBytes, 51)
        transfer.record(method: "GET", status: 206, contentLength: 49, contentRange: "bytes 1-49/100")
        XCTAssertTrue(transfer.isComplete)
        XCTAssertEqual(transfer.completedBytes, 100)
    }

    func testInvalidOrUnsentBodiesCannotCountAsDelivered() {
        var transfer = InstallTransferCoverage(totalBytes: 100)
        for header in ["bytes 0-100/100", "bytes -1-9/100", "bytes 50-0/100", "bytes 0-99/101", "bytes */100"] {
            XCTAssertFalse(transfer.record(method: "GET", status: 206, contentLength: 100, contentRange: header))
        }
        XCTAssertFalse(transfer.record(method: "GET", status: 304, contentLength: 100, contentRange: nil))
        XCTAssertFalse(transfer.record(method: "GET", status: 200, contentLength: 99, contentRange: nil))
        XCTAssertEqual(transfer.completedBytes, 0)
        XCTAssertTrue(transfer.record(method: "GET", status: 200, contentLength: 100, contentRange: nil))
        XCTAssertTrue(transfer.isComplete)
    }
}
