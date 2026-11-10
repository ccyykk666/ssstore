import Foundation

/// Simulate a stalled Security.framework IPC without accessing the runner's
/// Keychain. The UI/main queue must remain available to release the operation.
@main
struct ManifestCredentialChecks {
    enum Failure: Error { case ranOnMainThread, neverStarted, blockedMainQueue, unexpectedResult }

    @MainActor
    static func main() async throws {
        let worker = ManifestCredentialWorkQueue()
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let read = Task {
            try await worker.perform {
                guard !Thread.isMainThread else { throw Failure.ranOnMainThread }
                entered.signal()
                guard release.wait(timeout: .now() + 3) == .success else { throw Failure.blockedMainQueue }
                return "finished"
            }
        }
        // If perform() ever starts blocking its caller, this main-queue turn
        // cannot run and the simulated IPC times out, failing this regression.
        async let heartbeat: Void = withCheckedThrowingContinuation { continuation in
            DispatchQueue.global().async {
                guard entered.wait(timeout: .now() + 3) == .success else {
                    continuation.resume(throwing: Failure.neverStarted)
                    return
                }
                DispatchQueue.main.async {
                    release.signal()
                    continuation.resume()
                }
            }
        }
        guard try await read.value == "finished" else { throw Failure.unexpectedResult }
        try await heartbeat

        // A failure must reach the caller and leave the queue usable.
        var receivedError = false
        do {
            let _: Bool = try await worker.perform { throw Failure.unexpectedResult }
        } catch Failure.unexpectedResult { receivedError = true }
        guard receivedError else { throw Failure.unexpectedResult }
        guard try await worker.perform({ !Thread.isMainThread }) else { throw Failure.ranOnMainThread }

        // Validation is exercised through the real async credential API, but
        // malformed input must fail before touching any Keychain entry.
        do {
            try await ManifestAPICredentials.save("invalid", for: URL(string: "https://example.invalid/manifest.plist")!)
            throw Failure.unexpectedResult
        } catch let error as NSError {
            guard error.domain == "dev.personal.ssstore.manifest-api", error.code == 1 else { throw error }
        }
        print("Manifest credential checks passed: stalled IPC leaves the main queue responsive; errors propagate and the queue recovers.")
    }
}
