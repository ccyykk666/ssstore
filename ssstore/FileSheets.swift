import SwiftUI
import UIKit

struct FilePresentation: Identifiable {
    enum Kind { case preview, share }
    let id = UUID()
    let url: URL
    let kind: Kind
}

struct FilePreviewSheet: View {
    let url: URL
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            QuickLookFile(url: url)
                .navigationTitle(url.lastPathComponent)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }
}

struct ShareFileButton: View {
    @EnvironmentObject private var model: AppModel
    let title: String
    let url: URL

    var body: some View {
        Button { model.filePresentation = FilePresentation(url: url, kind: .share) } label: {
            Label(title, systemImage: "square.and.arrow.up")
        }
    }
}

struct FileShareSheet: View {
    let url: URL
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ActivitySheet(items: [url]) { dismiss() }
            .safeAreaInset(edge: .top) {
                HStack {
                    Text("分享").font(.headline)
                    Spacer()
                    Button("完成") { dismiss() }
                }.padding().background(.bar)
            }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}

private struct ActivitySheet: UIViewControllerRepresentable {
    let items: [Any]
    let completion: () -> Void

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: items, applicationActivities: nil)
        controller.completionWithItemsHandler = { _, completed, _, _ in
            if completed { completion() }
        }
        return controller
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

