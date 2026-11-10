import UIKit
import UpdateCore

@MainActor
final class NativeManifestService: NativePage {
    private var probeStatus: String?
    init(_ model: AppModel) { super.init(model, title: "安装清单服务") }
    required init?(coder: NSCoder) { fatalError() }

    override func rows() -> [NativeSection] {
        var rows = [
            NativeRow(title: "服务地址", detail: InstallerManifestService.displayAddress,
                action: { [weak self] in self?.editEndpoint() }),
            NativeRow(title: "访问令牌", detail: credentialStatus,
                action: { [weak self] in self?.editToken() }),
            link(working ? "正在测试连接…" : "测试连接") { [weak self] in self?.probe() },
        ]
        if let probeStatus { rows.append(NativeRow(title: probeStatus)) }
        var sections = [NativeSection(rows: rows), NativeSection(rows: [NativeRow(title:
            "用于兼容安装。填写可直接访问的 HTTPS 清单接口，安装包仍在手机本机传输。私有服务需填写访问令牌，令牌仅保存在本机钥匙串并绑定当前完整地址，更换地址需单独配置。测试只发送示例数据。")])]
        if InstallerManifestService.savedAddress != nil {
            sections.append(NativeSection(rows: [link("恢复默认服务") { [weak self] in
                try? InstallerManifestService.setAddress("")
                self?.probeStatus = nil; self?.reload()
            }]))
        }
        return sections
    }

    private var credentialStatus: String {
        do {
            return try ManifestAPICredentials.load(for: InstallerManifestService.endpoint()) == nil ? "未设置" : "已保存"
        } catch { return "暂时无法读取" }
    }

    private func editToken() {
        do {
            let endpoint = try InstallerManifestService.endpoint()
            let hasToken = try ManifestAPICredentials.load(for: endpoint) != nil
            let editor = UIAlertController(title: "访问令牌", message:
                "填写私有清单服务器生成的令牌。不要填写 Apple ID 密码或服务器登录密码。", preferredStyle: .alert)
            editor.addTextField { field in
                field.isSecureTextEntry = true
                field.placeholder = hasToken ? "输入新令牌以替换" : "服务器生成的随机令牌"
                field.autocapitalizationType = .none; field.autocorrectionType = .no
            }
            editor.addAction(UIAlertAction(title: "取消", style: .cancel))
            editor.addAction(UIAlertAction(title: "保存", style: .default) { [weak self, weak editor] _ in
                do {
                    try ManifestAPICredentials.save(editor?.textFields?.first?.text ?? "", for: endpoint)
                    self?.probeStatus = nil
                } catch { self?.probeStatus = error.localizedDescription }
                self?.reload()
            })
            if hasToken {
                editor.addAction(UIAlertAction(title: "移除当前服务令牌", style: .destructive) { [weak self] _ in
                    do { try ManifestAPICredentials.clear(for: endpoint); self?.probeStatus = nil }
                    catch { self?.probeStatus = error.localizedDescription }
                    self?.reload()
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
        run { [self] in
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
