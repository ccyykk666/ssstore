import UIKit
import UpdateCore

@MainActor
final class NativeManifestService: NativePage {
    private enum CredentialState { case loading, absent, present, unavailable }
    private var probeStatus: String?
    private var credentialState: CredentialState = .loading
    private var credentialLookup: Task<Void, Never>?
    private var credentialGeneration = UUID()
    private var credentialWorkDescription: String?
    private var testing = false
    private var usingPublicService: Bool {
        (try? InstallerManifestService.endpoint()) == InstallerManifestService.legacyPublicEndpoint
    }
    init(_ model: AppModel) { super.init(model, title: "安装清单服务") }
    required init?(coder: NSCoder) { fatalError() }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        refreshCredentialStatus()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        cancelCredentialLookup()
    }

    override func rows() -> [NativeSection] {
        // Rendering and navigation must use cached state only. In particular,
        // no synchronous Security.framework IPC may run from rows().
        var rows = [
            NativeRow(title: "服务地址", detail: InstallerManifestService.displayAddress,
                action: working ? nil : { [weak self] in self?.editEndpoint() }),
            NativeRow(title: "访问令牌", detail: credentialWorkDescription ?? credentialStatus,
                action: working || usingPublicService ? nil : { [weak self] in self?.editToken() }),
            NativeRow(title: testing ? "正在测试连接…" : "测试连接", color: working ? .secondaryLabel : .systemBlue,
                action: working ? nil : { [weak self] in self?.probe() }),
        ]
        if let probeStatus { rows.append(NativeRow(title: probeStatus)) }
        var sections = [NativeSection(rows: rows), NativeSection(rows: [NativeRow(title:
            "用于兼容安装。填写可直接访问的 HTTPS 清单接口，安装包仍在手机本机传输。私有服务需填写访问令牌，令牌仅保存在本机钥匙串并绑定当前完整地址，更换地址需单独配置。测试只发送示例数据。")])]
        if InstallerManifestService.savedAddress != nil {
            sections.append(NativeSection(rows: [NativeRow(title: "恢复默认服务", color: .systemBlue, action: working ? nil : { [weak self] in
                try? InstallerManifestService.setAddress("")
                self?.probeStatus = nil; self?.refreshCredentialStatus()
            })]))
        }
        return sections
    }

    private var credentialStatus: String {
        if usingPublicService { return "公开服务无需设置" }
        return switch credentialState {
        case .loading: "正在读取…"
        case .absent: "未设置"
        case .present: "已保存"
        case .unavailable: "暂时无法读取"
        }
    }

    private func cancelCredentialLookup() {
        credentialGeneration = UUID()
        credentialLookup?.cancel()
        credentialLookup = nil
    }

    private func refreshCredentialStatus() {
        cancelCredentialLookup()
        let endpoint: URL
        do { endpoint = try InstallerManifestService.endpoint() }
        catch { credentialState = .unavailable; reload(); return }
        if endpoint == InstallerManifestService.legacyPublicEndpoint {
            credentialState = .absent
            reload()
            return
        }
        credentialState = .loading
        reload()
        let generation = credentialGeneration
        credentialLookup = Task { [weak self] in
            let state: CredentialState
            do { state = try await ManifestAPICredentials.load(for: endpoint) == nil ? .absent : .present }
            catch {
                state = .unavailable
                logger.warning("Manifest credential lookup failed: \(DiagnosticLog.errorDetails(error))")
            }
            guard !Task.isCancelled, let self, self.credentialGeneration == generation,
                  (try? InstallerManifestService.endpoint()) == endpoint else { return }
            self.credentialState = state
            self.credentialLookup = nil
            self.reload()
        }
    }

    private func changeCredential(_ value: String?, for endpoint: URL) {
        guard !working else { return }
        cancelCredentialLookup()
        credentialWorkDescription = value == nil ? "正在移除…" : "正在保存…"
        run { [weak self] in
            guard let self else { return }
            defer { self.credentialWorkDescription = nil }
            do {
                if let value { try await ManifestAPICredentials.save(value, for: endpoint) }
                else { try await ManifestAPICredentials.clear(for: endpoint) }
                self.credentialState = value == nil ? .absent : .present
                self.probeStatus = nil
            } catch {
                self.credentialState = .unavailable
                self.probeStatus = error.localizedDescription
                logger.warning("Manifest credential update failed: \(DiagnosticLog.errorDetails(error))")
            }
        }
    }

    private func editToken() {
        do {
            let endpoint = try InstallerManifestService.endpoint()
            let hasToken = credentialState == .present
            let canRemoveToken = hasToken || credentialState == .unavailable
            let editor = UIAlertController(title: "访问令牌", message:
                "填写私有清单服务器生成的令牌。不要填写 Apple ID 密码或服务器登录密码。", preferredStyle: .alert)
            editor.addTextField { field in
                field.isSecureTextEntry = true
                field.placeholder = hasToken ? "输入新令牌以替换" : "服务器生成的随机令牌"
                field.autocapitalizationType = .none; field.autocorrectionType = .no
            }
            editor.addAction(UIAlertAction(title: "取消", style: .cancel))
            editor.addAction(UIAlertAction(title: "保存", style: .default) { [weak self, weak editor] _ in
                self?.changeCredential(editor?.textFields?.first?.text ?? "", for: endpoint)
            })
            if canRemoveToken {
                editor.addAction(UIAlertAction(title: "移除当前服务令牌", style: .destructive) { [weak self] _ in
                    self?.changeCredential(nil, for: endpoint)
                })
            }
            present(editor, animated: true)
        } catch { probeStatus = error.localizedDescription; reload() }
    }

    private func editEndpoint() {
        let editor = UIAlertController(title: "清单服务地址", message: "填写域名或完整 HTTPS 接口地址；留空使用默认服务。", preferredStyle: .alert)
        editor.addTextField { field in
            field.text = InstallerManifestService.displayAddress
            field.keyboardType = .URL; field.textContentType = .URL
            field.autocapitalizationType = .none; field.autocorrectionType = .no
            field.clearButtonMode = .whileEditing
        }
        editor.addAction(UIAlertAction(title: "取消", style: .cancel))
        let save = UIAlertAction(title: "保存", style: .default) { [weak self, weak editor] _ in
            do {
                try InstallerManifestService.setAddress(editor?.textFields?.first?.text ?? "")
                self?.probeStatus = nil
                self?.refreshCredentialStatus()
            } catch { self?.probeStatus = error.localizedDescription }
            self?.reload()
        }
        editor.addAction(save)
        if let field = editor.textFields?.first {
            field.addAction(UIAction { [weak field, weak save] _ in
                let value = field?.text ?? ""
                save?.isEnabled = value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                    (try? InstallationManifest.endpoint(from: value)) != nil
            }, for: .editingChanged)
        }
        present(editor, animated: true)
    }

    private func probe() {
        guard !working else { return }
        testing = true
        run { [self] in
            defer { testing = false }
            probeStatus = nil
            let address = InstallerManifestService.displayAddress
            do {
                try await InstallerManifestService.probe()
                guard InstallerManifestService.displayAddress == address,
                      view.window != nil, navigationController?.topViewController === self else { return }
                probeStatus = "连接正常，安装清单有效。"
            } catch {
                guard InstallerManifestService.displayAddress == address,
                      view.window != nil, navigationController?.topViewController === self else { return }
                throw error
            }
        }
    }
}
