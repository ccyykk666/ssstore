import UIKit
import UpdateCore

@MainActor
final class PerformanceDashboard: UIView {
    private let stack = UIStackView()
    private var rows: [UIStackView] = []
    private let cards = [
        PerformanceMetricCard(title: "CPU", symbol: "cpu", color: .systemBlue),
        PerformanceMetricCard(title: "内存", symbol: "memorychip", color: .systemPurple),
        PerformanceMetricCard(title: "下载", symbol: "arrow.down", color: .systemTeal),
        PerformanceMetricCard(title: "上传", symbol: "arrow.up", color: .systemGreen),
        PerformanceMetricCard(title: "磁盘读取", symbol: "internaldrive", color: .systemOrange),
        PerformanceMetricCard(title: "磁盘写入", symbol: "square.and.pencil", color: .systemPink),
        PerformanceMetricCard(title: "GPU", symbol: "cube.transparent", color: .systemIndigo),
        PerformanceMetricCard(title: "电池温度", symbol: "thermometer.medium", color: .systemRed),
    ]
    override init(frame: CGRect) {
        super.init(frame: frame)
        stack.axis = .vertical; stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false; addSubview(stack)
        for index in stride(from: 0, to: cards.count, by: 2) {
            let row = UIStackView(arrangedSubviews: [cards[index], cards[index + 1]])
            row.spacing = 12; row.distribution = .fillEqually; rows.append(row); stack.addArrangedSubview(row)
        }
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor), stack.bottomAnchor.constraint(equalTo: bottomAnchor)])
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layoutSubviews() {
        let axis: NSLayoutConstraint.Axis = bounds.width < 300 || traitCollection.preferredContentSizeCategory.isAccessibilityCategory ? .vertical : .horizontal
        for row in rows where row.axis != axis { row.axis = axis }
        super.layoutSubviews()
    }
    func update(current: PerformanceReading?, scope: PerformanceScope, metrics: LocalPerformanceMetrics?) {
        let values = [current?.cpuPercent, current?.memoryBytes, current?.networkReceived, current?.networkSent, current?.diskRead, current?.diskWritten]
        for index in values.indices {
            let caption: String
            if index == 0 { caption = scope.isDevice ? "整机使用率" : "进程使用率 · 单核心 100%" }
            else if index == 1 { caption = scope.isDevice ? "非空闲内存（估算）" : "进程物理内存" }
            else { caption = scope.isDevice ? "整机当前速率" : index < 4 ? "应用网络速率暂不可用" : "进程当前速率" }
            cards[index].update(value: values[index], total: index == 1 ? current?.memoryTotal : nil,
                percent: index == 0, perSecond: index >= 2, caption: caption)
        }
        rows.last?.isHidden = !scope.isDevice
        cards[6].update(value: metrics?.gpuPercent, total: nil, percent: true, perSecond: false, caption: "整机驱动当前值")
        cards[7].updateTemperature(metrics?.batteryTemperature)
    }
}

@MainActor
private final class PerformanceMetricCard: UIView {
    private let value = UILabel(), unit = UILabel(), caption = UILabel()
    private let progress = UIProgressView(progressViewStyle: .default)
    private let titleText: String
    init(title: String, symbol: String, color: UIColor) {
        titleText = title; super.init(frame: .zero)
        backgroundColor = .secondarySystemGroupedBackground; layer.cornerRadius = 16; layer.cornerCurve = .continuous
        directionalLayoutMargins = NSDirectionalEdgeInsets(top: 18, leading: 16, bottom: 18, trailing: 16)
        let label = UILabel(); label.text = title; label.font = .preferredFont(forTextStyle: .subheadline); label.adjustsFontForContentSizeCategory = true
        let icon = UIImageView(image: UIImage(systemName: symbol)); icon.tintColor = color; icon.setContentHuggingPriority(.required, for: .horizontal)
        let header = UIStackView(arrangedSubviews: [icon, label]); header.spacing = 7
        value.font = UIFontMetrics(forTextStyle: .largeTitle).scaledFont(for: .monospacedDigitSystemFont(ofSize: 32, weight: .semibold))
        value.adjustsFontForContentSizeCategory = true; value.adjustsFontSizeToFitWidth = true; value.minimumScaleFactor = 0.5
        value.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        unit.font = .preferredFont(forTextStyle: .caption1); unit.textColor = .secondaryLabel; unit.adjustsFontForContentSizeCategory = true
        let amount = UIStackView(arrangedSubviews: [value, unit]); amount.spacing = 4; amount.alignment = .firstBaseline
        caption.font = .preferredFont(forTextStyle: .caption2); caption.textColor = .secondaryLabel
        caption.numberOfLines = 0; caption.adjustsFontForContentSizeCategory = true
        progress.progressTintColor = color; progress.trackTintColor = color.withAlphaComponent(0.1)
        let content = UIStackView(arrangedSubviews: [header, amount, caption, progress]); content.axis = .vertical; content.spacing = 12
        content.translatesAutoresizingMaskIntoConstraints = false; addSubview(content)
        let guide = layoutMarginsGuide
        NSLayoutConstraint.activate([content.leadingAnchor.constraint(equalTo: guide.leadingAnchor), content.trailingAnchor.constraint(equalTo: guide.trailingAnchor),
            content.topAnchor.constraint(equalTo: guide.topAnchor), content.bottomAnchor.constraint(equalTo: guide.bottomAnchor)])
        isAccessibilityElement = true
    }
    required init?(coder: NSCoder) { fatalError() }
    func updateTemperature(_ number: Double?) {
        caption.text = "电池传感器 · 非 CPU 温度"; progress.isHidden = true
        accessibilityLabel = titleText
        if let number, number.isFinite {
            value.text = String(format: "%.1f", number); unit.text = "°C"
            accessibilityValue = (value.text ?? "") + " °C"
        } else { value.text = "—"; unit.text = nil; accessibilityValue = "暂不可用" }
    }
    func update(value number: Double?, total: Double?, percent: Bool, perSecond: Bool, caption text: String) {
        caption.text = text; accessibilityLabel = titleText + "，" + text
        if let number, number.isFinite, number >= 0 {
            let formatted = percent ? (String(format: "%.1f", number), "%") : Self.bytes(number, perSecond: perSecond)
            value.text = formatted.0; unit.text = formatted.1; accessibilityValue = formatted.0 + " " + formatted.1
        } else { value.text = "—"; unit.text = nil; accessibilityValue = "暂不可用" }
        progress.isHidden = number == nil || (!percent && total == nil)
        let scale = percent ? max(100, number ?? 0) : max(1, total ?? 1)
        progress.setProgress(Float(min(1, max(0, (number ?? 0) / scale))), animated: false)
    }
    private static func bytes(_ number: Double, perSecond: Bool) -> (String, String) {
        let units = ["B", "KB", "MB", "GB", "TB"]; var value = number, index = 0
        while value >= 1024 && index < units.count - 1 { value /= 1024; index += 1 }
        return (String(format: value >= 100 ? "%.0f" : "%.1f", value), units[index] + (perSecond ? "/s" : ""))
    }
}
