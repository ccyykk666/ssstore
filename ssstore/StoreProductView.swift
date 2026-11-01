import ApplePackage
import SwiftUI

struct StoreProductView: View {
    let bundleID: String
    let region: String
    @State private var package: AppStore.AppPackage?
    @State private var failure: String?
    @State private var selectedDownload: PackageManifest?
    @State private var navigationPath = NavigationPath()

    var body: some View {
        Group {
            if let package {
                ProductView(archive: package, region: region.uppercased(), navigationPath: $navigationPath) { selectedDownload = $0 }
            } else if let failure {
                ContentUnavailableView {
                    Label("未取得商店信息", systemImage: "exclamationmark.triangle")
                } description: { Text(failure) } actions: {
                    Button("重试") { Task { await load() } }
                }
            } else {
                ProgressView("正在查询商店…")
            }
        }
        .navigationDestination(item: $selectedDownload) { PackageView(pkg: $0) }
        .task { if package == nil && failure == nil { await load() } }
    }

    private func load() async {
        failure = nil
        do {
            let software = try await ApplePackage.Lookup.lookup(bundleID: bundleID, countryCode: region.uppercased())
            guard software.bundleID == bundleID else {
                throw NSError(domain: "ssstore.Store", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "商店返回的应用标识不符。"])
            }
            package = AppStore.AppPackage(software: software, entityType: .iPhone)
        } catch { failure = error.localizedDescription }
    }
}
