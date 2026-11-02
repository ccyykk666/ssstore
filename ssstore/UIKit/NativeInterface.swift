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
        let cell = tableView.dequeueReusableCell(withIdentifier: "row") ?? UITableViewCell(style: .subtitle, reuseIdentifier: "row")
        var config = cell.defaultContentConfiguration()
        config.text = row.title; config.secondaryText = row.detail
        config.textProperties.color = row.color
        config.textProperties.numberOfLines = 0
        config.secondaryTextProperties.numberOfLines = 0
        config.imageProperties.maximumSize = CGSize(width: 52, height: 52)
        config.imageProperties.cornerRadius = 11
        cell.imageView?.kf.cancelDownloadTask()
        cell.imageView?.image = nil
        cell.contentConfiguration = config
        if let url = row.icon {
            cell.imageView?.kf.setImage(with: url, placeholder: UIImage(systemName: "app"))
        }
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

@MainActor
final class NativeApps: NativeSearchPage {
    var onlyAttention = false
    var onlyFailed = false
    init(_ model: AppModel) { super.init(model, title: "ssstore") }
    required init?(coder: NSCoder) { fatalError() }
    override func viewDidLoad() {
        super.viewDidLoad(); search.searchBar.placeholder = "搜索应用或 Bundle ID"
        navigationItem.leftBarButtonItem = UIBarButtonItem(image: UIImage(systemName: "gearshape"), primaryAction: UIAction { [weak self] _ in guard let self else { return }; sheet(NativeSettings(model)) })
    }
    override func rows() -> [NativeSection] {
        let includeSystem = UserDefaults.standard.bool(forKey: "includeSystemApps")
        let listed = model.records.filter { includeSystem || !$0.installed.isSystem }
        let progress = model.matchProgress.flatMap { $0.scope == model.country ? $0 : nil }
        let revealed = progress.map { Set($0.revealedMatches.map(\.id)) }
        let statistics = progress?.statistics(visibleIDs: Set(listed.map(\.id))) ?? ApplicationMatchStatistics(matches: listed.map { ApplicationMatch(record: $0, scope: model.country) })
        if statistics.failures == 0 { onlyFailed = false }
        navigationItem.rightBarButtonItem = UIBarButtonItem(image: UIImage(systemName: "ellipsis"), menu: UIMenu(children: [
            UIAction(title: "刷新应用", image: UIImage(systemName: "arrow.triangle.2.circlepath"), attributes: model.busy ? .disabled : []) { [weak self] _ in guard let self else { return }; Task { await model.refreshApps() } },
            UIAction(title: "停止刷新", attributes: model.isChecking ? [] : .hidden) { [weak self] _ in self?.model.cancelCheck() },
            UIAction(title: "下载", image: UIImage(systemName: "arrow.down.circle")) { [weak self] _ in guard let self else { return }; push(NativeDownloads(model)) },
            UIAction(title: "有更新与待核对", state: onlyAttention ? .on : .off) { [weak self] _ in self?.onlyAttention.toggle(); self?.reload() },
            UIAction(title: "显示系统应用", state: includeSystem ? .on : .off) { [weak self] _ in UserDefaults.standard.set(!includeSystem, forKey: "includeSystemApps"); self?.reload() }
        ]))
        var summary = [NativeRow(title: "\(statistics.applications) 应用    \(statistics.updates) 有更新    \(statistics.pending) 待核对")]
        if statistics.failures > 0 { summary.append(link("\(statistics.failures) 失败") { [weak self] in self?.onlyFailed.toggle(); self?.reload() }) }
        for warning in [model.scanWarning, model.queryWarning] where !warning.isEmpty { summary.append(NativeRow(title: warning, color: .systemOrange)) }
        let filtered = listed.filter { record in
            let matched = revealed?.contains(record.id) ?? true
            return (!onlyAttention || (matched && record.status(country: model.country) != .current)) && (!onlyFailed || (matched && record.error != nil)) && (query.isEmpty || record.installed.name.localizedCaseInsensitiveContains(query) || record.id.localizedCaseInsensitiveContains(query))
        }
        let rows = filtered.map { record -> NativeRow in
            let matched = revealed?.contains(record.id) ?? true
            let status = record.status(country: model.country)
            let update = matched && (status == .different || status == .update)
            let tag = update ? " · 有更新" : (matched && status == .unknown ? " · 待核对" : "")
            return NativeRow(title: record.installed.name + tag, detail: "本机 \(record.displayedVersion(country: model.country) ?? "未知") · 商店 \(record.release?.version ?? "—")" + (matched && record.error != nil ? "\n查询失败" : ""), icon: model.localIconURL(for: record.installed) ?? record.release?.iconURL, action: { [weak self] in guard let self else { return }; push(NativeAppDetail(model, id: record.id)) }, delete: { [weak self] in self?.model.ignoreApp(record.id) }, deleteTitle: "忽略")
        }
        return [NativeSection(rows: summary), NativeSection(title: "共\(filtered.count)个应用", rows: rows.isEmpty ? [NativeRow(title: "暂无匹配应用")] : rows)]
    }
}

