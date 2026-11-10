import UIKit
import Combine
import Observation
import ApplePackage
import UpdateCore
import Kingfisher
import QuickLook
import UniformTypeIdentifiers
import ZIPFoundation
import LocalInstallTLS

@MainActor
final class NativeProductHeaderCell: UITableViewCell {
    private let icon = UIImageView()
    private let name = UILabel()
    private let price = UILabel()
    private let seller = UILabel()
    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        selectionStyle = .none
        name.font = .preferredFont(forTextStyle: .body); name.numberOfLines = 0
        price.font = .preferredFont(forTextStyle: .subheadline); price.textColor = .secondaryLabel
        seller.font = .preferredFont(forTextStyle: .subheadline); seller.textColor = .secondaryLabel; seller.numberOfLines = 0
        for label in [name, price, seller] { label.adjustsFontForContentSizeCategory = true }
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        seller.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        price.setContentHuggingPriority(.required, for: .horizontal)
        price.setContentCompressionResistancePriority(.required, for: .horizontal)
        let text = UIStackView(arrangedSubviews: [name, seller]); text.axis = .vertical; text.spacing = 2
        icon.contentMode = .scaleAspectFit; icon.layer.cornerRadius = 11; icon.clipsToBounds = true
        let row = UIStackView(arrangedSubviews: [icon, text, price]); row.alignment = .center; row.spacing = 16
        row.translatesAutoresizingMaskIntoConstraints = false; contentView.addSubview(row)
        NSLayoutConstraint.activate([icon.widthAnchor.constraint(equalToConstant: 52), icon.heightAnchor.constraint(equalToConstant: 52), row.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20), row.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20), row.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 12), row.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -12)])
    }
    required init?(coder: NSCoder) { fatalError() }
    override func prepareForReuse() { super.prepareForReuse(); icon.kf.cancelDownloadTask() }
    func update(_ row: NativeRow) {
        name.text = row.title; price.text = row.badge; seller.text = row.detail
        price.isHidden = row.badge?.isEmpty != false; seller.isHidden = row.detail.isEmpty
        icon.kf.setImage(with: row.icon, placeholder: UIImage(systemName: "app"), options: [.processor(DownsamplingImageProcessor(size: CGSize(width: 52, height: 52))), .scaleFactor(UIScreen.main.scale), .backgroundDecode])
    }
}

@MainActor
final class NativeProduct: NativePage {
    private var prewarm: Task<Void, Never>?
    let package: AppStore.AppPackage
    let region: String
    var accountID: String?
    init(_ model: AppModel, package: AppStore.AppPackage, region: String) {
        self.package = package; self.region = region
        accountID = AppStore.this.eligibleAccounts(for: region).first?.id
        super.init(model, title: package.software.name)
        navigationItem.largeTitleDisplayMode = .never
    }
    required init?(coder: NSCoder) { fatalError() }
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        prewarm = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 3_000_000_000) } catch { return }
            guard let self, let id = self.accountID,
                  let account = AppStore.this.accounts.first(where: { $0.id == id }) else { return }
            let guid = ApplePackage.Configuration.deviceIdentifier
            if await KBSyncStore.shared.cached(guid: guid, dsid: account.account.directoryServicesIdentifier) == nil {
                _ = try? await KBSyncStore.shared.generate(guid: guid, dsid: account.account.directoryServicesIdentifier)
            }
        }
    }
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated); prewarm?.cancel(); prewarm = nil
    }
    override func rows() -> [NativeSection] {
        let accounts = AppStore.this.eligibleAccounts(for: region)
        if !accounts.contains(where: { $0.id == accountID }) { accountID = accounts.first?.id }
        navigationItem.rightBarButtonItem = UIBarButtonItem(image: UIImage(systemName: "arrow.down.circle"), primaryAction: UIAction { [weak self] _ in
            guard let self else { return }; self.push(NativeDownloads(self.model))
        })
        let app = package.software
        let descriptionRow = NativeRow(title: app.description, isDescription: true)
        var header = [NativeRow(title: app.name, detail: app.sellerName, icon: URL(string: app.artworkUrl), badge: app.formattedPrice ?? "—", productHeader: true), descriptionRow]
        header.append(link("版本 \(app.version)") { [weak self] in guard let self else { return }; push(NativeHistory(model, archive: AppPackageArchive(accountID: accountID, region: region, package: package))) })
        header.append(link(working ? "正在请求…" : "下载") { [weak self] in self?.download() })
        var details = [NativeRow(title: "Bundle ID", detail: app.bundleID), NativeRow(title: "开发者", detail: app.sellerName), NativeRow(title: "类别", detail: app.primaryGenreName), NativeRow(title: "兼容性", detail: app.minimumOsVersion + "+")]
        if let size = app.fileSizeBytes.flatMap(Int64.init) { details.append(NativeRow(title: "大小", detail: ByteCountFormatter.string(fromByteCount: size, countStyle: .file))) }
        var sections = [NativeSection(rows: header), NativeSection(title: "详情", rows: details), NativeSection(title: "新功能", rows: [NativeRow(title: app.releaseNotes ?? "")])]
        if accountID == nil { sections.append(NativeSection(rows: [NativeRow(title: "请添加此地区的账户。", color: .systemOrange)])) }
        return sections
    }
    func download() {
        guard let accountID else { alert("请先添加此地区账户。"); return }
        if let existing = Downloads.this.downloadRequest(forArchive: package) { push(NativePackage(model, package: existing)); return }
        run { [self] in
            try await Downloads.this.startDownload(for: package, accountID: accountID)
            if let request = Downloads.this.downloadRequest(forArchive: package) { push(NativePackage(model, package: request)) }
        }
    }
}

