import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var importing = false
    @State private var removing = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("协议", selection: $model.mode) {
                        ForEach(PairingMode.allCases) { Text($0.rawValue).tag($0) }
                    }
                    TextField("IPv4 地址", text: $model.host)
                        .keyboardType(.numbersAndPunctuation).textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("端口", text: $model.port).keyboardType(.numberPad)
                    Label(model.hasPairing ? "已保存配对文件" : "尚未导入配对文件", systemImage: model.hasPairing ? "checkmark.circle" : "doc.badge.plus")
                    Button("导入配对文件") { importing = true }
                    if model.hasPairing { Button("移除本软件内的配对文件", role: .destructive) { removing = true } }
                } header: {
                    Text("本机连接")
                } footer: {
                    Text("iOS 27.2 优先使用 Remote Pairing（默认 49152）。传统 Lockdown（62078）用于旧系统实验。导入的配对格式会自动选择协议。")
                }
                Section {
                    Text("1. Loon 更新至 3.5.3（Build 1007）或更高版本。")
                    Text("2. 在 Loon 中启用“本机开发服务回环”插件并启动 VPN。")
                    Text("3. 在电脑上用 idevice_pair 创建 Remote Pairing，导出文件并导入这里。")
                    Text("4. 保持设备解锁，先在 Wi-Fi 环境中点击“读取本机”。")
                    Link("查看你提供的回环插件", destination: URL(string: "https://github.com/ios151/Rewrite/blob/main/dev-loopback/modules/dev-loopback.lpx")!)
                } header: {
                    Text("配合 Loon 使用")
                } footer: {
                    Text("Loon 负责网络通路，配对文件负责设备认证。无需为此功能启用 HTTPS 解密。iOS 27.2 的读取能力尚待真机验证。")
                }
                Section("版本数据") {
                    Picker("商店地区", selection: $model.country) {
                        Text("中国大陆 CN").tag("cn")
                        Text("美国 US").tag("us")
                        Text("香港 HK").tag("hk")
                        Text("日本 JP").tag("jp")
                    }
                    Text("切换地区后请重新检查更新。下架、地区限定或改过 Bundle ID 的应用可能查不到，可在应用详情中绑定原始 Bundle ID。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("关于") {
                    Text("ssstore · 0.1.0")
                    Text("查询仅发送应用 Bundle ID 与所选商店地区到苹果。配对文件保存在本软件本地，不会随版本查询上传。")
                    Text("读取清单和检查更新是两个动作。安装、卸载或升级应用后，请重新读取本机；导入清单只是快照。")
                    Text("本版显示可用版本与更新说明。应用安装和签名续期仍由原安装渠道处理。")
                }
            }
            .disabled(model.busy)
            .navigationTitle("连接设置")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.item]) { result in
                switch result {
                case .success(let url): model.importPairing(from: url)
                case .failure(let error): model.message = error.localizedDescription
                }
            }
            .alert("提示", isPresented: Binding(get: { model.message != nil }, set: { if !$0 { model.message = nil } })) {
                Button("知道了") { model.message = nil }
            } message: { Text(model.message ?? "") }
            .confirmationDialog("移除本软件保存的配对文件？", isPresented: $removing, titleVisibility: .visible) {
                Button("移除", role: .destructive) { model.removePairing() }
            } message: { Text("之后读取本机时需重新导入。设备上的信任关系不会被此操作撤销。") }
        }
    }
}
