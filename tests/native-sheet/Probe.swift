import UIKit
import Darwin

@MainActor
final class SheetTrace {
    static let shared = SheetTrace()
    private var phase = "starting"
    private var measurements = 0
    private var events: [[String: Any]] = []
    private let file = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("probe.json")

    func mark(_ name: String, status: String = "running", detail: String = "") {
        events.append(["phase": phase, "measurements": measurements])
        phase = name; measurements = 0
        write(status: status, detail: detail)
    }

    func measured() {
        measurements += 1
        if measurements > 400 {
            write(status: "failed", detail: "Sheet measurements did not settle: " + Thread.callStackSymbols.prefix(100).joined(separator: "\n"))
            exit(72)
        }
    }

    private func write(status: String, detail: String) {
        let data = try! JSONSerialization.data(withJSONObject: ["status": status, "phase": phase,
            "measurements": measurements, "events": events, "detail": detail,
            "system": UIDevice.current.systemVersion], options: [.prettyPrinted, .sortedKeys])
        try! data.write(to: file, options: .atomic)
    }
}

@MainActor
final class SheetPage: UITableViewController, NativeSheetContent {
    struct Section { let title: String; let rows: [(String, String)] }
    let sections: [Section]
    var openManifest: (() -> Void)?
    private(set) var measuredCount = 0
    private(set) var appearances = 0
    var sheetScrollView: UIScrollView { tableView }
    var sheetContentHeight: CGFloat {
        measuredCount += 1
        SheetTrace.shared.measured()
        return tableView.contentSize.height
    }

    init(_ title: String, sections: [Section]) {
        self.sections = sections
        super.init(style: .insetGrouped)
        self.title = title
    }
    required init?(coder: NSCoder) { fatalError() }
    override func viewDidLoad() {
        super.viewDidLoad()
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = UITableView.automaticDimension
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "row")
    }
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // Same notification path as the production NativePage.
        (navigationController as? NativeFittingNavigation)?.updateContentSize()
    }
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        appearances += 1
    }
    override func numberOfSections(in tableView: UITableView) -> Int { sections.count }
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { sections[section].rows.count }
    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? { sections[section].title }
    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "row", for: indexPath)
        let row = sections[indexPath.section].rows[indexPath.row]
        var config = cell.defaultContentConfiguration()
        config.text = row.0; config.secondaryText = row.1
        config.textProperties.numberOfLines = 0; config.secondaryTextProperties.numberOfLines = 0
        config.textProperties.adjustsFontForContentSizeCategory = true
        config.secondaryTextProperties.adjustsFontForContentSizeCategory = true
        cell.contentConfiguration = config
        cell.accessoryType = .disclosureIndicator
        return cell
    }
    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        if sections[indexPath.section].rows[indexPath.row].0 == "清单服务" { openManifest?() }
    }
}

@main
@MainActor
final class ProbeDelegate: UIResponder, UIApplicationDelegate {
    func application(_ application: UIApplication, configurationForConnecting session: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let config = UISceneConfiguration(name: "Probe", sessionRole: session.role)
        config.delegateClass = ProbeScene.self
        return config
    }
}

