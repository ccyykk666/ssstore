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
    var singleLine = false
    var isDescription = false
    var productHeader = false

    func hasSameContent(as other: NativeRow) -> Bool {
        title == other.title && detail == other.detail && icon == other.icon && color == other.color &&
        badge == other.badge && metrics == other.metrics && iconRevision == other.iconRevision && compact == other.compact &&
        accessoryAction?.title == other.accessoryAction?.title && accessoryAction?.attributes == other.accessoryAction?.attributes &&
        singleLine == other.singleLine && isDescription == other.isDescription && productHeader == other.productHeader &&
        (action == nil) == (other.action == nil) && (delete == nil) == (other.delete == nil) && deleteTitle == other.deleteTitle
    }
}
@MainActor
final class NativeCell: UITableViewCell {
    var representedIcon: URL?
    var imageTask: DownloadTask?
    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: .subtitle, reuseIdentifier: reuseIdentifier)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func prepareForReuse() {
        super.prepareForReuse()
        imageTask?.cancel()
        imageTask = nil
        representedIcon = nil
    }
}
@MainActor
final class NativeDescriptionCell: UITableViewCell, UITextViewDelegate {
    private let textView = UITextView()
    private var source = ""
    private var expanded = false
    private var cachedWidth: CGFloat = 0
    private var cachedFont: UIFont?
    private var collapsedText = NSAttributedString(string: "")
    private var expandedText = NSAttributedString(string: "")
    private var onSizeChange: (() -> Void)?

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        selectionStyle = .none
        textView.isEditable = false; textView.isScrollEnabled = false; textView.backgroundColor = .clear
        textView.textContainerInset = .zero; textView.textContainer.lineFragmentPadding = 0
        textView.adjustsFontForContentSizeCategory = true; textView.delegate = self
        textView.linkTextAttributes = [.foregroundColor: UIColor.systemBlue]
        textView.translatesAutoresizingMaskIntoConstraints = false; contentView.addSubview(textView)
        NSLayoutConstraint.activate([textView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20), textView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20), textView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 12), textView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -12)])
    }
    required init?(coder: NSCoder) { fatalError() }
    func update(_ text: String, onSizeChange: @escaping () -> Void) {
        self.onSizeChange = onSizeChange
        if source != text { source = text; expanded = false; cachedWidth = 0 }
    }
    override func systemLayoutSizeFitting(_ targetSize: CGSize, withHorizontalFittingPriority horizontalFittingPriority: UILayoutPriority, verticalFittingPriority: UILayoutPriority) -> CGSize {
        prepareText(width: targetSize.width - 40)
        return super.systemLayoutSizeFitting(targetSize, withHorizontalFittingPriority: horizontalFittingPriority, verticalFittingPriority: verticalFittingPriority)
    }
    private func prepareText(width: CGFloat) {
        let font = UIFont.preferredFont(forTextStyle: .body)
        guard width > 0, cachedWidth != width || cachedFont != font else { return }
        cachedWidth = width; cachedFont = font
        let paragraph = NSMutableParagraphStyle()
        paragraph.tabStops = [NSTextTab(textAlignment: .right, location: width, options: [:])]
        paragraph.defaultTabInterval = width
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: UIColor.label, .paragraphStyle: paragraph]
        let text = source.trimmingCharacters(in: .whitespacesAndNewlines)
        func linked(_ body: String, _ title: String) -> NSAttributedString {
            let result = NSMutableAttributedString(string: body + "\t" + title, attributes: attributes)
            result.addAttribute(.link, value: URL(string: "ssstore://description")!, range: NSRange(location: result.length - (title as NSString).length, length: (title as NSString).length))
            return result
        }
        func height(_ text: NSAttributedString) -> CGFloat {
            text.boundingRect(with: CGSize(width: width, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil).height
        }
        let full = NSAttributedString(string: text, attributes: attributes)
        let limit = ceil(font.lineHeight * 6)
        if height(full) <= limit {
            collapsedText = full; expandedText = full
        } else {
            let characters = Array(text)
            var lower = 0; var upper = characters.count
            while lower < upper {
                let middle = (lower + upper + 1) / 2
                let candidate = String(characters.prefix(middle)).trimmingCharacters(in: .whitespacesAndNewlines) + "…"
                if height(linked(candidate, "更多")) <= limit { lower = middle } else { upper = middle - 1 }
            }
            collapsedText = linked(String(characters.prefix(lower)).trimmingCharacters(in: .whitespacesAndNewlines) + "…", "更多")
            expandedText = linked(text, "收起")
        }
        textView.attributedText = expanded ? expandedText : collapsedText
    }
    func textView(_ textView: UITextView, primaryActionFor textItem: UITextItem, defaultAction: UIAction) -> UIAction? {
        UIAction { [weak self] _ in
            guard let self else { return }
            expanded.toggle()
            textView.attributedText = expanded ? expandedText : collapsedText
            onSizeChange?()
        }
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
    private let names = ["应用", "新版本", "待核对", "失败"]

    var body: some View {
        let values = state.values
        HStack(alignment: .top, spacing: 0) {
            ForEach(values.indices, id: \.self) { index in
                if (index != 1 && index != 3) || values[index] > 0 {
                    Button { state.actions[index]?() } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(String(values[index]))
                                .font(.system(size: 30, weight: .bold)).monospacedDigit()
                                .foregroundStyle(index == 3 ? Color.red : Color.primary)
                                .contentTransition(.numericText(value: Double(values[index])))
                            Text(names[index]).font(.caption)
                                .foregroundStyle(index == 3 ? Color.red : Color.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(values[index]) 个\(names[index])")
                }
            }
        }
        .animation(reduceMotion ? nil : .snappy(duration: 0.22), value: values)
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

/// All active screens use UIKit tables and native navigation; no hosting controllers.
@MainActor
class NativePage: UITableViewController {
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
        tableView.estimatedRowHeight = 70
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
        var config = cell.defaultContentConfiguration()
        config.text = row.title; config.secondaryText = row.detail
        config.textProperties.color = row.color
        config.textProperties.numberOfLines = row.singleLine ? 1 : 0
        config.secondaryTextProperties.numberOfLines = row.singleLine ? 1 : 0
        let iconSize: CGFloat = row.compact ? 46 : 52
        config.imageProperties.maximumSize = CGSize(width: iconSize, height: iconSize)
        config.imageProperties.cornerRadius = row.compact ? 10 : 11
        if row.compact {
            config.imageProperties.reservedLayoutSize = CGSize(width: iconSize, height: iconSize)
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
            label.font = .preferredFont(forTextStyle: .caption1); label.sizeToFit(); cell.accessoryView = label
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
        let nav = UINavigationController(rootViewController: page)
        page.navigationItem.rightBarButtonItem = UIBarButtonItem(systemItem: .done, primaryAction: UIAction { [weak page] _ in page?.dismiss(animated: true) })
        nav.sheetPresentationController?.prefersGrabberVisible = false
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
        let page = NativePreview(url)
        page.modalPresentationStyle = .pageSheet
        page.sheetPresentationController?.detents = [.medium(), .large()]
        page.sheetPresentationController?.prefersGrabberVisible = true
        present(page, animated: true)
    }
    func link(_ title: String, _ action: @escaping () -> Void) -> NativeRow { NativeRow(title: title, color: .systemBlue, action: action) }
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
        search.searchBar.sizeToFit()
        navigationItem.searchController = search
        navigationItem.hidesSearchBarWhenScrolling = true
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

