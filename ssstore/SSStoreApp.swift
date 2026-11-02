import UIKit

@main
final class SSStoreApplication: AppDelegate {
    var window: UIWindow?
    override func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        StoreRuntime.prepare()
        let model = AppModel()
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = NativeTabs(model: model)
        window.makeKeyAndVisible()
        self.window = window
        return super.application(application, didFinishLaunchingWithOptions: launchOptions)
    }
}

