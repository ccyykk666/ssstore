import UIKit
import UpdateCore

@MainActor
final class NativeTools: NativePage {
    init(_ model: AppModel) { super.init(model, title: "工具") }
    required init?(coder: NSCoder) { fatalError() }
    override func rows() -> [NativeSection] {
        [NativeSection(title: "性能", rows: [link("实时面板") { [weak self] in
            guard let self else { return }; push(NativePerformancePanel(model))
        }, link("硬件传感器") { [weak self] in
            guard let self else { return }; push(NativeHardwareSensors(model))
        }]), NativeSection(title: "设备", rows: [
            link("数据") { [weak self] in guard let self else { return }; push(NativeData(model)) },
            link("连接诊断") { [weak self] in guard let self else { return }; push(NativeInspection(model, operation: .probe)) },
        ])]
    }
}

@MainActor
final class NativePerformancePanel: NativePage {
    private let panel = PerformancePanel()
    private let dashboard = PerformanceDashboard()
    private let dashboardCell = UITableViewCell(style: .default, reuseIdentifier: nil)
    private let scopeCell = UITableViewCell(style: .default, reuseIdentifier: nil)
    private let scopeControl = UISegmentedControl(items: ["整机", "单个应用"])
    private let applicationButton = UIButton(type: .system)
    private let statusLabel = UILabel(), timeLabel = UILabel()
    private var selectedApplication: PerformanceApplication?
    private var observers: [NSObjectProtocol] = []
    init(_ model: AppModel) { super.init(model, title: "实时面板") }
    required init?(coder: NSCoder) { fatalError() }
    override func viewDidLoad() {
        super.viewDidLoad()
        scopeControl.selectedSegmentIndex = 0
        scopeControl.addAction(UIAction { [weak self] _ in self?.changeScope() }, for: .valueChanged)
        applicationButton.contentHorizontalAlignment = .leading
        var configuration = UIButton.Configuration.plain()
        configuration.image = UIImage(systemName: "chevron.down"); configuration.imagePlacement = .trailing
        configuration.imagePadding = 8; configuration.contentInsets = .zero
        applicationButton.configuration = configuration
        applicationButton.titleLabel?.font = .preferredFont(forTextStyle: .body)
        applicationButton.titleLabel?.numberOfLines = 0
        applicationButton.addAction(UIAction { [weak self] _ in self?.chooseApplication() }, for: .touchUpInside)
        for label in [statusLabel, timeLabel] {
            label.font = .preferredFont(forTextStyle: .footnote); label.adjustsFontForContentSizeCategory = true
            label.numberOfLines = 0; label.textColor = .secondaryLabel
        }
        let controls = UIStackView(arrangedSubviews: [scopeControl, applicationButton, statusLabel, timeLabel])
        controls.axis = .vertical; controls.spacing = 12
        embed(controls, in: scopeCell); embed(dashboard, in: dashboardCell, margins: false)
        dashboardCell.backgroundConfiguration = .clear()
        panel.onChange = { [weak self] in self?.scheduleReload() }
        navigationItem.rightBarButtonItem = UIBarButtonItem(systemItem: .refresh, primaryAction: UIAction { [weak self] _ in self?.panel.reloadCurrent() })
        observers.append(NotificationCenter.default.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.panel.setVisible(false) }
        })
        observers.append(NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.viewIfLoaded?.window != nil, self.navigationController?.visibleViewController === self else { return }
                self.panel.setVisible(true)
            }
        })
    }
    deinit { for observer in observers { NotificationCenter.default.removeObserver(observer) } }
    private func embed(_ content: UIView, in cell: UITableViewCell, margins: Bool = true) {
        cell.selectionStyle = .none; content.translatesAutoresizingMaskIntoConstraints = false
        cell.contentView.addSubview(content)
        let guide = margins ? cell.contentView.layoutMarginsGuide : cell.contentView.safeAreaLayoutGuide
        NSLayoutConstraint.activate([content.leadingAnchor.constraint(equalTo: guide.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: guide.trailingAnchor), content.topAnchor.constraint(equalTo: guide.topAnchor),
            content.bottomAnchor.constraint(equalTo: guide.bottomAnchor)])
    }
    override func viewDidAppear(_ animated: Bool) { super.viewDidAppear(animated); panel.setVisible(true) }
    override func viewWillDisappear(_ animated: Bool) { panel.setVisible(false); super.viewWillDisappear(animated) }
    override func reload() {
        guard isViewLoaded else { return }
        scopeControl.selectedSegmentIndex = panel.scope.isDevice ? 0 : 1
        applicationButton.isHidden = panel.scope.isDevice
        applicationButton.configuration?.title = panel.scope.title
        statusLabel.text = panel.status
        timeLabel.text = panel.latest.map { "更新于 " + DateFormatter.localizedString(from: $0.capturedAt, dateStyle: .none, timeStyle: .medium) }
        dashboard.update(current: panel.reading, scope: panel.scope, metrics: panel.latest?.localMetrics)
        super.reload()
    }
    private func changeScope() {
        if scopeControl.selectedSegmentIndex == 0 { panel.select(.device) }
        else if let app = selectedApplication { select(app) }
        else { panel.select(.application(bundleID: "", name: "")); chooseApplication() }
    }
    private func select(_ application: PerformanceApplication) {
        selectedApplication = application
        panel.select(.application(bundleID: application.bundleID, name: application.name))
    }
    private func chooseApplication() {
        Task { [weak self] in
            let local = await Task.detached(priority: .utility) { LocalPerformance.applications() }.value
            guard let self, viewIfLoaded?.window != nil, presentedViewController == nil else { return }
            var applications: [String: PerformanceApplication] = [:]
            for record in model.records { applications[record.id] = PerformanceApplication(bundleID: record.id, name: record.installed.name) }
            for item in local {
                guard let identifier = item["bundleID"], !identifier.isEmpty else { continue }
                applications[identifier] = PerformanceApplication(bundleID: identifier, name: item["name"] ?? identifier)
            }
            let picker = NativeApplicationPicker(model, applications: Array(applications.values)) { [weak self] in self?.select($0) }
            let navigation = UINavigationController(rootViewController: picker)
            navigation.navigationBar.prefersLargeTitles = true
            navigation.sheetPresentationController?.detents = [.large()]
            navigation.sheetPresentationController?.prefersGrabberVisible = true
            present(navigation, animated: true)
        }
    }
    override func rows() -> [NativeSection] {
        var result = [NativeSection(rows: [NativeRow(title: "显示范围")]), NativeSection(rows: [NativeRow(title: "当前数值")])]
        if panel.scope.isDevice, let sample = panel.latest {
            var values = [NativeRow(title: "热状态", detail: sample.thermalState ?? "暂不可用")]
            if let total = sample.memoryTotal { values.append(NativeRow(title: "物理内存", detail: ByteCountFormatter.string(fromByteCount: Int64(total), countStyle: .memory))) }
            for (index, value) in sample.corePercent.enumerated() {
                values.append(NativeRow(title: "核心 \(index + 1)", detail: value.map { String(format: "%.1f%%", $0) } ?? "等待下次刷新"))
            }
            result.append(NativeSection(title: "设备", rows: values))
        }
        if let sample = panel.latest, let metrics = sample.localMetrics {
            result.append(contentsOf: metricSections(metrics, scope: panel.scope, uptime: sample.uptime))
        }
        if !panel.issues.isEmpty {
            let labels = ["cpu":"CPU", "memory":"内存", "network":"网络", "disk":"磁盘", "application":"应用",
                "gpu":"GPU", "battery":"电池", "memoryAvailability":"可用内存", "processDetails":"进程详情"]
            result.append(NativeSection(title: "接口状态", rows: panel.issues.keys.sorted().map { key in
                NativeRow(title: labels[key] ?? key, detail: panel.issues[key] ?? "", color: .secondaryLabel)
            }))
        }
        return result
    }
    private func metricSections(_ value: LocalPerformanceMetrics, scope: PerformanceScope, uptime: Double) -> [NativeSection] {
        func number(_ title: String, _ amount: Double?, unit: String = "", digits: Int = 0) -> NativeRow? {
            guard let amount, amount.isFinite else { return nil }
            return NativeRow(title: title, detail: String(format: "%.*f%@", digits, amount, unit))
        }
        func bytes(_ title: String, _ amount: Double?) -> NativeRow? {
            guard let amount, amount.isFinite, amount >= 0, amount < Double(Int64.max) else { return nil }
            return NativeRow(title: title, detail: ByteCountFormatter.string(fromByteCount: Int64(amount), countStyle: .memory))
        }
        func state(_ title: String, _ flag: Bool?) -> NativeRow? { flag.map { NativeRow(title: title, detail: $0 ? "是" : "否") } }
        func text(_ title: String, _ string: String?) -> NativeRow? { string.map { NativeRow(title: title, detail: $0) } }
        func group(_ title: String, _ rows: [NativeRow?]) -> NativeSection? {
            let available = rows.compactMap { $0 }; return available.isEmpty ? nil : NativeSection(title: title, rows: available)
        }
        if scope.isDevice {
            return [group("GPU", [number("渲染器使用率", value.gpuRenderer, unit: "%", digits: 1), number("分块器使用率", value.gpuTiler, unit: "%", digits: 1), bytes("GPU 系统内存占用", value.gpuMemory)]),
                group("电池与电源", [number("电量", value.batteryPercent, unit: "%"), number("电池电压", value.batteryVoltage, unit: " V", digits: 3),
                    number("电池电流", value.batteryCurrent, unit: " A", digits: 3), number("电池侧功率", value.batteryPower, unit: " W", digits: 2),
                    number("循环次数", value.batteryCycles), state("正在充电", value.batteryCharging), state("外接电源", value.batteryExternal),
                    state("已充满", value.batteryFull), state("低电量模式", value.lowPowerMode), number("适配器标称功率", value.adapterWatts, unit: " W")]),
                group("内存分类", [number("内核可用内存比例", value.memoryAvailablePercent, unit: "%"), bytes("活跃内存", value.memoryActive),
                    bytes("非活跃内存", value.memoryInactive), bytes("固定内存", value.memoryWired), bytes("压缩器占用", value.memoryCompressed), bytes("可清理内存", value.memoryPurgeable)]),
                group("系统", [number("运行时间", uptime / 3600, unit: " 小时", digits: 1), number("处理器核心数", value.processorCount),
                    number("活跃处理器核心数", value.activeProcessorCount), number("1 分钟负载", value.load1, digits: 2),
                    number("5 分钟负载", value.load5, digits: 2), number("15 分钟负载", value.load15, digits: 2),
                    bytes("存储总容量", value.storageTotal), bytes("文件系统空闲空间", value.storageFree)]),
                group("硬件与系统信息", [text("产品型号", value.hardwareProduct), text("硬件型号", value.hardwareModel), text("硬件平台", value.hardwarePlatform),
                    text("处理器架构", value.cpuArchitecture), text("设备类别", value.deviceClass), text("系统构建", value.osBuild), text("Darwin 版本", value.darwinVersion)])].compactMap { $0 }
        }
        return [group("进程详情", [bytes("常驻内存", value.processResident), bytes("固定内存", value.processWired), bytes("虚拟地址空间", value.processVirtual),
            number("线程数", value.processThreads), number("运行中线程数", value.processRunningThreads),
            number("缺页累计", value.processFaults), number("换入页累计", value.processPageins), number("上下文切换累计", value.processContextSwitches),
            number("空闲唤醒累计", value.processIdleWakeups), number("中断唤醒累计", value.processInterruptWakeups)])].compactMap { $0 }
    }
    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        if indexPath.section == 0 { return scopeCell }
        if indexPath.section == 1 { return dashboardCell }
        return super.tableView(tableView, cellForRowAt: indexPath)
    }
    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        section == 1 ? "仅在页面可见时刷新，不保存历史。单个应用按主进程统计，数据取决于系统是否允许读取。" : nil
    }
}

