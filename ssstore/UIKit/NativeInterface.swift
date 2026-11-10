import UIKit
import SwiftUI
import Combine
import Observation
import ApplePackage
import UpdateCore
import Kingfisher
import QuickLook
import UniformTypeIdentifiers
import ZIPFoundation

@MainActor
struct NativeRow {
    var title: String
    var detail: String = ""
    var icon: URL? = nil
    var color: UIColor = .label
    var action: (() -> Void)? = nil
    var delete: (() -> Void)? = nil
    var deleteTitle = "删除"
    var badge: String? = nil
    var metrics: [Int]? = nil
    var iconRevision = 0
    var accessoryAction: UIAction?
    var metricActions: [Int: () -> Void] = [:]
    var compact = false
    var isDescription = false
    var productHeader = false
    var isDownload = false
    var progress: Double? = nil

    func hasSameContent(as other: NativeRow) -> Bool {
        title == other.title && detail == other.detail && icon == other.icon && color == other.color &&
        badge == other.badge && metrics == other.metrics && iconRevision == other.iconRevision && compact == other.compact &&
        accessoryAction?.title == other.accessoryAction?.title && accessoryAction?.attributes == other.accessoryAction?.attributes &&
        isDescription == other.isDescription && productHeader == other.productHeader &&
        isDownload == other.isDownload && progress == other.progress &&
        (action == nil) == (other.action == nil) && (delete == nil) == (other.delete == nil) && deleteTitle == other.deleteTitle
    }
}
@MainActor
final class NativeCell: UITableViewCell {
    let progressFill = NativeProgressFill(frame: .zero)
    var representedIcon: URL?
    var imageTask: DownloadTask?
    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: .subtitle, reuseIdentifier: reuseIdentifier)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layoutSubviews() {
        accessoryView?.sizeToFit()
        super.layoutSubviews()
    }
    override func prepareForReuse() {
        super.prepareForReuse()
        imageTask?.cancel()
        imageTask = nil
        representedIcon = nil
    }
}
@MainActor
final class NativeProgressFill: UIView {
    private let fill = UIView()
    private var fraction = 0.0
    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false; clipsToBounds = true
        fill.backgroundColor = UIColor.systemBlue.withAlphaComponent(0.28)
        addSubview(fill)
    }
    required init?(coder: NSCoder) { fatalError() }
    func update(_ value: Double) {
        fraction = min(1, max(0, value))
        guard window != nil else { layoutFill(); return }
        UIView.animate(withDuration: 0.25, delay: 0, options: [.beginFromCurrentState, .curveLinear, .allowUserInteraction]) { self.layoutFill() }
    }
    func reset() { fill.layer.removeAllAnimations(); fraction = 0; layoutFill() }
    override func layoutSubviews() { super.layoutSubviews(); layoutFill() }
    private func layoutFill() { fill.frame = CGRect(x: 0, y: 0, width: bounds.width * fraction, height: bounds.height) }
}
@MainActor
final class NativeDescriptionCell: UITableViewCell, UITextViewDelegate {
    private let textView = UITextView(usingTextLayoutManager: false)
    private let more = UIButton(type: .system)
    private var source = ""
    private var expanded = false
    private var canExpand = false
    private var cachedWidth: CGFloat = 0
    private var cachedFont: UIFont?
    private var collapsedText = NSAttributedString(string: "")
    private var expandedText = NSAttributedString(string: "")
    private var collapsedExclusion: [UIBezierPath] = []
    private var moreFrame = CGRect.zero
    private var onSizeChange: (() -> Void)?

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        selectionStyle = .none
        textView.isEditable = false; textView.isScrollEnabled = false; textView.backgroundColor = .clear
        textView.textContainerInset = .zero; textView.textContainer.lineFragmentPadding = 0
        textView.adjustsFontForContentSizeCategory = true; textView.delegate = self
        textView.linkTextAttributes = [.foregroundColor: UIColor.systemBlue]
        contentView.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 12, leading: 20, bottom: 12, trailing: 20)
        textView.translatesAutoresizingMaskIntoConstraints = false; contentView.addSubview(textView)
        NSLayoutConstraint.activate([textView.leadingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.leadingAnchor), textView.trailingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.trailingAnchor), textView.topAnchor.constraint(equalTo: contentView.layoutMarginsGuide.topAnchor), textView.bottomAnchor.constraint(equalTo: contentView.layoutMarginsGuide.bottomAnchor)])
        more.setTitle("更多", for: .normal); more.isHidden = true
        more.addAction(UIAction { [weak self] _ in self?.toggleExpanded() }, for: .touchUpInside)
        contentView.addSubview(more)
    }
    required init?(coder: NSCoder) { fatalError() }
    func update(_ text: String, onSizeChange: @escaping () -> Void) {
        self.onSizeChange = onSizeChange
        if source != text { source = text; expanded = false; cachedWidth = 0 }
    }
    override func systemLayoutSizeFitting(_ targetSize: CGSize, withHorizontalFittingPriority horizontalFittingPriority: UILayoutPriority, verticalFittingPriority: UILayoutPriority) -> CGSize {
        prepareText(width: targetSize.width - contentView.layoutMargins.left - contentView.layoutMargins.right)
        return super.systemLayoutSizeFitting(targetSize, withHorizontalFittingPriority: horizontalFittingPriority, verticalFittingPriority: verticalFittingPriority)
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        more.frame = moreFrame.offsetBy(dx: textView.frame.minX, dy: textView.frame.minY)
    }
    private func lineRects() -> [CGRect] {
        let manager = textView.layoutManager
        manager.ensureLayout(for: textView.textContainer)
        var rects: [CGRect] = []
        manager.enumerateLineFragments(forGlyphRange: manager.glyphRange(for: textView.textContainer)) { rect, _, _, _, _ in rects.append(rect) }
        return rects
    }
    private func prepareText(width: CGFloat) {
        let font = UIFont.preferredFont(forTextStyle: .body)
        guard width > 0, cachedWidth != width || cachedFont != font else { return }
        cachedWidth = width; cachedFont = font; more.titleLabel?.font = font
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: UIColor.label]
        let text = source.trimmingCharacters(in: .whitespacesAndNewlines)
        let full = NSAttributedString(string: text, attributes: attributes)
        textView.bounds.size.width = width
        textView.textContainer.size = CGSize(width: width, height: .greatestFiniteMagnitude)
        textView.textContainer.maximumNumberOfLines = 0
        textView.textContainer.lineBreakMode = .byWordWrapping
        textView.textContainer.exclusionPaths = []
        textView.attributedText = full
        canExpand = lineRects().count > 6
        collapsedText = full; expandedText = full; collapsedExclusion = []
        if canExpand {
            let summary = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: " ")
            collapsedText = NSAttributedString(string: summary, attributes: attributes)
            textView.attributedText = collapsedText
            textView.textContainer.maximumNumberOfLines = 6
            textView.textContainer.lineBreakMode = .byTruncatingTail
            let last = lineRects().last!
            let buttonWidth = ceil(("更多" as NSString).size(withAttributes: [.font: font]).width)
            moreFrame = CGRect(x: width - buttonWidth, y: last.minY, width: buttonWidth, height: last.height)
            collapsedExclusion = [UIBezierPath(rect: CGRect(x: moreFrame.minX - 6, y: last.minY, width: buttonWidth + 6, height: last.height))]
            let paragraph = NSMutableParagraphStyle()
            paragraph.tabStops = [NSTextTab(textAlignment: .right, location: width, options: [:])]
            let expanded = NSMutableAttributedString(string: text + "\t收起", attributes: attributes)
            let tail = NSRange(location: expanded.length - 2, length: 2)
            expanded.addAttribute(.paragraphStyle, value: paragraph, range: (expanded.string as NSString).paragraphRange(for: tail))
            expanded.addAttribute(.link, value: URL(string: "ssstore://description")!, range: tail)
            expandedText = expanded
        }
        applyText()
    }
    private func applyText() {
        let compact = canExpand && !expanded
        textView.attributedText = expanded ? expandedText : collapsedText
        textView.textContainer.maximumNumberOfLines = compact ? 6 : 0
        textView.textContainer.lineBreakMode = compact ? .byTruncatingTail : .byWordWrapping
        textView.textContainer.exclusionPaths = compact ? collapsedExclusion : []
        more.isHidden = !compact
        setNeedsLayout()
    }
    private func toggleExpanded() {
        expanded.toggle(); applyText(); onSizeChange?()
    }
    func textView(_ textView: UITextView, primaryActionFor textItem: UITextItem, defaultAction: UIAction) -> UIAction? {
        UIAction { [weak self] _ in self?.toggleExpanded() }
    }
}

