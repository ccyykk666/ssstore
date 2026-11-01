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
                }
                Section {
                    Picker("商店地区", selection: $model.country) {
                        Text("中国大陆优先").tag(StoreQueryPolicy.chinaThenUS)
                        Text("中国大陆 CN").tag("cn")
                        Text("美国 US").tag("us")
                        Text("香港 HK").tag("hk")
                        Text("日本 JP").tag("jp")
                    }
                }
                if !model.ignoredApps.names.isEmpty {
                    Section {
                        NavigationLink("已忽略应用（\(model.ignoredApps.names.count)）") { IgnoredAppsView() }
                    }
                }
                Section("关于") {
                    NavigationLink("商店设置") { SettingView(embedded: true) }
                    NavigationLink("开源许可") {
                        ScrollView {
                            Text((try? String(contentsOf: Bundle.main.url(forResource: "AssppLicense", withExtension: "txt")!, encoding: .utf8)) ?? "Asspp · MIT License")
                                .font(.footnote).textSelection(.enabled).padding()
                        }.navigationTitle("Asspp · MIT")
                    }
                    Text("ssstore · 0.5.0")
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


private struct IgnoredAppsView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        List {
            Section {
                ForEach(model.ignoredApps.names.keys.sorted(), id: \.self) { id in
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(model.ignoredApps.names[id] ?? id)
                            Text(id).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("恢复") { model.restoreApp(id) }
                            .buttonStyle(.bordered).disabled(model.busy)
                    }
                }
            } footer: {
                Text("恢复后重新读取应用。")
            }
        }
        .navigationTitle("已忽略应用")
    }
}
