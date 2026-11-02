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
final class NativeProduct: NativePage {
    let package: AppStore.AppPackage
    let region: String
    var accountID: String?
    var expanded = false
    init(_ model: AppModel, package: AppStore.AppPackage, region: String) {
        self.package = package; self.region = region
        accountID = AppStore.this.eligibleAccounts(for: region).first?.id
        super.init(model, title: package.software.name)
        navigationItem.largeTitleDisplayMode = .never
    }
    required init?(coder: NSCoder) { fatalError() }
    override func rows() -> [NativeSection] {
        let accounts = AppStore.this.eligibleAccounts(for: region)
        if !accounts.contains(where: { $0.id == accountID }) { accountID = accounts.first?.id }
        navigationItem.rightBarButtonItem = UIBarButtonItem(image: UIImage(systemName: "person.crop.circle"), menu: UIMenu(children: accounts.map { account in UIAction(title: account.account.email, state: accountID == account.id ? .on : .off) { [weak self] _ in self?.accountID = account.id; self?.reload() } }))
        let app = package.software
        let description = expanded ? app.description : String(app.description.prefix(180))
        var header = [NativeRow(title: app.name + " · " + (app.formattedPrice ?? "—"), detail: app.sellerName, icon: URL(string: app.artworkUrl)), NativeRow(title: description)]
        if app.description.count > 180 { header.append(link(expanded ? "收起" : "更多") { [weak self] in self?.expanded.toggle(); self?.reload() }) }
        header.append(link("版本 \(app.version)") { [weak self] in guard let self else { return }; push(NativeHistory(model, archive: AppPackageArchive(accountID: accountID, region: region, package: package))) })
        header.append(link(working ? "正在请求…" : "下载") { [weak self] in self?.download() })
        var details = [NativeRow(title: "Bundle ID", detail: app.bundleID), NativeRow(title: "开发者", detail: app.sellerName), NativeRow(title: "类别", detail: app.primaryGenreName), NativeRow(title: "兼容性", detail: app.minimumOsVersion + "+"), NativeRow(title: "评分", detail: "\(app.averageUserRating) (\(app.userRatingCount))")]
        if let size = app.fileSizeBytes.flatMap(Int64.init) { details.append(NativeRow(title: "大小", detail: ByteCountFormatter.string(fromByteCount: size, countStyle: .file))) }
        var sections = [NativeSection(rows: header), NativeSection(title: "详情", rows: details), NativeSection(title: "新功能", rows: [NativeRow(title: app.releaseNotes ?? "")])]
        if app.price == 0 { sections.append(NativeSection(rows: [link("获取许可证") { [weak self] in self?.license() }])) }
        if accountID == nil { sections.append(NativeSection(rows: [NativeRow(title: "请添加此地区的账户。", color: .systemOrange)])) }
        return sections
    }
    func download() {
        guard let accountID else { alert("请先添加此地区账户。"); return }
        if let existing = Downloads.this.downloadRequest(forArchive: package) { push(NativePackage(model, package: existing)); return }
        run { [self] in
            do { try await Downloads.this.startDownload(for: package, accountID: accountID) }
            catch {
                if case ApplePackageError.licenseRequired = error, package.software.price == 0 {
                    let alert = UIAlertController(title: "需要许可证", message: nil, preferredStyle: .alert)
                    alert.addAction(UIAlertAction(title: "取消", style: .cancel))
                    alert.addAction(UIAlertAction(title: "获取许可证", style: .default) { [weak self] _ in self?.license() })
                    present(alert, animated: true); return
                }
                throw error
            }
            if let request = Downloads.this.downloadRequest(forArchive: package) { push(NativePackage(model, package: request)) }
        }
    }
    func license() {
        guard let accountID else { return }
        run { [self] in
            try await AppStore.this.withAccount(id: accountID) { account in
                try await ApplePackage.Authenticator.rotatePasswordToken(for: &account.account)
                try await ApplePackage.Purchase.purchase(account: &account.account, app: self.package.software)
            }
            alert("请求成功")
        }
    }
}

