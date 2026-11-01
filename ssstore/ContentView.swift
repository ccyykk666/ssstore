import SwiftUI
import UniformTypeIdentifiers
import UpdateCore

struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @State private var search = ""
    @State private var onlyUpdates = false
    @State private var includeSystem = false
    @State private var settings = false
    @State private var importing = false

    private var visible: [AppRecord] {
        model.records.filter { record in
            (includeSystem || !record.installed.isSystem) &&
            (!onlyUpdates || record.status(country: model.country) == .update) &&
            (search.isEmpty || record.installed.name.localizedCaseInsensitiveContains(search) ||
             record.id.localizedCaseInsensitiveContains(search))
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 14) {
                        Label("ssstore", systemImage: "square.stack.3d.up.fill")
                            .font(.title2.bold()).foregroundStyle(.tint)
                        Text("所有版本，一处查看。")
                            .font(.headline)
                        HStack(spacing: 28) {
                            metric("已收录", value: model.records.filter { !$0.installed.isSystem }.count)
                            metric("可更新", value: model.records.filter { $0.status(country: model.country) == .update }.count)
                            metric("待确认", value: model.records.filter { !$0.installed.isSystem && [.unknown, .different].contains($0.status(country: model.country)) }.count)
                        }
                        if let date = model.scannedAt {
                            Text("\(model.inventoryOrigin) · \(date.formatted(date: .abbreviated, time: .shortened))")
                                .font(.caption).foregroundStyle(.secondary)
                        } else {
                            Text("先在连接设置中创建或导入配对文件，再开启 Loon 回环读取应用。")
                                .font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 8)
                    if !model.iconReadSummary.isEmpty { Text(model.iconReadSummary).font(.caption).foregroundStyle(.secondary) }
                    if !model.checkSummary.isEmpty { Text(model.checkSummary).font(.caption).foregroundStyle(.secondary) }
                }
                if model.busy {
                    Section {
                        HStack { ProgressView(); Text(model.activity).font(.subheadline) }
                        if model.isChecking { Button("停止版本查询", role: .cancel) { model.cancelCheck() } }
                    }
                }
                Section {
                    Toggle("只看可更新", isOn: $onlyUpdates)
                    Toggle("显示系统应用", isOn: $includeSystem)
                } footer: {
                    Text("数据源：苹果目录与 Lookup · \(model.country.uppercased()) 区。5 分钟内可复用查询缓存；更多菜单可强制刷新。版本需核对表示本机内部编号与商店展示无法直接比较。")
                }
                Section("应用 · \(visible.count)") {
                    if visible.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            Label(model.records.isEmpty ? "尚无应用清单" : "没有符合条件的应用", systemImage: "tray")
                                .font(.headline)
                            Text(model.records.isEmpty ? "在连接设置中创建或导入 Remote Pairing 文件，然后点击“读取本机”。也可导入电脑导出的清单。" : "调整筛选条件，或点击检查更新获取商店版本。")
                                .font(.subheadline).foregroundStyle(.secondary)
                        }.padding(.vertical, 12)
                    }
                    ForEach(visible) { record in
                        NavigationLink { AppDetailView(id: record.id) } label: { AppRow(record: record, country: model.country) }
                    }
                }
            }
            .navigationTitle("应用更新")
            .searchable(text: $search, prompt: "搜索应用或 Bundle ID")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button { settings = true } label: { Image(systemName: "gearshape") }
                        .accessibilityLabel("连接设置")
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Menu {
                        Button { Task { await model.scan() } } label: { Label("读取本机", systemImage: "iphone") }
                        Button { model.checkUpdates() } label: { Label("检查更新", systemImage: "arrow.clockwise") }
                        Button { model.checkUpdates(force: true) } label: { Label("强制刷新全部版本", systemImage: "arrow.triangle.2.circlepath") }
                        Button { importing = true } label: { Label("导入应用清单", systemImage: "square.and.arrow.down") }
                        if FileManager.default.fileExists(atPath: model.rawInventoryURL.path) {
                            ShareLink(item: model.rawInventoryURL) { Label("导出本机原始字段", systemImage: "square.and.arrow.up") }
                        }
                    } label: { Image(systemName: "ellipsis.circle") }
                    .disabled(model.busy)
                }
                ToolbarItem(placement: .bottomBar) {
                    Button { Task { await model.scan() } } label: { Label("读取本机", systemImage: "iphone") }
                        .disabled(model.busy)
                }
                ToolbarItem(placement: .bottomBar) { Spacer() }
                ToolbarItem(placement: .bottomBar) {
                    Button { model.checkUpdates() } label: { Label("检查更新", systemImage: "arrow.clockwise") }
                        .disabled(model.busy || model.records.isEmpty)
                }
            }
            .sheet(isPresented: $settings) { SettingsView() }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.item]) { result in
                switch result {
                case .success(let url): model.importInventory(from: url)
                case .failure(let error): model.message = error.localizedDescription
                }
            }
            .alert("提示", isPresented: Binding(get: { model.message != nil && !settings }, set: { if !$0 { model.message = nil } })) {
                Button("知道了") { model.message = nil }
            } message: { Text(model.message ?? "") }
        }
    }

    private func metric(_ title: String, value: Int) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(value.formatted()).font(.title.bold().monospacedDigit())
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct AppRow: View {
    let record: AppRecord
    let country: String
    private var status: UpdateStatus { record.status(country: country) }

    var body: some View {
        HStack(spacing: 12) {
            AppIconView(app: record.installed, storeIconURL: record.release?.iconURL)
            VStack(alignment: .leading, spacing: 5) {
                Text(record.installed.name).font(.headline).lineLimit(1)
                Text("本机 \(record.displayedVersion(country: country) ?? "未知")  ·  最新 \(record.release?.country == country ? record.release?.version ?? "—" : "—")")
                    .font(.caption).foregroundStyle(.secondary)
                if record.error != nil { Text("查询失败，点按查看原因").font(.caption2).foregroundStyle(.orange) }
            }
            Spacer(minLength: 2)
            Text(status.rawValue).font(.caption2.bold())
                .foregroundStyle(status == .update ? Color.orange : Color.secondary)
        }.padding(.vertical, 4)
    }
}
