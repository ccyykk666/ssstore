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
final class NativeApps: NativeSearchPage {
    enum Filter { case all, attention, updates, pending, failed }
    var filter = Filter.all
    private var menuKey = ""
    init(_ model: AppModel) { super.init(model, title: "ssstore") }
    required init?(coder: NSCoder) { fatalError() }
    func showApplications(_ filter: Filter = .all) {
        self.filter = filter; query = ""; search.searchBar.text = ""; search.isActive = false
        reload()
    }
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
        if (filter == .failed && statistics.failures == 0) || (filter == .updates && statistics.updates == 0) { filter = .all }
        let key = "\(model.busy)|\(model.isChecking)|\(filter)|\(includeSystem)"
        if key != menuKey {
        menuKey = key
        navigationItem.rightBarButtonItem = UIBarButtonItem(image: UIImage(systemName: "ellipsis"), menu: UIMenu(children: [
            UIAction(title: "刷新应用", image: UIImage(systemName: "arrow.triangle.2.circlepath"), attributes: model.busy ? .disabled : []) { [weak self] _ in guard let self else { return }; Task { await self.model.refreshApps() } },
            UIAction(title: "停止刷新", image: UIImage(systemName: "stop.circle"), attributes: model.isChecking ? [] : .hidden) { [weak self] _ in self?.model.cancelCheck() },
            UIAction(title: "下载", image: UIImage(systemName: "arrow.down.circle")) { [weak self] _ in guard let self else { return }; push(NativeDownloads(model)) },
            UIAction(title: "仅显示差异项", image: UIImage(systemName: "line.3.horizontal.decrease"), state: filter == .attention ? .on : .off) { [weak self] _ in guard let self else { return }; filter = filter == .attention ? .all : .attention; reload() },
            UIAction(title: "显示系统应用", image: UIImage(systemName: "gearshape"), state: includeSystem ? .on : .off) { [weak self] _ in UserDefaults.standard.set(!includeSystem, forKey: "includeSystemApps"); self?.reload() }
        ]))
        }
        var summary = [NativeRow(title: "", metrics: [statistics.applications, statistics.updates, statistics.pending, statistics.failures], metricActions: [
            0: { [weak self] in self?.showApplications() },
            1: { [weak self] in self?.showApplications(.updates) },
            2: { [weak self] in self?.showApplications(.pending) },
            3: { [weak self] in self?.showApplications(.failed) }
        ])]
        for warning in [model.scanWarning, model.queryWarning] where !warning.isEmpty { summary.append(NativeRow(title: warning, color: .systemOrange)) }
        let filtered = listed.filter { record in
            let matched = revealed?.contains(record.id) ?? true
            let included: Bool
            switch filter {
            case .all: included = true
            case .attention: included = matched && record.status(country: model.country) != .current
            case .updates: included = matched && [.different, .update].contains(record.status(country: model.country))
            case .pending: included = matched && record.error == nil && record.status(country: model.country) == .unknown
            case .failed: included = matched && record.error != nil
            }
            return included && (query.isEmpty || record.installed.name.localizedCaseInsensitiveContains(query) || record.id.localizedCaseInsensitiveContains(query))
        }
        let rows = filtered.map { record -> NativeRow in
            let matched = revealed?.contains(record.id) ?? true
            let status = record.status(country: model.country)
            let update = matched && (status == .different || status == .update)
            let tag = update ? "新版本" : (matched && status == .unknown ? "待核对" : "")
            return NativeRow(title: record.installed.name, detail: "本机 \(record.displayedVersion(country: model.country) ?? "未知") · 商店 \(record.release.flatMap { $0.matches(scope: self.model.country) ? $0.version : nil } ?? "—")" + (matched && record.error != nil ? "\n查询失败" : ""), icon: model.localIconURL(for: record.installed) ?? record.release?.iconURL, action: { [weak self] in guard let self else { return }; push(NativeAppDetail(model, id: record.id)) }, delete: { [weak self] in self?.model.ignoreApp(record.id) }, deleteTitle: "忽略", badge: tag.isEmpty ? nil : tag, iconRevision: model.iconRevision, compact: true)
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
        let query = UIAction(title: "查询", attributes: model.busy ? .disabled : []) { [weak self] _ in
            guard let self else { return }; model.checkUpdates(only: id)
        }
        var fields = [NativeRow(title: record.installed.name, icon: model.localIconURL(for: record.installed), iconRevision: model.iconRevision, accessoryAction: query), NativeRow(title: "本机版本", detail: record.displayedVersion(country: model.country) ?? "未知")]
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
    private var menuKey = ""
    init(_ model: AppModel) { super.init(model, title: "搜索") }
    required init?(coder: NSCoder) { fatalError() }
    override func viewDidLoad() {
        super.viewDidLoad()
        search.searchBar.placeholder = "关键词、Bundle ID 或链接"
    }
    override func rows() -> [NativeSection] {
        let regions = AppStore.this.possibleRegions.sorted()
        if let first = regions.first, !regions.contains(region) {
            region = first
            UserDefaults.standard.set(first, forKey: "searchRegion")
            reset()
        }
        navigationItem.hidesSearchBarWhenScrolling = !results.isEmpty
        let key = ([region, entity.rawValue] + regions).joined(separator: "|")
        if key != menuKey {
        menuKey = key
        var buttons = [UIBarButtonItem(image: UIImage(systemName: entity.iconName), menu: UIMenu(children: EntityType.allCases.map { type in UIAction(title: type.rawValue, state: type == entity ? .on : .off) { [weak self] _ in self?.entity = type; self?.reset(); self?.reload() } }))]
        if !regions.isEmpty {
            buttons.insert(regionButton(menu: UIMenu(children: regions.map { key in UIAction(title: "\(StoreRegionNames.name(key))  \(key)", state: key == region ? .on : .off) { [weak self] _ in self?.region = key; UserDefaults.standard.set(key, forKey: "searchRegion"); self?.reset(); self?.reload() } })), at: 0)
        }
        navigationItem.rightBarButtonItems = buttons
        buttons.forEach { $0.tintColor = .label }
        }
        var sections: [NativeSection] = []
        if let error { sections.append(NativeSection(rows: [NativeRow(title: error, color: .systemRed)])) }
        if loading || !results.isEmpty { sections.append(NativeSection(title: loading ? "正在搜索…" : "\(results.count) 个结果", rows: results.map { package in NativeRow(title: package.software.name, detail: package.software.sellerName, icon: URL(string: package.software.artworkUrl), action: { [weak self] in guard let self else { return }; push(NativeProduct(model, package: package, region: region)) }, compact: true) })) }
        return sections
    }
    private func regionButton(menu: UIMenu) -> UIBarButtonItem {
        let button = UIButton(type: .system)
        var configuration = UIButton.Configuration.plain()
        configuration.title = region; configuration.image = UIImage(systemName: "globe"); configuration.imagePadding = 6
        configuration.baseForegroundColor = .label
        configuration.imageColorTransformer = UIConfigurationColorTransformer { _ in .label }
        configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var attributes = incoming; attributes.foregroundColor = .label; return attributes
        }
        button.tintColor = .label
        button.configuration = configuration; button.menu = menu; button.showsMenuAsPrimaryAction = true
        return UIBarButtonItem(customView: button)
    }
    override func queryChanged() { reset(); scheduleReload() }
    override func searchBarSearchButtonClicked(_ searchBar: UISearchBar) {
        super.searchBarSearchButtonClicked(searchBar)
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { reset(); reload(); return }
        if let link = AppStoreLink.parse(term) {
            reset()
            (tabBarController as? NativeTabs)?.openStoreLink(link)
            return
        }
        reset(); let id = generation; let country = region; let type = entity
        loading = true; reload()
        request = Task { [weak self] in
            defer { if let self, generation == id { request = nil } }
            do {
                var apps = try await ApplePackage.Searcher.search(term: term, countryCode: country, limit: 32, entityType: type)
                try Task.checkCancellation()
                if term.contains("."), !term.contains(where: \.isWhitespace),
                   let app = try? await ApplePackage.Lookup.lookup(bundleID: term, countryCode: country, entityType: type) {
                    apps.removeAll { $0.bundleID == app.bundleID }
                    apps.insert(app, at: 0)
                }
                try Task.checkCancellation()
                guard let self, generation == id else { return }
                results = apps.map { AppStore.AppPackage(software: $0, entityType: type) }; loading = false; reload()
            } catch { guard let self, !Task.isCancelled, generation == id else { return }; self.error = error.localizedDescription; loading = false; reload() }
        }
    }
    func reset() { request?.cancel(); request = nil; generation = UUID(); results = []; error = nil; loading = false }
}