@MainActor
final class NativeAppDetail: NativePage {
    let id: String
    init(_ model: AppModel, id: String) { self.id = id; super.init(model, title: "版本详情"); navigationItem.largeTitleDisplayMode = .never }
    required init?(coder: NSCoder) { fatalError() }
    override func rows() -> [NativeSection] {
        guard let record = model.records.first(where: { $0.id == id }) else { return [] }
        navigationItem.rightBarButtonItem = UIBarButtonItem(title: "查询", primaryAction: UIAction { [weak self] _ in guard let self else { return }; model.checkUpdates(only: id) })
        var fields = [NativeRow(title: record.installed.name, icon: model.localIconURL(for: record.installed)), NativeRow(title: "本机版本", detail: record.displayedVersion(country: model.country) ?? "未知")]
        if let original = record.installed.version, original != record.displayedVersion(country: model.country) { fields.append(NativeRow(title: "原始版本", detail: original)) }
        fields += [NativeRow(title: "构建号", detail: record.installed.build ?? "未提供"), NativeRow(title: "构建 SDK", detail: record.installed.buildSDKDescription ?? "未提供"), NativeRow(title: "Bundle ID", detail: record.id)]
        var store: [NativeRow] = []
        if let release = record.release { store += [NativeRow(title: "最新版本", detail: release.version), NativeRow(title: "更新时间", detail: release.releasedAt ?? "未提供"), NativeRow(title: "最低系统版本", detail: release.minimumOS ?? "未提供")] }
        store.append(link("查看商店页") { [weak self] in guard let self else { return }; let region = record.release?.country ?? (model.country == StoreQueryPolicy.chinaThenUS ? "cn" : model.country); run { let app = try await ApplePackage.Lookup.lookup(bundleID: record.effectiveBundleID, countryCode: region.uppercased()); guard app.bundleID == record.effectiveBundleID else { throw NSError(domain: "Store", code: 1, userInfo: [NSLocalizedDescriptionKey: "应用标识不符"]) }; self.push(NativeProduct(self.model, package: AppStore.AppPackage(software: app, entityType: .iPhone), region: region.uppercased())) } })
        var result = [NativeSection(rows: fields), NativeSection(title: "商店", rows: store), NativeSection(rows: [link("应用数据") { [weak self] in guard let self else { return }; push(NativeData(model, bundle: id)) }]), NativeSection(title: "更新说明", rows: [NativeRow(title: record.release?.notes ?? "暂无更新说明")])]
        if let error = record.error { result.append(NativeSection(rows: [NativeRow(title: error, color: .systemOrange)])) }
        return result
    }
}

@MainActor
final class NativeStoreSearch: NativeSearchPage {
    var region = UserDefaults.standard.string(forKey: "searchRegion") ?? "US"
    var entity = EntityType.iPhone
    var results: [AppStore.AppPackage] = []
    var request: Task<Void, Never>?
    var generation = UUID()
    var error: String?
    var loading = false
    init(_ model: AppModel) { super.init(model, title: "搜索") }
    required init?(coder: NSCoder) { fatalError() }
    override func rows() -> [NativeSection] {
        navigationItem.rightBarButtonItems = [UIBarButtonItem(title: region, menu: UIMenu(children: ApplePackage.Configuration.storeFrontValues.keys.sorted().map { key in UIAction(title: "\(StoreRegionNames.name(key))  \(key)", state: key == region ? .on : .off) { [weak self] _ in self?.region = key; UserDefaults.standard.set(key, forKey: "searchRegion"); self?.reset(); self?.reload() } })), UIBarButtonItem(image: UIImage(systemName: entity.iconName), menu: UIMenu(children: EntityType.allCases.map { type in UIAction(title: type.rawValue, state: type == entity ? .on : .off) { [weak self] _ in self?.entity = type; self?.reset(); self?.reload() } }))]
        var sections: [NativeSection] = []
        if let error { sections.append(NativeSection(rows: [NativeRow(title: error, color: .systemRed)])) }
        if loading || !results.isEmpty { sections.append(NativeSection(title: loading ? "正在搜索…" : "\(results.count) 个结果", rows: results.map { package in NativeRow(title: package.software.name, detail: package.software.sellerName + " · " + package.software.version, icon: URL(string: package.software.artworkUrl), action: { [weak self] in guard let self else { return }; push(NativeProduct(model, package: package, region: region)) }) })) }
        return sections
    }
    override func queryChanged() { if query.isEmpty { reset(); reload() } }
    override func searchBarSearchButtonClicked(_ searchBar: UISearchBar) {
        super.searchBarSearchButtonClicked(searchBar)
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { reset(); reload(); return }
        reset(); let id = generation; let country = region; let type = entity
        loading = true; reload()
        request = Task { [weak self] in
            do {
                var apps = try await ApplePackage.Searcher.search(term: term, countryCode: country, limit: 32, entityType: type)
                try Task.checkCancellation()
                if let app = try? await ApplePackage.Lookup.lookup(bundleID: term, countryCode: country, entityType: type) { apps.insert(app, at: 0) }
                try Task.checkCancellation()
                guard let self, generation == id else { return }
                results = apps.map { AppStore.AppPackage(software: $0, entityType: type) }; loading = false; reload()
            } catch { guard let self, !Task.isCancelled, generation == id else { return }; self.error = error.localizedDescription; loading = false; reload() }
        }
    }
    func reset() { request?.cancel(); request = nil; generation = UUID(); results = []; error = nil; loading = false }
}

