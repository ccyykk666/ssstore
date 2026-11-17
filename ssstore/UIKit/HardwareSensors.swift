import UIKit
import UpdateCore

@MainActor
final class NativeHardwareSensors: NativeSearchPage {
    private let refresh = CurrentValueRefresh()
    private let filter = UISegmentedControl(items: ["全部", "温度", "电流", "电压"])
    private var snapshot: LocalSensorSnapshot?
    private var status = "正在读取传感器…"
    private var observers: [NSObjectProtocol] = []
    init(_ model: AppModel) { super.init(model, title: "硬件传感器") }
    required init?(coder: NSCoder) { fatalError() }
    override func viewDidLoad() {
        super.viewDidLoad()
        filter.selectedSegmentIndex = 0
        filter.addAction(UIAction { [weak self] _ in self?.scheduleReload() }, for: .valueChanged)
        let header = UIView(frame: CGRect(x: 0, y: 0, width: tableView.bounds.width, height: 48))
        filter.frame = header.bounds.insetBy(dx: 16, dy: 6)
        filter.autoresizingMask = [.flexibleWidth, .flexibleHeight]; header.addSubview(filter)
        tableView.tableHeaderView = header
        navigationItem.rightBarButtonItem = UIBarButtonItem(systemItem: .refresh, primaryAction: UIAction { [weak self] _ in
            self?.refresh.stop(); self?.start()
        })
        observers.append(NotificationCenter.default.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refresh.stop() }
        })
        observers.append(NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.start() }
        })
    }
    deinit { for observer in observers { NotificationCenter.default.removeObserver(observer) } }
    override func viewDidAppear(_ animated: Bool) { super.viewDidAppear(animated); start() }
    override func viewWillDisappear(_ animated: Bool) { refresh.stop(); super.viewWillDisappear(animated) }
    private func start() {
        guard !refresh.isActive, UIApplication.shared.applicationState == .active,
              viewIfLoaded?.window != nil, navigationController?.visibleViewController === self else { return }
        refresh.start(read: { try JSONSerialization.data(withJSONObject: LocalPerformance.sensorsSnapshot()) }, onValue: { [weak self] data in
            guard let self else { return }
            do {
                snapshot = try JSONDecoder().decode(LocalSensorSnapshot.self, from: data)
                status = snapshot?.status ?? "未返回传感器数据"
            } catch { snapshot = nil; status = "读取失败：\(error.localizedDescription)" }
            scheduleReload()
        }, onError: { [weak self] error in
            self?.snapshot = nil; self?.status = "读取失败：\(error.localizedDescription)"; self?.scheduleReload()
        })
    }
    override func rows() -> [NativeSection] {
        let kind = ["", "temperature", "current", "voltage"][filter.selectedSegmentIndex]
        let sensors = (snapshot?.sensors ?? []).filter {
            (kind.isEmpty || $0.kind == kind) && (query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) || $0.key.localizedCaseInsensitiveContains(query))
        }.sorted { ($0.name, $0.key, $0.id) < ($1.name, $1.key, $1.id) }
        var info = [NativeRow(title: status, color: .secondaryLabel)]
        if let snapshot {
            let time = DateFormatter.localizedString(from: Date(timeIntervalSince1970: snapshot.timestamp), dateStyle: .none, timeStyle: .medium)
            info.append(NativeRow(title: "\(snapshot.sensors.count) 个有效传感器 · 更新于 \(time)", color: .secondaryLabel))
            if snapshot.unavailableCount > 0 { info.append(NativeRow(title: "\(snapshot.unavailableCount) 项未返回有效值", color: .secondaryLabel)) }
        }
        return [NativeSection(rows: info), NativeSection(title: "当前数值", rows: sensors.map { sensor in
            let key = sensor.key.isEmpty ? "" : " · \(sensor.key)"
            return NativeRow(title: sensor.name + key, detail: String(format: "%.2f %@", sensor.value, sensor.unit))
        })]
    }
    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        section == 1 ? "仅显示系统返回的传感器名称和当前值；未知位置不猜测为 CPU、GPU 或电池。页面离开或进入后台即暂停，不保存历史。" : nil
    }
}
