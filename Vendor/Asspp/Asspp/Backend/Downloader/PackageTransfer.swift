import Foundation

/// URLSession writes the IPA directly to disk. Only throttled progress reaches UI.
final class PackageTransfer: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    typealias ProgressHandler = @MainActor @Sendable (Double, Int64) -> Void
    typealias CompletionHandler = @MainActor @Sendable (Result<URL, Error>) -> Void

    private final class Transfer {
        let id: UUID
        let url: URL
        let progress: ProgressHandler
        let completion: CompletionHandler
        var task: URLSessionDownloadTask?
        var paused = false
        var wantsResume = false
        var lastTime = ProcessInfo.processInfo.systemUptime
        var lastBytes: Int64 = 0
        init(id: UUID, url: URL, progress: @escaping ProgressHandler, completion: @escaping CompletionHandler) {
            self.id = id; self.url = url; self.progress = progress; self.completion = completion
        }
    }

    private let directory: URL
    private let queue = DispatchQueue(label: "dev.personal.ssstore.transfer", qos: .utility)
    private var transfers: [UUID: Transfer] = [:]
    private var taskIDs: [Int: UUID] = [:]
    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.httpMaximumConnectionsPerHost = 6
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 86_400
        let callbacks = OperationQueue()
        callbacks.maxConcurrentOperationCount = 1
        callbacks.underlyingQueue = queue
        return URLSession(configuration: configuration, delegate: self, delegateQueue: callbacks)
    }()

    init(directory: URL) {
        self.directory = directory
        super.init()
    }

    func resume(id: UUID, url: URL, progress: @escaping ProgressHandler, completion: @escaping CompletionHandler) {
        queue.async {
            if let transfer = self.transfers[id] {
                if transfer.paused { transfer.wantsResume = true }
                if transfer.task == nil { self.launch(transfer) }
                return
            }
            let transfer = Transfer(id: id, url: url, progress: progress, completion: completion)
            self.transfers[id] = transfer
            self.launch(transfer)
        }
    }

    func pause(id: UUID) {
        queue.async {
            guard let transfer = self.transfers[id], let task = transfer.task, !transfer.paused else { return }
            transfer.paused = true
            transfer.wantsResume = false
            task.cancel { data in
                self.queue.async {
                    guard self.transfers[id] === transfer else { return }
                    if let data { try? data.write(to: self.resumeFile(id), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]) }
                    transfer.task = nil
                    if transfer.wantsResume { self.launch(transfer) }
                }
            }
        }
    }

    func cancel(id: UUID) {
        queue.async {
            if let transfer = self.transfers.removeValue(forKey: id), let task = transfer.task {
                self.taskIDs.removeValue(forKey: task.taskIdentifier)
                task.cancel()
            }
            try? FileManager.default.removeItem(at: self.resumeFile(id))
        }
    }

    private func resumeFile(_ id: UUID) -> URL { directory.appendingPathComponent(id.uuidString + ".resume") }

    private func launch(_ transfer: Transfer) {
        do { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        catch { finish(transfer, result: .failure(error)); return }
        let task: URLSessionDownloadTask
        if let data = try? Data(contentsOf: resumeFile(transfer.id)) {
            task = session.downloadTask(withResumeData: data)
        } else {
            let request = URLRequest(url: transfer.url, cachePolicy: .reloadIgnoringLocalCacheData)
            task = session.downloadTask(with: request)
        }
        transfer.paused = false; transfer.wantsResume = false
        transfer.lastTime = ProcessInfo.processInfo.systemUptime; transfer.lastBytes = 0
        transfer.task = task
        taskIDs[task.taskIdentifier] = transfer.id
        task.priority = URLSessionTask.highPriority
        task.resume()
    }

    private func transfer(for task: URLSessionTask) -> Transfer? {
        taskIDs[task.taskIdentifier].flatMap { transfers[$0] }
    }

    private func finish(_ transfer: Transfer, result: Result<URL, Error>) {
        transfers.removeValue(forKey: transfer.id)
        if let task = transfer.task { taskIDs.removeValue(forKey: task.taskIdentifier) }
        Task { @MainActor in transfer.completion(result) }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didResumeAtOffset fileOffset: Int64, expectedTotalBytes: Int64) {
        transfer(for: downloadTask)?.lastBytes = fileOffset
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let transfer = transfer(for: downloadTask), !transfer.paused else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let elapsed = now - transfer.lastTime
        guard elapsed >= 0.25 else { return }
        let speed = Int64(Double(max(0, totalBytesWritten - transfer.lastBytes)) / elapsed)
        let fraction = totalBytesExpectedToWrite > 0 ? min(1, Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)) : 0
        transfer.lastTime = now; transfer.lastBytes = totalBytesWritten
        Task { @MainActor in transfer.progress(fraction, speed) }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let transfer = transfer(for: downloadTask), !transfer.paused else { return }
        do {
            guard let response = downloadTask.response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else {
                throw URLError(.badServerResponse)
            }
            let target = directory.appendingPathComponent(transfer.id.uuidString + ".download")
            try FileManager.default.moveItem(at: location, to: target)
            try? FileManager.default.removeItem(at: resumeFile(transfer.id))
            finish(transfer, result: .success(target))
        } catch { finish(transfer, result: .failure(error)) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let transfer = transfer(for: task), let error else { return }
        taskIDs.removeValue(forKey: task.taskIdentifier)
        guard !transfer.paused else { return }
        let failure = error as NSError
        if let data = failure.userInfo[NSURLSessionDownloadTaskResumeData] as? Data {
            try? data.write(to: resumeFile(transfer.id), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }
        finish(transfer, result: .failure(error))
    }
}
