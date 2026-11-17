import UIKit
import UpdateCore

@MainActor
final class NativeTools: NativePage {
    init(_ model: AppModel) { super.init(model, title: "工具") }
    required init?(coder: NSCoder) { fatalError() }
    override func rows() -> [NativeSection] {
        [NativeSection(title: "性能", rows: [link("实时面板") { [weak self] in
            guard let self else { return }; push(NativePerformancePanel(model))
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
        dashboard.update(current: panel.reading, scope: panel.scope)
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
        if !panel.issues.isEmpty {
            let labels = ["cpu":"CPU", "memory":"内存", "network":"网络", "disk":"磁盘", "application":"应用"]
            result.append(NativeSection(title: "接口状态", rows: panel.issues.keys.sorted().map { key in
                NativeRow(title: labels[key] ?? key, detail: panel.issues[key] ?? "", color: .secondaryLabel)
            }))
        }
        return result
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