@MainActor
final class NativeHistory: NativePage {
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
        if archive.isLoadingIndex { rows.append(NativeRow(title: "正在加载历史版本...")) }
        if let error = archive.error { rows.append(NativeRow(title: error, color: .systemOrange)) }
        versionRowOffset = rows.count
        displayedVersionIDs = archive.versionIdentifiers
        for key in displayedVersionIDs {
            if let package = archive.package(for: key), let metadata = archive.versionItems[key] {
                rows.append(link(package.software.version + (metadata.releaseDate.map { " · " + $0.formatted(date: .numeric, time: .omitted) } ?? "")) { [weak self] in
                    guard let self, let account = archive.accountIdentifier else { self?.alert("请先选择账户。"); return }
                    confirm("下载 \(package.software.version)？") { [weak self] in self?.run { try await Downloads.this.startDownload(for: package, accountID: account) } }
                })
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
        navigationItem.rightBarButtonItem = UIBarButtonItem(systemItem: .add, primaryAction: UIAction { [weak self] _ in guard let self else { return }; let add = NativeAddAccount(model); let nav = UINavigationController(rootViewController: add); nav.sheetPresentationController?.detents = [.custom(identifier: .init("account")) { context in min(390, context.maximumDetentValue) }]; present(nav, animated: true) })
    }
    override func rows() -> [NativeSection] {
        [NativeSection(title: "Apple ID", rows: AppStore.this.accounts.map { account in NativeRow(title: account.account.email, detail: ApplePackage.Configuration.countryCode(for: account.account.store) ?? account.account.store, action: { [weak self] in guard let self else { return }; push(NativeAccountDetail(model, id: account.id)) }) })]
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
        let cell = UITableViewCell(); let field = [email, password, code][indexPath.row]
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
                    guard let self, let account = accounts.first(where: { $0.id == id }), let region = ApplePackage.Configuration.countryCode(for: account.account.store) else { return }
                    run { let app = try await ApplePackage.Lookup.lookup(bundleID: bundle, countryCode: region); try await Downloads.this.startDownload(for: AppStore.AppPackage(software: app), accountID: id) }
                }
                push(picker)
            }
        })
    }
    override func rows() -> [NativeSection] {
        [NativeSection(rows: Downloads.this.manifests.sorted { $0.creation > $1.creation }.map { package in NativeRow(title: package.package.software.name + " · " + package.package.software.version, detail: (package.state.error ?? package.state.status.rawValue) + " · \(Int(package.state.percent * 100))% " + package.state.speed, icon: URL(string: package.package.software.artworkUrl), action: { [weak self] in guard let self else { return }; push(NativePackage(model, package: package)) }, delete: { Downloads.this.delete(request: package) }) })]
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
            controls = [link("配对安装") { [weak self] in guard let self else { return }; let page = NativeInstall(model, package: package); sheet(page); page.start() }, link("证书安装") { [weak self] in guard let self else { return }; run { let installer = try await Installer(archive: self.package.package, path: self.package.targetLocation); self.push(NativeCertificateInstall(self.model, installer: installer)) } }, link("导出安装包 / AirDrop") { [weak self] in guard let self else { return }; share(package.targetLocation) }, link("查看安装包内容") { [weak self] in guard let self else { return }; push(NativeArchiveFiles(model, file: package.targetLocation)) }]
        } else {
            controls = Downloads.this.getAvailableActions(for: package).filter { $0 != .delete }.map { action in link(Downloads.this.getActionLabel(for: action).title) { [weak self] in guard let self else { return }; Downloads.this.performDownloadAction(for: package, action: action); reload() } }
        }
        return [NativeSection(rows: [NativeRow(title: app.name, detail: app.version, icon: URL(string: app.artworkUrl)), NativeRow(title: "Bundle ID", detail: app.bundleID), NativeRow(title: "开发者", detail: app.sellerName), NativeRow(title: package.state.error ?? package.state.status.rawValue, detail: "\(Int(package.state.percent * 100))%")]), NativeSection(rows: controls), NativeSection(title: "账户", rows: [NativeRow(title: package.account.account.email)]), NativeSection(rows: [NativeRow(title: "删除安装包", color: .systemRed, action: { [weak self] in guard let self else { return }; Downloads.this.delete(request: package); navigationController?.popViewController(animated: true) })])]
    }
}

@MainActor
final class NativeInstall: NativePage {
    let package: PackageManifest
    var status = "正在连接设备…"
    var fraction = 0.0
    init(_ model: AppModel, package: PackageManifest) { self.package = package; super.init(model, title: "配对安装") }
    required init?(coder: NSCoder) { fatalError() }
    func start() {
        guard !working else { return }; working = true
        navigationController?.isModalInPresentation = true; navigationItem.rightBarButtonItem?.isEnabled = false
        Task { [self] in
            do { try await model.installPackage(at: package.targetLocation, bundleID: package.package.software.bundleID) { [weak self] stage, value in self?.status = stage; self?.fraction = value; self?.scheduleReload() }; status = "安装完成" }
            catch { status = error.localizedDescription }
            working = false; navigationController?.isModalInPresentation = false; navigationItem.rightBarButtonItem?.isEnabled = true; reload()
        }
    }
    override func rows() -> [NativeSection] { [NativeSection(rows: [NativeRow(title: status, detail: "\(Int(fraction * 100))%"), link("重试") { [weak self] in self?.start() }])] }
}

@MainActor
final class NativeCertificateInstall: NativePage {
    let installer: Installer
    init(_ model: AppModel, installer: Installer) { self.installer = installer; super.init(model, title: "证书安装") }
    required init?(coder: NSCoder) { fatalError() }
    override func viewDidAppear(_ animated: Bool) { super.viewDidAppear(animated); UIApplication.shared.open(installer.iTunesLink) }
    override func viewDidDisappear(_ animated: Bool) { super.viewDidDisappear(animated); if isMovingFromParent { installer.destroy() } }
    override func rows() -> [NativeSection] {
        let text: String
        switch installer.status {
        case .ready: text = "准备安装"
        case .sendingManifest: text = "正在发送清单…"
        case .sendingPayload: text = "正在发送安装包…"
        case .completed(let result): text = (try? result.get()) != nil ? "发送完成" : "发送失败"
        case .broken(let error): text = error.localizedDescription
        }
        return [NativeSection(rows: [NativeRow(title: text), link("安装") { [weak self] in guard let self else { return }; UIApplication.shared.open(installer.iTunesLink) }])]
    }
}

