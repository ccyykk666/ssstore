import SwiftUI
import UIKit

struct OnDevicePairingView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var controller: OnDevicePairingController

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("需要 iOS 27 及以上、Wi-Fi 和开发者模式。")
                        .foregroundStyle(.secondary)
                }
                Section("操作步骤") {
                    Text("1. 开始配对，允许本地网络访问，等待主机就绪。")
                    Text("2. 前往“设置 → 隐私与安全 → 开发者模式”，选择 ssstore。")
                    Text("3. 输入通知或本页的配对码，完成后返回。")
                }
                Section("状态") {
                    if controller.isActive { ProgressView() }
                    Text(controller.status).textSelection(.enabled)
                    if let pin = controller.pin {
                        Text(pin).font(.system(size: 36, weight: .bold, design: .monospaced))
                            .frame(maxWidth: .infinity).textSelection(.enabled)
                            .accessibilityLabel("配对码 \(pin.map(String.init).joined(separator: " "))")
                        Button("复制配对码") { UIPasteboard.general.string = pin }
                    }
                    if controller.isActive && !controller.notificationsAllowed {
                        Text("通知未开启，请在本页查看配对码。")
                            .font(.footnote).foregroundStyle(.orange)
                    }
                    if controller.isActive {
                        Text("请勿停止后台任务。配对限时两分钟。")
                            .font(.footnote).foregroundStyle(.secondary)
                        Button("停止配对", role: .cancel) { controller.cancel() }
                            .disabled(controller.phase == .stopping)
                    } else {
                        Button(controller.phase == .idle ? "开始配对" : "重新配对") {
                            model.createPairingOnDevice()
                        }.disabled(model.busy)
                    }
                }
                if !controller.diagnostics.isEmpty {
                    Section {
                        DisclosureGroup("配对日志") {
                            Text(controller.diagnostics.joined(separator: "\n"))
                                .font(.caption.monospaced()).textSelection(.enabled)
                            Button("复制日志") {
                                UIPasteboard.general.string = controller.diagnostics.joined(separator: "\n")
                            }
                        }
                    }
                }
                if controller.phase == .completed && model.hasPairing {
                    Section {
                        Label("配对文件已保存", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
                        Button("刷新应用") { Task { await model.refreshApps() } }
                            .disabled(model.busy)
                        if model.busy { ProgressView(model.activity) }
                    } footer: {
                        Text("启用 Loon 回环后刷新应用。")
                    }
                }
            }
            .navigationTitle("创建配对")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }.disabled(controller.isActive)
                }
            }
            .interactiveDismissDisabled(controller.isActive)
            .alert("提示", isPresented: Binding(get: { model.message != nil }, set: { if !$0 { model.message = nil } })) {
                Button("好") { model.message = nil }
            } message: { Text(model.message ?? "") }
        }
    }
}
