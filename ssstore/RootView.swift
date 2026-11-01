import SwiftUI

struct RootView: View {
    @State private var downloads = Downloads.this

    var body: some View {
        TabView {
            ContentView().tabItem { Label("应用", systemImage: "square.stack.3d.up") }
            SearchView().tabItem { Label("商店", systemImage: "magnifyingglass") }
            DownloadView().tabItem { Label("下载", systemImage: "arrow.down.circle") }
                .badge(downloads.runningTaskCount)
            AccountView().tabItem { Label("账户", systemImage: "person.crop.circle") }
        }
    }
}