@MainActor
final class NativeProduct: NativePage {
    let package: AppStore.AppPackage
    let region: String
    var accountID: String?
    var expanded = false
    init(_ model: AppModel, package: AppStore.AppPackage, region: String) {
        self.package = package; self.region = region
        accountID = AppStore.this.eligibleAccounts(for: region).first?.id
        super.init(model, title: package.software.name)
        navigationItem.largeTitleDisplayMode = .never
    }
    required init?(coder: NSCoder) { fatalError() }
    override func rows() -> [NativeSection] {
        let accounts = AppStore.this.eligibleAccounts(for: region)
        if !accounts.contains(where: { $0.id == accountID }) { accountID = accounts.first?.id }
        navigationItem.rightBarButtonItem = UIBarButtonItem(image: UIImage(systemName: "person.crop.circle"), menu: UIMenu(children: accounts.map { account in UIAction(title: account.account.email, state: accountID == account.id ? .on : .off) { [weak self] _ in self?.accountID = account.id; self?.reload() } }))
        let app = package.software
        let description = expanded ? app.description : String(app.description.prefix(180))
        var header = [NativeRow(title: app.name + " · " + (app.formattedPrice ?? "—"), detail: app.sellerName, icon: URL(string: app.artworkUrl)), NativeRow(title: description)]
        if app.description.count > 180 { header.append(link(expanded ? "收起" : "更多") { [weak self] in self?.expanded.toggle(); self?.reload() }) }
        header.append(link("版本 \(app.version)") { [weak self] in guard let self else { return }; push(NativeHistory(model, archive: AppPackageArchive(accountID: accountID, region: region, package: package))) })
        header.append(link(working ? "正在请求…" : "下载") { [weak self] in self?.download() })
        var details = [NativeRow(title: "Bundle ID", detail: app.bundleID), NativeRow(title: "开发者", detail: app.sellerName), NativeRow(title: "类别", detail: app.primaryGenreName), NativeRow(title: "兼容性", detail: app.minimumOsVersion + "+"), NativeRow(title: "评分", detail: "\(app.averageUserRating) (\(app.userRatingCount))")]
        if let size = app.fileSizeBytes.flatMap(Int64.init) { details.append(NativeRow(title: "大小", detail: ByteCountFormatter.string(fromByteCount: size, countStyle: .file))) }
        var sections = [NativeSection(rows: header), NativeSection(title: "详情", rows: details), NativeSection(title: "新功能", rows: [NativeRow(title: app.releaseNotes ?? "")])]
        if app.price == 0 { sections.append(NativeSection(rows: [link("获取许可证") { [weak self] in self?.license() }])) }
        if accountID == nil { sections.append(NativeSection(rows: [NativeRow(title: "请添加此地区的账户。", color: .systemOrange)])) }
        return sections
    }
    func download() {
        guard let accountID else { alert("请先添加此地区账户。"); return }
        if let existing = Downloads.this.downloadRequest(forArchive: package) { push(NativePackage(model, package: existing)); return }
        run { [self] in
            do { try await Downloads.this.startDownload(for: package, accountID: accountID) }
            catch {
                if case ApplePackageError.licenseRequired = error, package.software.price == 0 {
                    let alert = UIAlertController(title: "需要许可证", message: nil, preferredStyle: .alert)
                    alert.addAction(UIAlertAction(title: "取消", style: .cancel))
                    alert.addAction(UIAlertAction(title: "获取许可证", style: .default) { [weak self] _ in self?.license() })
                    present(alert, animated: true); return
                }
                throw error
            }
            if let request = Downloads.this.downloadRequest(forArchive: package) { push(NativePackage(model, package: request)) }
        }
    }
    func license() {
        guard let accountID else { return }
        run { [self] in
            try await AppStore.this.withAccount(id: accountID) { account in
                try await ApplePackage.Authenticator.rotatePasswordToken(for: &account.account)
                try await ApplePackage.Purchase.purchase(account: &account.account, app: self.package.software)
            }
            alert("请求成功")
        }
    }
}

@MainActor
final class NativeHistory: NativePage {
    let archive: AppPackageArchive
    init(_ model: AppModel, archive: AppPackageArchive) { self.archive = archive; super.init(model, title: "版本历史"); navigationItem.largeTitleDisplayMode = .never }
    required init?(coder: NSCoder) { fatalError() }
    override func viewDidAppear(_ animated: Bool) { super.viewDidAppear(animated); archive.loadHistory() }
    override func viewDidDisappear(_ animated: Bool) { super.viewDidDisappear(animated); archive.cancelHistoryLoading() }
    override func rows() -> [NativeSection] {
        navigationItem.rightBarButtonItem = UIBarButtonItem(image: UIImage(systemName: "ellipsis"), menu: UIMenu(children: [UIAction(title: "加载更多", image: UIImage(systemName: "list.bullet.below.rectangle")) { [weak self] _ in self?.archive.populateNextVersionItems() }, UIAction(title: "刷新", image: UIImage(systemName: "arrow.clockwise")) { [weak self] _ in self?.archive.loadHistory(force: true) }]))
        var rows: [NativeRow] = []
        if archive.isLoadingIndex { rows.append(NativeRow(title: "正在加载历史版本...")) }
        if let error = archive.error { rows.append(NativeRow(title: error, color: .systemOrange)) }
        for key in archive.versionIdentifiers {
            if let package = archive.package(for: key), let metadata = archive.versionItems[key] {
                rows.append(link(package.software.version + (metadata.releaseDate.map { " · " + $0.formatted(date: .numeric, time: .omitted) } ?? "")) { [weak self] in
                    guard let self, let account = archive.accountIdentifier else { self?.alert("请先选择账户。"); return }
                    confirm("下载 \(package.software.version)？") { [weak self] in self?.run { try await Downloads.this.startDownload(for: package, accountID: account) } }
                })
            } else {
                rows.append(NativeRow(title: key, detail: archive.metadataErrors[key] ?? (archive.loadingIDs.contains(key) ? "加载中…" : "点按加载"), action: { [weak self] in self?.archive.populateVersionItem(for: key, retry: true) }))
            }
        }
        if archive.canLoadEarlierVersions && !archive.isLoadingIndex { rows.append(link("加载更早版本") { [weak self] in self?.archive.loadEarlierVersions() }) }
        return [NativeSection(rows: rows)]
    }
    override func tableView(_ tableView: UITableView, willDisplay cell: UITableViewCell, forRowAt indexPath: IndexPath) {
        // Load only the visible missing metadata, as in the previous history screen.
        let offset = (archive.isLoadingIndex ? 1 : 0) + (archive.error == nil ? 0 : 1)
        let index = indexPath.row - offset
        if archive.versionIdentifiers.indices.contains(index) { archive.populateVersionItem(for: archive.versionIdentifiers[index]) }
    }
}

