import Foundation
import UIKit
import UserNotifications
import Darwin

enum OnDevicePairingPhase: Equatable {
    case idle, preparing, advertising, exchanging, stopping, completed, stopped, failed

    var isActive: Bool {
        switch self {
        case .preparing, .advertising, .exchanging, .stopping: return true
        default: return false
        }
    }
}

@MainActor
final class OnDevicePairingController: NSObject, ObservableObject, NetServiceDelegate {
    @Published private(set) var phase: OnDevicePairingPhase = .idle
    @Published private(set) var status = "尚未开始配对。"
    @Published private(set) var pin: String?
    @Published private(set) var notificationsAllowed = false
    @Published private(set) var diagnostics: [String] = []

    var isActive: Bool { phase.isActive }
    private var service: NetService?
    private var listener: DispatchSourceRead?
    private var host: PairingHost?
    private var acceptedSocket: Int32 = -1
    private var timeout: Timer?
    private let backgroundExecution = PairingBackgroundExecution()
    private var observers: [NSObjectProtocol] = []
    private var awaitingForeground = false
    private var startedAt = Date()
    private var permissionTask: Task<Void, Never>?
    private var completion: ((Result<Data, Error>) -> Void)?
    private var stopReason: String?
    private let notificationID = "ssstore.pairing-code"

