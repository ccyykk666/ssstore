import BackgroundTasks
import UIKit

/// One system activity represents the downloads the user starts in this session.
@available(iOS 26.0, *)
@MainActor
final class DownloadBackgroundExecution {
    static let shared = DownloadBackgroundExecution()

    private struct Entry {
        let name: String
        var subtitle: String
        var completed: Int64
        var active = true
        var start: (() -> Void)?
    }

    private let identifier = Bundle.main.bundleIdentifier! + ".downloads"
    private var registered = false
    private var requested = false
    private var task: BGContinuedProcessingTask?
    private var entries: [UUID: Entry] = [:]
    private var hadFailure = false
    private var lastTitle = ""
    private var lastSubtitle = ""

    func register() {
        registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: .main) { [weak self] incoming in
            MainActor.assumeIsolated {
                guard let self, let continued = incoming as? BGContinuedProcessingTask else {
                    incoming.setTaskCompleted(success: false)
                    return
                }
                self.requested = false
                guard self.entries.values.contains(where: \.active) else {
                    incoming.setTaskCompleted(success: false)
                    return
                }
                self.task = continued
                Downloads.this.backgroundNotice = nil
                continued.expirationHandler = { [weak self, weak continued] in
                    Task { @MainActor in
                        guard let self, let continued, self.task === continued else { return }
                        self.stop()
                    }
                }
                for id in Array(self.entries.keys) { self.startEntry(id) }
                self.updateActivity()
            }
        }
    }

    func begin(_ request: PackageManifest, start: @escaping () -> Void) {
        entries[request.id] = Entry(name: request.package.software.name, subtitle: "正在连接下载服务器…",
                                    completed: min(999, Int64(request.state.percent * 1000)), start: start)
        if task != nil {
            startEntry(request.id)
            updateActivity()
            return
        }
        guard !requested else { return }
        guard UIApplication.shared.applicationState == .active else {
            Downloads.this.suspend(request: request)
            Downloads.this.backgroundNotice = "请返回 App 后继续下载。"
            return
        }
        let submission = BGContinuedProcessingTaskRequest(identifier: identifier,
            title: request.package.software.name, subtitle: "正在连接下载服务器…")
        submission.strategy = .fail
        do {
            guard registered else { throw DownloadBackgroundError.registrationFailed }
            requested = true
            try BGTaskScheduler.shared.submit(submission)
        } catch {
            requested = false
            Downloads.this.backgroundNotice = "系统未允许后台下载，请保持 App 在前台。"
            logger.warning("Continued download task unavailable: \(error.localizedDescription)")
            for id in Array(entries.keys) { startEntry(id) }
        }
    }

    private func startEntry(_ id: UUID) {
        let start = entries[id]?.start
        entries[id]?.start = nil
        start?()
    }

    func update(_ request: PackageManifest) {
        guard entries[request.id]?.active == true else { return }
        entries[request.id]?.completed = min(999, Int64(request.state.percent * 1000))
        entries[request.id]?.subtitle = request.state.status == .processing
            ? "正在整理安装包…"
            : ["\(Int(request.state.percent * 100))%", request.state.speed].filter { !$0.isEmpty }.joined(separator: " · ")
        updateActivity()
    }

    func finish(_ request: PackageManifest) {
        guard entries[request.id] != nil else { return }
        if request.completed {
            entries[request.id]?.active = false
            entries[request.id]?.completed = 1000
            entries[request.id]?.start = nil
        } else {
            hadFailure = true
            entries.removeValue(forKey: request.id)
        }
        if entries.values.contains(where: \.active) { updateActivity() }
        else {
            task?.updateTitle(request.package.software.name, subtitle: request.state.status.title)
            end(success: !hadFailure)
        }
    }

    private func updateActivity() {
        guard let task, let current = entries.values.first(where: \.active) else { return }
        let total = Int64(entries.count) * 1000
        let completed = entries.values.reduce(Int64(0)) { $0 + $1.completed }
        if total < task.progress.completedUnitCount { task.progress.completedUnitCount = completed }
        task.progress.totalUnitCount = total
        task.progress.completedUnitCount = completed
        let activeCount = entries.values.filter(\.active).count
        let title = activeCount == 1 ? current.name : "ssstore：\(activeCount) 个下载"
        let subtitle = activeCount == 1 ? current.subtitle : current.name + " · " + current.subtitle
        if lastTitle != title || lastSubtitle != subtitle {
            task.updateTitle(title, subtitle: subtitle)
            lastTitle = title; lastSubtitle = subtitle
        }
    }

    /// Called when the short UIKit grace period ends without a granted system task.
    func pauseIfUnprotected() {
        if task == nil { stop() }
    }

    private func stop() {
        let activeIDs = Set(entries.filter { $0.value.active }.map(\.key))
        let expired = task
        expired?.expirationHandler = nil
        task = nil
        // A successful immediate submission can already have its launch callback
        // enqueued. Let it drain, so a quick pause/resume never adopts a stale task.
        entries = [:]; hadFailure = false
        lastTitle = ""; lastSubtitle = ""
        Downloads.this.backgroundNotice = nil
        for request in Downloads.this.manifests where activeIDs.contains(request.id) {
            Downloads.this.suspend(request: request)
        }
        expired?.setTaskCompleted(success: false)
    }

    private func end(success: Bool) {
        if success, let task { task.progress.completedUnitCount = task.progress.totalUnitCount }
        task?.expirationHandler = nil
        task?.setTaskCompleted(success: success)
        task = nil
        entries = [:]; hadFailure = false
        lastTitle = ""; lastSubtitle = ""
        Downloads.this.backgroundNotice = nil
    }
}

private enum DownloadBackgroundError: Error { case registrationFailed }