@MainActor
final class NativeHistory: NativePage {
    private static let dateFormatters: [DateFormatter] = ["MM/dd", "yyyy/MM/dd"].map { format in
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = format
        return formatter
    }
    let archive: AppPackageArchive
    private var displayedVersionIDs: [String] = []
    private var versionRowOffset = 0
    init(_ model: AppModel, archive: AppPackageArchive) { self.archive = archive; super.init(model, title: "版本历史"); navigationItem.largeTitleDisplayMode = .never }
    required init?(coder: NSCoder) { fatalError() }
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        archive.loadHistory()
        reload()
        for index in tableView.indexPathsForVisibleRows ?? [] { loadVersion(at: index) }
    }
    override func viewDidDisappear(_ animated: Bool) { super.viewDidDisappear(animated); archive.cancelHistoryLoading() }
    override func rows() -> [NativeSection] {
        navigationItem.rightBarButtonItem = UIBarButtonItem(image: UIImage(systemName: "ellipsis"), menu: UIMenu(children: [UIAction(title: "加载更多", image: UIImage(systemName: "list.bullet.below.rectangle")) { [weak self] _ in self?.archive.populateNextVersionItems() }, UIAction(title: "刷新", image: UIImage(systemName: "arrow.clockwise")) { [weak self] _ in self?.archive.loadHistory(force: true) }]))
        var rows: [NativeRow] = []
        if working { rows.append(NativeRow(title: "正在请求下载…")) }
        if archive.isLoadingIndex { rows.append(NativeRow(title: "正在加载历史版本...")) }
        if let error = archive.error { rows.append(NativeRow(title: error, color: .systemOrange)) }
        versionRowOffset = rows.count
        displayedVersionIDs = archive.versionIdentifiers
        for key in displayedVersionIDs {
            if let package = archive.package(for: key), let metadata = archive.versionItems[key] {
                let date = metadata.releaseDate.map { date in
                    let thisYear = Calendar(identifier: .gregorian).isDate(date, equalTo: Date(), toGranularity: .year)
                    return Self.dateFormatters[thisYear ? 0 : 1].string(from: date)
                }
                rows.append(NativeRow(title: package.software.version, color: .systemBlue, action: { [weak self] in
                    guard let self, let account = archive.accountIdentifier else { self?.alert("请先选择账户。"); return }
                    confirm("下载 \(package.software.version)？") { [weak self] in self?.run {
                        guard let self else { return }
                        self.archive.cancelHistoryLoading()
                        if Downloads.this.downloadRequest(forArchive: package) == nil {
                            try await Downloads.this.startDownload(for: package, accountID: account)
                        }
                        if let request = Downloads.this.downloadRequest(forArchive: package) { self.push(NativePackage(self.model, package: request)) }
                    } }
                }, badge: date))
            } else {
                rows.append(NativeRow(title: key, detail: archive.metadataErrors[key] ?? (archive.loadingIDs.contains(key) ? "加载中…" : "点按加载"), action: { [weak self] in self?.archive.populateVersionItem(for: key, retry: true) }))
            }
        }
        if archive.canLoadEarlierVersions && !archive.isLoadingIndex { rows.append(link("加载更早版本") { [weak self] in self?.archive.loadEarlierVersions() }) }
        return [NativeSection(rows: rows)]
    }
    override func tableView(_ tableView: UITableView, willDisplay cell: UITableViewCell, forRowAt indexPath: IndexPath) {
        loadVersion(at: indexPath)
    }
    private func loadVersion(at indexPath: IndexPath) {
        let index = indexPath.row - versionRowOffset
        if displayedVersionIDs.indices.contains(index) { archive.populateVersionItem(for: displayedVersionIDs[index]) }
    }
}

