import SwiftUI
import UpdateCore

struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @State private var search = ""
    @State private var onlyFailed = false
    @State private var onlyAttention = false
    @AppStorage("includeSystemApps") private var includeSystem = false
    @State private var settings = false

    private var listedRecords: [AppRecord] {
        model.records.filter { includeSystem || !$0.installed.isSystem }
    }
    private var failureCount: Int { listedRecords.filter { $0.error != nil }.count }
    private var updateCount: Int { listedRecords.filter { $0.status(country: model.country) == .different }.count }
    private var applicationCount: Int {
        model.isRefreshingApps ? listedRecords.filter { model.processedApplicationIDs.contains($0.id) }.count : listedRecords.count
    }

    private var visible: [AppRecord] {
        listedRecords.filter { record in
            (!onlyFailed || record.error != nil) &&
            (!onlyAttention || record.status(country: model.country) != .current) &&
            (search.isEmpty || record.installed.name.localizedCaseInsensitiveContains(search) ||
             record.id.localizedCaseInsensitiveContains(search))
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack(alignment: .top, spacing: 12) {
                            metric("应用", value: applicationCount)
                            metric("有更新", value: updateCount)
                            metric("待核对", value: listedRecords.filter { $0.error == nil && $0.status(country: model.country) == .unknown }.count)
                            if failureCount > 0 {
                                Button { onlyFailed.toggle() } label: { metric("失败", value: failureCount) }
                                    .buttonStyle(.plain)
                                    .foregroundStyle(onlyFailed ? Color.orange : Color.primary)
                                    .accessibilityLabel("\(failureCount) 个失败项，点按筛选")
                                    .accessibilityAddTraits(onlyFailed ? [.isSelected] : [])
                            }
                        }
                    }
                    .padding(.vertical, 8)
                    if !model.scanWarning.isEmpty { Text(model.scanWarning).font(.caption).foregroundStyle(.orange) }
                    if !model.queryWarning.isEmpty { Text(model.queryWarning).font(.caption).foregroundStyle(.orange) }
                }
                Section("共\(visible.count)个应用") {
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
                        .accessibilityLabel("设置")
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Menu {
                        Button { Task { await model.refreshApps() } } label: {
                            Label("刷新应用", systemImage: "arrow.triangle.2.circlepath")
                        }.disabled(model.busy)
                        if model.isChecking {
                            Button("停止刷新", role: .cancel) { model.cancelCheck() }
                        }
                        NavigationLink { DownloadView(embedded: true) } label: { Label("下载", systemImage: "arrow.down.circle") }
                        Button { onlyAttention.toggle() } label: {
                            Label("有更新与待核对", systemImage: onlyAttention ? "checkmark.circle.fill" : "circle")
                        }
                        .menuActionDismissBehavior(.disabled)
                        .accessibilityAddTraits(onlyAttention ? [.isSelected] : [])
                        Button { includeSystem.toggle() } label: {
                            Label("显示系统应用", systemImage: includeSystem ? "checkmark.circle.fill" : "circle")
                        }
                        .menuActionDismissBehavior(.disabled)
                        .accessibilityAddTraits(includeSystem ? [.isSelected] : [])
                    } label: { Image(systemName: "ellipsis.circle") }
                }
            }
            .onChange(of: failureCount) { _, count in if count == 0 { onlyFailed = false } }
            .sheet(isPresented: $settings) { SettingsView() }
            .alert("提示", isPresented: Binding(get: { model.message != nil && !settings }, set: { if !$0 { model.message = nil } })) {
                Button("好") { model.message = nil }
            } message: { Text(model.message ?? "") }
        }
    }

    private func metric(_ title: String, value: Int) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            AnimatedMetricNumber(value: Double(value))
                .font(.title.bold().monospacedDigit())
                .animation(value == 0 ? nil : .linear(duration: 0.6), value: value)
            Text(title).font(.caption).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Interpolate the displayed integer itself so batches count through their
/// intermediate values at a constant speed, rather than jumping to a new total.
private struct AnimatedMetricNumber: View, Animatable {
    var value: Double
    var animatableData: Double {
        get { value }
        set { value = newValue }
    }
    var body: some View {
        Text(Int(value.rounded()), format: .number)
            .contentTransition(.numericText(value: value))
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
                Text("本机 \(record.displayedVersion(country: country) ?? "未知")  ·  商店 \(releaseLabel)")
                    .font(.caption).foregroundStyle(.secondary)
                if record.error != nil { Text("查询失败").font(.caption2).foregroundStyle(.orange) }
            }
            Spacer(minLength: 2)
            if status == .different || status == .update {
                Text("有更新").font(.caption2.bold()).foregroundStyle(.green)
            } else if status == .unknown {
                Text("待核对").font(.caption2.bold()).foregroundStyle(.secondary)
            }
        }.padding(.vertical, 4)
    }

    private var releaseLabel: String {
        guard let release = record.release, release.matches(scope: country) else { return "—" }
        return release.version
    }
}


