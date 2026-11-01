import SwiftUI
import UpdateCore

struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @State private var search = ""
    @State private var onlyDifferent = false
    @State private var includeSystem = false
    @State private var settings = false

    private var visible: [AppRecord] {
        model.records.filter { record in
            (includeSystem || !record.installed.isSystem) &&
            (!onlyDifferent || record.status(country: model.country) == .different) &&
            (search.isEmpty || record.installed.name.localizedCaseInsensitiveContains(search) ||
             record.id.localizedCaseInsensitiveContains(search))
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack(spacing: 28) {
                            metric("应用", value: model.records.filter { !$0.installed.isSystem }.count)
                            metric("标识不同", value: model.records.filter { !$0.installed.isSystem && $0.status(country: model.country) == .different }.count)
                            metric("待核对", value: model.records.filter { !$0.installed.isSystem && $0.status(country: model.country) == .unknown }.count)
                        }
                    }
                    .padding(.vertical, 8)
                    if !model.scanWarning.isEmpty { Text(model.scanWarning).font(.caption).foregroundStyle(.orange) }
                    if !model.queryWarning.isEmpty { Text(model.queryWarning).font(.caption).foregroundStyle(.orange) }
                }
                if model.busy {
                    Section {
                        HStack { ProgressView(); Text(model.activity).font(.subheadline) }
                        if model.isChecking { Button("停止查询", role: .cancel) { model.cancelCheck() } }
                    }
                }
                Section {
                    Toggle("显示差异项", isOn: $onlyDifferent)
                    Toggle("显示系统应用", isOn: $includeSystem)
                }
                Section("应用 · \(visible.count)") {
                    if visible.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            Label(model.records.isEmpty ? "暂无应用" : "无匹配应用", systemImage: "tray")
                                .font(.headline)
                            Text(model.records.isEmpty ? "设置连接后读取应用。" : "请调整搜索或筛选条件。")
                                .font(.subheadline).foregroundStyle(.secondary)
                        }.padding(.vertical, 12)
                    }
                    ForEach(visible) { record in
                        NavigationLink { AppDetailView(id: record.id) } label: { AppRow(record: record, country: model.country) }
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button { model.ignoreApp(record.id) } label: { Label("忽略", systemImage: "eye.slash") }
                                    .tint(.orange).disabled(model.busy)
                            }
                    }
                }
            }
            .navigationTitle("ssstore")
            .searchable(text: $search, prompt: "搜索应用或 Bundle ID")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button { settings = true } label: { Image(systemName: "gearshape") }
                        .accessibilityLabel("连接设置")
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Menu {
                        Button { model.checkUpdates(force: true) } label: { Label("刷新全部版本", systemImage: "arrow.triangle.2.circlepath") }
                        NavigationLink { InspectionView() } label: { Label("设备数据", systemImage: "server.rack") }
                    } label: { Image(systemName: "ellipsis.circle") }
                    .disabled(model.busy)
                }
                ToolbarItem(placement: .bottomBar) {
                    Button { Task { await model.scan() } } label: { Label("读取应用", systemImage: "iphone") }
                        .disabled(model.busy)
                }
                ToolbarItem(placement: .bottomBar) { Spacer() }
                ToolbarItem(placement: .bottomBar) {
                    Button { model.checkUpdates() } label: { Label("查询版本", systemImage: "arrow.clockwise") }
                        .disabled(model.busy || model.records.isEmpty)
                }
            }
            .sheet(isPresented: $settings) { SettingsView() }
            .alert("提示", isPresented: Binding(get: { model.message != nil && !settings }, set: { if !$0 { model.message = nil } })) {
                Button("好") { model.message = nil }
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
                Text("\(status == .current ? "本机" : "本机原始") \(record.displayedVersion(country: country) ?? "未知")  ·  商店 \(releaseLabel)")
                    .font(.caption).foregroundStyle(.secondary)
                if record.error != nil { Text("查询失败").font(.caption2).foregroundStyle(.orange) }
            }
            Spacer(minLength: 2)
            if status != .current {
                Text(status.rawValue).font(.caption2.bold())
                    .foregroundStyle(status == .different ? Color.orange : Color.secondary)
            }
        }.padding(.vertical, 4)
    }

    private var releaseLabel: String {
        guard let release = record.release, release.matches(scope: country) else { return "—" }
        return "\(release.version) · \(release.country.uppercased())"
    }
}