@MainActor
final class NativeAccounts: NativePage {
    init(_ model: AppModel) { super.init(model, title: "账户") }
    required init?(coder: NSCoder) { fatalError() }
    override func viewDidLoad() {
        super.viewDidLoad()
        navigationItem.rightBarButtonItem = UIBarButtonItem(systemItem: .add, primaryAction: UIAction { [weak self] _ in
            guard let self else { return }
            let add = NativeAddAccount(model)
            let nav = NativeFittingNavigation(root: add)
            present(nav, animated: true)
        })
    }
    override func rows() -> [NativeSection] {
        [NativeSection(title: "Apple ID", rows: AppStore.this.accounts.map { account in NativeRow(title: account.account.email, detail: ApplePackage.Configuration.countryCode(for: StoreProtocol.storefrontIdentifier(account.account.store)) ?? account.account.store, action: { [weak self] in guard let self else { return }; push(NativeAccountDetail(model, id: account.id)) }) })]
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
    var credentialsChanged = true
    init(_ model: AppModel) { super.init(model, title: "添加账户") }
    required init?(coder: NSCoder) { fatalError() }
    override func viewDidLoad() {
        super.viewDidLoad()
        navigationItem.largeTitleDisplayMode = .never
        email.placeholder = "邮箱（Apple ID）"; email.keyboardType = .emailAddress; email.textContentType = .username
        password.placeholder = "密码"; password.isSecureTextEntry = true; password.textContentType = .password
        code.placeholder = "验证码"; code.keyboardType = .numberPad; code.textContentType = .oneTimeCode
        for field in [email, password, code] {
            field.font = .preferredFont(forTextStyle: .body); field.adjustsFontForContentSizeCategory = true
            field.autocapitalizationType = .none; field.autocorrectionType = .no
            field.addAction(UIAction { [weak self] _ in self?.navigationItem.rightBarButtonItem?.isEnabled = !(self?.working ?? true) }, for: .editingChanged)
        }
        for field in [email, password] {
            field.addAction(UIAction { [weak self] _ in
                guard let self else { return }; credentialsChanged = true
                if needsCode { needsCode = false; code.text = ""; reload() }
            }, for: .editingChanged)
        }
        navigationItem.leftBarButtonItem = UIBarButtonItem(title: "取消", primaryAction: UIAction { [weak self] _ in self?.dismiss(animated: true) })
        navigationItem.rightBarButtonItem = UIBarButtonItem(title: "确认", primaryAction: UIAction { [weak self] _ in self?.authenticate() })
    }
    override func rows() -> [NativeSection] { [NativeSection(rows: Array(repeating: NativeRow(title: ""), count: needsCode ? 3 : 2)), NativeSection(rows: [link(password.isSecureTextEntry ? "显示密码" : "隐藏密码") { [weak self] in self?.password.isSecureTextEntry.toggle(); self?.reload() }])] }
    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        guard indexPath.section == 0 else { return super.tableView(tableView, cellForRowAt: indexPath) }
        let cell = UITableViewCell(); cell.selectionStyle = .none
        let field = [email, password, code][indexPath.row]
        field.removeFromSuperview(); field.translatesAutoresizingMaskIntoConstraints = false; cell.contentView.addSubview(field)
        NSLayoutConstraint.activate([field.leadingAnchor.constraint(equalTo: cell.contentView.leadingAnchor, constant: 18), field.trailingAnchor.constraint(equalTo: cell.contentView.trailingAnchor, constant: -18), field.topAnchor.constraint(equalTo: cell.contentView.topAnchor, constant: 16), field.bottomAnchor.constraint(equalTo: cell.contentView.bottomAnchor, constant: -16)])
        return cell
    }
    func authenticate() {
        guard !working, let emailText = email.text?.trimmingCharacters(in: .whitespacesAndNewlines), !emailText.isEmpty, let secret = password.text, !secret.isEmpty, !needsCode || !(code.text ?? "").isEmpty else { return }
        view.endEditing(true); working = true; isModalInPresentation = true; navigationController?.isModalInPresentation = true; for field in [email, password, code] { field.isEnabled = false }; navigationItem.rightBarButtonItem?.isEnabled = false; navigationItem.leftBarButtonItem?.isEnabled = false
        Task { [self] in
            defer { working = false; isModalInPresentation = false; navigationController?.isModalInPresentation = false; for field in [email, password, code] { field.isEnabled = true }; navigationItem.rightBarButtonItem?.isEnabled = true; navigationItem.leftBarButtonItem?.isEnabled = true }
            do {
                if credentialsChanged { authenticator = nil; credentialsChanged = false }
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
                    guard let self, let account = accounts.first(where: { $0.id == id }), let region = ApplePackage.Configuration.countryCode(for: StoreProtocol.storefrontIdentifier(account.account.store)) else { return }
                    run { let app = try await ApplePackage.Lookup.lookup(bundleID: bundle, countryCode: region); try await Downloads.this.startDownload(for: AppStore.AppPackage(software: app), accountID: id) }
                }
                push(picker)
            }
        })
    }
    override func rows() -> [NativeSection] {
        var sections: [NativeSection] = []
        if let notice = Downloads.this.backgroundNotice { sections.append(NativeSection(rows: [NativeRow(title: notice, color: .secondaryLabel)])) }
        sections.append(NativeSection(rows: Downloads.this.manifests.sorted { $0.creation > $1.creation }.map { package in
            let active = [.pending, .downloading, .paused].contains(package.state.status)
            let showPercent = active && package.state.percent < 1
            let detail = [package.state.error ?? package.state.status.title,
                          showPercent ? "\(Int(package.state.percent * 100))%" : "",
                          package.state.status == .downloading ? package.state.speed : ""]
                .filter { !$0.isEmpty }.joined(separator: " · ")
            return NativeRow(title: package.package.software.name, detail: detail,
                             icon: URL(string: package.package.software.artworkUrl),
                             action: { [weak self] in guard let self else { return }; self.push(NativePackage(self.model, package: package)) },
                             delete: { Downloads.this.delete(request: package) }, badge: package.package.software.version,
                             compact: true, isDownload: true, progress: active ? package.state.percent : nil)
        }))
        return sections
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
            controls = [link("配对安装") { [weak self] in guard let self else { return }; let page = NativeInstall(model, package: package); page.present(from: self); page.start() }, link("证书安装") { [weak self] in guard let self else { return }; run { let installer = try await Installer(archive: self.package.package, path: self.package.targetLocation); self.push(NativeCertificateInstall(self.model, installer: installer)) } }, link("导出安装包 / AirDrop") { [weak self] in guard let self else { return }; share(package.targetLocation) }, link("查看安装包内容") { [weak self] in guard let self else { return }; push(NativeArchiveFiles(model, file: package.targetLocation)) }]
        } else {
            controls = Downloads.this.getAvailableActions(for: package).filter { $0 != .delete }.map { action in link(Downloads.this.getActionLabel(for: action).title) { [weak self] in guard let self else { return }; Downloads.this.performDownloadAction(for: package, action: action); reload() } }
        }
        let bytes = package.completed ? (try? FileManager.default.attributesOfItem(atPath: package.targetLocation.path)[.size] as? NSNumber)?.int64Value : nil
        let size = bytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? (package.completed ? "未知" : "下载完成后可查看")
        return [NativeSection(rows: [NativeRow(title: app.name, icon: URL(string: app.artworkUrl), badge: app.version, isDownload: true), NativeRow(title: "Bundle ID", detail: app.bundleID), NativeRow(title: "开发者", detail: app.sellerName), NativeRow(title: "大小", detail: size), NativeRow(title: package.state.error ?? package.state.status.title, detail: package.state.percent < 1 ? "\(Int(package.state.percent * 100))%" : "", progress: [.pending, .downloading, .paused].contains(package.state.status) ? package.state.percent : nil)]), NativeSection(rows: controls), NativeSection(title: "账户", rows: [NativeRow(title: package.account.account.email)]), NativeSection(rows: [NativeRow(title: "删除安装包", color: .systemRed, action: { [weak self] in guard let self else { return }; Downloads.this.delete(request: package); navigationController?.popViewController(animated: true) })])]
    }
}