@MainActor
final class ProbeScene: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions) {
        guard let scene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: scene)
        let root = UIViewController(); root.view.backgroundColor = .systemBackground
        window.rootViewController = root; self.window = window; window.makeKeyAndVisible()
        Task { await exercise(root) }
    }

    private func until(_ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(8))
        while !condition(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(50)) }
        return condition()
    }

    private func present(_ page: UIViewController, from parent: UIViewController) async {
        await withCheckedContinuation { continuation in
            parent.present(page, animated: true) { continuation.resume() }
        }
    }

    private func dismiss(_ page: UIViewController) async {
        await withCheckedContinuation { continuation in
            page.dismiss(animated: true) { continuation.resume() }
        }
    }

    private func exercise(_ root: UIViewController) async {
        guard exerciseListRendering() else { return }
        let address = "https://ssstore-install-manifest.kkkk0615.chatgpt.site/manifest.plist"
        let settings = SheetPage("设置", sections: [
            .init(title: "连接配置", rows: [("IP 地址", "10.7.0.1"), ("端口", "49152"), ("配对", "已配对")]),
            .init(title: "", rows: [("商店地区", "中国大陆优先")]),
            .init(title: "商店连接", rows: [("设备 GUID", "0123456789AB"), ("安装证书", ""), ("打开系统设置", "")]),
            .init(title: "兼容安装", rows: [("清单服务", address)]),
            .init(title: "下载管理", rows: [("删除全部下载", ""), ("重置商店数据", ""), ("日志", "")]),
            .init(title: "", rows: [("ssstore", "0.6.0")]),
        ])
        let nav = NativeSheetNavigation.settings(root: settings)
        settings.navigationItem.rightBarButtonItem = UIBarButtonItem(systemItem: .done, primaryAction: UIAction { _ in nav.dismiss(animated: true) })
        var pushed: SheetPage?
        settings.openManifest = { [weak nav] in
            let manifest = SheetPage("安装清单服务", sections: [
                .init(title: "", rows: [("服务地址", address), ("访问令牌", "默认公开服务无需设置"), ("测试连接", "")]),
                .init(title: "", rows: [("用于兼容安装。填写可直接访问的 HTTPS 清单接口，安装包仍在手机本机传输。私有服务需填写访问令牌，令牌仅保存在本机钥匙串并绑定当前完整地址，更换地址需单独配置。测试只发送示例数据。", "")]),
            ])
            pushed = manifest
            nav?.pushViewController(manifest, animated: true)
        }
        SheetTrace.shared.mark("present-settings")
        await present(nav, from: root)
        for iteration in 0..<3 {
            let index = IndexPath(row: 0, section: 3)
            settings.tableView.scrollToRow(at: index, at: .middle, animated: false)
            await Task.yield()
            SheetTrace.shared.mark("tap-manifest-\(iteration)")
            settings.tableView(settings.tableView, didSelectRowAt: index)
            guard let manifest = pushed, await until({ nav.topViewController === manifest && manifest.appearances > 0 }) else {
                SheetTrace.shared.mark("navigation-incomplete", status: "failed"); return
            }
            SheetTrace.shared.mark("manifest-visible-\(iteration)")
            let editor = UIAlertController(title: "清单服务地址", message: nil, preferredStyle: .alert)
            editor.addTextField { $0.text = address }
            editor.addAction(UIAlertAction(title: "取消", style: .cancel))
            await present(editor, from: manifest)
            await dismiss(editor)
            SheetTrace.shared.mark("back-to-settings-\(iteration)")
            let beforeReturn = settings.appearances
            nav.popViewController(animated: true)
            guard await until({ nav.topViewController === settings && settings.appearances > beforeReturn }) else {
                SheetTrace.shared.mark("return-incomplete", status: "failed"); return
            }
            if iteration == 0 { nav.traitOverrides.preferredContentSizeCategory = .accessibilityExtraExtraExtraLarge }
            if iteration == 1 { nav.overrideUserInterfaceStyle = .dark }
            await Task.yield()
        }
        SheetTrace.shared.mark("dismiss-settings")
        await dismiss(nav)
        guard root.presentedViewController == nil else { SheetTrace.shared.mark("dismiss-incomplete", status: "failed"); return }
        // Standalone previews/progress sheets still use content fitting. Check
        // that those can measure and close without recursive layout as well.
        SheetTrace.shared.mark("present-single-fitting-sheet")
        let preview = SheetPage("预览", sections: [.init(title: "", rows: [("预览内容", "按内容适配")])])
        let fitting = NativeFittingNavigation(root: preview)
        await present(fitting, from: root)
        guard await until({ preview.measuredCount > 0 }) else { SheetTrace.shared.mark("fitting-not-measured", status: "failed"); return }
        SheetTrace.shared.mark("dismiss-single-fitting-sheet")
        await dismiss(fitting)
        guard root.presentedViewController == nil else { SheetTrace.shared.mark("fitting-dismiss-incomplete", status: "failed"); return }
        SheetTrace.shared.mark("finished", status: "passed")
    }

    private func exerciseListRendering() -> Bool {
        SheetTrace.shared.mark("list-icon-lifecycle")
        let state = NativeIconState()
        var completions: [(UIImage?) -> Void] = [], cancellations = 0, delivered = 0
        let loader: NativeIconState.Loader = { _, completion in
            completions.append(completion); return { cancellations += 1 }
        }
        func require(_ condition: Bool, _ message: String) -> Bool {
            if !condition { SheetTrace.shared.mark("list-regression", status: "failed", detail: message) }
            return condition
        }
        let first = NativeIconRequest(url: URL(string: "https://example.com/a.png")!, size: 46, scale: 3)
        let next = NativeIconRequest(url: URL(string: "https://example.com/b.png")!, size: 46, scale: 3)
        for _ in 0..<50 { _ = state.update(first, load: loader) { _ in delivered += 1 } }
        guard require(completions.count == 1 && cancellations == 0, "Progress refresh restarted an in-flight icon") else { return false }
        _ = state.update(next, load: loader) { _ in delivered += 1 }
        completions[0](UIImage())
        guard require(state.image == nil && delivered == 0 && cancellations == 1, "Reused request accepted a stale callback") else { return false }
        let loaded = UIImage()
        completions[1](loaded)
        for _ in 0..<50 { _ = state.update(next, load: loader) { _ in delivered += 1 } }
        guard require(completions.count == 2 && state.image === loaded && delivered == 1, "Loaded icon decoded again during text/progress updates") else { return false }
        state.reset()
        guard require(state.image == nil, "Reset retained the decoded image") else { return false }
        _ = state.update(first, load: loader) { _ in delivered += 1 }
        state.reset(); completions[2](UIImage())
        guard require(state.image == nil && delivered == 1 && cancellations == 2, "Cancelled icon updated a reused cell") else { return false }
        _ = state.update(first, load: { _, done in done(loaded); return { cancellations += 1 } }) { _ in delivered += 1 }
        state.reset()
        guard require(cancellations == 2, "Synchronously completed cache result retained cancellation") else { return false }
        _ = state.update(first, load: loader) { _ in }
        completions[3](nil)
        _ = state.update(first, load: loader) { _ in }
        guard require(completions.count == 5, "Failed request could not be retried") else { return false }
        state.reset()
        let cell = NativeCell(style: .subtitle, reuseIdentifier: "test")
        var configuration = cell.defaultContentConfiguration(); configuration.image = loaded; cell.contentConfiguration = configuration
        cell.prepareForReuse()
        guard require((cell.contentConfiguration as? UIListContentConfiguration)?.image == nil, "Reusable cell retained previous icon") else { return false }
        let progress = NativeProgressFill(frame: CGRect(x: 0, y: 0, width: 200, height: 40))
        progress.update(0.5); progress.layoutIfNeeded()
        guard require(progress.subviews.first?.frame.width == 100, "First progress value animated from a reused row's origin") else { return false }
        progress.update(.nan); progress.layoutIfNeeded()
        guard require(progress.subviews.first?.frame.width == 0, "Invalid progress produced invalid geometry") else { return false }
        progress.update(0.75); progress.reset()
        return require(progress.subviews.first?.frame.width == 0, "Progress reuse retained old width")
    }
}
