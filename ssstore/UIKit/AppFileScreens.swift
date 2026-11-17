import UIKit
import UniformTypeIdentifiers
import UpdateCore
import ApplePackage

@MainActor
final class NativeAppFilesHome: NativePage {
    private var attemptedLoad = false
    private var applications: [PerformanceApplication] = []
    init(_ model: AppModel) { super.init(model, title: "应用文件") }
    required init?(coder: NSCoder) { fatalError() }
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if !attemptedLoad { attemptedLoad = true; refreshApplications() }
    }
    override func viewDidLoad() {
        super.viewDidLoad()
        navigationItem.rightBarButtonItem = UIBarButtonItem(systemItem: .refresh, primaryAction: UIAction { [weak self] _ in self?.refreshApplications() })
    }
    override func rows() -> [NativeSection] {
        return [NativeSection(rows: [NativeRow(title: working ? "正在读取应用…" : "选择应用", detail: applications.isEmpty ? "先读取设备上的应用列表" : "\(applications.count) 个应用", action: working ? nil : { [weak self] in
            guard let self else { return }
            if applications.isEmpty { refreshApplications(); return }
            push(NativeApplicationPicker(model, applications: applications, dismissOnSelection: false) { [weak self] app in
                guard let self else { return }; push(NativeAppFileLocations(model, application: app))
            })
        })])]
    }
    private func refreshApplications() {
        guard !working else { return }
        run { [self] in
            do {
                applications = PerformanceApplication.fromInstalledApplications(try await model.inspect(.installedApps).0.value)
            } catch {
                if model.records.isEmpty { _ = await model.scan() }
                applications = model.records.map { PerformanceApplication(bundleID: $0.id, name: $0.installed.name) }
                if applications.isEmpty { throw error }
            }
        }
    }
    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        "可浏览应用授权的文档和容器；访问权限由设备与应用决定。"
    }
}

@MainActor
final class NativeAppFileLocations: NativePage {
    let application: PerformanceApplication
    init(_ model: AppModel, application: PerformanceApplication) {
        self.application = application; super.init(model, title: application.name.isEmpty ? application.bundleID : application.name)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func rows() -> [NativeSection] {
        var sections = [NativeSection(rows: [NativeRow(title: application.bundleID)]), NativeSection(rows: [
            NativeRow(title: "共享文档", action: { [weak self] in self?.open(.documents) }),
            NativeRow(title: "应用容器", action: { [weak self] in self?.open(.container) }),
        ])]
        if let package = Downloads.this.manifests.filter({ $0.completed && $0.package.software.bundleID == application.bundleID }).sorted(by: { $0.creation > $1.creation }).first {
            sections.append(NativeSection(title: "本机已下载的 IPA", rows: [NativeRow(title: "安装包内容", action: { [weak self] in
                guard let self else { return }; push(NativeArchiveFiles(model, file: package.targetLocation))
            })]))
        }
        return sections
    }
    private func open(_ source: InspectionOperation) {
        push(NativeAppDirectory(model, application: application, source: source))
    }
    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        section == 1 ? "共享文档通常需要应用启用文件共享；完整容器需要设备服务允许访问。已下载 IPA 的包内文件仍可在下载详情中浏览。" : nil
    }
}