@MainActor
final class NativeInstall: UIViewController, NativeSheetContent {
    private let model: AppModel
    private let package: PackageManifest
    private let status = UILabel()
    private let progress = UIProgressView(progressViewStyle: .default)
    private let percent = UILabel()
    private let retry = UIButton(type: .system)
    private let stack = UIStackView()
    private let scroll = UIScrollView()
    var sheetScrollView: UIScrollView { scroll }
    var sheetContentHeight: CGFloat {
        stack.systemLayoutSizeFitting(CGSize(width: scroll.frameLayoutGuide.layoutFrame.width, height: 0), withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel).height
    }
    private var working = false
    init(_ model: AppModel, package: PackageManifest) {
        self.model = model; self.package = package
        super.init(nibName: nil, bundle: nil)
        title = "配对安装"
    }
    required init?(coder: NSCoder) { fatalError() }
    func present(from owner: UIViewController) {
        let nav = NativeFittingNavigation(root: self)
        owner.present(nav, animated: true)
    }
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        navigationItem.rightBarButtonItem = UIBarButtonItem(systemItem: .done, primaryAction: UIAction { [weak self] _ in self?.dismiss(animated: true) })
        status.font = .preferredFont(forTextStyle: .body); status.numberOfLines = 0
        percent.font = .preferredFont(forTextStyle: .caption1); percent.textColor = .secondaryLabel
        for label in [status, percent] { label.adjustsFontForContentSizeCategory = true }
        progress.accessibilityLabel = "安装进度"
        retry.setTitle("重试", for: .normal)
        retry.addAction(UIAction { [weak self] _ in self?.start() }, for: .touchUpInside)
        scroll.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scroll)
        stack.axis = .vertical; stack.spacing = 12
        for item in [status, progress, percent, retry] { stack.addArrangedSubview(item) }
        stack.translatesAutoresizingMaskIntoConstraints = false; scroll.addSubview(stack)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 20), scroll.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -20),
            scroll.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 16), scroll.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -16),
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor), stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor), stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor), stack.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor)
        ])
    }
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        (navigationController as? NativeFittingNavigation)?.updateContentSize()
    }
    func start() {
        guard !working else { return }
        loadViewIfNeeded(); working = true
        navigationController?.isModalInPresentation = true
        retry.isHidden = true; navigationItem.rightBarButtonItem?.isEnabled = false
        status.text = "正在连接设备…"; progress.setProgress(0, animated: false); percent.isHidden = false; percent.text = "0%"
        Task { [self] in
            do {
                try await model.installPackage(at: package.targetLocation, bundleID: package.package.software.bundleID) { [weak self] stage, value in
                    guard let self, self.working else { return }
                    self.status.text = stage
                    self.progress.setProgress(Float(min(1, max(0, value))), animated: true)
                    self.percent.text = "\(Int(min(1, max(0, value)) * 100))%"
                }
                status.text = "安装完成"; progress.setProgress(1, animated: true); percent.isHidden = true
            } catch { status.text = error.localizedDescription; retry.isHidden = false }
            working = false; navigationController?.isModalInPresentation = false; navigationItem.rightBarButtonItem?.isEnabled = true
        }
    }
}

