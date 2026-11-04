import CryptoKit
import Foundation

@main
struct TransferChecks {
    @MainActor static func main() async throws {
        let timeout = Task {
            do { try await Task.sleep(nanoseconds: 60_000_000_000) } catch { return }
            fatalError("Native transfer checks timed out")
        }
        defer { timeout.cancel() }
        let base = URL(string: CommandLine.arguments[1])!
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let transfer = NativePackageTransfer(directory: directory)
        let payload = Data((0..<8_388_608).map { UInt8(truncatingIfNeeded: $0) })
        let expected = SHA256.hash(data: payload)

        let firstID = UUID()
        var progressCount = 0
        let first: URL = try await withCheckedThrowingContinuation { continuation in
            transfer.resume(id: firstID, url: base.appendingPathComponent("single")) { _, speed in
                precondition(speed >= 0)
                progressCount += 1
            } completion: { continuation.resume(with: $0) }
            transfer.resume(id: firstID, url: base.appendingPathComponent("single")) { _, _ in
                fatalError("Duplicate callback registration")
            } completion: { _ in fatalError("Duplicate completion") }
        }
        let firstBytes = try Data(contentsOf: first)
        precondition(SHA256.hash(data: firstBytes) == expected)
        precondition(progressCount > 0 && progressCount < 16, "Progress must be throttled before reaching MainActor")
        let recovered: URL = try await withCheckedThrowingContinuation { continuation in
            let nextSession = NativePackageTransfer(directory: directory)
            nextSession.resume(id: firstID, url: base.appendingPathComponent("single")) { _, _ in }
                completion: { continuation.resume(with: $0) }
        }
        precondition(recovered == first, "A completed transfer must survive interruption before IPA finalization")

        let resumeID = UUID()
        var paused = false
        let resumed: URL = try await withCheckedThrowingContinuation { continuation in
            transfer.resume(id: resumeID, url: base.appendingPathComponent("resume")) { _, _ in
                guard !paused else { return }
                paused = true
                transfer.pause(id: resumeID)
                Task { @MainActor in
                    let resumeFile = directory.appendingPathComponent(resumeID.uuidString + ".resume")
                    let deadline = Date().addingTimeInterval(5)
                    while !FileManager.default.fileExists(atPath: resumeFile.path), Date() < deadline {
                        try await Task.sleep(nanoseconds: 10_000_000)
                    }
                    precondition(FileManager.default.fileExists(atPath: resumeFile.path), "Pause must save native resume data")
                    // A new session must continue the persisted transfer, not issue a HEAD.
                    let nextSession = NativePackageTransfer(directory: directory)
                    nextSession.resume(id: resumeID, url: base.appendingPathComponent("resume")) { _, _ in }
                        completion: { continuation.resume(with: $0) }
                }
            } completion: { _ in fatalError("Paused transfer completed") }
        }
        let resumedBytes = try Data(contentsOf: resumed)
        precondition(SHA256.hash(data: resumedBytes) == expected, "Resume must preserve every byte")

        let raceID = UUID()
        var toggled = false
        let rapidResume: URL = try await withCheckedThrowingContinuation { continuation in
            transfer.resume(id: raceID, url: base.appendingPathComponent("rapid-resume")) { _, _ in
                guard !toggled else { return }
                toggled = true
                transfer.pause(id: raceID)
                transfer.resume(id: raceID, url: base.appendingPathComponent("rapid-resume")) { _, _ in }
                    completion: { _ in fatalError("Rapid resume must keep the original completion") }
            } completion: { continuation.resume(with: $0) }
        }
        let rapidBytes = try Data(contentsOf: rapidResume)
        precondition(SHA256.hash(data: rapidBytes) == expected, "An old cancellation cannot terminate a resumed task")

        do {
            let _: URL = try await withCheckedThrowingContinuation { continuation in
                transfer.resume(id: UUID(), url: base.appendingPathComponent("denied")) { _, _ in }
                    completion: { continuation.resume(with: $0) }
            }
            fatalError("HTTP 403 must never be accepted as an IPA")
        } catch {}
        let (data, _) = try await URLSession.shared.data(from: base.appendingPathComponent("stats"))
        let stats = try JSONDecoder().decode([String: [String]].self, from: data)
        precondition(stats["/single"] == ["GET"], "No duplicate requests or HEAD preflight")
        precondition(stats["/resume"]?.contains(where: { $0.hasPrefix("bytes=") }) == true, "Resume must request the remaining range")
        precondition(!stats.values.flatMap { $0 }.contains("HEAD"))
        let parallel = PackageTransfer(directory: directory)
        let parallelFile: URL = try await withCheckedThrowingContinuation { continuation in
            parallel.resume(id: UUID(), url: base.appendingPathComponent("parallel")) { _, _ in }
                completion: { continuation.resume(with: $0) }
        }
        let parallelBytes = try Data(contentsOf: parallelFile)
        var parallelExpected = Data()
        for _ in 0..<4 { parallelExpected.append(payload) }
        precondition(SHA256.hash(data: parallelBytes) == SHA256.hash(data: parallelExpected))
        let (parallelStats, _) = try await URLSession.shared.data(from: base.appendingPathComponent("stats"))
        let ranges = try JSONDecoder().decode([String: [String]].self, from: parallelStats)["/parallel"] ?? []
        precondition(ranges.filter { $0.hasPrefix("bytes=") }.count == 4, "One IPA must use four distinct ranges")
        let parallelResumeID = UUID()
        var parallelPaused = false
        let parallelResumed: URL = try await withCheckedThrowingContinuation { continuation in
            let url = base.appendingPathComponent("parallel-resume")
            parallel.resume(id: parallelResumeID, url: url) { _, _ in
                guard !parallelPaused else { return }
                parallelPaused = true
                parallel.pause(id: parallelResumeID)
                parallel.resume(id: parallelResumeID, url: url) { _, _ in }
                    completion: { continuation.resume(with: $0) }
            } completion: { continuation.resume(with: $0) }
        }
        let resumedParallelData = try Data(contentsOf: parallelResumed)
        precondition(parallelPaused && SHA256.hash(data: resumedParallelData) == SHA256.hash(data: parallelExpected))
        let ignoredRange: URL = try await withCheckedThrowingContinuation { continuation in
            parallel.resume(id: UUID(), url: base.appendingPathComponent("parallel-ignored")) { _, _ in }
                completion: { continuation.resume(with: $0) }
        }
        let ignoredRangeData = try Data(contentsOf: ignoredRange)
        precondition(SHA256.hash(data: ignoredRangeData) == SHA256.hash(data: parallelExpected), "Ignored ranges must fall back without corrupting the file")
        print("Native transfer checks passed: integrity, coalescing, progress throttling, persisted and rapid resume, HTTP errors")
    }
}