@MainActor
private final class NativeMetricState: ObservableObject {
    @Published var values = [0, 0, 0, 0]
    var actions: [Int: () -> Void] = [:]
}

@MainActor
private struct NativeMetrics: View {
    @ObservedObject var state: NativeMetricState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .title) private var numberSize: CGFloat = 30
    private let names = ["应用", "新版本", "待核对", "失败"]

    var body: some View {
        let values = state.values
        let indices = values.indices.filter { ($0 != 1 && $0 != 3) || values[$0] > 0 }
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 32) {
                ForEach(indices, id: \.self) { index in
                    metric(index)
                }
            }
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 16) {
                ForEach(Array(stride(from: 0, to: indices.count, by: 2)), id: \.self) { start in
                    GridRow(alignment: .top) {
                        ForEach(Array(indices[start..<min(start + 2, indices.count)]), id: \.self) { metric($0) }
                    }
                }
            }
            VStack(alignment: .leading, spacing: 16) {
                ForEach(indices, id: \.self) { metric($0) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(reduceMotion ? nil : .snappy(duration: 0.22), value: values)
    }

    private func metric(_ index: Int) -> some View {
        Button { state.actions[index]?() } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(String(state.values[index]))
                    .font(.system(size: numberSize, weight: .bold)).monospacedDigit()
                    .foregroundStyle(index == 3 ? Color.red : Color.primary)
                    .contentTransition(.numericText(value: Double(state.values[index])))
                Text(names[index]).font(.caption)
                    .foregroundStyle(index == 3 ? Color.red : Color.secondary)
            }
            .fixedSize()
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(state.values[index]) 个\(names[index])")
    }
}

