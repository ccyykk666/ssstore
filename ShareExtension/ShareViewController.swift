import UIKit
import UniformTypeIdentifiers
import UpdateCore

@MainActor
final class ShareViewController: UIViewController {
    private struct Response: Decodable { let results: [Product] }
    private struct Product: Decodable {
        let trackId: Int64
        let trackName: String
        let artistName: String?
        let description: String?
        let version: String?
        let formattedPrice: String?
    }
    private let content = UIStackView()
    private let message = UILabel()
    private let details = UILabel()
    private let openButton = UIButton(type: .system)
    private let copyButton = UIButton(type: .system)
    private var link: AppStoreLink?
    private var load: Task<Void, Never>?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        let scroll = UIScrollView(); scroll.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scroll)
        content.axis = .vertical; content.spacing = 16; content.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(content)
        let title = UILabel(); title.text = "ssstore"; title.font = .preferredFont(forTextStyle: .title2)
        message.text = "正在读取分享链接…"; message.font = .preferredFont(forTextStyle: .headline)
        details.font = .preferredFont(forTextStyle: .body); details.textColor = .secondaryLabel
        for label in [title, message, details] { label.numberOfLines = 0; label.adjustsFontForContentSizeCategory = true }
        openButton.configuration = .filled(); openButton.setTitle("在 ssstore 中打开", for: .normal)
        openButton.addAction(UIAction { [weak self] _ in self?.openApp() }, for: .touchUpInside)
        copyButton.configuration = .plain(); copyButton.setTitle("复制应用链接", for: .normal)
        copyButton.addAction(UIAction { [weak self] _ in
            guard let self, let link else { return }
            UIPasteboard.general.string = link.storeURL.absoluteString
            message.text = "已复制应用链接"
            details.text = "打开 ssstore，在搜索页点击链接按钮即可查看。"
        }, for: .touchUpInside)
        let close = UIButton(type: .system); close.setTitle("完成", for: .normal)
        close.addAction(UIAction { [weak self] _ in self?.extensionContext?.completeRequest(returningItems: nil) }, for: .touchUpInside)
        for child in [title, message, details, openButton, copyButton, close] { content.addArrangedSubview(child) }
        openButton.isHidden = true; copyButton.isHidden = true
        let margins = view.layoutMarginsGuide
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: margins.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: margins.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: margins.topAnchor), scroll.bottomAnchor.constraint(equalTo: margins.bottomAnchor),
            content.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
            content.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            content.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            content.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor)
        ])
        load = Task { [weak self] in await self?.readLink() }
    }

    deinit { load?.cancel() }
    override func viewDidDisappear(_ animated: Bool) { super.viewDidDisappear(animated); load?.cancel() }

    private func readLink() async {
        let items = extensionContext?.inputItems as? [NSExtensionItem] ?? []
        for provider in items.flatMap({ $0.attachments ?? [] }) {
            for type in [UTType.url.identifier, UTType.plainText.identifier] where provider.hasItemConformingToTypeIdentifier(type) {
                let item = try? await provider.loadItem(forTypeIdentifier: type, options: nil)
                if Task.isCancelled { return }
                let text = (item as? URL)?.absoluteString ?? (item as? String) ?? (item as? Data).flatMap { String(data: $0, encoding: .utf8) }
                guard let text, let parsed = AppStoreLink.parse(text) else { continue }
                link = parsed
                message.text = "应用 ID：\(parsed.appID)"
                openButton.isHidden = false; copyButton.isHidden = false
                await loadProduct(parsed)
                return
            }
        }
        message.text = "未找到 App Store 应用链接"
        details.text = "请从 App Store 或浏览器分享应用页面。"
    }

    private func loadProduct(_ link: AppStoreLink) async {
        let country = link.country ?? Locale.current.region?.identifier ?? "US"
        do {
            let (data, response) = try await URLSession.shared.data(from: link.lookupURL(country: country))
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let product = try JSONDecoder().decode(Response.self, from: data).results.first,
                  product.trackId == link.appID else { throw ShareError.unavailable }
            try Task.checkCancellation()
            message.text = product.trackName
            details.text = [product.artistName, product.formattedPrice,
                product.version.map { "版本 \($0)" }, product.description].compactMap { $0 }.joined(separator: "\n\n")
        } catch {
            guard !Task.isCancelled else { return }
            details.text = "暂时无法载入应用介绍，仍可在 ssstore 中打开此链接。"
        }
    }

    private func openApp() {
        guard let link, let scene = view.window?.windowScene else { showCopyHint(); return }
        scene.open(link.deepLink, options: nil) { [weak self] opened in
            guard let self else { return }
            if opened { extensionContext?.completeRequest(returningItems: nil) }
            else { showCopyHint() }
        }
    }

    private func showCopyHint() {
        message.text = "当前 App 不允许直接跳转"
        details.text = "请复制应用链接，打开 ssstore 后在搜索页点击链接按钮。"
    }
}

private enum ShareError: Error { case unavailable }
