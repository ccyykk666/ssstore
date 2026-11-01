import SwiftUI

struct RootView: View {
    @EnvironmentObject private var model: AppModel
    var body: some View {
        TabView {
            ContentView().tabItem { Label("应用", systemImage: "square.stack.3d.up") }
            NavigationStack { InspectionView() }.tabItem { Label("数据", systemImage: "chart.bar.xaxis") }
            AccountView().tabItem { Label("账户", systemImage: "person.crop.circle") }
            SearchView().tabItem { Label("搜索", systemImage: "magnifyingglass") }
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
