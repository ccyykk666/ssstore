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
    private var progress: ApplicationMatchProgress? {
        guard let progress = model.matchProgress, progress.scope == model.country else { return nil }
        return progress
    }
    private var revealedIDs: Set<String>? { progress.map { Set($0.revealedMatches.map(\.id)) } }
    private var statistics: ApplicationMatchStatistics {
        if let progress {
            return progress.statistics(visibleIDs: Set(listedRecords.map(\.id)))
        }
        return ApplicationMatchStatistics(matches: listedRecords.map { ApplicationMatch(record: $0, scope: model.country) })
    }
    private var failureCount: Int { statistics.failures }

    private var visible: [AppRecord] {
        listedRecords.filter { record in
            (!onlyFailed || ((revealedIDs?.contains(record.id) ?? true) && record.error != nil)) &&
            (!onlyAttention || ((revealedIDs?.contains(record.id) ?? true) && record.status(country: model.country) != .current)) &&
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
                            metric("应用", value: statistics.applications)
                            metric("有更新", value: statistics.updates)
                            metric("待核对", value: statistics.pending)
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
                    .id(progress?.id)
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
                        NavigationLink { AppDetailView(id: record.id) } label: { AppRow(record: record, country: model.country, showStatus: revealedIDs?.contains(record.id) ?? true) }
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
            Text(value, format: .number)
                .font(.title.bold().monospacedDigit())
                .contentTransition(.numericText(value: Double(value)))
            Text(title).font(.caption).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct AppRow: View {
    let record: AppRecord
    let country: String
    let showStatus: Bool
    private var status: UpdateStatus { record.status(country: country) }

    var body: some View {
        HStack(spacing: 12) {
            AppIconView(app: record.installed, storeIconURL: record.release?.iconURL)
            VStack(alignment: .leading, spacing: 5) {
                Text(record.installed.name).font(.headline).lineLimit(1)
                Text("本机 \(record.displayedVersion(country: country) ?? "未知")  ·  商店 \(releaseLabel)")
                    .font(.caption).foregroundStyle(.secondary)
                if showStatus && record.error != nil { Text("查询失败").font(.caption2).foregroundStyle(.orange) }
            }
            Spacer(minLength: 2)
            if showStatus && (status == .different || status == .update) {
                Text("有更新").font(.caption2.bold()).foregroundStyle(.green)
            } else if showStatus && status == .unknown {
                Text("待核对").font(.caption2.bold()).foregroundStyle(.secondary)
            }
        }.padding(.vertical, 4)
    }

    private var releaseLabel: String {
        guard let release = record.release, release.matches(scope: country) else { return "—" }
        return release.version
    }
}