@MainActor
final class NativeMetricCell: UITableViewCell {
    private let state = NativeMetricState()
    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        selectionStyle = .none
        contentConfiguration = UIHostingConfiguration { [state] in
            NativeMetrics(state: state)
        }.margins(.horizontal, 20).margins(.vertical, 18)
    }
    required init?(coder: NSCoder) { fatalError() }
    func update(_ values: [Int], actions: [Int: () -> Void]) {
        state.actions = actions
        state.values = values
    }
}
@MainActor
struct NativeSection {
    var title: String = ""
    var rows: [NativeRow]
}

/// Native scrollable content shares the adaptive UIKit sheet container.
@MainActor
protocol NativeSheetContent: AnyObject {
    var sheetScrollView: UIScrollView { get }
    var sheetContentHeight: CGFloat { get }
}

@MainActor
final class NativeFittingNavigation: UINavigationController {
    init(root: UIViewController & NativeSheetContent) {
        super.init(rootViewController: root)
        modalPresentationStyle = .pageSheet
        sheetPresentationController?.detents = [.custom(identifier: .init("content")) { [weak self] context in
            guard let height = self?.preferredContentSize.height, height > 0 else { return context.maximumDetentValue }
            return min(height, context.maximumDetentValue)
        }]
        sheetPresentationController?.prefersGrabberVisible = true
        sheetPresentationController?.prefersEdgeAttachedInCompactHeight = true
    }
    required init?(coder: NSCoder) { fatalError() }
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        topViewController?.view.layoutIfNeeded()
        updateContentSize()
    }
    func updateContentSize() {
        guard let content = topViewController as? (UIViewController & NativeSheetContent), content.isViewLoaded else { return }
        let scroll = content.sheetScrollView
        guard scroll.bounds.width > 0, scroll.bounds.height > 0 else { return }
        let chrome = view.bounds.height - scroll.bounds.height
            + scroll.adjustedContentInset.top + scroll.adjustedContentInset.bottom - view.safeAreaInsets.bottom
        let height = ceil(content.sheetContentHeight + chrome)
        if preferredContentSize.height != height {
            preferredContentSize.height = height
            sheetPresentationController?.invalidateDetents()
            sheetPresentationController?.selectedDetentIdentifier = .init("content")
        }
    }
}

