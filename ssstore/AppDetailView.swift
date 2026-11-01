import SwiftUI
import UIKit
import UpdateCore

struct AppDetailView: View {
    @EnvironmentObject private var model: AppModel
    let id: String
    private var record: AppRecord? { model.records.first { $0.id == id } }

    var body: some View {
        Group {
            if let record {
                List {
                    Section {
                        HStack(spacing: 12) {
                            AppIconView(app: record.installed, storeIconURL: record.release?.iconURL, size: 60)
                            Text(record.installed.name).font(.title2.bold())
                            Spacer(minLength: 8)
                            Button("查询") { model.checkUpdates(only: id) }
                                .buttonStyle(.bordered).disabled(model.busy)
                        }
                        field(record.status(country: model.country) == .current ? "本机版本（商店）" : "本机版本（原始）", record.displayedVersion(country: model.country) ?? "未知")
                        field("原始版本", record.installed.version ?? "未提供")
                        field("原始构建号", record.installed.build ?? "未提供")
                        field("本机版本标识", record.installed.externalVersionID ?? "未获取，请重新读取")
                        field("Bundle ID", record.id)
                    }
                    Section("本机数据") {
                        NavigationLink { InspectionView(bundleID: record.id) } label: { Label("应用数据", systemImage: "doc.text.magnifyingglass") }
                        if let note = record.installed.versionReadNote {
                            Text(note).font(.footnote).foregroundStyle(.secondary)
                        }
                        if let version = record.installed.coreDeviceVersion { field("CoreDevice · version", version) }
                        if let build = record.installed.coreDeviceBuild { field("CoreDevice · bundleVersion", build) }
                        if let version = record.installed.browseVersion { field("Browse · CFBundleShortVersionString", version) }
                        if let build = record.installed.browseBuild { field("Browse · CFBundleVersion", build) }
                        if let version = record.installed.metadataVersion { field("安装元数据 · bundleShortVersionString", version) }
                        if let build = record.installed.metadataBuild { field("安装元数据 · bundleVersion", build) }
                    }
                    if let release = record.release {
                        Section("商店版本 · \(release.country.uppercased())") {
                            field("最新版本", release.version)
                            field("更新时间", release.releasedAt ?? "未提供")
                            field("最低系统版本", release.minimumOS ?? "未提供")
                            field("查询时间", release.fetchedAt.formatted())
                            field("商店版本标识", release.externalVersionID ?? "未获取，请重新查询")
                            if !release.matches(scope: model.country) { Text("结果与当前查询设置不符，请重新查询。").foregroundStyle(.orange) }
                            if model.country == StoreQueryPolicy.chinaThenUS && release.country == "us" && release.lookupScope == model.country {
                                Text("美国商店结果。更新取决于安装渠道和账户地区。")
                                    .font(.footnote).foregroundStyle(.secondary)
                            }
                            if let minimumOS = release.minimumOS,
                               VersionOrder.status(installed: UIDevice.current.systemVersion, latest: minimumOS) == .update {
                                Label("需要更高版本的 iOS。", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                            }
                        }
                        Section("更新说明") {
                            Text(release.notes?.isEmpty == false ? release.notes! : "暂无更新说明。")
                                .textSelection(.enabled)
                        }
                    }
                    if let error = record.error {
                        Section("查询结果") {
                            Text(error).foregroundStyle(.orange).textSelection(.enabled)
                            if record.release != nil { Text("显示上次查询结果。").font(.caption) }
                        }
                    }
                }
            } else {
                Text("应用已不在清单中。")
            }
        }
        .navigationTitle("版本详情")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func field(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).textSelection(.enabled)
        }.padding(.vertical, 2)
    }
}