@MainActor
final class NativeAccounts: NativePage {
    init(_ model: AppModel) { super.init(model, title: "账户") }
    required init?(coder: NSCoder) { fatalError() }
    override func viewDidLoad() {
        super.viewDidLoad()
        navigationItem.rightBarButtonItem = UIBarButtonItem(systemItem: .add, primaryAction: UIAction { [weak self] _ in guard let self else { return }; let add = NativeAddAccount(model); let nav = UINavigationController(rootViewController: add); nav.sheetPresentationController?.detents = [.custom(identifier: .init("account")) { context in min(390, context.maximumDetentValue) }]; present(nav, animated: true) })
    }
    override func rows() -> [NativeSection] {
        [NativeSection(title: "Apple ID", rows: AppStore.this.accounts.map { account in NativeRow(title: account.account.email, detail: ApplePackage.Configuration.countryCode(for: account.account.store) ?? account.account.store, action: { [weak self] in guard let self else { return }; push(NativeAccountDetail(model, id: account.id)) }) })]
    }
}

@MainActor
final class NativeAccountDetail: NativePage {
    let id: String
    init(_ model: AppModel, id: String) { self.id = id; super.init(model, title: "账户详情") }
    required init?(coder: NSCoder) { fatalError() }
    override func rows() -> [NativeSection] {
        guard let user = AppStore.this.accounts.first(where: { $0.id == id }) else { return [] }
        return [NativeSection(rows: [NativeRow(title: user.account.email), NativeRow(title: "地区", detail: user.account.store), NativeRow(title: "Directory Services ID", detail: user.account.directoryServicesIdentifier), NativeRow(title: "密码令牌", detail: "••••••••"), link("轮换密码令牌") { [weak self] in guard let self else { return }; run { _ = try await AppStore.this.rotate(id: self.id); self.alert("已更新") } }, NativeRow(title: "删除账户", color: .systemRed, action: { [weak self] in self?.confirm("删除账户？") { [weak self] in guard let self else { return }; AppStore.this.delete(id: id); navigationController?.popViewController(animated: true) } })])]
    }
}

@MainActor
final class NativeAddAccount: NativePage {
    let email = UITextField()
    let password = UITextField()
    let code = UITextField()
    var authenticator: ApplePackage.Authenticator?
    var needsCode = false
    init(_ model: AppModel) { super.init(model, title: "添加账户") }
    required init?(coder: NSCoder) { fatalError() }
    override func viewDidLoad() {
        super.viewDidLoad()
        navigationItem.largeTitleDisplayMode = .never
        email.placeholder = "邮箱（Apple ID）"; email.keyboardType = .emailAddress; email.textContentType = .username
        password.placeholder = "密码"; password.isSecureTextEntry = true; password.textContentType = .password
        code.placeholder = "验证码"; code.keyboardType = .numberPad; code.textContentType = .oneTimeCode
        for field in [email, password, code] {
            field.autocapitalizationType = .none; field.autocorrectionType = .no
            field.addAction(UIAction { [weak self] _ in self?.navigationItem.rightBarButtonItem?.isEnabled = !(self?.working ?? true) }, for: .editingChanged)
        }
        navigationItem.leftBarButtonItem = UIBarButtonItem(title: "取消", primaryAction: UIAction { [weak self] _ in self?.dismiss(animated: true) })
        navigationItem.rightBarButtonItem = UIBarButtonItem(title: "确认", primaryAction: UIAction { [weak self] _ in self?.authenticate() })
    }
    override func rows() -> [NativeSection] { [NativeSection(rows: Array(repeating: NativeRow(title: ""), count: needsCode ? 3 : 2)), NativeSection(rows: [link(password.isSecureTextEntry ? "显示密码" : "隐藏密码") { [weak self] in self?.password.isSecureTextEntry.toggle(); self?.reload() }])] }
    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        guard indexPath.section == 0 else { return super.tableView(tableView, cellForRowAt: indexPath) }
        let cell = UITableViewCell(); let field = [email, password, code][indexPath.row]
        field.removeFromSuperview(); field.translatesAutoresizingMaskIntoConstraints = false; cell.contentView.addSubview(field)
        NSLayoutConstraint.activate([field.leadingAnchor.constraint(equalTo: cell.contentView.leadingAnchor, constant: 18), field.trailingAnchor.constraint(equalTo: cell.contentView.trailingAnchor, constant: -18), field.topAnchor.constraint(equalTo: cell.contentView.topAnchor, constant: 16), field.bottomAnchor.constraint(equalTo: cell.contentView.bottomAnchor, constant: -16)])
        return cell
    }
    func authenticate() {
        guard !working, let emailText = email.text?.trimmingCharacters(in: .whitespacesAndNewlines), !emailText.isEmpty, let secret = password.text, !secret.isEmpty, !needsCode || !(code.text ?? "").isEmpty else { return }
        view.endEditing(true); working = true; isModalInPresentation = true; navigationItem.rightBarButtonItem?.isEnabled = false; navigationItem.leftBarButtonItem?.isEnabled = false
        Task { [self] in
            defer { working = false; isModalInPresentation = false; navigationItem.rightBarButtonItem?.isEnabled = true; navigationItem.leftBarButtonItem?.isEnabled = true }
            do {
                let session: ApplePackage.Authenticator
                if let authenticator { session = authenticator } else { session = try await ApplePackage.Authenticator(); authenticator = session }
                _ = try await AppStore.this.authenticate(email: emailText, password: secret, code: code.text ?? "", using: session)
                password.text = ""; code.text = ""; dismiss(animated: true)
            } catch {
                if case ApplePackage.AuthenticationError.verificationCodeRequired = error { needsCode = true; reload() }
                else { authenticator = nil; alert(error.localizedDescription) }
            }
        }
    }
}