@MainActor
class NativePage: UITableViewController, NativeSheetContent {
    var sheetScrollView: UIScrollView { tableView }
    var sheetContentHeight: CGFloat { tableView.contentSize.height }
    let model: AppModel
    var sections: [NativeSection] = []
    private var changes: AnyCancellable?
    private var scheduled = false
    var working = false
    init(_ model: AppModel, title: String) {
        self.model = model
        super.init(style: .insetGrouped)
        self.title = title
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unsupported") }
    override func viewDidLoad() {
        super.viewDidLoad()
        tableView.register(NativeCell.self, forCellReuseIdentifier: "row")
        tableView.register(NativeMetricCell.self, forCellReuseIdentifier: "metrics")
        tableView.register(NativeDescriptionCell.self, forCellReuseIdentifier: "description")
        tableView.register(NativeProductHeaderCell.self, forCellReuseIdentifier: "product-header")
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = UITableView.automaticDimension
        tableView.keyboardDismissMode = .interactive
        if #available(iOS 26.0, *) { tableView.topEdgeEffect.style = .soft }
    }
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        changes = model.objectWillChange.sink { [weak self] _ in self?.scheduleReload() }
        reload()
    }
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        changes = nil
    }
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        (navigationController as? NativeFittingNavigation)?.updateContentSize()
    }
    func scheduleReload() {
        guard !scheduled, viewIfLoaded?.window != nil else { return }
        scheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.scheduled = false
            if self.viewIfLoaded?.window != nil { self.reload() }
        }
    }
    func rows() -> [NativeSection] { [] }
    func reload() {
        guard isViewLoaded else { return }
        let previous = sections
        withObservationTracking { sections = rows() } onChange: { [weak self] in
            Task { @MainActor in self?.scheduleReload() }
        }
        if previous.count == sections.count && zip(previous, sections).allSatisfy({ $0.title == $1.title && $0.rows.count == $1.rows.count }) {
            let changed = sections.indices.flatMap { section in
                sections[section].rows.indices.compactMap { row -> IndexPath? in
                    previous[section].rows[row].hasSameContent(as: sections[section].rows[row]) ? nil : IndexPath(row: row, section: section)
                }
            }
            if !changed.isEmpty { tableView.reconfigureRows(at: changed) }
        } else {
            tableView.reloadData()
        }
        if let message = model.message, view.window != nil, presentedViewController == nil {
            model.message = nil
            alert(message)
        }
    }
    override func numberOfSections(in tableView: UITableView) -> Int { sections.count }
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { sections[section].rows.count }
    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        sections[section].title.isEmpty ? nil : sections[section].title
    }
    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let row = sections[indexPath.section].rows[indexPath.row]
        if row.productHeader {
            let cell = tableView.dequeueReusableCell(withIdentifier: "product-header", for: indexPath) as! NativeProductHeaderCell
            cell.update(row)
            return cell
        }
        if row.isDescription {
            let cell = tableView.dequeueReusableCell(withIdentifier: "description", for: indexPath) as! NativeDescriptionCell
            cell.update(row.title) { [weak tableView] in tableView?.performBatchUpdates(nil) }
            return cell
        }
        if let metrics = row.metrics {
            let cell = tableView.dequeueReusableCell(withIdentifier: "metrics", for: indexPath) as! NativeMetricCell
            cell.update(metrics, actions: row.metricActions)
            return cell
        }
        let cell = tableView.dequeueReusableCell(withIdentifier: "row", for: indexPath) as! NativeCell
        var background = UIBackgroundConfiguration.listGroupedCell()
        if let progress = row.progress {
            cell.progressFill.update(progress)
            background.customView = cell.progressFill
        } else { cell.progressFill.reset() }
        cell.backgroundConfiguration = background
        var config = cell.defaultContentConfiguration()
        config.text = row.title; config.secondaryText = row.detail.isEmpty ? nil : row.detail
        config.textProperties.color = row.color
        config.textProperties.numberOfLines = 0
        config.secondaryTextProperties.numberOfLines = 0
        config.textProperties.adjustsFontForContentSizeCategory = true
        config.secondaryTextProperties.adjustsFontForContentSizeCategory = true
        let iconSize: CGFloat = row.compact ? 46 : 52
        config.imageProperties.maximumSize = CGSize(width: iconSize, height: iconSize)
        config.imageProperties.cornerRadius = row.compact ? 10 : 11
        if row.compact {
            config.imageProperties.reservedLayoutSize = CGSize(width: iconSize, height: iconSize)
            config.image = UIImage(systemName: "app")
            config.textProperties.font = .preferredFont(forTextStyle: .callout)
            config.secondaryTextProperties.font = .preferredFont(forTextStyle: .footnote)
            config.directionalLayoutMargins.top = 10; config.directionalLayoutMargins.bottom = 10
        }
        let previousImage = cell.representedIcon == row.icon ? (cell.contentConfiguration as? UIListContentConfiguration)?.image : nil
        cell.imageTask?.cancel()
        cell.representedIcon = row.icon
        if let url = row.icon {
            config.image = previousImage ?? UIImage(systemName: "app")
            let source: Kingfisher.Source = url.isFileURL ? .provider(LocalFileImageDataProvider(fileURL: url)) : .network(ImageResource(downloadURL: url))
            cell.imageTask = KingfisherManager.shared.retrieveImage(with: source, options: [.processor(DownsamplingImageProcessor(size: CGSize(width: iconSize, height: iconSize))), .scaleFactor(UIScreen.main.scale), .backgroundDecode]) { [weak cell] result in
                DispatchQueue.main.async {
                    guard let cell, cell.representedIcon == url, case let .success(value) = result,
                          var current = cell.contentConfiguration as? UIListContentConfiguration else { return }
                    current.image = value.image; cell.contentConfiguration = current
                }
            }
        }
        cell.contentConfiguration = config
        if let action = row.accessoryAction {
            let button = UIButton(type: .system, primaryAction: action)
            var configuration = UIButton.Configuration.bordered()
            configuration.title = action.title; configuration.cornerStyle = .capsule
            button.configuration = configuration
            button.isEnabled = !action.attributes.contains(.disabled)
            button.sizeToFit(); cell.accessoryView = button
        } else if let badge = row.badge {
            let label = (cell.accessoryView as? UILabel) ?? UILabel(); label.text = badge; label.textColor = badge == "新版本" ? .systemGreen : .secondaryLabel
            label.font = .preferredFont(forTextStyle: row.isDownload ? .subheadline : .caption1); label.adjustsFontForContentSizeCategory = true
            label.sizeToFit(); cell.accessoryView = label
        } else { cell.accessoryView = nil }
        cell.accessoryType = row.action == nil ? .none : .disclosureIndicator
        cell.selectionStyle = row.action == nil ? .none : .default
        return cell
    }
    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        sections[indexPath.section].rows[indexPath.row].action?()
    }
    override func tableView(_ tableView: UITableView, trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        let row = sections[indexPath.section].rows[indexPath.row]
        guard let action = row.delete else { return nil }
        let swipe = UIContextualAction(style: .destructive, title: row.deleteTitle) { _, _, done in action(); done(true) }
        let configuration = UISwipeActionsConfiguration(actions: [swipe]); configuration.performsFirstActionWithFullSwipe = false
        return configuration
    }
    func push(_ page: UIViewController) { navigationController?.pushViewController(page, animated: true) }
    func sheet(_ page: UIViewController) {
        let nav: UINavigationController
        if let content = page as? (UIViewController & NativeSheetContent) { nav = NativeFittingNavigation(root: content) }
        else { nav = UINavigationController(rootViewController: page) }
        page.navigationItem.rightBarButtonItem = UIBarButtonItem(systemItem: .done, primaryAction: UIAction { [weak page] _ in page?.dismiss(animated: true) })
        present(nav, animated: true)
    }
    func alert(_ message: String) {
        guard presentedViewController == nil else { return }
        let alert = UIAlertController(title: "提示", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "好", style: .default))
        present(alert, animated: true)
    }
    func confirm(_ title: String, action: @escaping () -> Void) {
        let alert = UIAlertController(title: title, message: nil, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        alert.addAction(UIAlertAction(title: "确认", style: .destructive) { _ in action() })
        present(alert, animated: true)
    }
    func edit(_ title: String, value: String = "", secure: Bool = false, save: @escaping (String) -> Void) {
        let alert = UIAlertController(title: title, message: nil, preferredStyle: .alert)
        alert.addTextField { field in field.text = value; field.isSecureTextEntry = secure; field.autocapitalizationType = .none; field.autocorrectionType = .no }
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        alert.addAction(UIAlertAction(title: "确认", style: .default) { _ in save(alert.textFields?.first?.text ?? "") })
        present(alert, animated: true)
    }
    func run(_ action: @escaping () async throws -> Void) {
        guard !working else { return }
        working = true; reload()
        Task { [weak self] in
            do { try await action() } catch { self?.alert(error.localizedDescription) }
            self?.working = false; self?.reload()
        }
    }
    func share(_ url: URL) {
        let activity = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        activity.popoverPresentationController?.sourceView = view
        activity.popoverPresentationController?.sourceRect = CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 1, height: 1)
        present(activity, animated: true)
    }
    func preview(_ url: URL) {
        let nav: UINavigationController
        if UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true,
           let image = UIImage(contentsOfFile: url.path) {
            nav = NativeFittingNavigation(root: NativeImagePreview(image: image, file: url))
        } else {
            nav = UINavigationController(rootViewController: NativePreview(url))
        }
        nav.topViewController?.navigationItem.rightBarButtonItem = UIBarButtonItem(systemItem: .done, primaryAction: UIAction { [weak nav] _ in nav?.dismiss(animated: true) })
        nav.modalPresentationStyle = .pageSheet
        nav.sheetPresentationController?.prefersGrabberVisible = true
        nav.sheetPresentationController?.prefersScrollingExpandsWhenScrolledToEdge = false
        present(nav, animated: true)
    }
    func link(_ title: String, _ action: @escaping () -> Void) -> NativeRow { NativeRow(title: title, color: .systemBlue, action: action) }
}

