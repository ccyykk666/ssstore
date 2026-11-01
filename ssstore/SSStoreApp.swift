import SwiftUI

@main
struct SSStoreApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()

    init() { StoreRuntime.prepare() }

    var body: some Scene {
        WindowGroup {
            RootView().environmentObject(model)
                .modifier(SoftTopScrollEdge())
        }
    }
}

struct SoftTopScrollEdge: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.scrollEdgeEffectStyle(.soft, for: .top)
        } else {
            content
        }
    }
}


