import SwiftUI
import UpdateCore

struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @State private var search = ""
    @State private var onlyFailed = false
    @State private var onlyDifferent = false
    @AppStorage("includeSystemApps") private var includeSystem = false
    @State private var settings = false

    private var listedRecords: [AppRecord] {
        model.records.filter { includeSystem || !$0.installed.isSystem }
    }
    private var failureCount: Int { listedRecords.filter { $0.error != nil }.count }
    private var differenceCount: Int { listedRecords.filter { $0.status(country: model.country) != .current }.count }

    private var visible: [AppRecord] {
        listedRecords.filter { record in
            (!onlyFailed || record.error != nil) &&
            (!onlyDifferent || record.status(country: model.country) != .current) &&
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
                            metric("应用", value: listedRecords.count)
                            metric("差异项", value: differenceCount)
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
                if model.busy {
                    Section {
                        HStack {
                            ProgressView()
                            if model.isChecking {
                                HStack(spacing: 0) {
                                    Text(model.lookupCompleted, format: .number)
                                        .contentTransition(.numericText(value: Double(model.lookupCompleted)))
                                        .animation(.snappy(duration: 0.3), value: model.lookupCompleted)
                                    Text("/\(model.lookupTotal)")
                                }
                                .monospacedDigit()
                                .font(.subheadline)
                                .accessibilityElement(children: .ignore)
                                .accessibilityLabel("已查询 \(model.lookupCompleted) 个，共 \(model.lookupTotal) 个")
                            } else {
                                Text(model.activity).font(.subheadline)
                            }
                        }
                        if model.isChecking { Button("停止查询", role: .cancel) { model.cancelCheck() } }
                    }
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
                        Button { Task { await model.scan() } } label: { Label("读取应用", systemImage: "iphone") }
                        Button { model.checkUpdates(force: true) } label: { Label("刷新全部版本", systemImage: "arrow.triangle.2.circlepath") }
                            .disabled(model.records.isEmpty)
                        NavigationLink { DownloadView(embedded: true) } label: { Label("下载", systemImage: "arrow.down.circle") }
                        Button { onlyDifferent.toggle() } label: {
                            Label("显示差异项", systemImage: onlyDifferent ? "checkmark.circle.fill" : "circle")
                        }
                        .menuActionDismissBehavior(.disabled)
                        .accessibilityAddTraits(onlyDifferent ? [.isSelected] : [])
                        Button { includeSystem.toggle() } label: {
                            Label("显示系统应用", systemImage: includeSystem ? "checkmark.circle.fill" : "circle")
                        }
                        .menuActionDismissBehavior(.disabled)
                        .accessibilityAddTraits(includeSystem ? [.isSelected] : [])
                    } label: { Image(systemName: "ellipsis.circle") }
                    .disabled(model.busy)
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
            Text(value, format: .number).font(.title.bold().monospacedDigit())
                .contentTransition(.numericText(value: Double(value)))
                .animation(.snappy(duration: 0.3), value: value)
            Text(title).font(.caption).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading)
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
        return release.version
    }
}


