import CryptoKit
import Foundation

@main
struct TransferChecks {
    @MainActor static func main() async throws {
        let base = URL(string: CommandLine.arguments[1])!
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let transfer = PackageTransfer(directory: directory)
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
                    let nextSession = PackageTransfer(directory: directory)
                    nextSession.resume(id: resumeID, url: base.appendingPathComponent("resume")) { _, _ in }
                        completion: { continuation.resume(with: $0) }
                }
            } completion: { _ in fatalError("Paused transfer completed") }
        }
        let resumedBytes = try Data(contentsOf: resumed)
        precondition(SHA256.hash(data: resumedBytes) == expected, "Resume must preserve every byte")

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
        print("Native transfer checks passed: integrity, coalescing, progress throttling, persisted resume, HTTP errors")
    }
}
