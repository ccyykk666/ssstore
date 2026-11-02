import SwiftUI

struct RootView: View {
    @EnvironmentObject private var model: AppModel
    var body: some View {
        NativeAppTabs(model: model)
        .sheet(item: $model.filePresentation) { item in
            switch item.kind {
            case .preview: FilePreviewSheet(url: item.url)
            case .share: FileShareSheet(url: item.url)
            }
        }
    }
}

