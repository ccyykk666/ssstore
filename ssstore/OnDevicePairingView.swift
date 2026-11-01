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
                    Label("在这台 iPhone 上完成配对", systemImage: "iphone.and.arrow.forward")
                        .font(.headline)
                    Text("需要 iOS 27 或更新版本。请连接 Wi-Fi，并开启系统的开发者模式。无需 Apple ID。")
                        .foregroundStyle(.secondary)
                }
                Section("操作步骤") {
                    Text("1. 点击下方“开始配对”，允许本地网络访问。建议允许通知，便于在设置中查看配对码。")
                    Text("2. 前往“设置 → 隐私与安全 → 开发者模式”，在可配对主机中选择 ssstore。")
                    Text("3. 输入 ssstore 通知中的配对码；若看不到通知，返回本页查看后再切回设置。")
                    Text("4. 系统确认后返回本页，配对记录会自动保存。")
                }
                Section("当前进度") {
                    if controller.isActive { ProgressView() }
                    Text(controller.status).textSelection(.enabled)
                    if let pin = controller.pin {
                        Text(pin).font(.system(size: 36, weight: .bold, design: .monospaced))
                            .frame(maxWidth: .infinity).textSelection(.enabled)
                            .accessibilityLabel("配对码 \(pin.map(String.init).joined(separator: " "))")
                        Button("复制配对码") { UIPasteboard.general.string = pin }
                    }
                    if controller.isActive && !controller.notificationsAllowed {
                        Text("未允许通知：配对码仍会显示在本页，可手动往返系统设置查看。")
                            .font(.footnote).foregroundStyle(.orange)
                    }
                    if controller.isActive {
                        Text("请尽快完成。切到系统设置后可用的后台时间由 iOS 决定；超时停止后可重新开始。")
                            .font(.footnote).foregroundStyle(.secondary)
                        Button("停止配对", role: .cancel) { controller.cancel() }
                            .disabled(controller.phase == .stopping)
                    } else {
                        Button(controller.phase == .idle ? "开始配对" : "重新开始配对") {
                            model.createPairingOnDevice()
                        }.disabled(model.busy)
                    }
                }
                if controller.phase == .completed && model.hasPairing {
                    Section {
                        Label("配对文件已保存到本机", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
                        Button("读取本机应用，验证连接") { Task { await model.scan() } }
                            .disabled(model.busy)
                        if model.busy { ProgressView(model.activity) }
                    } footer: {
                        Text("请先启用 Loon 的本机回环插件。配对成功和读取服务可用需要分别验证。")
                    }
                }
                Section {
                    Text("配对主机不出现时，请检查 Wi-Fi、开发者模式及 ssstore 的本地网络权限。若 Loon 的其他规则影响局域网发现，可暂时停止 VPN 完成配对，再启用回环读取应用。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("手机端配对")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }.disabled(controller.isActive)
                }
            }
            .interactiveDismissDisabled(controller.isActive)
            .onDisappear { controller.cancel() }
            .alert("提示", isPresented: Binding(get: { model.message != nil }, set: { if !$0 { model.message = nil } })) {
                Button("知道了") { model.message = nil }
            } message: { Text(model.message ?? "") }
        }
    }
}
