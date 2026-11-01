import SwiftUI

@main
struct SSStoreApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView().environmentObject(model)
                .modifier(SoftTopScrollEdge())
        }
    }
}

private struct SoftTopScrollEdge: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.scrollEdgeEffectStyle(.soft, for: .top)
        } else {
            content
        }
    }
}

