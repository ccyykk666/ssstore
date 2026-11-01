import ApplePackage
import SwiftUI
import UIKit

struct StoreSettingsSections: View {
    @Environment(\.openURL) private var openURL
    @State private var vm = AppStore.this
    @State private var showDeviceIdWarning = false
    @State private var editingDeviceId = false
    @State private var deviceIdDraft = ""
    @State private var showResetConfirmation = false

    private var normalizedDeviceID: String? { AppStore.normalizedDeviceIdentifier(deviceIdDraft) }

    var body: some View {
        Group {
            Section {
                if editingDeviceId {
                    TextField("设备 GUID", text: $deviceIdDraft)
                        .font(.body.monospaced())
                        .textInputAutocapitalization(.characters).autocorrectionDisabled()
                    if normalizedDeviceID == nil {
                        Text("请输入 12 位十六进制 GUID。").font(.footnote).foregroundStyle(.red)
                    }
                    HStack {
                        Button("保存") {
                            guard let identifier = normalizedDeviceID else { return }
                            vm.deviceIdentifier = identifier
                            editingDeviceId = false
                        }.disabled(normalizedDeviceID == nil)
                        Spacer()
                        Button("随机生成") { deviceIdDraft = DeviceIdentifier.random() }
                        Spacer()
                        Button("取消", role: .cancel) { editingDeviceId = false }
                    }.buttonStyle(.borderless)
                } else {
                    HStack {
                        Text("设备 GUID")
                        Spacer()
                        Text(vm.deviceIdentifier).font(.body.monospaced()).textSelection(.enabled)
                        Button("编辑") { showDeviceIdWarning = true }
                    }.buttonStyle(.borderless)
                }
                Button("安装证书") { openURL(Installer.caURL) }
                Button("打开系统设置") { openURL(URL(string: UIApplication.openSettingsURLString)!) }
            } header: {
                Text("商店连接")
            } footer: {
                Text("本机安装需安装并信任证书。")
            }
            Section("下载管理") {
                Button("删除全部下载", role: .destructive) { Downloads.this.removeAll() }
                Button("重置商店数据", role: .destructive) { showResetConfirmation = true }
                NavigationLink("日志") { LogView() }
            }
        }
        .alert("编辑设备 GUID？", isPresented: $showDeviceIdWarning) {
            Button("编辑", role: .destructive) { deviceIdDraft = vm.deviceIdentifier; editingDeviceId = true }
            Button("取消", role: .cancel) {}
        } message: {
            Text("更改后可能需要重新登录账户。")
        }
        .alert("重置商店数据？", isPresented: $showResetConfirmation) {
            Button("重置", role: .destructive) {
                try? FileManager.default.removeItem(at: documentsDirectory)
                try? FileManager.default.removeItem(at: temporaryDirectory)
                UIApplication.shared.perform(#selector(NSXPCConnection.suspend))
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(1))
                    exit(0)
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("删除下载文件和商店设置后关闭 App，账户和设备配对保留。")
        }
    }
}

struct SettingView: View {
    var body: some View {
        NavigationStack { Form { StoreSettingsSections() }.navigationTitle("设置") }
    }
}
