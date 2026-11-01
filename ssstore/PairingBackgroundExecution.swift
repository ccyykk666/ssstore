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
            throw BackgroundExecutionError.message("系统未能注册后台配对任务，请返回前台重试。")
        }
        let request = BGContinuedProcessingTaskRequest(identifier: id, title: "ssstore 手机配对",
                                                      subtitle: "正在准备配对主机")
        request.strategy = .fail
        do { try BGTaskScheduler.shared.submit(request) }
        catch {
            identifier = nil
            throw BackgroundExecutionError.message("系统未允许启动持续后台配对任务：\(error.localizedDescription)。请检查后台 App 刷新权限，并保持 App 在前台重新开始。")
        }
    }

    func update(completed: Int64, subtitle: String) {
        if #available(iOS 26.0, *), let task = task as? BGContinuedProcessingTask {
            task.progress.completedUnitCount = completed
            task.updateTitle("ssstore 手机配对", subtitle: subtitle)
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