@MainActor
final class NativeImagePreview: UIViewController, NativeSheetContent, UIScrollViewDelegate, UIGestureRecognizerDelegate {
    private let scroll = UIScrollView()
    private let imageView: UIImageView
    private let imageSize: CGSize
    private let file: URL
    private var viewportSize = CGSize.zero
    var sheetScrollView: UIScrollView { scroll }
    var sheetContentHeight: CGFloat {
        ceil(imageSize.height * min(1, scroll.bounds.width / imageSize.width))
    }
    init(image: UIImage, file: URL) {
        imageView = UIImageView(image: image)
        imageSize = image.size
        self.file = file
        super.init(nibName: nil, bundle: nil)
        title = file.deletingPathExtension().lastPathComponent
    }
    required init?(coder: NSCoder) { fatalError() }
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.contentInsetAdjustmentBehavior = .never
        scroll.delegate = self; scroll.maximumZoomScale = 4
        view.addSubview(scroll); scroll.addSubview(imageView)
        let margins = view.layoutMarginsGuide
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: margins.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: margins.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: margins.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: margins.bottomAnchor)
        ])
        navigationItem.leftBarButtonItem = UIBarButtonItem(systemItem: .action, primaryAction: UIAction { [weak self] _ in
            guard let self else { return }
            let activity = UIActivityViewController(activityItems: [file], applicationActivities: nil)
            activity.popoverPresentationController?.barButtonItem = navigationItem.leftBarButtonItem
            present(activity, animated: true)
        })
        let pan = UIPanGestureRecognizer(target: self, action: #selector(pulledDown(_:)))
        pan.maximumNumberOfTouches = 1
        pan.delegate = self; pan.cancelsTouchesInView = false
        view.addGestureRecognizer(pan)
    }
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let viewport = scroll.bounds.size
        if viewport.width > 0, viewport.height > 0, viewportSize != viewport {
            viewportSize = viewport
            scroll.zoomScale = 1
            let scale = min(1, viewport.width / imageSize.width, viewport.height / imageSize.height)
            imageView.frame = CGRect(origin: .zero, size: CGSize(width: imageSize.width * scale, height: imageSize.height * scale))
            scroll.contentSize = imageView.bounds.size
            centerImage()
        }
        (navigationController as? NativeFittingNavigation)?.updateContentSize()
    }
    func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }
    func scrollViewDidZoom(_ scrollView: UIScrollView) { centerImage() }
    private func centerImage() {
        imageView.center = CGPoint(x: max(scroll.bounds.width, scroll.contentSize.width) / 2,
                                   y: max(scroll.bounds.height, scroll.contentSize.height) / 2)
    }
    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let pan = gestureRecognizer as? UIPanGestureRecognizer else { return true }
        let velocity = pan.velocity(in: view)
        return scroll.zoomScale == scroll.minimumZoomScale && velocity.y > abs(velocity.x)
    }
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool { true }
    @objc private func pulledDown(_ pan: UIPanGestureRecognizer) {
        if pan.state == .ended, pan.translation(in: view).y > 90, !isBeingDismissed { dismiss(animated: true) }
    }
}