@MainActor
final class NativeAppDirectory: NativeSearchPage {
    private let application: PerformanceApplication
    private let source: InspectionOperation
    private let path: String
    private var entries: [RemoteInspectionEntry] = []
    private var displayed: [RemoteInspectionEntry] = []
    private var failure: String?
    private var loaded = false
    private var hasDirectoryListing = false
    private var canTryDeveloperFiles = false
    init(_ model: AppModel, application: PerformanceApplication, source: InspectionOperation, path: String = "/") {
        self.application = application; self.source = source; self.path = path
        super.init(model, title: path == "/" ? source.title : (path as NSString).lastPathComponent)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func viewDidLoad() {
        super.viewDidLoad()
        navigationItem.rightBarButtonItem = UIBarButtonItem(systemItem: .refresh, primaryAction: UIAction { [weak self] _ in self?.load() })
    }
    override func viewDidAppear(_ animated: Bool) { super.viewDidAppear(animated); if !loaded { loaded = true; load() } }
    override func rows() -> [NativeSection] {
        displayed = entries.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }.sorted {
            if ($0.isDirectory == true) != ($1.isDirectory == true) { return $0.isDirectory == true }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        let summary = working ? "正在读取…" : !hasDirectoryListing ? (failure == nil ? "尚未读取" : "读取失败") : "\(entries.count) 项"
        var status = [NativeRow(title: path, detail: summary)]
        if let failure { status.append(NativeRow(title: failure, color: .systemOrange)) }
        let files = displayed.map { entry in
            NativeRow(title: entry.name, detail: entry.isDirectory == true ? "文件夹" : entry.size.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "",
                action: working ? nil : { [weak self] in self?.open(entry) })
        }
        var sections = [NativeSection(rows: status)]
        if hasDirectoryListing {
            sections.append(NativeSection(rows: files.isEmpty ? [NativeRow(title: entries.isEmpty ? "没有文件" : "没有匹配的文件")] : files))
        } else if !working, failure != nil {
            var actions = [NativeRow(title: "重试", color: .systemBlue, action: { [weak self] in self?.load() })]
            if canTryDeveloperFiles {
                actions.append(NativeRow(title: "尝试开发者文件目录", color: .systemBlue, action: { [weak self] in
                    guard let self else { return }
                    // Keep the alternate service explicit. A successful directory
                    // list does not imply permission to read arbitrary files.
                    let page = NativeInspection(model, operation: .coreFiles, bundle: application.bundleID)
                    push(page); page.read()
                }))
            }
            sections.append(NativeSection(rows: actions))
        }
        return sections
    }
    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = super.tableView(tableView, cellForRowAt: indexPath)
        if indexPath.section == 1, displayed.indices.contains(indexPath.row), var config = cell.contentConfiguration as? UIListContentConfiguration {
            let entry = displayed[indexPath.row]
            config.image = UIImage(systemName: entry.isDirectory == true ? "folder.fill" : entry.type == "S_IFLNK" ? "link" : "doc")
            config.imageProperties.tintColor = entry.isDirectory == true ? .systemBlue : .secondaryLabel
            cell.contentConfiguration = config
        }
        return cell
    }
    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        section == 1 ? "文件只读。单文件读取上限 32 MB，可预览文本、键值、图片，或导出原文件。" : nil
    }
    private func load() {
        guard !working else { return }
        working = true; failure = nil; hasDirectoryListing = false; canTryDeveloperFiles = false; entries = []; reload()
        Task { [self] in
            defer { working = false; reload() }
            do {
                entries = try await model.inspect(source, bundleID: application.bundleID, path: path, entryDetails: true).0.entries
                hasDirectoryListing = true
            } catch {
                failure = error.localizedDescription
                let nativeError = error as NSError
                canTryDeveloperFiles = nativeError.domain == "ssstore.AppFiles" &&
                    (nativeError.userInfo["applicationFound"] as? Bool == true)
            }
        }
    }
    private func open(_ entry: RemoteInspectionEntry) {
        guard !working, let child = RemoteFilePath.child(entry.name, of: path) else { return }
        working = true; failure = nil; reload()
        Task { [self] in
            defer { working = false; reload() }
            do {
                var directory = entry.isDirectory
                var type = entry.type
                if directory == nil {
                    let info = try await model.inspect(.fileInfo, bundleID: application.bundleID, path: child, source: source.rawValue).0
                    directory = info.value["isDirectory"] == .bool(true); type = info.value["type"]?.string
                }
                guard view.window != nil else { return }
                if directory == true { push(NativeAppDirectory(model, application: application, source: source, path: child)); return }
                if type != "S_IFREG" {
                    let info = try await model.inspect(.fileInfo, bundleID: application.bundleID, path: child, source: source.rawValue).0
                    push(NativeValues(model, title: entry.name, value: info.value)); return
                }
                let output = try await model.inspect(.fileRead, bundleID: application.bundleID, path: child, source: source.rawValue).0
                guard let file = output.files.first, view.window != nil else { return }
                let url = URL(fileURLWithPath: file.path)
                let kind = UTType(filenameExtension: url.pathExtension)
                if kind?.conforms(to: .image) == true || kind?.conforms(to: .pdf) == true || kind?.conforms(to: .audiovisualContent) == true {
                    let preview = NativePreview(url)
                    preview.navigationItem.rightBarButtonItem = UIBarButtonItem(systemItem: .done, primaryAction: UIAction { [weak preview] _ in preview?.dismiss(animated: true) })
                    present(UINavigationController(rootViewController: preview), animated: true)
                }
                else { push(NativeFileContents(model: model, file: url, name: entry.name)) }
            } catch { failure = error.localizedDescription }
        }
    }
}

