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
    @Published private(set) var status = "准备在手机上创建配对记录。"
    @Published private(set) var pin: String?
    @Published private(set) var notificationsAllowed = false

    var isActive: Bool { phase.isActive }
    private var service: NetService?
    private var listener: DispatchSourceRead?
    private var host: PairingHost?
    private var acceptedSocket: Int32 = -1
    private var timeout: Timer?
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var permissionTask: Task<Void, Never>?
    private var completion: ((Result<Data, Error>) -> Void)?
    private var stopReason: String?
    private let notificationID = "ssstore.pairing-code"

    func start(completion: @escaping (Result<Data, Error>) -> Void) {
        guard !isActive else { return }
        self.completion = completion
        stopReason = nil
        pin = nil
        phase = .preparing
        status = "正在准备配对主机…"
        permissionTask = Task {
            notificationsAllowed = (try? await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound])) ?? false
            guard !Task.isCancelled else { return }
            do { try publishHost() }
            catch { finish(.failure(error)) }
        }
    }

    func cancel() {
        stop(reason: "已停止配对。你可以重新开始，原有配对文件仍保留。")
    }

    private func publishHost() throws {
        let identity = try PairingHost(name: "ssstore")
        let (socketFD, port) = try makeListener()
        host = identity
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "ssstore.remote-pairing") { [weak self] in
            Task { @MainActor in
                self?.stop(reason: "系统后台时间已用尽。请返回 App，重新开始并尽快在设置中完成配对。")
                self?.endBackgroundTask()
            }
        }
        timeout = Timer.scheduledTimer(withTimeInterval: 120, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.stop(reason: "等待配对超时。请确认已连接 Wi-Fi，并在开发者模式中选择 ssstore 后重试。") }
        }

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
        status = "正在发布 ssstore 配对主机。请允许本地网络访问。"
    }

    private func acceptConnection(on socketFD: Int32) {
        guard phase == .advertising || phase == .preparing, let host else { return }
        let fd = Darwin.accept(socketFD, nil, nil)
        guard fd >= 0 else {
            if errno != EAGAIN && errno != EWOULDBLOCK { finish(.failure(socketError())) }
            return
        }
        acceptedSocket = fd
        listener?.cancel()
        listener = nil
        service?.stop()
        service = nil
        phase = .exchanging
        status = "系统已连接。正在协商配对，请等待配对码…"

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
                else { finish(result) }
            }
        }
    }

    private func displayPIN(_ value: String) {
        guard phase == .exchanging, stopReason == nil else { return }
        pin = value
        status = "请在系统设置中输入下方配对码。"
        guard notificationsAllowed else { return }
        let content = UNMutableNotificationContent()
        content.title = "ssstore 配对码：\(value)"
        content.body = "在设置 → 隐私与安全 → 开发者模式的配对提示中输入此码。"
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: notificationID, content: content, trigger: nil), withCompletionHandler: nil)
    }

    private func stop(reason: String) {
        guard isActive, phase != .stopping else { return }
        stopReason = reason
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
        permissionTask = nil
        timeout?.invalidate()
        timeout = nil
        listener?.cancel()
        listener = nil
        service?.stop()
        service = nil
        host = nil
        endBackgroundTask()
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
                status = "系统配对成功。正在保存配对记录…"
            case .failure(let error):
                phase = .failed
                status = "配对未完成：\(error.localizedDescription)"
            }
        }
        completion(result)
    }

    func reportSaveResult(_ error: Error?) {
        if let error {
            phase = .failed
            status = "系统已完成配对，但保存记录失败：\(error.localizedDescription)。请重新配对。"
        } else {
            status = "配对记录已保存。开启 Loon 回环后，点击“读取本机”验证连接。"
        }
    }

    private func endBackgroundTask() {
        if backgroundTask != .invalid {
            UIApplication.shared.endBackgroundTask(backgroundTask)
            backgroundTask = .invalid
        }
    }

    func netServiceDidPublish(_ sender: NetService) {
        guard sender === service, phase == .preparing else { return }
        phase = .advertising
        status = "已发布 ssstore。请前往设置 → 隐私与安全 → 开发者模式，选择 ssstore 进行配对。"
    }

    func netService(_ sender: NetService, didNotPublish errorDict: [String: NSNumber]) {
        guard sender === service else { return }
        finish(.failure(OnDevicePairingError.message("无法发布配对主机。请检查本地网络权限和 Wi-Fi 连接（\(errorDict)）。")))
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