@MainActor
final class NativeApplicationPicker: NativeSearchPage {
    let applications: [PerformanceApplication]
    let dismissOnSelection: Bool
    let select: (PerformanceApplication) -> Void
    init(_ model: AppModel, applications: [PerformanceApplication], dismissOnSelection: Bool = true,
         select: @escaping (PerformanceApplication) -> Void) {
        self.applications = applications.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        self.dismissOnSelection = dismissOnSelection; self.select = select
        super.init(model, title: "选择应用")
    }
    required init?(coder: NSCoder) { fatalError() }
    override func viewDidLoad() {
        super.viewDidLoad()
        if dismissOnSelection {
            navigationItem.rightBarButtonItem = UIBarButtonItem(systemItem: .cancel, primaryAction: UIAction { [weak self] _ in self?.dismiss(animated: true) })
        }
    }
    override func rows() -> [NativeSection] {
        let apps = applications.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) || $0.bundleID.localizedCaseInsensitiveContains(query) }
        return [NativeSection(rows: apps.map { app in
            let record = model.records.first { $0.id == app.bundleID }
            let icon = record.flatMap { model.localIconURL(for: $0.installed) ?? $0.release?.iconURL }
            return NativeRow(title: app.name.isEmpty ? app.bundleID : app.name, detail: app.bundleID, icon: icon, action: { [weak self] in
                guard let self else { return }; select(app)
                if dismissOnSelection { dismiss(animated: true) }
            }, compact: true)
        })]
    }
}
