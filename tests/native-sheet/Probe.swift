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

    private func pause() async { try? await Task.sleep(for: .milliseconds(700)) }

    private func exercise(_ root: UIViewController) async {
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
        root.present(nav, animated: true)
        await pause()
        for iteration in 0..<3 {
            let index = IndexPath(row: 0, section: 3)
            settings.tableView.scrollToRow(at: index, at: .middle, animated: false)
            await pause()
            SheetTrace.shared.mark("tap-manifest-\(iteration)")
            settings.tableView(settings.tableView, didSelectRowAt: index)
            await pause()
            guard let manifest = pushed, nav.topViewController === manifest, nav.transitionCoordinator == nil else {
                SheetTrace.shared.mark("navigation-incomplete", status: "failed"); return
            }
            SheetTrace.shared.mark("manifest-visible-\(iteration)")
            let editor = UIAlertController(title: "清单服务地址", message: nil, preferredStyle: .alert)
            editor.addTextField { $0.text = address }
            editor.addAction(UIAlertAction(title: "取消", style: .cancel))
            manifest.present(editor, animated: true)
            await pause(); editor.dismiss(animated: true); await pause()
            SheetTrace.shared.mark("back-to-settings-\(iteration)")
            nav.popViewController(animated: true)
            await pause()
            guard nav.topViewController === settings, nav.transitionCoordinator == nil else {
                SheetTrace.shared.mark("return-incomplete", status: "failed"); return
            }
            if iteration == 0 { nav.traitOverrides.preferredContentSizeCategory = .accessibilityExtraExtraExtraLarge }
            if iteration == 1 { nav.overrideUserInterfaceStyle = .dark }
            await pause()
        }
        SheetTrace.shared.mark("dismiss-settings")
        nav.dismiss(animated: true)
        await pause()
        guard root.presentedViewController == nil else { SheetTrace.shared.mark("dismiss-incomplete", status: "failed"); return }
        // Standalone previews/progress sheets still use content fitting. Check
        // that those can measure and close without recursive layout as well.
        SheetTrace.shared.mark("present-single-fitting-sheet")
        let preview = SheetPage("预览", sections: [.init(title: "", rows: [("预览内容", "按内容适配")])])
        let fitting = NativeFittingNavigation(root: preview)
        root.present(fitting, animated: true)
        await pause()
        guard preview.measuredCount > 0 else { SheetTrace.shared.mark("fitting-not-measured", status: "failed"); return }
        SheetTrace.shared.mark("dismiss-single-fitting-sheet")
        fitting.dismiss(animated: true)
        await pause()
        guard root.presentedViewController == nil else { SheetTrace.shared.mark("fitting-dismiss-incomplete", status: "failed"); return }
        SheetTrace.shared.mark("finished", status: "passed")
    }
}
