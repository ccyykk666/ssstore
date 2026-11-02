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
    init(_ model: AppModel, title: String, items: [(String, String)], select: @escaping (String) -> Void) { self.items = items; self.select = select; super.init(model, title: title) }
    required init?(coder: NSCoder) { fatalError() }
    override func rows() -> [NativeSection] {
        [NativeSection(rows: items.filter { query.isEmpty || $0.1.localizedCaseInsensitiveContains(query) || $0.0.localizedCaseInsensitiveContains(query) }.map { key, title in NativeRow(title: title, icon: icons[key], action: { [weak self] in guard let self else { return }; select(key); navigationController?.popViewController(animated: true) }) })]
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
    private var ids: [String] = []
    init(_ model: AppModel) { super.init(model, title: "已忽略应用") }
    required init?(coder: NSCoder) { fatalError() }
    override func rows() -> [NativeSection] {
        ids = model.ignoredApps.names.keys.sorted()
        return [NativeSection(rows: ids.map { id in NativeRow(title: model.ignoredApps.names[id] ?? id, detail: id, icon: model.localIconURL(for: model.ignoredApps.application(for: id)) ?? model.ignoredApps.iconURLs?[id]) })]
    }
    override func reload() {
        guard isViewLoaded else { return }
        let remaining = model.ignoredApps.bundleIDs
        if ids.count == remaining.count + 1, let removed = ids.firstIndex(where: { !remaining.contains($0) }) {
            sections = rows()
            tableView.deleteRows(at: [IndexPath(row: removed, section: 0)], with: .fade)
        } else { super.reload() }
    }
    override func tableView(_ tableView: UITableView, leadingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        guard !model.busy else { return nil }
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
            controls.append(NativeRow(title: "应用", detail: model.records.first(where: { $0.id == bundle })?.installed.name ?? "请选择", action: { [weak self] in guard let self else { return }; let include = UserDefaults.standard.bool(forKey: "includeSystemApps"); let apps = model.records.filter { include || !$0.installed.isSystem }; let picker = NativeChoices(model, title: "选择应用", items: apps.map { ($0.id, $0.installed.name) }) { [weak self] in self?.bundle = $0; self?.result = nil; self?.reload() }; picker.icons = Dictionary(uniqueKeysWithValues: apps.compactMap { record in self.model.localIconURL(for: record.installed).map { (record.id, $0) } }); push(picker) }))
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
        var rows = [link("预览") { [weak self] in guard let self else { return }; preview(file) }, link("导出") { [weak self] in guard let self else { return }; share(file) }]
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