@MainActor
final class NativeDownloads: NativePage {
    init(_ model: AppModel) { super.init(model, title: "下载") }
    required init?(coder: NSCoder) { fatalError() }
    override func viewDidLoad() {
        super.viewDidLoad()
        navigationItem.rightBarButtonItem = UIBarButtonItem(systemItem: .add, primaryAction: UIAction { [weak self] _ in
            guard let self else { return }
            edit("Bundle ID") { [weak self] bundle in
                guard let self else { return }
                let accounts = AppStore.this.accounts
                let picker = NativeChoices(model, title: "选择账户", items: accounts.map { ($0.id, $0.account.email) }) { [weak self] id in
                    guard let self, let account = accounts.first(where: { $0.id == id }), let region = ApplePackage.Configuration.countryCode(for: account.account.store) else { return }
                    run { let app = try await ApplePackage.Lookup.lookup(bundleID: bundle, countryCode: region); try await Downloads.this.startDownload(for: AppStore.AppPackage(software: app), accountID: id) }
                }
                push(picker)
            }
        })
    }
    override func rows() -> [NativeSection] {
        [NativeSection(rows: Downloads.this.manifests.sorted { $0.creation > $1.creation }.map { package in NativeRow(title: package.package.software.name + " · " + package.package.software.version, detail: (package.state.error ?? package.state.status.rawValue) + " · \(Int(package.state.percent * 100))% " + package.state.speed, icon: URL(string: package.package.software.artworkUrl), action: { [weak self] in guard let self else { return }; push(NativePackage(model, package: package)) }, delete: { Downloads.this.delete(request: package) }) })]
    }
}

@MainActor
final class NativePackage: NativePage {
    let package: PackageManifest
    init(_ model: AppModel, package: PackageManifest) { self.package = package; super.init(model, title: package.package.software.name) }
    required init?(coder: NSCoder) { fatalError() }
    override func rows() -> [NativeSection] {
        let app = package.package.software
        var controls: [NativeRow] = []
        if package.completed {
            controls = [link("配对安装") { [weak self] in guard let self else { return }; let page = NativeInstall(model, package: package); sheet(page); page.start() }, link("证书安装") { [weak self] in guard let self else { return }; run { let installer = try await Installer(archive: self.package.package, path: self.package.targetLocation); self.push(NativeCertificateInstall(self.model, installer: installer)) } }, link("导出安装包 / AirDrop") { [weak self] in guard let self else { return }; share(package.targetLocation) }, link("查看安装包内容") { [weak self] in guard let self else { return }; push(NativeArchiveFiles(model, file: package.targetLocation)) }]
        } else {
            controls = Downloads.this.getAvailableActions(for: package).filter { $0 != .delete }.map { action in link(Downloads.this.getActionLabel(for: action).title) { [weak self] in guard let self else { return }; Downloads.this.performDownloadAction(for: package, action: action); reload() } }
        }
        return [NativeSection(rows: [NativeRow(title: app.name, detail: app.version, icon: URL(string: app.artworkUrl)), NativeRow(title: "Bundle ID", detail: app.bundleID), NativeRow(title: "开发者", detail: app.sellerName), NativeRow(title: package.state.error ?? package.state.status.rawValue, detail: "\(Int(package.state.percent * 100))%")]), NativeSection(rows: controls), NativeSection(title: "账户", rows: [NativeRow(title: package.account.account.email)]), NativeSection(rows: [NativeRow(title: "删除安装包", color: .systemRed, action: { [weak self] in guard let self else { return }; Downloads.this.delete(request: package); navigationController?.popViewController(animated: true) })])]
    }
}

@MainActor
final class NativeInstall: NativePage {
    let package: PackageManifest
    var status = "正在连接设备…"
    var fraction = 0.0
    init(_ model: AppModel, package: PackageManifest) { self.package = package; super.init(model, title: "配对安装") }
    required init?(coder: NSCoder) { fatalError() }
    func start() {
        guard !working else { return }; working = true
        navigationController?.isModalInPresentation = true; navigationItem.rightBarButtonItem?.isEnabled = false
        Task { [self] in
            do { try await model.installPackage(at: package.targetLocation, bundleID: package.package.software.bundleID) { [weak self] stage, value in self?.status = stage; self?.fraction = value; self?.reload() }; status = "安装完成" }
            catch { status = error.localizedDescription }
            working = false; navigationController?.isModalInPresentation = false; navigationItem.rightBarButtonItem?.isEnabled = true; reload()
        }
    }
    override func rows() -> [NativeSection] { [NativeSection(rows: [NativeRow(title: status, detail: "\(Int(fraction * 100))%"), link("重试") { [weak self] in self?.start() }])] }
}

@MainActor
final class NativeCertificateInstall: NativePage {
    let installer: Installer
    init(_ model: AppModel, installer: Installer) { self.installer = installer; super.init(model, title: "证书安装") }
    required init?(coder: NSCoder) { fatalError() }
    override func viewDidAppear(_ animated: Bool) { super.viewDidAppear(animated); UIApplication.shared.open(installer.iTunesLink) }
    override func viewDidDisappear(_ animated: Bool) { super.viewDidDisappear(animated); if isMovingFromParent { installer.destroy() } }
    override func rows() -> [NativeSection] {
        let text: String
        switch installer.status {
        case .ready: text = "准备安装"
        case .sendingManifest: text = "正在发送清单…"
        case .sendingPayload: text = "正在发送安装包…"
        case .completed(let result): text = (try? result.get()) != nil ? "发送完成" : "发送失败"
        case .broken(let error): text = error.localizedDescription
        }
        return [NativeSection(rows: [NativeRow(title: text), link("安装") { [weak self] in guard let self else { return }; UIApplication.shared.open(installer.iTunesLink) }])]
    }
}

