import UIKit
import UpdateCore

@MainActor
final class NativeTools: NativePage {
    init(_ model: AppModel) { super.init(model, title: "工具") }
    required init?(coder: NSCoder) { fatalError() }
    override func rows() -> [NativeSection] {
        [NativeSection(title: "性能", rows: [link("整机性能监控") { [weak self] in
            guard let self else { return }; push(NativePerformance(model))
        }]), NativeSection(title: "设备", rows: [
            link("数据") { [weak self] in guard let self else { return }; push(NativeData(model)) },
            link("连接诊断") { [weak self] in guard let self else { return }; push(NativeInspection(model, operation: .probe)) },
        ])]
    }
}

@MainActor
final class NativePerformance: NativePage {
    private let monitor = PerformanceMonitor()
    private let trend = PerformanceTrendView()
    private let trendCell = UITableViewCell(style: .default, reuseIdentifier: nil)
    private var sortByMemory = false
    private var lastButtonState: PerformanceMonitor.State?
    private var lastButtonActive: Bool?
    private let unavailable = "暂不可用"
    init(_ model: AppModel) { super.init(model, title: "整机性能监控") }
    required init?(coder: NSCoder) { fatalError() }
    override func viewDidLoad() {
        super.viewDidLoad()
        trend.translatesAutoresizingMaskIntoConstraints = false
        trendCell.contentView.addSubview(trend)
        let margins = trendCell.contentView.layoutMarginsGuide
        NSLayoutConstraint.activate([
            trend.leadingAnchor.constraint(equalTo: margins.leadingAnchor), trend.trailingAnchor.constraint(equalTo: margins.trailingAnchor),
            trend.topAnchor.constraint(equalTo: margins.topAnchor), trend.bottomAnchor.constraint(equalTo: margins.bottomAnchor),
        ])
        trendCell.selectionStyle = .none
        monitor.onChange = { [weak self] in
            guard let self else { return }
            self.trend.samples = self.monitor.history
            self.updateButton(); self.scheduleReload()
        }
        updateButton()
    }
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if presentedViewController == nil { monitor.stop(message: "已停止：离开监控页面") }
    }
    private func updateButton() {
        let active = monitor.isActive
        guard lastButtonState != monitor.state || lastButtonActive != active else { return }
        lastButtonState = monitor.state; lastButtonActive = active
        let button = UIBarButtonItem(image: UIImage(systemName: active ? "stop.fill" : "play.fill"),
            primaryAction: UIAction(title: active ? "停止监控" : "开始监控") { [weak self] _ in
                guard let self else { return }
                if self.monitor.isActive { self.monitor.stop() } else { self.monitor.start(self.model) }
            })
        button.accessibilityLabel = active ? "停止监控" : "开始监控"
        button.isEnabled = monitor.state != .stopping
        navigationItem.rightBarButtonItem = button
    }
    override func rows() -> [NativeSection] {
        let sample = monitor.latest
        let memoryTitle = sample?.memoryEstimated == true ? "非空闲内存（估算）" : "已用内存"
        let now = sample.map { DateFormatter.localizedString(from: $0.capturedAt, dateStyle: .none, timeStyle: .medium) }
        let controls = [NativeRow(title: monitor.status, detail: now.map { "最近采样：\($0)" } ?? "使用配对设备的开发者服务，监控整机指标。"),
            NativeRow(title: "导出性能记录", color: .systemBlue, action: sample == nil ? nil : { [weak self] in
                guard let self else { return }; do { share(try monitor.export()) } catch { alert(error.localizedDescription) }
            })]
        let metrics = [
            NativeRow(title: "CPU 使用率", detail: percent(sample?.cpuPercent)),
            NativeRow(title: memoryTitle, detail: bytes(sample?.memoryUsed)),
            NativeRow(title: "空闲 / 总内存", detail: "\(bytes(sample?.memoryFree)) / \(bytes(sample?.memoryTotal))"),
            NativeRow(title: "内存压力", detail: sample?.memoryPressure ?? unavailable),
            NativeRow(title: "网络下载", detail: rate(sample?.networkReceived)),
            NativeRow(title: "网络上传", detail: rate(sample?.networkSent)),
            NativeRow(title: "磁盘读取", detail: rate(sample?.diskRead)),
            NativeRow(title: "磁盘写入", detail: rate(sample?.diskWritten)),
            NativeRow(title: "温度状态", detail: sample?.thermalState ?? unavailable),
        ]
        let cores = sample?.corePercent ?? []
        let coreRows = cores.isEmpty ? [NativeRow(title: "各核心负载", detail: unavailable)] :
            cores.enumerated().map { NativeRow(title: "核心 \($0.offset + 1)", detail: percent($0.element)) }
        let processes = (sample?.processes ?? []).sorted {
            let a = sortByMemory ? $0.memoryBytes : $0.cpuPercent
            let b = sortByMemory ? $1.memoryBytes : $1.cpuPercent
            if a != b { return (a ?? -1) > (b ?? -1) }
            return $0.pid < $1.pid
        }
        var processRows = [link("排序：\(sortByMemory ? "内存" : "CPU")") { [weak self] in
            self?.chooseSort()
        }]
        if processes.isEmpty { processRows.append(NativeRow(title: "进程采样", detail: sample == nil ? "等待采样" : "设备未返回进程采样")) }
        processRows += processes.prefix(20).map { process in
            NativeRow(title: process.name, detail: "PID \(process.pid) · CPU \(percent(process.cpuPercent)) · \(bytes(process.memoryBytes))")
        }
        return [NativeSection(rows: controls), NativeSection(title: "整机指标", rows: metrics),
            NativeSection(title: "最近 120 次采样 · CPU 蓝色 / 内存紫色", rows: [NativeRow(title: "趋势")]),
            NativeSection(title: "CPU 核心", rows: coreRows), NativeSection(title: "进程排行 · 前 20 项", rows: processRows),
            NativeSection(rows: [NativeRow(title: "离开页面或进入后台后停止采样。未提供的指标会留空；速率需要两次有效采样。进程 CPU 按单核心 100% 计，多线程进程可能超过 100%。")])]
    }
    private func chooseSort() {
        let menu = UIAlertController(title: "进程排序", message: nil, preferredStyle: .actionSheet)
        menu.addAction(UIAlertAction(title: "CPU 使用率", style: .default) { [weak self] _ in
            self?.sortByMemory = false; self?.reload()
        })
        menu.addAction(UIAlertAction(title: "内存占用", style: .default) { [weak self] _ in
            self?.sortByMemory = true; self?.reload()
        })
        menu.addAction(UIAlertAction(title: "取消", style: .cancel))
        menu.popoverPresentationController?.sourceView = view
        menu.popoverPresentationController?.sourceRect = CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 1, height: 1)
        present(menu, animated: true)
    }
    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        if indexPath.section == 2 { return trendCell }
        return super.tableView(tableView, cellForRowAt: indexPath)
    }
    private func percent(_ value: Double?) -> String { value.map { String(format: "%.1f%%", $0) } ?? unavailable }
    private func bytes(_ value: Double?) -> String {
        guard let value, value.isFinite, value >= 0, value < Double(Int64.max) else { return unavailable }
        return ByteCountFormatter.string(fromByteCount: Int64(value), countStyle: .memory)
    }
    private func rate(_ value: Double?) -> String { value.map { "\(bytes($0))/s" } ?? (monitor.isActive && monitor.latest == nil ? "等待采样" : unavailable) }
}

