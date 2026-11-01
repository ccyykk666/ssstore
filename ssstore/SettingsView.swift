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
                    Label(model.hasPairing ? "已保存配对文件" : "未保存配对文件", systemImage: model.hasPairing ? "checkmark.circle" : "doc.badge.plus")
                    if #available(iOS 27.0, *) {
                        Button("创建配对") { creating = true }
                    }
                    Button("导入配对文件") { importing = true }
                    if model.hasPairing {
                        Button("导出配对文件") {
                            do { exportDocument = PairingFileDocument(data: try model.pairingDataForExport()); exporting = true }
                            catch { model.message = error.localizedDescription }
                        }
                        Button("删除配对文件", role: .destructive) { removing = true }
                    }
                } header: {
                    Text("本机连接")
                } footer: {
                    Text("默认端口：Remote Pairing 49152，Lockdown 62078。")
                }
                Section {
                    Text("Loon 3.5.3（1007）及以上：启用回环插件和 VPN，保持设备解锁并连接 Wi-Fi。")
                    Link("Loon 回环插件", destination: URL(string: "https://github.com/ios151/Rewrite/blob/main/dev-loopback/modules/dev-loopback.lpx")!)
                } header: {
                    Text("连接要求")
                }
                Section {
                    Picker("商店地区", selection: $model.country) {
                        Text("中国大陆优先").tag(StoreQueryPolicy.chinaThenUS)
                        Text("中国大陆 CN").tag("cn")
                        Text("美国 US").tag("us")
                        Text("香港 HK").tag("hk")
                        Text("日本 JP").tag("jp")
                    }
                    Text("中国大陆优先：未找到时查询美国。更改后需重新查询。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("关于") {
                    Text("ssstore · 0.4.1")
                    Text("查询仅向 Apple 发送应用标识和地区。配对文件保存在本机。")
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
                Button("好") { model.message = nil }
            } message: { Text(model.message ?? "") }
            .confirmationDialog("删除配对文件？", isPresented: $removing, titleVisibility: .visible) {
                Button("删除", role: .destructive) { model.removePairing() }
            } message: { Text("仅删除本 App 内的文件，设备信任不受影响。再次使用需重新配对或导入。") }
        }
    }
}