@MainActor
final class NativeChoices: NativeSearchPage {
    let items: [(String, String)]
    let select: (String) -> Void
    init(_ model: AppModel, title: String, items: [(String, String)], select: @escaping (String) -> Void) { self.items = items; self.select = select; super.init(model, title: title) }
    required init?(coder: NSCoder) { fatalError() }
    override func rows() -> [NativeSection] {
        [NativeSection(rows: items.filter { query.isEmpty || $0.1.localizedCaseInsensitiveContains(query) || $0.0.localizedCaseInsensitiveContains(query) }.map { key, title in NativeRow(title: title, action: { [weak self] in guard let self else { return }; select(key); navigationController?.popViewController(animated: true) }) })]
    }
}

@MainActor
final class NativeSettings: NativePage, UIDocumentPickerDelegate {
    init(_ model: AppModel) { super.init(model, title: "设置") }
    required init?(coder: NSCoder) { fatalError() }
    override func rows() -> [NativeSection] {
        var sections = [NativeSection(title: "连接配置", rows: [NativeRow(title: "IP 地址", detail: model.host, action: { [weak self] in guard let self else { return }; edit("IP 地址", value: model.host) { [weak self] in self?.model.host = $0; self?.reload() } }), NativeRow(title: "端口", detail: model.port, action: { [weak self] in guard let self else { return }; edit("端口", value: model.port) { [weak self] in self?.model.port = $0; self?.reload() } }), NativeRow(title: "配对", detail: model.hasPairing ? "已配对" : "未配对", action: { [weak self] in guard let self else { return }; push(NativePairing(model)) })]), NativeSection(rows: [NativeRow(title: "商店地区", detail: StoreRegionNames.name(model.country), action: { [weak self] in guard let self else { return }; let items = [(StoreQueryPolicy.chinaThenUS, "中国大陆优先")] + ApplePackage.Configuration.storeFrontValues.keys.sorted().map { ($0.lowercased(), "\(StoreRegionNames.name($0))  \($0)") }; push(NativeChoices(model, title: "商店地区", items: items) { [weak self] in self?.model.country = $0; self?.reload() }) })]), NativeSection(title: "商店连接", rows: [NativeRow(title: "设备 GUID", detail: AppStore.this.deviceIdentifier, action: { [weak self] in guard let self else { return }; edit("设备 GUID", value: AppStore.this.deviceIdentifier) { [weak self] value in guard let normalized = AppStore.normalizedDeviceIdentifier(value) else { self?.alert("请输入有效的 12 位十六进制 GUID。"); return }; AppStore.this.deviceIdentifier = normalized; self?.reload() } }), link("安装证书") { UIApplication.shared.open(Installer.caURL) }, link("打开系统设置") { UIApplication.shared.open(URL(string: UIApplication.openSettingsURLString)!) }]), NativeSection(title: "下载管理", rows: [NativeRow(title: "删除全部下载", color: .systemRed, action: { [weak self] in self?.confirm("删除全部下载？") { Downloads.this.removeAll() } }), NativeRow(title: "重置商店数据", color: .systemRed, action: { [weak self] in self?.confirm("重置商店数据后需要重启 App") { [weak self] in do { Downloads.this.removeAll(); try FileManager.default.removeItem(at: documentsDirectory); self?.alert("已重置，请关闭并重新打开 App。") } catch { self?.alert(error.localizedDescription) } } }), link("日志") { [weak self] in guard let self else { return }; push(NativeLogs(model)) }])]
        if !model.ignoredApps.names.isEmpty { sections.append(NativeSection(rows: [link("已忽略应用") { [weak self] in guard let self else { return }; push(NativeIgnored(model)) }])) }
        sections.append(NativeSection(title: "关于", rows: [link("开源许可") { [weak self] in guard let self else { return }; let text = ["AssppLicense", "AssppWebLicense"].compactMap { Bundle.main.url(forResource: $0, withExtension: "txt") }.compactMap { try? String(contentsOf: $0, encoding: .utf8) }.joined(separator: "\n\n"); push(NativeText(model, title: "开源许可", text: text)) }, NativeRow(title: "ssstore", detail: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "")]))
        return sections
    }
}
@MainActor
final class NativeIgnored: NativePage {
    init(_ model: AppModel) { super.init(model, title: "已忽略应用") }
    required init?(coder: NSCoder) { fatalError() }
    override func rows() -> [NativeSection] { [NativeSection(rows: model.ignoredApps.names.keys.sorted().map { id in NativeRow(title: model.ignoredApps.names[id] ?? id, detail: id, icon: model.localIconURL(for: model.ignoredApps.application(for: id)) ?? model.ignoredApps.iconURLs?[id], action: { [weak self] in self?.model.restoreApp(id); self?.reload() }) })] }
}
@MainActor
final class NativePairing: NativePage, UIDocumentPickerDelegate {
    private var observation: AnyCancellable?
    init(_ model: AppModel) { super.init(model, title: "配对") }
    required init?(coder: NSCoder) { fatalError() }
    override func viewDidLoad() {
        super.viewDidLoad(); observation = model.pairingController.objectWillChange.sink { [weak self] _ in self?.scheduleReload() }
    }
    override func rows() -> [NativeSection] {
        let controller = model.pairingController
        var rows = [NativeRow(title: "状态", detail: model.hasPairing ? "已配对" : "未配对"), NativeRow(title: controller.status)]
        if let pin = controller.pin { rows.append(link("配对码：\(pin)") { UIPasteboard.general.string = pin }) }
        if controller.isActive { rows.append(link("停止配对") { controller.cancel() }) }
        else { rows.append(link("创建配对") { [weak self] in self?.model.createPairingOnDevice() }) }
        rows.append(link("导入配对文件") { [weak self] in guard let self else { return }; let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.item], asCopy: true); picker.delegate = self; present(picker, animated: true) })
        if model.hasPairing {
            rows.append(link("导出配对文件") { [weak self] in guard let self else { return }; do { let file = temporaryDirectory.appendingPathComponent("ssstore-pairing.plist"); try model.pairingDataForExport().write(to: file, options: [.atomic, .completeFileProtection]); let picker = UIDocumentPickerViewController(forExporting: [file], asCopy: true); present(picker, animated: true) } catch { alert(error.localizedDescription) } })
            rows.append(NativeRow(title: "删除配对文件", color: .systemRed, action: { [weak self] in self?.confirm("删除配对文件？") { [weak self] in self?.model.removePairing() } }))
        }
        return [NativeSection(rows: rows), NativeSection(title: "创建配对", rows: [NativeRow(title: "开始配对后，前往系统设置 → 隐私与安全 → 开发者模式，选择 ssstore，输入配对码后返回。")]), NativeSection(title: "配对日志", rows: controller.diagnostics.map { NativeRow(title: $0) })]
    }
    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) { if let url = urls.first { model.importPairing(from: url); reload() } }
}
@MainActor
class NativeText: NativePage {
    let text: String
    init(_ model: AppModel, title: String, text: String) { self.text = text; super.init(model, title: title) }
    required init?(coder: NSCoder) { fatalError() }
    override func rows() -> [NativeSection] { [NativeSection(rows: [NativeRow(title: text, action: { [weak self] in UIPasteboard.general.string = self?.text })])] }
}
@MainActor
final class NativeLogs: NativePage {
    init(_ model: AppModel) { super.init(model, title: "日志") }
    required init?(coder: NSCoder) { fatalError() }
    override func viewDidLoad() { super.viewDidLoad(); navigationItem.rightBarButtonItem = UIBarButtonItem(systemItem: .refresh, primaryAction: UIAction { [weak self] _ in self?.reload() }) }
    override func rows() -> [NativeSection] { LogManager.shared.getMessages().map { message in NativeSection(rows: [NativeRow(title: message, action: { UIPasteboard.general.string = message })]) } }
}

