import SwiftUI
import UIKit
import UpdateCore

struct AppDetailView: View {
    @EnvironmentObject private var model: AppModel
    let id: String
    @State private var mapping = ""
    private var record: AppRecord? { model.records.first { $0.id == id } }

    var body: some View {
        Group {
            if let record {
                List {
                    Section {
                        HStack(spacing: 12) {
                            AppIconView(app: record.installed, storeIconURL: record.release?.iconURL, size: 60)
                            Text(record.installed.name).font(.title2.bold())
                        }
                        Text(record.status(country: model.country).rawValue)
                            .foregroundStyle(record.status(country: model.country) == .update ? Color.orange : Color.secondary)
                        field("本机版本", record.displayedVersion(country: model.country) ?? "未知")
                        if let explanation = record.versionExplanation(country: model.country) {
                            Text(explanation).font(.footnote).foregroundStyle(.secondary)
                        }
                        field("原始版本字段 · CFBundleShortVersionString", record.installed.version ?? "未提供")
                        field("原始构建字段 · CFBundleVersion", record.installed.build ?? "未提供")
                        if let external = record.installed.externalVersionID { field("本机商店版本标识", external) }
                        field("Bundle ID", record.id)
                        if let date = model.scannedAt { field("清单记录时间", date.formatted()) }
                    }
                    if let release = record.release {
                        Section("商店版本 · \(release.country.uppercased())") {
                            field("最新版本", release.version)
                            field("更新时间", release.releasedAt ?? "未提供")
                            field("最低系统版本", release.minimumOS ?? "未提供")
                            field("数据获取时间", release.fetchedAt.formatted())
                            field("数据来源", release.source ?? "iTunes Lookup（旧记录）")
                            if let external = release.externalVersionID { field("商店版本标识", external) }
                            if !release.matches(scope: model.country) { Text("这份结果不属于当前查询方式，请重新查询。").foregroundStyle(.orange) }
                            if model.country == StoreQueryPolicy.chinaThenUS && release.country == "us" && release.lookupScope == model.country {
                                Text("中国区未找到此应用，本次使用美区补查结果。能否更新取决于安装渠道与账号地区。")
                                    .font(.footnote).foregroundStyle(.secondary)
                            }
                            if let minimumOS = release.minimumOS,
                               VersionOrder.status(installed: UIDevice.current.systemVersion, latest: minimumOS) == .update {
                                Label("此版本要求更新的 iOS 系统。", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                            }
                        }
                        Section("最新版本更新说明") {
                            Text(release.notes?.isEmpty == false ? release.notes! : "开发者未提供更新说明。")
                                .textSelection(.enabled)
                            Text("这里只展示最新版本说明，未合并你当前版本之后的所有历史日志。")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if let error = record.error {
                        Section("查询结果") {
                            Text(error).foregroundStyle(.orange).textSelection(.enabled)
                            if record.release != nil { Text("上方保留的是上一次成功获取的数据。").font(.caption) }
                        }
                    }
                    Section {
                        TextField("原始 Bundle ID（留空使用本机标识）", text: $mapping)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                        Button("保存绑定") { model.setMapping(id: id, bundleID: mapping) }
                        Button("查询此应用") { model.checkUpdates(only: id) }
                    } header: { Text("商店匹配") } footer: {
                        Text("自签工具可能改写标识。请填原应用的 Bundle ID，不要填应用名称或数字商店 ID。单独查询会跳过 5 分钟缓存。")
                    }.disabled(model.busy)
                }
                .onAppear { mapping = record.lookupBundleID ?? "" }
            } else {
                Text("此应用已不在当前清单中。")
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
