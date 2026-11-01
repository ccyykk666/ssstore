import BackgroundTasks
import Foundation
import UpdateCore

/// Starts real, user-initiated work before the app switches to Settings.
/// Pairing is not advertised until iOS actually grants the continued task.
@MainActor
final class PairingBackgroundExecution {
    private var task: BGTask?
    private var identifier: String?

    @available(iOS 26.0, *)
    func start(onReady: @escaping () -> Void, onStop: @escaping () -> Void) throws {
        let permitted = Bundle.main.object(forInfoDictionaryKey: "BGTaskSchedulerPermittedIdentifiers") as? [String] ?? []
        let id = try PairingBackgroundIdentifier.make(bundleID: Bundle.main.bundleIdentifier, permitted: permitted)
        identifier = id
        let registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: id, using: .main) { [weak self] incoming in
            MainActor.assumeIsolated {
                guard let self, self.identifier == incoming.identifier,
                      let continued = incoming as? BGContinuedProcessingTask else {
                    incoming.setTaskCompleted(success: false)
                    return
                }
                self.task = continued
                continued.progress.totalUnitCount = 5
                continued.progress.completedUnitCount = 1
                continued.expirationHandler = { [weak self] in
                    Task { @MainActor in
                        guard self?.identifier == incoming.identifier else { return }
                        onStop()
                        self?.finish(success: false)
                    }
                }
                onReady()
            }
        }
        guard registered else {
            identifier = nil
            throw BackgroundExecutionError.message("无法注册后台任务，请返回 App 重试。")
        }
        let request = BGContinuedProcessingTaskRequest(identifier: id, title: "ssstore 配对",
                                                      subtitle: "正在准备配对主机")
        request.strategy = .fail
        do { try BGTaskScheduler.shared.submit(request) }
        catch {
            identifier = nil
            throw BackgroundExecutionError.message("无法启动后台任务：\(error.localizedDescription)。请检查“后台 App 刷新”并在前台重试。")
        }
    }

    func update(completed: Int64, subtitle: String) {
        if #available(iOS 26.0, *), let task = task as? BGContinuedProcessingTask {
            task.progress.completedUnitCount = completed
            task.updateTitle("ssstore 配对", subtitle: subtitle)
        }
    }

    func finish(success: Bool) {
        if success { update(completed: 5, subtitle: "配对记录已保存") }
        task?.expirationHandler = nil
        task?.setTaskCompleted(success: success)
        task = nil
        if let identifier { BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: identifier) }
        identifier = nil
    }
}

private enum BackgroundExecutionError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}