@MainActor
final class NativeData: NativeSearchPage {
    let bundle: String?
    init(_ model: AppModel, bundle: String? = nil) { self.bundle = bundle; super.init(model, title: bundle == nil ? "数据" : "应用数据") }
    required init?(coder: NSCoder) { fatalError() }
    override func rows() -> [NativeSection] {
        InspectionOperation.groups.compactMap { group in
            let items = InspectionOperation.menu.filter { $0.group == group && (bundle == nil || $0.requiresApp) && (query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) || $0.service.localizedCaseInsensitiveContains(query)) }
            guard !items.isEmpty else { return nil }
            return NativeSection(title: group, rows: items.map { operation in NativeRow(title: operation.title, action: { [weak self] in guard let self else { return }; push(NativeInspection(model, operation: operation, bundle: bundle ?? "")) }) })
        }
    }
}
@MainActor
final class NativeInspection: NativePage {
    let operation: InspectionOperation
    var bundle: String
    var path: String
    var domain = 1
    var groupID = ""
    var source: String?
    var result: InspectionResult?
    var report: URL?
    var failure: String?
    init(_ model: AppModel, operation: InspectionOperation, bundle: String = "", path: String = "/", source: String? = nil) { self.operation = operation; self.bundle = bundle; self.path = path; self.source = source; super.init(model, title: operation.title); navigationItem.largeTitleDisplayMode = .never }
    required init?(coder: NSCoder) { fatalError() }
    override func rows() -> [NativeSection] {
        var controls: [NativeRow] = []
        if !operation.note.isEmpty { controls.append(NativeRow(title: operation.note)) }
        if operation.requiresApp && !(operation == .coreFiles && domain != 1) {
            controls.append(NativeRow(title: "应用", detail: model.records.first(where: { $0.id == bundle })?.installed.name ?? "请选择", action: { [weak self] in guard let self else { return }; let include = UserDefaults.standard.bool(forKey: "includeSystemApps"); let apps = model.records.filter { include || !$0.installed.isSystem }; push(NativeChoices(model, title: "选择应用", items: apps.map { ($0.id, $0.installed.name) }) { [weak self] in self?.bundle = $0; self?.result = nil; self?.reload() }) }))
        }
        if operation.isBrowser || operation.isFileHelper { controls.append(NativeRow(title: "路径", detail: path, action: { [weak self] in guard let self else { return }; edit("路径", value: path) { [weak self] in self?.path = $0; self?.result = nil; self?.reload() } })) }
        if operation == .coreFiles {
            controls.append(link("文件域：\(domain)") { [weak self] in guard let self else { return }; push(NativeChoices(model, title: "文件域", items: [("1", "应用数据"), ("2", "App Group"), ("3", "临时目录"), ("5", "崩溃日志")]) { [weak self] in self?.domain = Int($0) ?? 1; self?.result = nil; self?.reload() }) })
            if domain == 2 { controls.append(link("App Group：\(groupID)") { [weak self] in guard let self else { return }; edit("App Group", value: groupID) { [weak self] in self?.groupID = $0; self?.reload() } }) }
        }
        controls.append(link(working ? "正在读取…" : "读取") { [weak self] in self?.read() })
        var sections = [NativeSection(rows: controls)]
        if let failure { sections.append(NativeSection(rows: [NativeRow(title: failure, color: .systemOrange)])) }
        if let result {
            if !result.entries.isEmpty {
                sections.append(NativeSection(title: "目录", rows: result.entries.map { entry in NativeRow(title: entry.name, action: { [weak self] in
                    guard let self else { return }
                    let page = NativeInspection(model, operation: operation == .coreFiles ? operation : .fileInfo, bundle: bundle, path: entry.path, source: operation.rawValue)
                    page.domain = domain; page.groupID = groupID; push(page); page.read()
                }) }))
            }
            if operation == .fileInfo {
                if result.value["isDirectory"] == .bool(true), let source, let browser = InspectionOperation(rawValue: source) {
                    sections.append(NativeSection(rows: [link("打开目录") { [weak self] in guard let self else { return }; let page = NativeInspection(model, operation: browser, bundle: bundle, path: path); push(page); page.read() }]))
                } else { sections.append(NativeSection(rows: [link("读取文件") { [weak self] in guard let self else { return }; let page = NativeInspection(model, operation: .fileRead, bundle: bundle, path: path, source: source); push(page); page.read() }])) }
            }
            if !result.files.isEmpty { sections.append(NativeSection(title: "文件", rows: result.files.flatMap { file in [link(file.name) { [weak self] in self?.preview(URL(fileURLWithPath: file.path)) }, link("导出 \(file.name)") { [weak self] in self?.share(URL(fileURLWithPath: file.path)) }] })) }
            sections.append(NativeSection(rows: valueRows(result.value)))
            if let report { sections.append(NativeSection(rows: [link("导出 JSON 报告") { [weak self] in self?.share(report) }])) }
        }
        sections.append(NativeSection(title: "服务", rows: [NativeRow(title: operation.service)]))
        return sections
    }
    func valueRows(_ value: InspectionValue) -> [NativeRow] { NativeValues.makeRows(value, owner: self) }
    func read() {
        guard !working else { return }; working = true; failure = nil; result = nil; report = nil; reload()
        Task { [self] in
            do { let output = try await model.inspect(operation, bundleID: bundle, path: path, source: source, domain: domain, groupID: groupID); result = output.0; report = output.1 }
            catch { failure = error.localizedDescription }
            working = false; reload()
        }
    }
}
@MainActor
final class NativeValues: NativePage {
    let value: InspectionValue
    init(_ model: AppModel, title: String, value: InspectionValue) { self.value = value; super.init(model, title: title) }
    required init?(coder: NSCoder) { fatalError() }
    override func rows() -> [NativeSection] { [NativeSection(rows: Self.makeRows(value, owner: self))] }
    static func makeRows(_ value: InspectionValue, owner: NativePage) -> [NativeRow] {
        let entries: [(String, InspectionValue)]
        switch value {
        case .object(let dict): entries = dict.keys.sorted().map { ($0, dict[$0]!) }
        case .array(let array): entries = array.enumerated().map { ("第 \($0.offset + 1) 项", $0.element) }
        default: return [NativeRow(title: value.text)]
        }
        return entries.map { key, child in
            switch child {
            case .object, .array: return NativeRow(title: key, detail: child.text, action: { [weak owner] in guard let owner else { return }; owner.push(NativeValues(owner.model, title: key, value: child)) })
            default:
                let sizeKeys = ["StaticDiskUsage", "DynamicDiskUsage", "size", "总字节数", "可用字节数", "字节数", "块大小", "TotalSystemCapacity", "TotalDataCapacity", "AmountDataAvailable", "AmountDataReserved", "BlockSize"]
                var text = child.text
                if sizeKeys.contains(key), let bytes = Double(text), bytes >= 0, bytes < Double(Int64.max) { text = ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file) }
                let copied = text
                return NativeRow(title: key, detail: text, action: { UIPasteboard.general.string = copied })
            }
        }
    }
}

