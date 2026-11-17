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
    ]
    override init(frame: CGRect) {
        super.init(frame: frame)
        stack.axis = .vertical; stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false; addSubview(stack)
        for index in stride(from: 0, to: cards.count, by: 2) {
            let row = UIStackView(arrangedSubviews: [cards[index], cards[index + 1]])
            row.spacing = 12; row.distribution = .fillEqually
            rows.append(row); stack.addArrangedSubview(row)
        }
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor), stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor)])
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layoutSubviews() {
        let axis: NSLayoutConstraint.Axis = bounds.width < 300 || traitCollection.preferredContentSizeCategory.isAccessibilityCategory ? .vertical : .horizontal
        for row in rows where row.axis != axis { row.axis = axis }
        super.layoutSubviews()
    }
    func update(current: PerformanceReading?, history: [PerformanceReading], scope: PerformanceScope) {
        let fields: [(PerformanceReading) -> Double?] = [
            { $0.cpuPercent }, { $0.memoryBytes }, { $0.networkReceived }, { $0.networkSent }, { $0.diskRead }, { $0.diskWritten },
        ]
        for index in cards.indices {
            let values = history.map { PerformancePlotPoint(time: $0.uptime, value: fields[index]($0)) }
            let value = current.flatMap(fields[index])
            let maximum = max(values.compactMap(\.value).max() ?? 0, value ?? 0)
            let scale: Double
            if index == 0 { scale = scope.isDevice ? 100 : max(100, ceil(maximum / 100) * 100) }
            else if index == 1 { scale = current?.memoryTotal ?? max(1024 * 1024, maximum * 1.1) }
            else { scale = max(1024, maximum * 1.1) }
            let label: String
            if index == 0 { label = scope.isDevice ? "整机使用率" : "关联进程合计 · 单核心 100%" }
            else if index == 1 {
                label = scope.isDevice ? (current?.memoryEstimated == true ? "非空闲内存（估算）" : "已用内存") : "关联进程物理内存"
            } else { label = scope.isDevice ? "整机实时速率" : "应用进程速率" }
            cards[index].update(value: value, points: values, scale: scale, percent: index == 0, perSecond: index >= 2, caption: label)
        }
    }
}

struct PerformancePlotPoint { let time: Double; let value: Double? }

@MainActor
private final class PerformanceMetricCard: UIView {
    private let value = UILabel(), unit = UILabel(), caption = UILabel(), range = UILabel()
    private let graph = PerformanceSparkline()
    private let progress = UIProgressView(progressViewStyle: .default)
    private let titleText: String
    init(title: String, symbol: String, color: UIColor) {
        titleText = title
        super.init(frame: .zero)
        backgroundColor = .secondarySystemGroupedBackground
        layer.cornerRadius = 16; layer.cornerCurve = .continuous
        directionalLayoutMargins = NSDirectionalEdgeInsets(top: 16, leading: 14, bottom: 14, trailing: 14)
        let titleLabel = UILabel(); titleLabel.text = title; titleLabel.font = .preferredFont(forTextStyle: .subheadline)
        titleLabel.adjustsFontForContentSizeCategory = true
        let icon = UIImageView(image: UIImage(systemName: symbol)); icon.tintColor = color
        icon.setContentHuggingPriority(.required, for: .horizontal)
        let header = UIStackView(arrangedSubviews: [icon, titleLabel]); header.spacing = 7; header.alignment = .center
        value.font = UIFontMetrics(forTextStyle: .largeTitle).scaledFont(for: .monospacedDigitSystemFont(ofSize: 32, weight: .semibold))
        value.adjustsFontForContentSizeCategory = true; value.adjustsFontSizeToFitWidth = true; value.minimumScaleFactor = 0.5
        value.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        unit.font = .preferredFont(forTextStyle: .caption1); unit.textColor = .secondaryLabel
        unit.adjustsFontForContentSizeCategory = true; unit.setContentHuggingPriority(.required, for: .horizontal)
        let amount = UIStackView(arrangedSubviews: [value, unit]); amount.spacing = 4; amount.alignment = .firstBaseline
        for label in [caption, range] {
            label.font = .preferredFont(forTextStyle: .caption2); label.adjustsFontForContentSizeCategory = true
            label.textColor = .secondaryLabel; label.numberOfLines = 0
        }
        progress.progressTintColor = color; progress.trackTintColor = color.withAlphaComponent(0.1)
        graph.color = color
        let content = UIStackView(arrangedSubviews: [header, amount, caption, progress, graph, range])
        content.axis = .vertical; content.spacing = 8; content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        let guide = layoutMarginsGuide
        NSLayoutConstraint.activate([content.leadingAnchor.constraint(equalTo: guide.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: guide.trailingAnchor), content.topAnchor.constraint(equalTo: guide.topAnchor),
            content.bottomAnchor.constraint(equalTo: guide.bottomAnchor)])
        isAccessibilityElement = true
    }
    required init?(coder: NSCoder) { fatalError() }
    func update(value number: Double?, points: [PerformancePlotPoint], scale: Double, percent: Bool, perSecond: Bool, caption text: String) {
        caption.text = text
        if let number, number.isFinite, number >= 0 {
            let formatted = percent ? (String(format: "%.1f", number), "%") : Self.bytes(number, perSecond: perSecond)
            value.text = formatted.0; unit.text = formatted.1
            accessibilityValue = formatted.0 + " " + formatted.1
        } else {
            value.text = "—"; unit.text = nil; accessibilityValue = "暂不可用"
        }
        accessibilityLabel = titleText + "，" + text
        progress.isHidden = !percent && !titleText.contains("内存")
        progress.setProgress(Float(min(1, max(0, (number ?? 0) / max(scale, 1)))), animated: false)
        graph.points = points; graph.scale = max(scale, 1)
        let upper = percent ? String(format: "%.0f%%", scale) : Self.bytes(scale, perSecond: perSecond).0 + " " + Self.bytes(scale, perSecond: perSecond).1
        range.text = "0 — \(upper)"
    }
    private static func bytes(_ number: Double, perSecond: Bool) -> (String, String) {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var value = number, index = 0
        while value >= 1024 && index < units.count - 1 { value /= 1024; index += 1 }
        return (String(format: value >= 100 ? "%.0f" : "%.1f", value), units[index] + (perSecond ? "/s" : ""))
    }
}