@MainActor
private final class PerformanceTrendView: UIView {
    var samples: [PerformanceSnapshot] = [] { didSet { setNeedsDisplay(); updateAccessibility() } }
    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: UIFont.preferredFont(forTextStyle: .body).lineHeight * 7)
    }
    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear; isOpaque = false; isAccessibilityElement = true
        accessibilityLabel = "CPU 与内存趋势"
    }
    required init?(coder: NSCoder) { fatalError() }
    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        invalidateIntrinsicContentSize(); setNeedsDisplay()
    }
    private func updateAccessibility() {
        let available = samples.filter { $0.cpuPercent != nil || $0.memoryUsed != nil }.count
        accessibilityValue = available == 0 ? "等待可用的采样数据" : "最近 \(available) 次采样；数值可在整机指标中查看"
    }
    override func draw(_ rect: CGRect) {
        let area = bounds.insetBy(dx: 4, dy: 10)
        UIColor.separator.setStroke()
        let grid = UIBezierPath()
        for fraction in [0.0, 0.5, 1.0] {
            let y = area.maxY - area.height * fraction
            grid.move(to: CGPoint(x: area.minX, y: y)); grid.addLine(to: CGPoint(x: area.maxX, y: y))
        }
        grid.lineWidth = 0.5; grid.stroke()
        drawSeries(samples.map { $0.cpuPercent.map { $0 / 100 } }, color: .systemBlue, in: area)
        drawSeries(samples.map { sample in
            guard let used = sample.memoryUsed, let total = sample.memoryTotal, total > 0 else { return nil }
            return used / total
        }, color: .systemPurple, in: area)
        if !samples.contains(where: { $0.cpuPercent != nil || $0.memoryUsed != nil }) {
            let text = "等待可用的采样数据"
            let font = UIFont.preferredFont(forTextStyle: .footnote)
            let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: UIColor.secondaryLabel]
            let size = (text as NSString).size(withAttributes: attributes)
            (text as NSString).draw(at: CGPoint(x: area.midX - size.width / 2, y: area.midY - size.height / 2), withAttributes: attributes)
        }
    }
    private func drawSeries(_ values: [Double?], color: UIColor, in area: CGRect) {
        let path = UIBezierPath(); var connected = false
        for (index, value) in values.enumerated() {
            guard let value, value.isFinite else { connected = false; continue }
            let point = CGPoint(x: area.minX + area.width * Double(index) / Double(max(1, values.count - 1)),
                                y: area.maxY - area.height * min(1, max(0, value)))
            if connected { path.addLine(to: point) } else { path.move(to: point) }
            connected = true
        }
        color.setStroke(); path.lineWidth = 2; path.stroke()
    }
}
