import UIKit
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
}
@MainActor
final class NativeCell: UITableViewCell {
    var representedIcon: URL?
}
@MainActor
final class NativeMetricCell: UITableViewCell {
    let numbers = (0..<3).map { _ in UILabel() }
    let stack = UIStackView()
    var previous: [Int] = []
    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        stack.axis = .horizontal; stack.distribution = .fillEqually; stack.translatesAutoresizingMaskIntoConstraints = false
        for (index, name) in ["应用", "有更新", "待核对"].enumerated() {
            let column = UIStackView(); column.axis = .vertical; column.spacing = 4
            numbers[index].font = .monospacedDigitSystemFont(ofSize: 30, weight: .bold)
            let label = UILabel(); label.text = name; label.font = .preferredFont(forTextStyle: .caption1); label.textColor = .secondaryLabel
            column.addArrangedSubview(numbers[index]); column.addArrangedSubview(label); stack.addArrangedSubview(column)
        }
        contentView.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20), stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20), stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 18), stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -18)])
        selectionStyle = .none
    }
    required init?(coder: NSCoder) { fatalError() }
    func update(_ values: [Int]) {
        for index in values.indices {
            if previous.indices.contains(index), previous[index] != values[index], !UIAccessibility.isReduceMotionEnabled {
                let animation = CATransition(); animation.type = .push; animation.subtype = .fromTop; animation.duration = 0.12
                animation.timingFunction = CAMediaTimingFunction(name: .linear)
                numbers[index].layer.add(animation, forKey: "number")
            }
            numbers[index].text = String(max(0, values[index]))
        }
        previous = values
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
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 70
        tableView.keyboardDismissMode = .interactive
        if #available(iOS 26.0, *) { tableView.topEdgeEffect.style = .soft }
        changes = model.objectWillChange.sink { [weak self] _ in self?.scheduleReload() }
        reload()
    }
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        reload()
    }
    func scheduleReload() {
        guard !scheduled else { return }
        scheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.scheduled = false
            self.reload()
        }
    }
    func rows() -> [NativeSection] { [] }
    func reload() {
        guard isViewLoaded else { return }
        withObservationTracking { sections = rows() } onChange: { [weak self] in
            Task { @MainActor in self?.scheduleReload() }
        }
        tableView.reloadData()
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
        if let metrics = row.metrics {
            let cell = (tableView.dequeueReusableCell(withIdentifier: "metrics") as? NativeMetricCell) ?? NativeMetricCell(style: .default, reuseIdentifier: "metrics")
            cell.update(metrics)
            return cell
        }
        let cell = (tableView.dequeueReusableCell(withIdentifier: "row") as? NativeCell) ?? NativeCell(style: .subtitle, reuseIdentifier: "row")
        var config = cell.defaultContentConfiguration()
        config.text = row.title; config.secondaryText = row.detail
        config.textProperties.color = row.color
        config.textProperties.numberOfLines = 0
        config.secondaryTextProperties.numberOfLines = 0
        config.imageProperties.maximumSize = CGSize(width: 52, height: 52)
        config.imageProperties.cornerRadius = 11
        cell.representedIcon = row.icon
        if let url = row.icon {
            if url.isFileURL { config.image = UIImage(contentsOfFile: url.path) }
            else {
                config.image = UIImage(systemName: "app")
                KingfisherManager.shared.retrieveImage(with: url) { [weak cell] result in
                    DispatchQueue.main.async {
                        guard let cell, cell.representedIcon == url, case let .success(value) = result,
                              var current = cell.contentConfiguration as? UIListContentConfiguration else { return }
                        current.image = value.image; cell.contentConfiguration = current
                    }
                }
            }
        }
        cell.contentConfiguration = config
        if let badge = row.badge {
            let label = UILabel(); label.text = badge; label.textColor = badge == "有更新" ? .systemGreen : .secondaryLabel
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
    func preview(_ url: URL) { push(NativePreview(url)) }
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
        navigationItem.hidesSearchBarWhenScrolling = false
    }
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if focusOnAppearance { focusOnAppearance = false; focusSearch() }
    }
    func focusSearch() {
        guard isViewLoaded, view.window != nil else { focusOnAppearance = true; return }
        navigationController?.view.layoutIfNeeded()
        if search.isActive { focusField() } else { search.isActive = true }
    }
    func didPresentSearchController(_ searchController: UISearchController) { focusField() }
    func focusField() {
        let field = search.searchBar.searchTextField
        field.becomeFirstResponder()
        if (field.text ?? "").isEmpty {
            let start = field.beginningOfDocument
            field.selectedTextRange = field.textRange(from: start, to: start)
        } else { field.selectAll(nil) }
    }
    func updateSearchResults(for searchController: UISearchController) {
        query = searchController.searchBar.text ?? ""
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
    let store: NativeStoreSearch
    init(model: AppModel) {
        self.model = model; store = NativeStoreSearch(model)
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func viewDidLoad() {
        super.viewDidLoad(); delegate = self
        let pages: [(UIViewController, String, String)] = [(NativeApps(model), "应用", "square.stack.3d.up"), (NativeData(model), "数据", "chart.bar.xaxis"), (NativeAccounts(model), "账户", "person.crop.circle"), (store, "搜索", "magnifyingglass")]
        viewControllers = pages.map { page, title, icon in
            let nav = UINavigationController(rootViewController: page)
            nav.navigationBar.prefersLargeTitles = true
            nav.tabBarItem = UITabBarItem(title: title, image: UIImage(systemName: icon), selectedImage: nil)
            return nav
        }
        if #available(iOS 26.0, *) { tabBarMinimizeBehavior = .never }
    }
    func tabBarController(_ tabBarController: UITabBarController, shouldSelect viewController: UIViewController) -> Bool {
        if selectedViewController === viewController, viewController === viewControllers?.last,
           presentedViewController == nil, let nav = viewController as? UINavigationController {
            if nav.topViewController !== store {
                store.focusOnAppearance = true
                nav.popToRootViewController(animated: true)
            } else { store.focusSearch() }
        }
        return true
    }
}

