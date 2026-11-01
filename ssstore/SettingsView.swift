import SwiftUI
import UniformTypeIdentifiers
import UpdateCore

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var importing = false
    @State private var removing = false
    @State private var creating = false
    @State private var exporting = false
    @State private var exportDocument = PairingFileDocument(data: Data())

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
                    if #available(iOS 27.0, *) {
                        Button("在手机上创建 Remote Pairing") { creating = true }
                    }
                    Button("导入配对文件") { importing = true }
                    if model.hasPairing {
                        Button("导出配对文件") {
                            do { exportDocument = PairingFileDocument(data: try model.pairingDataForExport()); exporting = true }
                            catch { model.message = error.localizedDescription }
                        }
                        Button("移除本软件内的配对文件", role: .destructive) { removing = true }
                    }
                } header: {
                    Text("本机连接")
                } footer: {
                    Text("iOS 27.2 优先使用 Remote Pairing（默认 49152）。传统 Lockdown（62078）用于旧系统实验。导入的配对格式会自动选择协议。")
                }
                Section {
                    Text("1. Loon 更新至 3.5.3（Build 1007）或更高版本。")
                    Text("2. 在 Loon 中启用“本机开发服务回环”插件并启动 VPN。")
                    Text("3. iOS 27 及更新版本可点击“在手机上创建 Remote Pairing”；也可导入电脑生成的文件。")
                    Text("4. 保持设备解锁，先在 Wi-Fi 环境中点击“读取本机”。")
                    Link("查看你提供的回环插件", destination: URL(string: "https://github.com/ios151/Rewrite/blob/main/dev-loopback/modules/dev-loopback.lpx")!)
                } header: {
                    Text("配合 Loon 使用")
                } footer: {
                    Text("Loon 负责网络通路，配对文件负责设备认证。读取本机时会同时缓存本地图标，未取得时再使用商店图标。")
                }
                Section("版本数据") {
                    Picker("商店地区", selection: $model.country) {
                        Text("中国区优先，未找到时查美区").tag(StoreQueryPolicy.chinaThenUS)
                        Text("中国大陆 CN").tag("cn")
                        Text("美国 US").tag("us")
                        Text("香港 HK").tag("hk")
                        Text("日本 JP").tag("jp")
                    }
                    Text("默认先查中国区，仅对未找到的应用重试美区；已在中国区查到的应用不会改用美区版本。也可手动固定单个地区。切换后请重新检查更新。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("关于") {
                    Text("ssstore · 0.3.1")
                    Text("批量查询仅向苹果发送 Bundle ID、数字商店 ID 与所选地区，无需 Apple ID 登录。配对文件与本地图标保存在本软件内，不会随版本查询上传。")
                    Text("读取清单和检查更新是两个动作。安装、卸载或升级应用后，请重新读取本机；导入清单只是快照。")
                    Text("本版显示可用版本与更新说明。应用安装和签名续期仍由原安装渠道处理。")
                }
            }
            .disabled(model.busy)
            .navigationTitle("连接设置")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
            .sheet(isPresented: $creating) {
                OnDevicePairingView(controller: model.pairingController)
                    .environment(\.isEnabled, true)
            }
            .fileExporter(isPresented: $exporting, document: exportDocument,
                          contentType: .propertyList, defaultFilename: "ssstore-pairing.plist") { result in
                if case .failure(let error) = result { model.message = error.localizedDescription }
            }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.item]) { result in
                switch result {
                case .success(let url): model.importPairing(from: url)
                case .failure(let error): model.message = error.localizedDescription
                }
            }
            .alert("提示", isPresented: Binding(get: { model.message != nil && !creating }, set: { if !$0 { model.message = nil } })) {
                Button("知道了") { model.message = nil }
            } message: { Text(model.message ?? "") }
            .confirmationDialog("移除本软件保存的配对文件？", isPresented: $removing, titleVisibility: .visible) {
                Button("移除", role: .destructive) { model.removePairing() }
            } message: { Text("之后读取本机时需重新导入。设备上的信任关系不会被此操作撤销。") }
        }
    }
}
