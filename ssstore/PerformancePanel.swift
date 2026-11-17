import Foundation
import UpdateCore

@MainActor
final class PerformancePanel {
    private(set) var scope: PerformanceScope = .device
    private(set) var latest: PerformanceSnapshot?
    private(set) var reading: PerformanceReading?
    private(set) var issues: [String: String] = [:]
    private(set) var status = "正在读取当前数据…"
    var onChange: (() -> Void)?
    private let refresh = CurrentValueRefresh()
    private var visible = false
    func setVisible(_ visible: Bool) {
        self.visible = visible
        if visible { start() } else { pause() }
    }
    func pause() { refresh.stop() }
    func select(_ scope: PerformanceScope) {
        guard self.scope != scope else { return }
        pause(); self.scope = scope; latest = nil; reading = nil; issues = [:]
        status = "正在读取当前数据…"; onChange?()
        if visible { start() }
    }
    func reloadCurrent() { pause(); if visible { start() } }
    private func start() {
        guard !refresh.isActive else { return }
        let scope = scope
        let bundle: String
        switch scope {
        case .device: bundle = ""
        case .application(let id, _):
            guard !id.isEmpty else { status = "请选择应用"; onChange?(); return }
            bundle = id
        }
        var reducer = LocalPerformanceReducer()
        refresh.start(read: {
            try JSONSerialization.data(withJSONObject: LocalPerformance.snapshot(bundleID: bundle))
        }, onValue: { [weak self] data in
            guard let self else { return }
            do {
                let sample = try reducer.consume(data, scope: scope)
                latest = sample; reading = PerformanceReading(snapshot: sample, scope: scope); issues = reducer.issues
                status = issues["application"] ?? "本机当前值 · 每秒刷新"
            } catch { status = "读取失败：\(error.localizedDescription)" }
            onChange?()
        }, onError: { [weak self] error in
            self?.status = "读取失败：\(error.localizedDescription)"; self?.onChange?()
        })
    }
}