@MainActor
final class NativeArchiveFiles: NativeSearchPage {
    let file: URL
    let prefix: String
    var entries: [Entry] = []
    init(_ model: AppModel, file: URL, prefix: String = "") { self.file = file; self.prefix = prefix; super.init(model, title: "安装包内容") }
    required init?(coder: NSCoder) { fatalError() }
    override func viewDidLoad() {
        super.viewDidLoad()
        run { [self] in let archive = try Archive(url: file, accessMode: .read); entries = Array(archive); reload() }
    }
    override func rows() -> [NativeSection] {
        let rows = entries.filter { entry in
            let stripped = entry.path.hasSuffix("/") ? String(entry.path.dropLast()) : entry.path
            let parent = (stripped as NSString).deletingLastPathComponent
            return parent == prefix && (query.isEmpty || entry.path.localizedCaseInsensitiveContains(query))
        }.map { entry in NativeRow(title: (entry.path as NSString).lastPathComponent, action: { [weak self] in
            guard let self else { return }
            if entry.type == .directory { push(NativeArchiveFiles(model, file: file, prefix: entry.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")))) }
            else if entry.type == .file {
                run { let archive = try Archive(url: self.file, accessMode: .read); let output = temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension((entry.path as NSString).pathExtension); _ = try archive.extract(entry, to: output); self.push(NativeExtractedFile(self.model, file: output)) }
            }
        }) }
        return [NativeSection(rows: rows)]
    }
}
@MainActor
final class NativeExtractedFile: NativePage {
    let file: URL
    init(_ model: AppModel, file: URL) { self.file = file; super.init(model, title: file.lastPathComponent) }
    required init?(coder: NSCoder) { fatalError() }
    override func rows() -> [NativeSection] {
        var rows = [link("预览") { [weak self] in guard let self else { return }; preview(file) }, link("导出") { [weak self] in guard let self else { return }; share(file) }]
        if let attributes = try? FileManager.default.attributesOfItem(atPath: file.path), let bytes = attributes[.size] as? NSNumber { rows.append(NativeRow(title: "大小", detail: ByteCountFormatter.string(fromByteCount: bytes.int64Value, countStyle: .file))) }
        if let data = try? Data(contentsOf: file), let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) { rows.append(NativeRow(title: String(describing: plist))) }
        return [NativeSection(rows: rows)]
    }
}
