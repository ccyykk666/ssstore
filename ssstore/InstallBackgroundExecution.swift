import BackgroundTasks
import UIKit

/// Keep the local server runnable while Safari and the system installer fetch it.
/// Opening Safari must wait for the continued task's launch callback, not submit().
@MainActor
final class InstallBackgroundExecution {
    private var task: BGTask?
    private var identifier: String?
    private var shortTask: UIBackgroundTaskIdentifier = .invalid
    private var finishingTransfer = false
    private var lastTitle = ""
    private var lastSubtitle = ""

    var diagnosticState: String {
        if task != nil { return "continued-task-granted" }
        if shortTask != .invalid { return "short-task-only" }
        return identifier == nil ? "none" : "waiting-for-grant"
    }

    /// Pairing can still run in the foreground when continued execution is
    /// unavailable. The caller exposes the limited short-task budget to the user.
    func beginPairing(id: UUID, name: String, onStop: @escaping () -> Void) async throws -> Bool {
        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                var resolved = false
                do {
                    try start(id: id, name: name, subtitle: "正在连接设备…", onReady: {
                        guard !resolved else { return }; resolved = true
                        continuation.resume()
                    }, onStop: {
                        onStop()
                        guard !resolved else { return }; resolved = true
                        continuation.resume(throwing: CancellationError())
                    })
                } catch {
                    guard !resolved else { return }; resolved = true
                    continuation.resume(throwing: error)
                }
            }
            return task != nil
        } catch is CancellationError { throw CancellationError() }
        catch {
            guard UIApplication.shared.applicationState == .active else { throw error }
            logger.warning("Pairing install [\(id)]: continued execution unavailable; using short foreground grace")
            try startShortTask(id: id, onStop: onStop)
            return false
        }
    }

    private func startShortTask(id: UUID, onStop: @escaping () -> Void) throws {
        shortTask = UIApplication.shared.beginBackgroundTask(withName: "LocalInstall") { [weak self] in
            guard let self else { return }
            logger.warning("Local install [\(id)]: short background task expired")
            self.finish(success: false)
            onStop()
        }
        guard shortTask != .invalid else {
            throw InstallBackgroundError.message("系统未允许本机安装服务在后台运行，请返回软件重试。")
        }
    }

    func start(id: UUID, name: String, subtitle: String = "等待系统下载本机安装包…", onReady: @escaping () -> Void,
               onStop: @escaping () -> Void) throws {
        finish(success: false)
        guard UIApplication.shared.applicationState == .active else {
            throw InstallBackgroundError.message("请返回 App 后重新点击安装。")
        }
        if #available(iOS 26.0, *) {
            guard let bundleID = Bundle.main.bundleIdentifier,
                  let permitted = Bundle.main.object(forInfoDictionaryKey: "BGTaskSchedulerPermittedIdentifiers") as? [String],
                  permitted.contains(bundleID + ".installation.*") else {
                throw InstallBackgroundError.message("安装后台任务标识不匹配，请保留原 Bundle ID 或同步修改后台任务标识后重新签名。")
            }
            let requestID = bundleID + ".installation." + UUID().uuidString
            identifier = requestID
            let registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: requestID, using: .main) { [weak self] incoming in
                MainActor.assumeIsolated {
                    guard let self, self.identifier == incoming.identifier,
                          let continued = incoming as? BGContinuedProcessingTask else {
                        incoming.setTaskCompleted(success: false)
                        return
                    }
                    self.task = continued
                    continued.progress.totalUnitCount = 1000
                    continued.progress.completedUnitCount = 0
                    continued.expirationHandler = { [weak self] in
                        Task { @MainActor in
                            guard let self, self.identifier == requestID else { return }
                            logger.warning("Local install [\(id)]: continued task expired or stopped by user")
                            self.finish(success: false)
                            onStop()
                        }
                    }
                    logger.info("Local install [\(id)]: continued task granted; operation may begin")
                    onReady()
                }
            }
            guard registered else {
                identifier = nil
                throw InstallBackgroundError.message("无法注册安装后台任务，请返回软件重试。")
            }
            let request = BGContinuedProcessingTaskRequest(identifier: requestID,
                title: name, subtitle: subtitle)
            request.strategy = .fail
            do {
                try BGTaskScheduler.shared.submit(request)
                logger.info("Local install [\(id)]: continued task submitted; waiting for grant")
            } catch {
                logger.error("Local install [\(id)]: continued task rejected: \(error.localizedDescription)")
                finish(success: false)
                throw InstallBackgroundError.message("系统未允许本机安装服务在后台运行：\(error.localizedDescription)。请检查“后台 App 刷新”后重试。")
            }
        } else {
            try startShortTask(id: id, onStop: onStop)
            logger.info("Local install [\(id)]: short background task granted (iOS before 26)")
            onReady()
        }
    }

    func update(completed: Int64, name: String, subtitle: String) {
        if #available(iOS 26.0, *), let continued = task as? BGContinuedProcessingTask {
            continued.progress.completedUnitCount = max(continued.progress.completedUnitCount, min(999, max(0, completed)))
            if lastTitle != name || lastSubtitle != subtitle {
                continued.updateTitle(name, subtitle: subtitle)
                lastTitle = name; lastSubtitle = subtitle
            }
        }
    }

    func completeTransfer(name: String, hasOpenResponses: Bool) {
        if !finishingTransfer {
            finishingTransfer = true
            endShortTask()
        }
        if hasOpenResponses, shortTask == .invalid {
            // Let the HTTP end/close cleanup drain after ending the visible
            // continued task. This grace does not represent installation.
            shortTask = UIApplication.shared.beginBackgroundTask(withName: "LocalInstallerFlush") { [weak self] in
                self?.endShortTask()
            }
        }
        if #available(iOS 26.0, *), let continued = task as? BGContinuedProcessingTask {
            continued.updateTitle(name, subtitle: "安装包已发送")
        }
        endContinuedTask(success: true)
        if !hasOpenResponses { endShortTask() }
    }

    func finish(success: Bool) {
        endContinuedTask(success: success)
        endShortTask()
        finishingTransfer = false
        lastTitle = ""; lastSubtitle = ""
    }

    private func endContinuedTask(success: Bool) {
        if #available(iOS 26.0, *), success, let continued = task as? BGContinuedProcessingTask {
            continued.progress.completedUnitCount = continued.progress.totalUnitCount
        }
        task?.expirationHandler = nil
        task?.setTaskCompleted(success: success)
        task = nil
        if let identifier { BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: identifier) }
        identifier = nil
    }

    private func endShortTask() {
        if shortTask != .invalid {
            UIApplication.shared.endBackgroundTask(shortTask)
            shortTask = .invalid
        }
    }
}

private enum InstallBackgroundError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}
