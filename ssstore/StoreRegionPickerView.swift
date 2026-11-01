import ApplePackage
import SwiftUI
import UpdateCore

enum StoreRegionNames {
    static func name(_ code: String) -> String {
        if code == StoreQueryPolicy.chinaThenUS { return "中国大陆优先" }
        return Locale(identifier: "zh_Hans_CN").localizedString(forRegionCode: code.uppercased()) ?? code.uppercased()
    }
}

struct StoreRegionPickerView: View {
    @Binding var selection: String
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    private var regions: [String] {
        ApplePackage.Configuration.storeFrontValues.keys.map { $0.lowercased() }.filter {
            search.isEmpty || $0.localizedCaseInsensitiveContains(search) ||
            StoreRegionNames.name($0).localizedCaseInsensitiveContains(search) ||
            (Locale(identifier: "en_US").localizedString(forRegionCode: $0.uppercased()) ?? "").localizedCaseInsensitiveContains(search)
        }.sorted { StoreRegionNames.name($0).localizedStandardCompare(StoreRegionNames.name($1)) == .orderedAscending }
    }

    var body: some View {
        NavigationStack {
            List {
                if search.isEmpty || "中国大陆优先".contains(search) { regionRow(StoreQueryPolicy.chinaThenUS) }
                ForEach(regions, id: \.self) { regionRow($0) }
            }
            .searchable(text: $search, prompt: "搜索国家或地区")
            .navigationTitle("商店地区")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } } }
        }
        .modifier(SoftTopScrollEdge())
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }

    private func regionRow(_ code: String) -> some View {
        Button {
            selection = code
            UserDefaults.standard.set(code == StoreQueryPolicy.chinaThenUS ? "CN" : code.uppercased(), forKey: "searchRegion")
            dismiss()
        } label: {
            HStack {
                Text(StoreRegionNames.name(code)).foregroundStyle(.primary)
                if code != StoreQueryPolicy.chinaThenUS { Text(code.uppercased()).font(.caption).foregroundStyle(.secondary) }
                Spacer()
                if code == selection { Image(systemName: "checkmark") }
            }
        }
    }
}
