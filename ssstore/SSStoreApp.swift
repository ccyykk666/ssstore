import SwiftUI

@main
struct SSStoreApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup { ContentView().environmentObject(model) }
    }
}
