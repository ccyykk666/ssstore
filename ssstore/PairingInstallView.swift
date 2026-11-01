import SwiftUI

struct PairingInstallView: View {
    let packageURL: URL
    let bundleID: String
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var running = true
    @State private var started = false
    @State private var completed = false
    @State private var stage = "正在连接设备…"
    @State private var fraction = 0.0
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if running {
                        ProgressView(value: fraction)
                        Text(stage)
                        Text(fraction, format: .percent.precision(.fractionLength(0)))
                            .monospacedDigit()
                            .contentTransition(.numericText(value: fraction))
                            .animation(.snappy(duration: 0.3), value: fraction)
                    } else if completed {
                        Label("安装完成", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    } else if let error {
                        Text(error).foregroundStyle(.red).textSelection(.enabled)
                        Button("重试") { Task { await install() } }.disabled(model.busy)
                    }
                }
            }
            .modifier(SoftTopScrollEdge())
            .navigationTitle("配对安装")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() }.disabled(running) } }
        }
        .modifier(SoftTopScrollEdge())
        .interactiveDismissDisabled(running)
        .presentationDragIndicator(.visible)
        .task {
            guard !started else { return }
            started = true
            await install()
        }
    }

    @MainActor private func install() async {
        running = true; completed = false; error = nil; fraction = 0
        defer { running = false }
        do {
            try await model.installPackage(at: packageURL, bundleID: bundleID) { text, value in
                stage = text; fraction = value
            }
            completed = true
        } catch { self.error = error.localizedDescription }
    }
}
