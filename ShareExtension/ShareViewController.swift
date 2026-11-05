import UIKit
import UniformTypeIdentifiers
import UpdateCore

@MainActor
final class ShareNavigationController: UINavigationController {
    override func viewDidLoad() {
        super.viewDidLoad()
        setViewControllers([ShareViewController()], animated: false)
    }
}

@MainActor
final class ShareViewController: UITableViewController {
    private struct Response: Decodable { let results: [Product] }
    private struct Product: Decodable {
        let trackId: Int64
        let trackName: String
        let artistName: String?
        let version: String?
        let formattedPrice: String?
        let artworkUrl512: URL?
    }
    private var link: AppStoreLink?
    private var product: Product?
    private var artwork: UIImage?
    private var status: String?
    private var load: Task<Void, Never>?
    private var context: NSExtensionContext? { navigationController?.extensionContext ?? extensionContext }
    private var metadata: [(String, String)] {
        [("版本", product?.version), ("价格", product?.formattedPrice)].compactMap { name, value in
            value.map { (name, $0) }
        }
    }

    init() { super.init(style: .insetGrouped) }
    required init?(coder: NSCoder) { fatalError() }
    override func viewDidLoad() {
        super.viewDidLoad()
        title = "ssstore"
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = UITableView.automaticDimension
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "row")
        navigationItem.rightBarButtonItem = UIBarButtonItem(systemItem: .done, primaryAction: UIAction { [weak self] _ in
            self?.context?.completeRequest(returningItems: nil)
        })
        load = Task { [weak self] in await self?.readLink() }
    }
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let height = ceil(tableView.contentSize.height + tableView.adjustedContentInset.top + tableView.adjustedContentInset.bottom)
        if navigationController?.preferredContentSize.height != height {
            navigationController?.preferredContentSize = CGSize(width: tableView.bounds.width, height: height)
        }
    }
    deinit { load?.cancel() }
    override func viewDidDisappear(_ animated: Bool) { super.viewDidDisappear(animated); load?.cancel() }

    override func numberOfSections(in tableView: UITableView) -> Int { link == nil ? 1 : 3 }
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch section {
        case 0: return 1
        case 1: return metadata.count
        default: return 2
        }
    }
    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        section == (link == nil ? 0 : 2) ? status : nil
    }
    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "row", for: indexPath)
        var configuration = UIListContentConfiguration.subtitleCell()
        cell.selectionStyle = .none
        switch indexPath.section {
        case 0:
            configuration.text = product?.trackName ?? (status != nil ? "App Store 应用" : (link == nil ? "正在读取分享链接…" : "正在载入应用信息…"))
            configuration.secondaryText = product?.artistName
            configuration.image = artwork ?? UIImage(systemName: "app")
            configuration.imageProperties.maximumSize = CGSize(width: 52, height: 52)
            configuration.imageProperties.reservedLayoutSize = CGSize(width: 52, height: 52)
            configuration.imageProperties.cornerRadius = 11
        case 1:
            configuration = UIListContentConfiguration.valueCell()
            configuration.text = metadata[indexPath.row].0
            configuration.secondaryText = metadata[indexPath.row].1
        default:
            configuration = UIListContentConfiguration.cell()
            configuration.text = indexPath.row == 0 ? "在 ssstore 中打开" : "复制应用链接"
            configuration.image = UIImage(systemName: indexPath.row == 0 ? "arrow.up.forward.app" : "doc.on.doc")
            configuration.textProperties.color = .systemBlue
            cell.selectionStyle = .default
        }
        configuration.textProperties.numberOfLines = 0
        configuration.secondaryTextProperties.numberOfLines = 0
        configuration.textProperties.adjustsFontForContentSizeCategory = true
        configuration.secondaryTextProperties.adjustsFontForContentSizeCategory = true
        cell.contentConfiguration = configuration
        return cell
    }
    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard indexPath.section == 2, let link else { return }
        if indexPath.row == 0 { openApp() }
        else {
            UIPasteboard.general.string = link.storeURL.absoluteString
            context?.completeRequest(returningItems: nil)
        }
    }

    private func readLink() async {
        let items = context?.inputItems as? [NSExtensionItem] ?? []
        for provider in items.flatMap({ $0.attachments ?? [] }) {
            for type in [UTType.url.identifier, UTType.plainText.identifier] where provider.hasItemConformingToTypeIdentifier(type) {
                let item = try? await provider.loadItem(forTypeIdentifier: type, options: nil)
                if Task.isCancelled { return }
                let text = (item as? URL)?.absoluteString ?? (item as? String) ?? (item as? Data).flatMap { String(data: $0, encoding: .utf8) }
                guard let text, let parsed = AppStoreLink.parse(text) else { continue }
                link = parsed
                tableView.reloadData()
                await loadProduct(parsed)
                return
            }
        }
        status = "未找到 App Store 应用链接，请从 App Store 或浏览器分享应用页面。"
        tableView.reloadData()
    }

    private func loadProduct(_ link: AppStoreLink) async {
        let country = link.country ?? Locale.current.region?.identifier ?? "US"
        do {
            let (data, response) = try await URLSession.shared.data(from: link.lookupURL(country: country))
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let result = try JSONDecoder().decode(Response.self, from: data).results.first,
                  result.trackId == link.appID else { throw ShareError.unavailable }
            try Task.checkCancellation()
            product = result
            tableView.reloadData()
            if let url = result.artworkUrl512,
               let (imageData, _) = try? await URLSession.shared.data(from: url) {
                try Task.checkCancellation()
                artwork = UIImage(data: imageData)
                tableView.reloadRows(at: [IndexPath(row: 0, section: 0)], with: .none)
            }
        } catch {
            guard !Task.isCancelled else { return }
            status = "暂时无法载入应用信息，仍可打开或复制此链接。"
            tableView.reloadData()
        }
    }

    private func openApp() {
        guard let link, let scene = view.window?.windowScene else { showCopyHint(); return }
        scene.open(link.deepLink, options: nil) { [weak self] opened in
            guard let self else { return }
            if opened { context?.completeRequest(returningItems: nil) }
            else { showCopyHint() }
        }
    }
    private func showCopyHint() {
        status = "当前 App 不允许直接跳转。请复制链接，打开 ssstore 后粘贴到搜索框并搜索。"
        tableView.reloadData()
    }
}

private enum ShareError: Error { case unavailable }