@MainActor
final class NativePreview: QLPreviewController, QLPreviewControllerDataSource {
    let file: URL
    init(_ file: URL) { self.file = file; super.init(nibName: nil, bundle: nil); dataSource = self }
    required init?(coder: NSCoder) { fatalError() }
    func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }
    func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem { file as NSURL }
}

@MainActor
class NativeSearchPage: NativePage, UISearchResultsUpdating, UISearchBarDelegate, UISearchControllerDelegate {
    let search = UISearchController(searchResultsController: nil)
    var query = ""
    var focusOnAppearance = false
    override func viewDidLoad() {
        super.viewDidLoad()
        definesPresentationContext = true
        search.obscuresBackgroundDuringPresentation = false
        search.hidesNavigationBarDuringPresentation = true
        search.searchResultsUpdater = self; search.searchBar.delegate = self; search.delegate = self
        search.searchBar.placeholder = "关键词"
        navigationItem.searchController = search
        navigationItem.preferredSearchBarPlacement = .stacked
        navigationItem.hidesSearchBarWhenScrolling = true
        if #available(iOS 26.0, *) { navigationItem.searchBarPlacementAllowsToolbarIntegration = false }
    }
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if focusOnAppearance { focusOnAppearance = false; focusSearch() }
    }
    func focusSearch() {
        guard isViewLoaded, view.window != nil else { focusOnAppearance = true; return }
        if search.isActive { focusField() } else { search.searchBar.becomeFirstResponder() }
    }
    func didPresentSearchController(_ searchController: UISearchController) { focusField() }
    func focusField() {
        search.searchBar.becomeFirstResponder()
        let field = search.searchBar.searchTextField
        if (field.text ?? "").isEmpty {
            let start = field.beginningOfDocument
            field.selectedTextRange = field.textRange(from: start, to: start)
        } else { field.selectAll(nil) }
    }
    func updateSearchResults(for searchController: UISearchController) {
        let text = searchController.searchBar.text ?? ""
        guard text != query else { return }
        query = text
        queryChanged()
    }
    func queryChanged() { reload() }
    func searchBarSearchButtonClicked(_ searchBar: UISearchBar) { searchBar.resignFirstResponder() }
    func searchBarCancelButtonClicked(_ searchBar: UISearchBar) {
        query = ""; searchBar.text = ""; queryChanged()
    }
}

