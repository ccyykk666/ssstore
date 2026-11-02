import SwiftUI
import UpdateCore

struct ApplicationPickerView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @Binding var selection: String
    @State private var search = ""
    @AppStorage("includeSystemApps") private var includeSystem = false

    private var apps: [AppRecord] {
        model.records.filter {
            (includeSystem || !$0.installed.isSystem) &&
            (search.isEmpty || $0.installed.name.localizedCaseInsensitiveContains(search) ||
             $0.id.localizedCaseInsensitiveContains(search))
        }.sorted { $0.installed.name.localizedStandardCompare($1.installed.name) == .orderedAscending }
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(apps) { record in
                    Button { select(record.id) } label: {
                        HStack(spacing: 12) {
                            AppIconView(app: record.installed, storeIconURL: record.release?.iconURL)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(record.installed.name).foregroundStyle(.primary)
                                Text(record.id).font(.caption).foregroundStyle(.primary)
                            }
                            Spacer()
                            if record.id == selection { Image(systemName: "checkmark").foregroundStyle(Color.accentColor) }
                        }
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.primary)
                }
            }
            .searchable(text: $search, prompt: "搜索应用或 Bundle ID")
            .navigationTitle("选择应用")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } } }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }

    private func select(_ id: String) { selection = id; dismiss() }
}

