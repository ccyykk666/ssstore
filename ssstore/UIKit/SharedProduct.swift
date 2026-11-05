import UIKit
import ApplePackage
import UpdateCore

@MainActor
final class NativeSharedProduct: NativePage {
    private struct Response: Decodable { let results: [ApplePackage.Software] }
    private let storeLink: AppStoreLink
    private let country: String
    private var request: Task<Void, Never>?
    private var failure: String?

    init(_ model: AppModel, link: AppStoreLink) {
        storeLink = link
        country = link.country ?? AppStore.this.possibleRegions.sorted().first ?? "US"
        super.init(model, title: "应用详情")
        navigationItem.largeTitleDisplayMode = .never
    }
    required init?(coder: NSCoder) { fatalError() }
    override func viewDidAppear(_ animated: Bool) { super.viewDidAppear(animated); if request == nil { loadProduct() } }
    override func viewDidDisappear(_ animated: Bool) { super.viewDidDisappear(animated); request?.cancel(); request = nil }
    override func rows() -> [NativeSection] {
        if let failure { return [NativeSection(rows: [NativeRow(title: failure, color: .secondaryLabel), link("重试") { [weak self] in self?.loadProduct() }])] }
        return [NativeSection(rows: [NativeRow(title: "正在载入应用信息…")])]
    }
    private func loadProduct() {
        request?.cancel(); failure = nil; reload()
        request = Task { [weak self] in
            guard let self else { return }
            do {
                let (data, response) = try await URLSession.shared.data(from: storeLink.lookupURL(country: country))
                guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw SharedProductError.unavailable }
                let result = try JSONDecoder().decode(Response.self, from: data)
                guard let software = result.results.first, software.id == storeLink.appID else { throw SharedProductError.unavailable }
                try Task.checkCancellation()
                guard let nav = navigationController, nav.topViewController === self else { return }
                let page = NativeProduct(model, package: AppStore.AppPackage(software: software, entityType: .iPhone), region: country)
                nav.setViewControllers(Array(nav.viewControllers.dropLast()) + [page], animated: false)
            } catch {
                guard !Task.isCancelled else { return }
                failure = "无法载入此地区的应用信息，请检查网络或稍后重试。"
                reload()
            }
        }
    }
}

private enum SharedProductError: Error { case unavailable }

extension NativeTabs {
    func openStoreLink(_ link: AppStoreLink) {
        loadViewIfNeeded()
        let open = { [self] in
            guard let nav = viewControllers?.last as? UINavigationController else { return }
            selectedViewController = nav
            store.search.isActive = false
            nav.setViewControllers([store, NativeSharedProduct(model, link: link)], animated: false)
        }
        if presentedViewController != nil { dismiss(animated: true, completion: open) } else { open() }
    }
}
