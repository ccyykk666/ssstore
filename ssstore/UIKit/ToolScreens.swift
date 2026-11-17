import UIKit
import UpdateCore

@MainActor
final class NativeTools: NativePage {
    init(_ model: AppModel) { super.init(model, title: "工具") }
    required init?(coder: NSCoder) { fatalError() }
    override func rows() -> [NativeSection] {
        [NativeSection(title: "性能", rows: [link("性能监控") { [weak self] in
            guard let self else { return }; push(NativePerformance(model))
        }]), NativeSection(title: "文件", rows: [link("应用文件") { [weak self] in
            guard let self else { return }; push(NativeAppFilesHome(model))
        }]), NativeSection(title: "设备", rows: [
            link("数据") { [weak self] in guard let self else { return }; push(NativeData(model)) },
            link("连接诊断") { [weak self] in guard let self else { return }; push(NativeInspection(model, operation: .probe)) },
        ])]
    }
}

@MainActor
final class NativePerformance: NativePage {
    private let monitor = PerformanceMonitor()
    private let dashboard = PerformanceDashboard()
    private let dashboardCell = UITableViewCell(style: .default, reuseIdentifier: nil)
    private let scopeCell = UITableViewCell(style: .default, reuseIdentifier: nil)
    private let scopeControl = UISegmentedControl(items: ["整机", "单个应用"])
    private let applicationButton = UIButton(type: .system)
    private let statusLabel = UILabel(), timeLabel = UILabel()
    private var selectedApplication: PerformanceApplication?
    private var sortByMemory = false
    private var didAutoStart = false
    private var loadingApplications = false
    private var lastButtonState: PerformanceMonitor.State?
    private var lastButtonActive: Bool?
    private var renderedScope: PerformanceScope?
    private var renderedBackground: Bool?
    init(_ model: AppModel) { super.init(model, title: "性能监控") }
    required init?(coder: NSCoder) { fatalError() }
    override func viewDidLoad() {
        super.viewDidLoad()
        scopeControl.selectedSegmentIndex = 0
        scopeControl.addAction(UIAction { [weak self] _ in self?.changeScope() }, for: .valueChanged)
        applicationButton.contentHorizontalAlignment = .leading
        var applicationConfiguration = UIButton.Configuration.plain()
        applicationConfiguration.image = UIImage(systemName: "chevron.down")
        applicationConfiguration.imagePlacement = .trailing; applicationConfiguration.imagePadding = 8
        applicationConfiguration.contentInsets = .zero
        applicationButton.configuration = applicationConfiguration
        applicationButton.titleLabel?.font = .preferredFont(forTextStyle: .body)
        applicationButton.titleLabel?.adjustsFontForContentSizeCategory = true
        applicationButton.titleLabel?.numberOfLines = 0
        applicationButton.addAction(UIAction { [weak self] _ in self?.chooseApplication() }, for: .touchUpInside)
        for label in [statusLabel, timeLabel] {
            label.font = .preferredFont(forTextStyle: .footnote); label.adjustsFontForContentSizeCategory = true
            label.numberOfLines = 0; label.textColor = .secondaryLabel
        }
        let controls = UIStackView(arrangedSubviews: [scopeControl, applicationButton, statusLabel, timeLabel])
        controls.axis = .vertical; controls.spacing = 12
        embed(controls, in: scopeCell)
        embed(dashboard, in: dashboardCell, margins: false)
        dashboardCell.backgroundConfiguration = .clear()
        monitor.onChange = { [weak self] in self?.scheduleReload() }
    }
    private func embed(_ content: UIView, in cell: UITableViewCell, margins: Bool = true) {
        cell.selectionStyle = .none; content.translatesAutoresizingMaskIntoConstraints = false
        cell.contentView.addSubview(content)
        let guide = margins ? cell.contentView.layoutMarginsGuide : cell.contentView.safeAreaLayoutGuide
        NSLayoutConstraint.activate([content.leadingAnchor.constraint(equalTo: guide.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: guide.trailingAnchor), content.topAnchor.constraint(equalTo: guide.topAnchor),
            content.bottomAnchor.constraint(equalTo: guide.bottomAnchor)])
    }
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if !didAutoStart { didAutoStart = true; monitor.start(model) }
    }
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if isMovingFromParent || navigationController?.isBeingDismissed == true { monitor.stop() }
    }
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if presentedViewController == nil && !monitor.supportsBackground { monitor.stop(message: "已停止：系统未允许后台采样") }
    }
    override func reload() {
        guard isViewLoaded else { return }
        let scope = monitor.scope
        scopeControl.selectedSegmentIndex = scope.isDevice ? 0 : 1
        applicationButton.isHidden = scope.isDevice
        applicationButton.isEnabled = !loadingApplications
        applicationButton.configuration?.title = loadingApplications ? "正在读取应用…" : scope.title
        var status = monitor.status
        if !scope.isDevice, let reading = monitor.reading, reading.processes.isEmpty {
            status += " · 等待所选应用的关联进程"
        }
        statusLabel.text = status
        timeLabel.text = monitor.latest.map { "最近更新 " + DateFormatter.localizedString(from: $0.capturedAt, dateStyle: .none, timeStyle: .medium) }
        dashboard.update(current: monitor.reading, history: monitor.readings, scope: scope)
        updateButtons()
        let structureChanged = renderedScope != scope || renderedBackground != monitor.supportsBackground
        renderedScope = scope; renderedBackground = monitor.supportsBackground
        super.reload()
        if structureChanged { tableView.reloadData() }
    }
    private func updateButtons() {
        let active = monitor.isActive
        guard lastButtonState != monitor.state || lastButtonActive != active else { return }
        lastButtonState = monitor.state; lastButtonActive = active
        let control = UIBarButtonItem(image: UIImage(systemName: active ? "stop.fill" : "play.fill"),
            primaryAction: UIAction(title: active ? "停止监控" : "开始监控") { [weak self] _ in
                guard let self else { return }
                if self.monitor.isActive { self.monitor.stop() } else { self.monitor.start(self.model) }
            })
        control.accessibilityLabel = active ? "停止监控" : "开始监控"
        control.isEnabled = monitor.state != .stopping
        let export = UIBarButtonItem(image: UIImage(systemName: "square.and.arrow.up"), primaryAction: UIAction(title: "导出性能记录") { [weak self] _ in
            guard let self else { return }; do { share(try monitor.export()) } catch { alert(error.localizedDescription) }
        })
        export.accessibilityLabel = "导出性能记录"; export.isEnabled = monitor.latest != nil
        navigationItem.rightBarButtonItems = [control, export]
    }
    private func changeScope() {
        if scopeControl.selectedSegmentIndex == 0 { monitor.select(.device) }
        else if let app = selectedApplication { select(app) }
        else { monitor.select(.application(bundleID: "", name: "")); chooseApplication() }
    }
    private func select(_ app: PerformanceApplication) {
        selectedApplication = app
        monitor.select(.application(bundleID: app.bundleID, name: app.name.isEmpty ? app.bundleID : app.name))
    }
    private func chooseApplication() {
        guard !loadingApplications else { return }
        Task { [weak self] in
            guard let self else { return }
            var apps = monitor.latest?.applications ?? []
            if apps.isEmpty && model.records.isEmpty {
                loadingApplications = true; reload()
                if let result = try? await model.inspect(.coreApps).0.value { apps = PerformanceApplication.fromInspection(result) }
                if apps.isEmpty { _ = await model.scan() }
                loadingApplications = false; reload()
            }
            if apps.isEmpty { apps = model.records.map { PerformanceApplication(bundleID: $0.id, name: $0.installed.name) } }
            guard view.window != nil, presentedViewController == nil else { return }
            let picker = NativeApplicationPicker(model, applications: apps) { [weak self] in self?.select($0) }
            let nav = UINavigationController(rootViewController: picker)
            nav.navigationBar.prefersLargeTitles = true
            nav.sheetPresentationController?.detents = [.large()]
            nav.sheetPresentationController?.prefersGrabberVisible = true
            present(nav, animated: true)
        }
    }
    override func rows() -> [NativeSection] {
        let reading = monitor.reading
        var result = [NativeSection(rows: [NativeRow(title: "监控范围")]),
                      NativeSection(rows: [NativeRow(title: "实时面板")])]
        if monitor.scope.isDevice {
            let sample = monitor.latest
            var device = [NativeRow(title: "内存压力", detail: sample?.memoryPressure ?? "暂不可用"),
                          NativeRow(title: "温度状态", detail: sample?.thermalState ?? "暂不可用")]
            for (index, load) in (sample?.corePercent ?? []).enumerated() {
                device.append(NativeRow(title: "核心 \(index + 1)", detail: percent(load)))
            }
            result.append(NativeSection(title: "设备状态", rows: device))
        }
        var processes = reading?.processes ?? []
        processes.sort {
            let a = sortByMemory ? $0.memoryBytes : $0.cpuPercent, b = sortByMemory ? $1.memoryBytes : $1.cpuPercent
            return a != b ? (a ?? -1) > (b ?? -1) : $0.pid < $1.pid
        }
        var processRows = [link("排序：\(sortByMemory ? "内存" : "CPU")") { [weak self] in self?.chooseSort() }]
        if processes.isEmpty { processRows.append(NativeRow(title: "等待进程采样", detail: monitor.scope.isDevice ? "" : "仅显示已确认属于所选应用的进程")) }
        processRows += processes.prefix(20).map { process in
            NativeRow(title: process.name, detail: "PID \(process.pid) · CPU \(percent(process.cpuPercent)) · \(bytes(process.memoryBytes))", action: process.bundleID == nil ? nil : { [weak self] in
                guard let self, let id = process.bundleID else { return }
                let app = monitor.latest?.applications?.first { $0.bundleID == id } ?? PerformanceApplication(bundleID: id, name: process.name)
                select(app)
            }, compact: true)
        }
        result.append(NativeSection(title: monitor.scope.isDevice ? "进程排行 · 前 20 项" : "应用关联进程", rows: processRows))
        return result
    }
    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        if section == 0 { return monitor.supportsBackground ? "可切换到目标应用操作；本次采样最多 5 分钟，系统可能提前结束后台任务。" : "本次采样最多 5 分钟。后台执行暂不可用，进入后台会停止。" }
        if section == 1 { return "切换范围后曲线重新开始。暂不可用的指标会留空。" }
        if section == sections.count - 1 { return "应用 CPU 按单核心 100% 计，多线程可超过 100%；仅统计已确认关联的进程。" }
        return nil
    }
    private func chooseSort() {
        let menu = UIAlertController(title: "进程排序", message: nil, preferredStyle: .actionSheet)
        for (title, memory) in [("CPU 使用率", false), ("内存占用", true)] {
            menu.addAction(UIAlertAction(title: title, style: .default) { [weak self] _ in self?.sortByMemory = memory; self?.reload() })
        }
        menu.addAction(UIAlertAction(title: "取消", style: .cancel))
        menu.popoverPresentationController?.sourceView = view
        menu.popoverPresentationController?.sourceRect = CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 1, height: 1)
        present(menu, animated: true)
    }
    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        if indexPath.section == 0 { return scopeCell }
        if indexPath.section == 1 { return dashboardCell }
        return super.tableView(tableView, cellForRowAt: indexPath)
    }
    private func percent(_ value: Double?) -> String { value.map { String(format: "%.1f%%", $0) } ?? "暂不可用" }
    private func bytes(_ value: Double?) -> String {
        guard let value, value.isFinite, value >= 0, value < Double(Int64.max) else { return "暂不可用" }
        return ByteCountFormatter.string(fromByteCount: Int64(value), countStyle: .memory)
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