@MainActor
final class NativeCertificateInstall: NativePage {
    let installer: Installer
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var certificateTrusted = false
    private var awaitingSystem = false
    private var trustTask: Task<Void, Never>?
    private var foregroundObserver: NSObjectProtocol?
    private var backgroundObserver: NSObjectProtocol?
    init(_ model: AppModel, installer: Installer) { self.installer = installer; super.init(model, title: "证书安装") }
    required init?(coder: NSCoder) { fatalError() }
    override func viewDidLoad() {
        super.viewDidLoad()
        foregroundObserver = NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification,
            object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if self.awaitingSystem { logger.info("Certificate install [\(self.installer.id)]: app returned to foreground, stage=\(self.installer.diagnosticStatus)") }
                self.refreshCertificateTrust()
            }
        }
        backgroundObserver = NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification,
            object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.awaitingSystem else { return }
                logger.info("Certificate install [\(self.installer.id)]: app entered background, stage=\(self.installer.diagnosticStatus)")
            }
        }
    }
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        refreshCertificateTrust()
    }
    deinit {
        trustTask?.cancel()
        if let foregroundObserver { NotificationCenter.default.removeObserver(foregroundObserver) }
        if let backgroundObserver { NotificationCenter.default.removeObserver(backgroundObserver) }
    }
    private func refreshCertificateTrust() {
        trustTask?.cancel()
        let identity = installer.certificateIdentity
        trustTask = Task { [weak self] in
            let trusted = await Task.detached { identity.isTrusted }.value
            guard !Task.isCancelled else { return }
            self?.certificateTrusted = trusted
            self?.reload()
        }
    }
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if isMovingFromParent { endBackgroundTask(); installer.destroy() }
    }
    override func rows() -> [NativeSection] {
        let text: String
        switch installer.status {
        case .ready: text = awaitingSystem ? "等待系统获取安装清单…" : "准备安装"
        case .sendingManifest: text = "正在发送清单…"
        case .sendingPayload: text = "正在发送安装包…"
        case .completed(let result): text = (try? result.get()) != nil ? "发送完成" : "发送失败"
        case .broken(let error): text = error.localizedDescription
        }
        var sections = [NativeSection(rows: [NativeRow(title: working ? "正在检查本地连接…" : text,
            detail: "通过本机连接安装，无需 Wi-Fi。"), link("安装") { [weak self] in self?.openInstaller() }])]
        if !certificateTrusted {
            sections.insert(NativeSection(title: "首次使用 IP 安装", rows: [
                NativeRow(title: installer.certificateIdentity.rootName,
                    detail: "安装描述文件后，在设置 → 通用 → 关于本机 → 证书信任设置中启用此证书的完整信任。旧版 Asspp 证书不适用于本机 IP。"),
                link("安装本机证书") { [weak self] in self?.openCertificateProfile() },
            ]), at: 0)
        }
        return sections
    }
    private func openCertificateProfile() {
        run { try await Installer.openCertificateProfile() }
    }
    private func openInstaller() {
        run { [self] in
            let identity = installer.certificateIdentity
            certificateTrusted = await Task.detached { identity.isTrusted }.value
            logger.info("Certificate install [\(installer.id)]: system trust=\(certificateTrusted) root=\(identity.rootName)")
            guard certificateTrusted else {
                throw NSError(domain: "ssstore.install", code: 2, userInfo: [NSLocalizedDescriptionKey:
                    "请先安装本机证书，并在系统的证书信任设置中启用 \(identity.rootName) 的完整信任，然后返回重试。"])
            }
            var request = URLRequest(url: installer.pingEndpoint)
            request.cachePolicy = .reloadIgnoringLocalCacheData
            request.timeoutInterval = 10
            do {
                let (_, response) = try await URLSession.shared.data(for: request)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                    throw NSError(domain: "ssstore.install", code: 1, userInfo: [NSLocalizedDescriptionKey: "本机安装服务未正常响应。"])
                }
                logger.info("Certificate install [\(installer.id)]: HTTPS preflight succeeded, manifest=\(installer.plistEndpoint.absoluteString)")
            } catch {
                logger.error("Certificate install [\(installer.id)]: HTTPS preflight failed: \(DiagnosticLog.errorDetails(error))")
                guard view.window != nil, navigationController?.topViewController === self else { return }
                let error = error as NSError
                throw NSError(domain: "ssstore.install", code: error.code, userInfo: [NSLocalizedDescriptionKey: "本机安装服务连接失败（\(error.code)）：\(error.localizedDescription)"])
            }
            guard view.window != nil, navigationController?.topViewController === self else { return }
            installer.status = .ready
            if backgroundTask == .invalid {
                backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "CertificateInstall") { [weak self] in
                    guard let self else { return }
                    switch installer.status {
                    case .completed, .broken: break
                    default:
                        installer.status = .broken(NSError(domain: "ssstore.install", code: 4,
                            userInfo: [NSLocalizedDescriptionKey: "系统已结束本机安装服务的后台执行时间，请返回软件重新点击安装。"]))
                    }
                    logger.warning("Local installer background time expired")
                    endBackgroundTask()
                }
            }
            awaitingSystem = true
            logger.info("Opening local installation page: \(installer.installPage.absoluteString)")
            UIApplication.shared.open(installer.installPage) { [weak self] opened in
                guard let self, !opened else { return }
                self.awaitingSystem = false
                self.endBackgroundTask()
                self.reload()
                self.alert("无法打开安装页面，请检查网络和本地服务后重试。")
            }
        }
    }
    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }
}

