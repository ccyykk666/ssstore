import SwiftUI
import UIKit
import UpdateCore

struct AppIconView: View {
    @EnvironmentObject private var model: AppModel
    let app: InstalledApp
    let storeIconURL: URL?
    var size: CGFloat = 46
    @State private var localImage: UIImage?

    var body: some View {
        Group {
            if let localImage {
                Image(uiImage: localImage).resizable().scaledToFill()
            } else {
                AsyncImage(url: storeIconURL) { phase in
                    if let image = phase.image { image.resizable().scaledToFill() }
                    else { placeholder }
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.22))
        .accessibilityLabel(localImage == nil ? "\(app.name)图标" : "\(app.name)本地图标")
        .task(id: "\(app.localIconKey ?? "")-\(model.iconRevision)") {
            guard let url = model.localIconURL(for: app) else { localImage = nil; return }
            if let data = await LocalIconData.shared.read(url) { localImage = UIImage(data: data) }
            else { localImage = nil }
        }
    }

    private var placeholder: some View {
        ZStack {
            Color.accentColor.opacity(0.1)
            Image(systemName: app.isSystem ? "gearshape.2" : "app.dashed")
                .font(.title2).foregroundStyle(.tint)
        }
    }
}

private actor LocalIconData {
    static let shared = LocalIconData()
    private let cache: NSCache<NSURL, NSData> = {
        let cache = NSCache<NSURL, NSData>()
        cache.totalCostLimit = 24 * 1024 * 1024
        return cache
    }()

    func read(_ url: URL) -> Data? {
        if let data = cache.object(forKey: url as NSURL) { return data as Data }
        guard let data = try? Data(contentsOf: url) else { return nil }
        cache.setObject(data as NSData, forKey: url as NSURL, cost: data.count)
        return data
    }
}