@MainActor
final class NativeFileContents: UIViewController {
    private let model: AppModel
    private let file: URL
    private let textView = UITextView()
    private let format = UISegmentedControl(items: ["文本", "十六进制"])
    private let notice = UILabel()
    private var content: FileContentPreview?
    init(model: AppModel, file: URL, name: String) { self.model = model; self.file = file; super.init(nibName: nil, bundle: nil); title = name }
    required init?(coder: NSCoder) { fatalError() }
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemGroupedBackground
        format.selectedSegmentIndex = 0
        format.addAction(UIAction { [weak self] _ in self?.render() }, for: .valueChanged)
        textView.isEditable = false; textView.isSelectable = true; textView.backgroundColor = .clear; textView.textColor = .label
        textView.font = UIFontMetrics(forTextStyle: .footnote).scaledFont(for: .monospacedSystemFont(ofSize: 13, weight: .regular))
        textView.adjustsFontForContentSizeCategory = true; textView.text = "正在读取…"
        notice.font = .preferredFont(forTextStyle: .footnote); notice.adjustsFontForContentSizeCategory = true
        notice.textColor = .secondaryLabel; notice.numberOfLines = 0
        let controls = UIStackView(arrangedSubviews: [format, notice]); controls.axis = .vertical; controls.spacing = 10
        controls.translatesAutoresizingMaskIntoConstraints = false; textView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(controls); view.addSubview(textView)
        let safe = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([controls.leadingAnchor.constraint(equalTo: safe.leadingAnchor, constant: 16),
            controls.trailingAnchor.constraint(equalTo: safe.trailingAnchor, constant: -16), controls.topAnchor.constraint(equalTo: safe.topAnchor, constant: 12),
            textView.topAnchor.constraint(equalTo: controls.bottomAnchor, constant: 8), textView.leadingAnchor.constraint(equalTo: safe.leadingAnchor, constant: 12),
            textView.trailingAnchor.constraint(equalTo: safe.trailingAnchor, constant: -12), textView.bottomAnchor.constraint(equalTo: safe.bottomAnchor)])
        configureMenu()
        Task { [weak self, file] in
            do {
                let result = try await Task.detached(priority: .userInitiated) { try FileContentPreview.load(file) }.value
                guard let self else { return }; content = result
                format.setEnabled(result.text != nil, forSegmentAt: 0)
                format.selectedSegmentIndex = result.text == nil ? 1 : 0
                configureMenu(); render()
            } catch { self?.textView.text = error.localizedDescription }
        }
    }
    private func render() {
        guard let content else { return }
        let hex = format.selectedSegmentIndex == 1
        textView.text = hex ? content.hex : content.text
        let shown = hex ? min(content.bytesShown, 16 * 1024) : content.bytesShown
        notice.text = content.truncated && !hex ? "内容较多，仅显示部分预览；可导出原文件。" : content.totalBytes > shown ? "预览前 \(ByteCountFormatter.string(fromByteCount: Int64(shown), countStyle: .file))；可导出原文件。" : ByteCountFormatter.string(fromByteCount: content.totalBytes, countStyle: .file)
        textView.scrollRangeToVisible(NSRange(location: 0, length: 0))
    }
    private func configureMenu() {
        var actions = [UIAction(title: "系统预览", image: UIImage(systemName: "eye")) { [weak self] _ in
            guard let self else { return }
            let preview = NativePreview(file)
            preview.navigationItem.rightBarButtonItem = UIBarButtonItem(systemItem: .done, primaryAction: UIAction { [weak preview] _ in preview?.dismiss(animated: true) })
            present(UINavigationController(rootViewController: preview), animated: true)
        }, UIAction(title: "导出原文件", image: UIImage(systemName: "square.and.arrow.up")) { [weak self] _ in
            guard let self else { return }
            let share = UIActivityViewController(activityItems: [file], applicationActivities: nil)
            share.popoverPresentationController?.sourceView = view
            share.popoverPresentationController?.sourceRect = CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 1, height: 1)
            present(share, animated: true)
        }, UIAction(title: "复制当前内容", image: UIImage(systemName: "doc.on.doc")) { [weak self] _ in UIPasteboard.general.string = self?.textView.text }]
        if let value = content?.structured {
            actions.insert(UIAction(title: content?.truncated == true ? "查看键值（部分）" : "查看键值", image: UIImage(systemName: "list.bullet.indent")) { [weak self] _ in
                guard let self else { return }; navigationController?.pushViewController(NativeValues(model, title: title ?? "键值", value: value), animated: true)
            }, at: 0)
        }
        navigationItem.rightBarButtonItem = UIBarButtonItem(image: UIImage(systemName: "ellipsis"), menu: UIMenu(children: actions))
    }
}
