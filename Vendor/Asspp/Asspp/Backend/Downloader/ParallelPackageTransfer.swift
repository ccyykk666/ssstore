import Foundation

@MainActor
final class PackageTransfer {
    private enum TransferError: Error { case unsupportedRange }
    typealias ProgressHandler = NativePackageTransfer.ProgressHandler
    typealias CompletionHandler = NativePackageTransfer.CompletionHandler
    private struct Checkpoint: Codable {
        let size: Int64
        let validator: String
        var completed: Set<Int>
    }
    private let directory: URL
    private let fallback: NativePackageTransfer
    private var jobs: [UUID: Task<Void, Never>] = [:]
    private var stopping: Set<UUID> = []
    private var restart: [UUID: () -> Void] = [:]
    private var native: Set<UUID> = []
    private var discard: Set<UUID> = []
    private let chunkSize: Int64 = 8 * 1024 * 1024
    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil; config.urlCache = nil
        config.httpMaximumConnectionsPerHost = 4
        config.timeoutIntervalForRequest = 30
        return URLSession(configuration: config)
    }()
    init(directory: URL) { self.directory = directory; fallback = NativePackageTransfer(directory: directory) }
    private func file(_ id: UUID, _ suffix: String) -> URL { directory.appendingPathComponent(id.uuidString + suffix) }

    func resume(id: UUID, url: URL, progress: @escaping ProgressHandler, completion: @escaping CompletionHandler) {
        if native.contains(id) || FileManager.default.fileExists(atPath: file(id, ".resume").path) {
            native.insert(id)
            fallback.resume(id: id, url: url, progress: progress, completion: completion); return
        }
        if jobs[id] != nil {
            if stopping.contains(id) { restart[id] = { self.resume(id: id, url: url, progress: progress, completion: completion) } }
            return
        }
        jobs[id] = Task {
            defer {
                jobs[id] = nil; stopping.remove(id)
                if discard.remove(id) != nil { clean(id) }
                let next = restart.removeValue(forKey: id); next?()
            }
            do {
                if FileManager.default.fileExists(atPath: file(id, ".download").path) {
                    completion(.success(file(id, ".download"))); return
                }
                var probe = URLRequest(url: url, timeoutInterval: 3)
                probe.httpMethod = "HEAD"
                let response = (try? await session.data(for: probe))?.1 as? HTTPURLResponse
                try Task.checkCancellation()
                guard let response, response.statusCode == 200,
                      response.value(forHTTPHeaderField: "Accept-Ranges")?.lowercased() == "bytes",
                      response.expectedContentLength >= 16 * 1024 * 1024,
                      let validator = response.value(forHTTPHeaderField: "ETag").flatMap({ $0.hasPrefix("W/") ? nil : $0 }) ?? response.value(forHTTPHeaderField: "Last-Modified") else {
                    native.insert(id)
                    fallback.resume(id: id, url: url, progress: progress, completion: completion)
                    return
                }
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let validatorHeader = response.value(forHTTPHeaderField: "ETag")?.hasPrefix("W/") == false ? "ETag" : "Last-Modified"
                let total = response.expectedContentLength
                let stateFile = file(id, ".ranges")
                let destination = file(id, ".partial")
                var state = (try? JSONDecoder().decode(Checkpoint.self, from: Data(contentsOf: stateFile)))
                if state?.size != total || state?.validator != validator || (try? FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? NSNumber)?.int64Value != total {
                    state = Checkpoint(size: total, validator: validator, completed: [])
                    FileManager.default.createFile(atPath: destination.path, contents: nil)
                    let handle = try FileHandle(forWritingTo: destination)
                    try handle.truncate(atOffset: UInt64(total)); try handle.close()
                }
                var checkpoint = state!
                let count = Int((total + chunkSize - 1) / chunkSize)
                let pending = (0..<count).filter { !checkpoint.completed.contains($0) }
                var next = 0
                var bytes: [Int: Int64] = [:]
                for index in checkpoint.completed { bytes[index] = min(chunkSize, total - Int64(index) * chunkSize) }
                var lastTime = ProcessInfo.processInfo.systemUptime
                var lastBytes = bytes.values.reduce(0, +)
                let notify: @MainActor (Int, Int64) -> Void = { index, value in
                    bytes[index] = value
                    let now = ProcessInfo.processInfo.systemUptime
                    guard now - lastTime >= 0.25 else { return }
                    let current = bytes.values.reduce(0, +)
                    progress(Double(current) / Double(total), Int64(Double(max(0, current - lastBytes)) / (now - lastTime)))
                    lastTime = now; lastBytes = current
                }
                let session = self.session
                let chunkSize = self.chunkSize
                try await withThrowingTaskGroup(of: Int.self) { group in
                    func enqueue(_ index: Int) {
                        group.addTask {
                            let start = Int64(index) * chunkSize
                            let end = min(total - 1, start + chunkSize - 1)
                            var request = URLRequest(url: url)
                            request.setValue("bytes=\(start)-\(end)", forHTTPHeaderField: "Range")
                            request.setValue(validator, forHTTPHeaderField: "If-Range")
                            let delegate = ChunkProgress { value in Task { @MainActor in notify(index, value) } }
                            let temporary: URL
                            let reply: URLResponse
                            do { (temporary, reply) = try await session.download(for: request, delegate: delegate) }
                            catch {
                                if delegate.needsFallback { throw TransferError.unsupportedRange }
                                throw error
                            }
                            defer { try? FileManager.default.removeItem(at: temporary) }
                            if (reply as? HTTPURLResponse)?.statusCode == 200 { throw TransferError.unsupportedRange }
                            guard let reply = reply as? HTTPURLResponse, reply.statusCode == 206,
                                  reply.value(forHTTPHeaderField: validatorHeader) == validator,
                                  reply.value(forHTTPHeaderField: "Content-Range") == "bytes \(start)-\(end)/\(total)",
                                  (try FileManager.default.attributesOfItem(atPath: temporary.path)[.size] as? NSNumber)?.int64Value == end - start + 1 else { throw URLError(.badServerResponse) }
                            try Task.checkCancellation()
                            try await Task.detached {
                                let input = try FileHandle(forReadingFrom: temporary)
                                let output = try FileHandle(forWritingTo: destination)
                                defer { try? input.close(); try? output.close() }
                                try output.seek(toOffset: UInt64(start))
                                while let data = try input.read(upToCount: 1024 * 1024), !data.isEmpty { try output.write(contentsOf: data) }
                                try output.synchronize()
                            }.value
                            await MainActor.run { notify(index, end - start + 1) }
                            return index
                        }
                    }
                    for _ in 0..<min(4, pending.count) { enqueue(pending[next]); next += 1 }
                    while let index = try await group.next() {
                        checkpoint.completed.insert(index)
                        try JSONEncoder().encode(checkpoint).write(to: stateFile, options: .atomic)
                        try Task.checkCancellation()
                        if next < pending.count { enqueue(pending[next]); next += 1 }
                    }
                }
                try Task.checkCancellation()
                try FileManager.default.moveItem(at: destination, to: file(id, ".download"))
                try? FileManager.default.removeItem(at: stateFile)
                completion(.success(file(id, ".download")))
            } catch {
                if !stopping.contains(id) {
                    if case TransferError.unsupportedRange = error {
                        clean(id); native.insert(id)
                        fallback.resume(id: id, url: url, progress: progress, completion: completion)
                    } else { completion(.failure(error)) }
                }
            }
        }
    }
    func pause(id: UUID) {
        if native.contains(id) { fallback.pause(id: id); return }
        stopping.insert(id); jobs[id]?.cancel()
    }
    func cancel(id: UUID) {
        restart[id] = nil
        if native.remove(id) != nil { fallback.cancel(id: id) }
        stopping.insert(id)
        if let job = jobs[id] { discard.insert(id); job.cancel() }
        else { clean(id) }
    }
    private func clean(_ id: UUID) {
        for suffix in [".ranges", ".partial", ".download"] { try? FileManager.default.removeItem(at: file(id, suffix)) }
    }
}

private final class ChunkProgress: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let update: @Sendable (Int64) -> Void
    private let lock = NSLock()
    private var last: TimeInterval = 0
    private var rejected = false
    var needsFallback: Bool { lock.lock(); defer { lock.unlock() }; return rejected }
    init(_ update: @escaping @Sendable (Int64) -> Void) { self.update = update }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        lock.lock(); defer { lock.unlock() }
        if (downloadTask.response as? HTTPURLResponse)?.statusCode == 200 {
            rejected = true; downloadTask.cancel(); return
        }
        let now = ProcessInfo.processInfo.systemUptime
        if now - last >= 0.25 { last = now; update(totalBytesWritten) }
    }
}
