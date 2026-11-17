import Foundation
import Network
import UIKit
import UpdateCore

@MainActor
final class PerformanceMonitor {
    enum State: Equatable { case idle, connecting, running, stopping, stopped, failed }
    private(set) var state: State = .idle
    private(set) var status = "尚未开始"
    private(set) var latest: PerformanceSnapshot?
    private(set) var history: [PerformanceSnapshot] = []
    private(set) var raw: Data?
    private(set) var scope: PerformanceScope = .device
    private(set) var reading: PerformanceReading?
    private(set) var readings: [PerformanceReading] = []
    private let background = InstallBackgroundExecution()
    private var deadline: Task<Void, Never>?
    private var beganAt = 0.0
    var supportsBackground: Bool { background.isContinued }
    var onChange: (() -> Void)?
    private var relay: PerformanceRelay?
    private var recording: Task<Void, Never>?
    private var backgroundObserver: NSObjectProtocol?
    private var session = UUID()
    var isActive: Bool { recording != nil }

    init() {
        backgroundObserver = NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification,
            object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    guard let self, !self.supportsBackground else { return }
                    self.stop(message: "已停止：系统未允许后台采样")
                }
            }
    }
    deinit {
        relay?.cancel()
        recording?.cancel()
        deadline?.cancel()
        if let backgroundObserver { NotificationCenter.default.removeObserver(backgroundObserver) }
    }
    func start(_ model: AppModel) {
        guard recording == nil else { return }
        guard !model.busy else { fail("请等待当前设备操作完成。"); return }
        guard model.hasPairing else { fail("请先在设置中创建或导入配对文件。"); return }
        guard let port = UInt16(model.port), port > 0 else { fail("端口应在 1 到 65535 之间。"); return }
        let host = model.host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard IPv4Address(host) != nil else { fail("请输入有效 IPv4 地址。"); return }
        let relay = PerformanceRelay(host: host, port: port)
        self.relay = relay
        let token = UUID(); session = token
        let pairing = model.pairingURL.path
        latest = nil; history = []; raw = nil; reading = nil; readings = []
        state = .connecting; status = "正在连接开发者性能服务…"
        recording = Task { [weak self] in
            do {
                let localPort = try await relay.open()
                guard let owner = self else { relay.cancel(); return }
                _ = try await owner.background.beginMonitoring(id: token) { [weak self] in
                    self?.stop(message: "采样已停止：系统后台任务结束")
                }
                owner.beganAt = ProcessInfo.processInfo.systemUptime
                owner.deadline = Task { [weak self] in
                    do { try await Task.sleep(nanoseconds: 300_000_000_000) } catch { return }
                    self?.stop(message: "本次 5 分钟采样已完成")
                }
                owner.onChange?()
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    DispatchQueue.global(qos: .utility).async {
                        var reducer = PerformanceReducer()
                        var decodingError: Error?
                        do {
                            try DevicePerformance.stream(pairingPath: pairing, host: "127.0.0.1", port: localPort,
                                isCancelled: { relay.isStopped }, sample: { data in
                                    do {
                                        let snapshot = try reducer.consume(data)
                                        relay.receivedSample()
                                        Task { @MainActor [weak self] in
                                            guard let self, self.session == token, self.state != .stopping else { return }
                                            self.latest = snapshot; self.raw = data
                                            self.history.append(snapshot.summary)
                                            if self.history.count > 120 { self.history.removeFirst(self.history.count - 120) }
                                            let reading = PerformanceReading(snapshot: snapshot, scope: self.scope)
                                            self.reading = reading; self.readings.append(reading.summary)
                                            if self.readings.count > 120 { self.readings.removeFirst(self.readings.count - 120) }
                                            let elapsed = max(0, min(300, snapshot.uptime - self.beganAt))
                                            let cpu = reading.cpuPercent.map { String(format: "CPU %.1f%%", $0) } ?? "等待 CPU"
                                            let memory = reading.memoryBytes.map { ByteCountFormatter.string(fromByteCount: Int64(min($0, Double(Int64.max / 2))), countStyle: .memory) } ?? "等待内存"
                                            self.background.update(completed: Int64(elapsed / 300 * 1000), name: self.scope.title + "性能监控", subtitle: cpu + " · " + memory)
                                            self.state = .running; self.status = "实时采样中"; self.onChange?()
                                        }
                                    } catch {
                                        decodingError = error
                                        relay.cancel()
                                    }
                                })
                            if let decodingError { throw decodingError }
                            if let failure = relay.failure { throw failure }
                            continuation.resume()
                        } catch { continuation.resume(throwing: decodingError ?? relay.failure ?? error) }
                    }
                }
                guard let self, self.session == token else { return }
                if self.state != .stopping { self.state = .stopped; self.status = "采样已结束" }
            } catch {
                guard let self, self.session == token else { return }
                if self.state != .stopping {
                    self.state = .failed
                    self.status = "采样失败：\(error.localizedDescription)"
                    logger.warning("Performance recording failed: \(DiagnosticLog.errorDetails(error))")
                }
            }
            relay.cancel()
            guard let self, self.session == token else { return }
            self.deadline?.cancel(); self.deadline = nil
            self.background.finish(success: self.latest != nil && self.state != .failed)
            if self.state == .stopping { self.state = .stopped }
            self.relay = nil; self.recording = nil; self.onChange?()
        }
        onChange?()
    }
    func stop(message: String = "采样已停止") {
        guard recording != nil else { return }
        state = .stopping; status = message
        relay?.cancel(); onChange?()
    }
    private func fail(_ text: String) { state = .failed; status = text; onChange?() }
    func select(_ scope: PerformanceScope) {
        guard self.scope != scope else { return }
        self.scope = scope; readings = []
        reading = latest.map { PerformanceReading(snapshot: $0, scope: scope) }
        if let reading { readings = [reading.summary] }
        onChange?()
    }
    func export() throws -> URL {
        let folder = temporaryDirectory.appendingPathComponent("performance-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let report = PerformanceRecording(capturedAt: Date(), latest: scope.isDevice ? latest : nil,
            history: scope.isDevice ? history : [], rawSample: scope.isDevice ? raw.flatMap { try? JSONDecoder().decode(InspectionValue.self, from: $0) } : nil,
            scope: scope, readings: readings, currentReading: reading)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
        let url = folder.appendingPathComponent("性能记录.json")
        try encoder.encode(report).write(to: url, options: [.atomic, .completeFileProtection])
        return url
    }
}