@MainActor
final class NativeTabs: UITabBarController, UITabBarControllerDelegate {
    let model: AppModel
    let apps: NativeApps
    let store: NativeStoreSearch
    init(model: AppModel) {
        self.model = model; apps = NativeApps(model); store = NativeStoreSearch(model)
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func viewDidLoad() {
        super.viewDidLoad(); delegate = self
        let pages: [(UIViewController, String, String)] = [(apps, "应用", "square.stack.3d.up"), (NativeData(model), "数据", "chart.bar.xaxis"), (NativeAccounts(model), "账户", "person.crop.circle"), (store, "搜索", "magnifyingglass")]
        viewControllers = pages.map { page, title, icon in
            let nav = UINavigationController(rootViewController: page)
            nav.navigationBar.prefersLargeTitles = true
            nav.tabBarItem = UITabBarItem(title: title, image: UIImage(systemName: icon), selectedImage: nil)
            return nav
        }
        if #available(iOS 26.0, *) { tabBarMinimizeBehavior = .never }
    }
    func tabBarController(_ tabBarController: UITabBarController, shouldSelect viewController: UIViewController) -> Bool {
        if viewController === viewControllers?.first, presentedViewController == nil,
           let nav = viewController as? UINavigationController {
            apps.showApplications()
            nav.popToRootViewController(animated: selectedViewController === viewController)
            if selectedViewController === viewController { return false }
        }
        if selectedViewController === viewController, viewController === viewControllers?.last,
           presentedViewController == nil, let nav = viewController as? UINavigationController {
            if nav.topViewController !== store {
                store.focusOnAppearance = true
                nav.popToRootViewController(animated: true)
            } else { store.focusSearch() }
            return false
        }
        return true
    }
}