@MainActor
private final class PerformanceSparkline: UIView {
    var points: [PerformancePlotPoint] = [] { didSet { setNeedsDisplay() } }
    var scale: Double = 100 { didSet { setNeedsDisplay() } }
    var color: UIColor = .systemBlue
    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: UIFont.preferredFont(forTextStyle: .body).lineHeight * 3)
    }
    override init(frame: CGRect) { super.init(frame: frame); isOpaque = false; backgroundColor = .clear }
    required init?(coder: NSCoder) { fatalError() }
    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection); invalidateIntrinsicContentSize(); setNeedsDisplay()
    }
    override func draw(_ rect: CGRect) {
        let area = bounds.insetBy(dx: 2, dy: 4)
        guard area.width > 0, area.height > 0 else { return }
        let grid = UIBezierPath()
        for ratio in [0.0, 0.5, 1.0] {
            let y = area.maxY - area.height * ratio
            grid.move(to: CGPoint(x: area.minX, y: y)); grid.addLine(to: CGPoint(x: area.maxX, y: y))
        }
        UIColor.separator.setStroke(); grid.lineWidth = 0.5; grid.stroke()
        let start = points.first?.time ?? 0, end = points.last?.time ?? 0
        let path = UIBezierPath(); var connected = false
        for point in points {
            guard let value = point.value, value.isFinite else { connected = false; continue }
            let x = end > start ? area.minX + area.width * (point.time - start) / (end - start) : area.midX
            let position = CGPoint(x: x, y: area.maxY - area.height * min(1, max(0, value / scale)))
            if connected { path.addLine(to: position) } else { path.move(to: position) }
            connected = true
            color.setFill(); UIBezierPath(ovalIn: CGRect(x: position.x - 1.5, y: position.y - 1.5, width: 3, height: 3)).fill()
        }
        color.setStroke(); path.lineWidth = 2; path.lineJoinStyle = .round; path.stroke()
        if !points.contains(where: { $0.value != nil }) {
            let text = "等待数据"
            let attributes: [NSAttributedString.Key: Any] = [.font: UIFont.preferredFont(forTextStyle: .caption2), .foregroundColor: UIColor.tertiaryLabel]
            let size = (text as NSString).size(withAttributes: attributes)
            (text as NSString).draw(at: CGPoint(x: area.midX - size.width / 2, y: area.midY - size.height / 2), withAttributes: attributes)
        }
    }
}
