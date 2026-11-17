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
final class NativeChoices: NativeSearchPage {
    let items: [(String, String)]
    let select: (String) -> Void
    var icons: [String: URL] = [:]
    var compact = false
    init(_ model: AppModel, title: String, items: [(String, String)], select: @escaping (String) -> Void) { self.items = items; self.select = select; super.init(model, title: title) }
    required init?(coder: NSCoder) { fatalError() }
    override func rows() -> [NativeSection] {
        [NativeSection(rows: items.filter { query.isEmpty || $0.1.localizedCaseInsensitiveContains(query) || $0.0.localizedCaseInsensitiveContains(query) }.map { key, title in NativeRow(title: title, icon: icons[key], action: { [weak self] in guard let self else { return }; select(key); navigationController?.popViewController(animated: true) }, compact: compact) })]
    }
}

@MainActor
final class NativeSettings: NativePage, UIDocumentPickerDelegate {
    private var clearingCache = false
    private var cacheStatus = ""
    init(_ model: AppModel) { super.init(model, title: "设置") }
    required init?(coder: NSCoder) { fatalError() }
    override func rows() -> [NativeSection] {
        var sections = [
            NativeSection(rows: [NativeRow(title: "商店地区", detail: StoreRegionNames.name(model.country), action: { [weak self] in
                guard let self else { return }
                let items = [(StoreQueryPolicy.chinaThenUS, "中国大陆优先")] + ApplePackage.Configuration.storeFrontValues.keys.sorted().map {
                    ($0.lowercased(), "\(StoreRegionNames.name($0))  \($0)")
                }
                push(NativeChoices(model, title: "商店地区", items: items) { [weak self] in
                    self?.model.country = $0; self?.reload()
                })
            })]),
            NativeSection(title: "连接配置", rows: [
                NativeRow(title: "IP 地址", detail: model.host, action: { [weak self] in
                    guard let self else { return }
                    edit("IP 地址", value: model.host) { [weak self] in self?.model.host = $0; self?.reload() }
                }),
                NativeRow(title: "端口", detail: model.port, action: { [weak self] in
                    guard let self else { return }
                    edit("端口", value: model.port) { [weak self] in self?.model.port = $0; self?.reload() }
                }),
                NativeRow(title: "配对", detail: model.hasPairing ? "已配对" : "未配对", action: { [weak self] in
                    guard let self else { return }; push(NativePairing(model))
                }),
            ]),
            NativeSection(title: "兼容安装", rows: [
                NativeRow(title: "清单服务", detail: InstallerManifestService.displayAddress, action: { [weak self] in
                    guard let self else { return }; push(NativeManifestService(model))
                }),
            ]),
            NativeSection(title: "下载管理", rows: [
                NativeRow(title: clearingCache ? "正在清理缓存…" : (cacheStatus.isEmpty ? "清理缓存" : cacheStatus),
                    color: .systemBlue, action: working || model.busy ? nil : { [weak self] in self?.clearCache() }),
                NativeRow(title: "删除全部下载", color: .systemRed, action: { [weak self] in
                    self?.confirm("删除全部下载？") { Downloads.this.removeAll() }
                }),
                NativeRow(title: "重置商店数据", color: .systemRed, action: { [weak self] in
                    self?.confirm("重置商店数据后需要重启 App") { [weak self] in
                        do {
                            Downloads.this.removeAll()
                            try FileManager.default.removeItem(at: documentsDirectory)
                            self?.alert("已重置，请关闭并重新打开 App。")
                        } catch { self?.alert(error.localizedDescription) }
                    }
                }),
            ]),
        ]
        if !model.ignoredApps.visibleBundleIDs.isEmpty { sections.append(NativeSection(rows: [link("已忽略应用") { [weak self] in guard let self else { return }; push(NativeIgnored(model)) }])) }
        sections.append(NativeSection(title: "关于", rows: [link("日志") { [weak self] in guard let self else { return }; push(NativeLogs(model)) }, link("开源许可") { [weak self] in guard let self else { return }; let text = ["AssppLicense", "AssppWebLicense", "IDeviceLicense"].compactMap { Bundle.main.url(forResource: $0, withExtension: "txt") }.compactMap { try? String(contentsOf: $0, encoding: .utf8) }.joined(separator: "\n\n"); push(NativeText(model, title: "开源许可", text: text)) }, NativeRow(title: "ssstore", detail: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "")]))
        return sections
    }
    private func clearCache() {
        guard !working, !model.busy else { return }
        let protected = model.protectedCacheFiles
        let ids = Set(Downloads.this.manifests.map(\.id))
        cacheStatus = ""
        clearingCache = true
        run { [self] in
            defer { clearingCache = false }
            do {
                try await AppCacheCleaner.clear(keeping: protected, downloadIDs: ids)
                cacheStatus = "缓存已清理"
            } catch {
                cacheStatus = "清理失败：\(error.localizedDescription)"
            }
        }
    }
}
@MainActor
final class NativeIgnored: NativePage {
    private var ids: [String] = []
    private var refreshedInventory = false
    init(_ model: AppModel) { super.init(model, title: "已忽略应用") }
    required init?(coder: NSCoder) { fatalError() }
    override func viewDidLoad() {
        super.viewDidLoad()
        navigationItem.rightBarButtonItem = UIBarButtonItem(systemItem: .refresh, primaryAction: UIAction { [weak self] _ in self?.refreshInventory() })
    }
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if !refreshedInventory { refreshInventory() }
    }
    private func refreshInventory() {
        guard !working, !model.busy, model.hasPairing else { return }
        refreshedInventory = true
        run { [self] in _ = await model.scan() }
    }
    override func rows() -> [NativeSection] {
        ids = model.ignoredApps.visibleBundleIDs.sorted()
        if ids.isEmpty { return [NativeSection(rows: [NativeRow(title: "暂无已忽略应用", color: .secondaryLabel)])] }
        return [NativeSection(rows: ids.map { id in NativeRow(title: model.ignoredApps.names[id] ?? id, detail: id, icon: model.localIconURL(for: model.ignoredApps.application(for: id)) ?? model.ignoredApps.iconURLs?[id], compact: true) })]
    }
    override func reload() {
        guard isViewLoaded else { return }
        navigationItem.rightBarButtonItem?.isEnabled = !working && !model.busy && model.hasPairing
        super.reload()
    }
    override func tableView(_ tableView: UITableView, trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        guard !working, !model.busy, ids.indices.contains(indexPath.row) else { return nil }
        let id = ids[indexPath.row]
        let restore = UIContextualAction(style: .normal, title: "恢复") { [weak self] _, _, completion in
            guard let self else { completion(false); return }
            model.restoreApp(id)
            completion(model.ignoredApps.names[id] == nil)
        }
        restore.backgroundColor = .systemGreen
        return UISwipeActionsConfiguration(actions: [restore])
    }
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
        var rows = [NativeRow(title: "状态", detail: model.hasPairing ? "已配对" : "未配对")]
        if controller.isActive || controller.phase == .failed { rows.append(NativeRow(title: controller.status)) }
        if let pin = controller.pin { rows.append(link("配对码：\(pin)") { UIPasteboard.general.string = pin }) }
        if controller.isActive { rows.append(link("停止配对") { controller.cancel() }) }
        else { rows.append(link(model.hasPairing ? "重新配对" : "创建配对") { [weak self] in self?.model.createPairingOnDevice() }) }
        rows.append(link("导入配对文件") { [weak self] in guard let self else { return }; let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.item], asCopy: true); picker.delegate = self; present(picker, animated: true) })
        if model.hasPairing {
            rows.append(link("导出配对文件") { [weak self] in guard let self else { return }; do { let file = temporaryDirectory.appendingPathComponent("ssstore-pairing.plist"); try model.pairingDataForExport().write(to: file, options: [.atomic, .completeFileProtection]); let picker = UIDocumentPickerViewController(forExporting: [file], asCopy: true); present(picker, animated: true) } catch { alert(error.localizedDescription) } })
            rows.append(NativeRow(title: "删除配对文件", color: .systemRed, action: { [weak self] in self?.confirm("删除配对文件？") { [weak self] in self?.model.removePairing() } }))
        }
        var sections = [NativeSection(rows: rows)]
        if !model.hasPairing || controller.isActive {
            sections.append(NativeSection(title: model.hasPairing ? "重新配对" : "创建配对", rows: [NativeRow(title: "开始配对后，前往系统设置 → 隐私与安全 → 开发者模式，选择 ssstore，输入配对码后返回。")]))
        }
        if !controller.diagnostics.isEmpty { sections.append(NativeSection(title: "配对日志", rows: controller.diagnostics.map { NativeRow(title: $0) })) }
        return sections
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
final class NativeLogs: UIViewController, NativeSheetContent, UITextViewDelegate {
    private let textView = UITextView()
    private var observer: NSObjectProtocol?
    private var updateTask: Task<Void, Never>?
    private var feedbackTask: Task<Void, Never>?
    private var renderedRevision: UInt64?
    private var didScrollToLatest = false
    var sheetScrollView: UIScrollView { textView }
    var sheetContentHeight: CGFloat { textView.contentSize.height }
    init(_ model: AppModel) { super.init(nibName: nil, bundle: nil); title = "日志" }
    required init?(coder: NSCoder) { fatalError() }
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemGroupedBackground
        textView.backgroundColor = .clear
        textView.isEditable = false
        textView.isSelectable = true
        textView.delegate = self
        textView.font = UIFontMetrics(forTextStyle: .footnote).scaledFont(for: .monospacedSystemFont(ofSize: 13, weight: .regular))
        textView.adjustsFontForContentSizeCategory = true
        textView.textColor = .label
        textView.textContainer.lineFragmentPadding = 0
        textView.textContainerInset = UIEdgeInsets(top: 16, left: 20, bottom: 20, right: 20)
        textView.alwaysBounceVertical = true
        textView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(textView)
        NSLayoutConstraint.activate([
            textView.topAnchor.constraint(equalTo: view.topAnchor), textView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            textView.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            textView.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
        ])
        let copy = UIBarButtonItem(image: UIImage(systemName: "doc.on.doc"), primaryAction: UIAction(title: "复制全部日志") { [weak self] _ in self?.copyLogs() })
        copy.accessibilityLabel = "复制全部日志"
        navigationItem.rightBarButtonItem = copy
        observer = NotificationCenter.default.addObserver(forName: LogManager.didChange, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.scheduleRefresh() }
        }
    }
    override func viewWillAppear(_ animated: Bool) { super.viewWillAppear(animated); refresh() }
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if !didScrollToLatest {
            didScrollToLatest = true
            textView.scrollRangeToVisible(NSRange(location: (textView.text as NSString).length, length: 0))
        }
    }
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        (navigationController as? NativeFittingNavigation)?.updateContentSize()
    }
    deinit {
        updateTask?.cancel(); feedbackTask?.cancel()
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }
    private func scheduleRefresh() {
        guard viewIfLoaded?.window != nil, updateTask == nil else { return }
        updateTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            self?.updateTask = nil
            self?.refresh()
        }
    }
    private func report(_ messages: [String]) -> String {
        DiagnosticLog.report(messages: messages,
            version: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?",
            build: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?",
            system: "\(UIDevice.current.systemName) \(UIDevice.current.systemVersion)",
            device: UIDevice.current.model, capacity: LogManager.maxMessages)
    }
    private func refresh() {
        guard isViewLoaded, textView.selectedRange.length == 0 else { return }
        let snapshot = LogManager.shared.snapshot()
        guard renderedRevision != snapshot.revision else { return }
        let oldOffset = textView.contentOffset
        let nearBottom = oldOffset.y + textView.bounds.height >= textView.contentSize.height + textView.adjustedContentInset.bottom - 24
        let firstRender = renderedRevision == nil
        renderedRevision = snapshot.revision
        textView.text = report(snapshot.messages)
        textView.layoutIfNeeded()
        if firstRender || nearBottom {
            textView.scrollRangeToVisible(NSRange(location: (textView.text as NSString).length, length: 0))
        } else { textView.setContentOffset(oldOffset, animated: false) }
        (navigationController as? NativeFittingNavigation)?.updateContentSize()
    }
    func textViewDidChangeSelection(_ textView: UITextView) {
        if textView.selectedRange.length == 0 { scheduleRefresh() }
    }
    private func copyLogs() {
        // Always take a new snapshot, even while the user is selecting older text.
        UIPasteboard.general.string = report(LogManager.shared.getMessages())
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        UIAccessibility.post(notification: .announcement, argument: "已复制全部日志")
        navigationItem.rightBarButtonItem?.image = UIImage(systemName: "checkmark")
        feedbackTask?.cancel()
        feedbackTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            self?.navigationItem.rightBarButtonItem?.image = UIImage(systemName: "doc.on.doc")
        }
    }
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
    var source: String?
    var result: InspectionResult?
    var report: URL?
    var failure: String?
    init(_ model: AppModel, operation: InspectionOperation, bundle: String = "", path: String = "/", source: String? = nil) { self.operation = operation; self.bundle = bundle; self.path = path; self.source = source; super.init(model, title: operation.title); navigationItem.largeTitleDisplayMode = .never }
    required init?(coder: NSCoder) { fatalError() }
    override func rows() -> [NativeSection] {
        var controls: [NativeRow] = []
        if !operation.note.isEmpty { controls.append(NativeRow(title: operation.note)) }
        if operation.requiresApp {
            controls.append(NativeRow(title: "应用", detail: model.records.first(where: { $0.id == bundle })?.installed.name ?? (bundle.isEmpty ? "请选择" : bundle), action: { [weak self] in guard let self else { return }; let include = UserDefaults.standard.bool(forKey: "includeSystemApps"); let apps = model.records.filter { include || !$0.installed.isSystem }; let picker = NativeChoices(model, title: "选择应用", items: apps.map { ($0.id, $0.installed.name) }) { [weak self] in self?.bundle = $0; self?.result = nil; self?.reload() }; picker.compact = true; picker.icons = Dictionary(uniqueKeysWithValues: apps.compactMap { record in self.model.localIconURL(for: record.installed).map { (record.id, $0) } }); push(picker) }))
        }
        if operation.isBrowser || operation.isFileHelper { controls.append(NativeRow(title: "路径", detail: path, action: { [weak self] in guard let self else { return }; edit("路径", value: path) { [weak self] in self?.path = $0; self?.result = nil; self?.reload() } })) }
        controls.append(NativeRow(title: working ? "正在读取…" : "读取", color: .systemBlue, action: working || model.busy ? nil : { [weak self] in self?.read() }))
        var sections = [NativeSection(rows: controls)]
        if let failure { sections.append(NativeSection(rows: [NativeRow(title: failure, color: .systemOrange)])) }
        if let result {
            if !result.entries.isEmpty {
                sections.append(NativeSection(title: "目录", rows: result.entries.map { entry in NativeRow(title: entry.name, action: { [weak self] in
                    guard let self else { return }
                    let page = NativeInspection(model, operation: .fileInfo, bundle: bundle, path: entry.path, source: operation.rawValue)
                    push(page); page.read()
                }) }))
            }
            if operation == .fileInfo {
                if result.value["isDirectory"] == .bool(true), let source, let browser = InspectionOperation(rawValue: source) {
                    sections.append(NativeSection(rows: [link("打开目录") { [weak self] in guard let self else { return }; let page = NativeInspection(model, operation: browser, bundle: bundle, path: path); push(page); page.read() }]))
                } else { sections.append(NativeSection(rows: [link("读取文件") { [weak self] in guard let self else { return }; let page = NativeInspection(model, operation: .fileRead, bundle: bundle, path: path, source: source); push(page); page.read() }])) }
            }
            if !result.files.isEmpty { sections.append(NativeSection(title: "文件", rows: result.files.flatMap { file in [link(file.name) { [weak self] in self?.preview(URL(fileURLWithPath: file.path)) }, link("导出 \(file.name)") { [weak self] in self?.share(URL(fileURLWithPath: file.path)) }] })) }
            if let message = result.message, result.files.isEmpty, result.entries.isEmpty {
                sections.append(NativeSection(rows: [NativeRow(title: message, color: .secondaryLabel)]))
            }
            let values = valueRows(result.value)
            if !values.isEmpty { sections.append(NativeSection(rows: values)) }
            else if result.message == nil, result.files.isEmpty, result.entries.isEmpty {
                sections.append(NativeSection(rows: [NativeRow(title: "暂无数据", color: .secondaryLabel)]))
            }
            if let report { sections.append(NativeSection(rows: [link("导出 JSON 报告") { [weak self] in self?.share(report) }])) }
        }
        return sections
    }
    func valueRows(_ value: InspectionValue) -> [NativeRow] { NativeValues.makeRows(value, owner: self) }
    func read() {
        guard !working else { return }; working = true; failure = nil; result = nil; report = nil; reload()
        Task { [self] in
            do { let output = try await model.inspect(operation, bundleID: bundle, path: path, source: source); result = output.0; report = output.1 }
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
    init(_ model: AppModel, file: URL, prefix: String = "", entries: [Entry] = []) { self.file = file; self.prefix = prefix; self.entries = entries; super.init(model, title: "安装包内容") }
    required init?(coder: NSCoder) { fatalError() }
    override func viewDidLoad() {
        super.viewDidLoad()
        if entries.isEmpty {
            run { [self] in
                entries = try await Task.detached(priority: .userInitiated) { [file] in
                    Array(try Archive(url: file, accessMode: .read))
                }.value
            }
        }
    }
    override func rows() -> [NativeSection] {
        let rows = entries.filter { entry in
            let stripped = entry.path.hasSuffix("/") ? String(entry.path.dropLast()) : entry.path
            let parent = (stripped as NSString).deletingLastPathComponent
            return parent == prefix && (query.isEmpty || entry.path.localizedCaseInsensitiveContains(query))
        }.map { entry in NativeRow(title: (entry.path as NSString).lastPathComponent, action: { [weak self] in
            guard let self else { return }
            if entry.type == .directory { push(NativeArchiveFiles(model, file: file, prefix: entry.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")), entries: entries)) }
            else if entry.type == .file {
                run {
                    let file = self.file
                    let output = temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension((entry.path as NSString).pathExtension)
                    try await Task.detached(priority: .userInitiated) {
                        let archive = try Archive(url: file, accessMode: .read)
                        _ = try archive.extract(entry, to: output)
                    }.value
                    self.push(NativeExtractedFile(self.model, file: output))
                }
            }
        }) }
        return [NativeSection(rows: rows)]
    }
}
@MainActor
final class NativeExtractedFile: NativePage {
    let file: URL
    private var size: Int64?
    private var plist: String?
    init(_ model: AppModel, file: URL) { self.file = file; super.init(model, title: file.lastPathComponent) }
    required init?(coder: NSCoder) { fatalError() }
    override func viewDidLoad() {
        super.viewDidLoad()
        run { [self] in
            (size, plist) = await Task.detached(priority: .userInitiated) { [file] in
                let attributes = try? FileManager.default.attributesOfItem(atPath: file.path)
                let bytes = (attributes?[.size] as? NSNumber)?.int64Value
                var text: String?
                if ["plist", "strings", "entitlements"].contains(file.pathExtension.lowercased()),
                   let data = try? Data(contentsOf: file),
                   let value = try? PropertyListSerialization.propertyList(from: data, format: nil) {
                    text = String(describing: value)
                }
                return (bytes, text)
            }.value
        }
    }
    override func rows() -> [NativeSection] {
        var rows = [link("查看内容") { [weak self] in guard let self else { return }; push(NativeFileContents(model: model, file: file, name: file.lastPathComponent)) }, link("预览") { [weak self] in guard let self else { return }; preview(file) }, link("导出") { [weak self] in guard let self else { return }; share(file) }]
        if let size { rows.append(NativeRow(title: "大小", detail: ByteCountFormatter.string(fromByteCount: size, countStyle: .file))) }
        if let plist { rows.append(NativeRow(title: plist)) }
        return [NativeSection(rows: rows)]
    }
}

@MainActor
enum StoreRegionNames {
    static func name(_ code: String) -> String {
        if code == StoreQueryPolicy.chinaThenUS { return "中国大陆优先" }
        return Locale(identifier: "zh_Hans_CN").localizedString(forRegionCode: code.uppercased()) ?? code.uppercased()
    }
}
extension ApplePackage.EntityType {
    var iconName: String {
        switch self { case .iPhone: "iphone"; case .iPad: "ipad"; case .appleTV: "appletv" }
    }
}