    override init() {
        super.init()
        let center = NotificationCenter.default
        for name in [UIApplication.didEnterBackgroundNotification, UIApplication.willEnterForegroundNotification,
                     UIApplication.didBecomeActiveNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] event in
                MainActor.assumeIsolated {
                    guard let self, self.isActive else { return }
                    if event.name == UIApplication.didEnterBackgroundNotification { self.record("App 已进入后台") }
                    else if event.name == UIApplication.willEnterForegroundNotification { self.record("App 正在返回前台") }
                    else {
                        self.record("App 已回到活动状态")
                        if self.awaitingForeground { self.awaitingForeground = false; self.beginBackgroundExecution() }
                    }
                }
            })
        }
    }

    func start(completion: @escaping (Result<Data, Error>) -> Void) {
        guard !isActive else { return }
        self.completion = completion
        stopReason = nil
        awaitingForeground = false
        startedAt = Date()
        diagnostics = []
        record("用户开始配对")
        pin = nil
        phase = .preparing
        status = "正在准备配对主机…"
        permissionTask = Task {
            notificationsAllowed = (try? await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound])) ?? false
            guard !Task.isCancelled else { return }
            record(notificationsAllowed ? "允许配对码通知" : "通知未开启，配对码显示在 App 和后台任务中")
            if UIApplication.shared.applicationState == .active { beginBackgroundExecution() }
            else {
                awaitingForeground = true
                status = "请返回 ssstore，等待配对主机就绪。"
                record("等待 App 回到前台再申请后台任务")
            }
        }
    }

    func cancel() {
        stop(reason: "配对已停止，原配对文件已保留。")
    }

    private func beginBackgroundExecution() {
        guard phase == .preparing else { return }
        guard #available(iOS 26.0, *) else {
            finish(.failure(OnDevicePairingError.message("当前系统不支持后台配对，请导入配对文件。")))
            return
        }
        status = "正在启动后台任务，请留在本页…"
        record("申请 iOS 持续后台任务")
        timeout = Timer.scheduledTimer(withTimeInterval: 120, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.stop(reason: "配对超时。请连接 Wi-Fi，并在开发者模式中选择 ssstore 后重试。") }
        }
        do {
            try backgroundExecution.start(onReady: { [weak self] in
                guard let self, self.phase == .preparing else { return }
                self.record("持续后台任务已启动")
                do { try self.publishHost() }
                catch { self.finish(.failure(error)) }
            }, onStop: { [weak self] in
                self?.stop(reason: "后台任务已停止，请返回 App 重新配对。")
            })
        } catch { finish(.failure(error)) }
    }

    private func publishHost() throws {
        let identity = try PairingHost(name: "ssstore")
        let (socketFD, port) = try makeListener()
        host = identity

        let source = DispatchSource.makeReadSource(fileDescriptor: socketFD, queue: .main)
        source.setEventHandler { [weak self] in self?.acceptConnection(on: socketFD) }
        source.setCancelHandler { Darwin.close(socketFD) }
        listener = source
        source.resume()

        let service = NetService(domain: "local.", type: "_remotepairing-pairable-host._tcp.",
                                 name: identity.serviceName, port: Int32(port))
        service.delegate = self
        service.setTXTRecord(NetService.data(fromTXTRecord: identity.txtRecords))
        self.service = service
        service.publish()
        status = "正在发布配对主机，请允许本地网络访问。"
        record("正在发布配对主机，等待系统发现")
    }

    private func acceptConnection(on socketFD: Int32) {
        guard isActive, let host else { return }
        let fd = Darwin.accept(socketFD, nil, nil)
        guard fd >= 0 else {
            if errno != EAGAIN && errno != EWOULDBLOCK { finish(.failure(socketError())) }
            return
        }
        guard acceptedSocket < 0, phase != .stopping else {
            Darwin.close(fd)
            record("已保留当前握手，关闭额外的连接请求")
            return
        }
        acceptedSocket = fd
        // Settings must keep seeing this host while it confirms the passcode
        // and pairing PIN. Withdraw the advertisement only when the run ends.
        phase = .exchanging
        status = "设备已连接，等待配对码…"
        record("系统 TCP 连接已建立；广播保持发布")
        backgroundExecution.update(completed: 3, subtitle: "系统已连接，正在协商配对")

        DispatchQueue.global(qos: .userInitiated).async {
            let result: Result<Data, Error>
            do {
                let data = try host.accept(socket: fd) { [weak self] value in
                    DispatchQueue.main.async { self?.displayPIN(value) }
                }
                result = .success(data)
            } catch { result = .failure(error) }
            DispatchQueue.main.async { [self] in
                // The FFI call has released its duplicate. Close our owned fd now.
                Darwin.close(fd)
                acceptedSocket = -1
                if let stopReason { finish(.failure(OnDevicePairingError.message(stopReason))) }
                else {
                    if case .failure(let error) = result { record("设备握手返回失败：\(error.localizedDescription)") }
                    finish(result)
                }
            }
        }
    }

    private func displayPIN(_ value: String) {
        guard phase == .exchanging, stopReason == nil else { return }
        pin = value
        status = "请在系统设置中输入配对码。"
        record("进入配对码确认阶段（不记录配对码内容）")
        backgroundExecution.update(completed: 4, subtitle: "配对码：\(value)，请在系统设置中输入")
        guard notificationsAllowed else { return }
        let content = UNMutableNotificationContent()
        content.title = "ssstore 配对码：\(value)"
        content.body = "请在“设置 → 隐私与安全 → 开发者模式”中输入配对码。"
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: notificationID, content: content, trigger: nil)) { [weak self] error in
            Task { @MainActor in
                guard let self, self.isActive else { return }
                self.record(error == nil ? "配对码通知已提交给系统" : "配对码通知提交失败：\(error!.localizedDescription)")
            }
        }
    }

    private func stop(reason: String) {
        guard isActive, phase != .stopping else { return }
        stopReason = reason
        record("停止原因：\(reason)")
        awaitingForeground = false
        permissionTask?.cancel()
        listener?.cancel()
        listener = nil
        service?.stop()
        service = nil
        if acceptedSocket >= 0 {
            phase = .stopping
            status = "正在停止配对…"
            // shutdown also interrupts the library's duplicate of this socket.
            Darwin.shutdown(acceptedSocket, SHUT_RDWR)
        } else { finish(.failure(OnDevicePairingError.message(reason))) }
    }

    private func finish(_ result: Result<Data, Error>) {
        guard let completion else { return }
        self.completion = nil
        awaitingForeground = false
        permissionTask = nil
        timeout?.invalidate()
        timeout = nil
        listener?.cancel()
        listener = nil
        service?.stop()
        service = nil
        host = nil
        record("握手已结束，停止发布配对主机")
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [notificationID])
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [notificationID])
        pin = nil
        if let stopReason {
            phase = .stopped
            status = stopReason
        } else {
            switch result {
            case .success:
                phase = .completed
                status = "配对成功，正在保存…"
            case .failure(let error):
                phase = .failed
                status = "配对未完成：\(error.localizedDescription)"
            }
        }
        completion(result)
        // Save the record via completion before handing background time back.
        backgroundExecution.finish(success: phase == .completed)
    }

    func reportSaveResult(_ error: Error?) {
        if let error {
            phase = .failed
            status = "保存配对文件失败：\(error.localizedDescription)。请重新配对。"
            record("配对记录保存失败：\(error.localizedDescription)")
        } else {
            status = "配对文件已保存，可启用 Loon 回环读取应用。"
            record("配对记录已保存")
        }
    }

    private func record(_ event: String) {
        let elapsed = Date().timeIntervalSince(startedAt)
        diagnostics.append(String(format: "%.1fs · %@", elapsed, event))
        if diagnostics.count > 60 { diagnostics.removeFirst(diagnostics.count - 60) }
    }

    func netServiceDidPublish(_ sender: NetService) {
        guard sender === service, phase == .preparing else { return }
        phase = .advertising
        status = "主机已就绪。请前往“设置 → 隐私与安全 → 开发者模式”，选择 ssstore。"
        record("配对主机发布成功，可以前往系统设置")
        backgroundExecution.update(completed: 2, subtitle: "请在开发者模式中选择 ssstore")
    }

    func netService(_ sender: NetService, didNotPublish errorDict: [String: NSNumber]) {
        guard sender === service else { return }
        stop(reason: "无法发布配对主机：\(errorDict)。请检查 Wi-Fi 和本地网络权限。")
    }

    private func makeListener() throws -> (Int32, UInt16) {
        let fd = Darwin.socket(AF_INET6, SOCK_STREAM, 0)
        guard fd >= 0 else { throw socketError() }
        do {
            var dualStack: Int32 = 0
            guard setsockopt(fd, IPPROTO_IPV6, IPV6_V6ONLY, &dualStack, socklen_t(MemoryLayout<Int32>.size)) == 0 else { throw socketError() }
            var address = sockaddr_in6()
            address.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
            address.sin6_family = sa_family_t(AF_INET6)
            let bound = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size)) }
            }
            guard bound == 0, Darwin.listen(fd, 1) == 0 else { throw socketError() }
            let flags = fcntl(fd, F_GETFL, 0)
            guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else { throw socketError() }
            var length = socklen_t(MemoryLayout<sockaddr_in6>.size)
            let result = withUnsafeMutablePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
            }
            guard result == 0 else { throw socketError() }
            return (fd, UInt16(bigEndian: address.sin6_port))
        } catch { Darwin.close(fd); throw error }
    }

    private func socketError() -> Error {
        OnDevicePairingError.message("无法建立配对监听：\(String(cString: strerror(errno)))")
    }
}

private enum OnDevicePairingError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}
