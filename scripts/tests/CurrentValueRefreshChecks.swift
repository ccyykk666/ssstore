import Foundation

private final class Reads: @unchecked Sendable {
    let lock = NSLock(), unblock = DispatchSemaphore(value: 0)
    private var count = 0, active = 0, maximum = 0
    private var discardedWasRead = false
    var discarded: Bool { lock.lock(); defer { lock.unlock() }; return discardedWasRead }
    var snapshot: (Int, Int) { lock.lock(); defer { lock.unlock() }; return (count, maximum) }
    func read(_ name: String, block: Bool = false) -> Data {
        lock.lock(); count += 1; active += 1; maximum = max(maximum, active)
        if name == "discarded" { discardedWasRead = true }; lock.unlock()
        if block { unblock.wait() }
        lock.lock(); active -= 1; lock.unlock()
        return Data(name.utf8)
    }
}
@main
struct CurrentValueRefreshChecks {
    enum Failure: Error { case deadline, staleValue, afterStop, overlap, retained }
    @MainActor static func main() async throws {
        let reads = Reads(), refresh = CurrentValueRefresh()
        var values: [String] = []
        refresh.start(interval: 5_000_000, read: { reads.read("old", block: true) },
                      onValue: { values.append(String(decoding: $0, as: UTF8.self)) }, onError: { _ in })
        for _ in 0..<200 {
            if reads.snapshot.0 == 1 { break }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        guard reads.snapshot.0 == 1 else { throw Failure.deadline }
        refresh.stop()
        refresh.start(interval: 5_000_000, read: { reads.read("discarded") }, onValue: { _ in }, onError: { _ in })
        // This request waits behind the first blocked read, then gets cancelled
        // before it starts. Its source must never be called after closing.
        try await Task.sleep(nanoseconds: 5_000_000)
        refresh.stop()
        refresh.start(interval: 5_000_000, read: { reads.read("new") },
                      onValue: { values.append(String(decoding: $0, as: UTF8.self)) }, onError: { _ in })
        reads.unblock.signal()
        for _ in 0..<200 {
            if !values.isEmpty { break }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        guard !values.isEmpty, values.allSatisfy({ $0 == "new" }) else { throw Failure.staleValue }
        refresh.stop(); let delivered = values.count
        try await Task.sleep(nanoseconds: 30_000_000)
        let stoppedReads = reads.snapshot.0
        try await Task.sleep(nanoseconds: 30_000_000)
        guard values.count == delivered, reads.snapshot.0 == stoppedReads else { throw Failure.afterStop }
        guard reads.snapshot.1 == 1 else { throw Failure.overlap }
        guard !reads.discarded else { throw Failure.afterStop }
        var temporary: CurrentValueRefresh? = CurrentValueRefresh()
        weak var released = temporary
        temporary?.start(interval: 1_000_000, read: { Data() }, onValue: { _ in }, onError: { _ in })
        temporary = nil
        try await Task.sleep(nanoseconds: 10_000_000)
        guard released == nil else { throw Failure.retained }
        print("Current values: stop during read, scope-change isolation, serial reads, queued-read cancellation, no work after stop and owner release passed")
    }
}
