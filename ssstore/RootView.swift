import SwiftUI

struct RootView: View {
    @EnvironmentObject private var model: AppModel
    var body: some View {
        TabView {
            ContentView().tabItem { Label("应用", systemImage: "square.stack.3d.up") }
            SearchView().tabItem { Label("商店", systemImage: "magnifyingglass") }
            NavigationStack { InspectionView() }.tabItem { Label("设备数据", systemImage: "server.rack") }
            AccountView().tabItem { Label("账户", systemImage: "person.crop.circle") }
        }
        .neverMinimizeTab()
        .sheet(item: $model.filePresentation) { item in
            switch item.kind {
            case .preview: FilePreviewSheet(url: item.url)
            case .share: FileShareSheet(url: item.url)
            }
        }
    }
}
