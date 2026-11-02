import SwiftUI
import UIKit

/// Own the native tab controller so SwiftUI cannot replace its selection delegate.
struct NativeAppTabs: UIViewControllerRepresentable {
    let model: AppModel

    func makeUIViewController(context: Context) -> Controller {
        let controller = Controller()
        controller.setViewControllers([
            host(ContentView(), title: "应用", icon: "square.stack.3d.up"),
            host(NavigationStack { InspectionView() }, title: "数据", icon: "chart.bar.xaxis"),
            host(AccountView(), title: "账户", icon: "person.crop.circle"),
            host(SearchView(), title: "搜索", icon: "magnifyingglass"),
        ], animated: false)
        return controller
    }

    func updateUIViewController(_ controller: Controller, context: Context) {}

    static func dismantleUIViewController(_ controller: Controller, coordinator: ()) {
        controller.cancelFocus()
    }

    private func host<Content: View>(_ content: Content, title: String, icon: String) -> UIViewController {
        let host = UIHostingController(rootView: content.environmentObject(model).modifier(SoftTopScrollEdge()))
        host.tabBarItem = UITabBarItem(title: title, image: UIImage(systemName: icon), selectedImage: nil)
        return host
    }

    final class Controller: UITabBarController, UITabBarControllerDelegate {
        private var reselectedSearch = false
        private var focusTask: Task<Void, Never>?

        override func viewDidLoad() {
            super.viewDidLoad()
            delegate = self
            if #available(iOS 26.0, *) { tabBarMinimizeBehavior = .never }
        }

        func tabBarController(_ tabs: UITabBarController, shouldSelect controller: UIViewController) -> Bool {
            cancelFocus()
            reselectedSearch = selectedViewController === controller && viewControllers?.last === controller
            return true
        }

        func tabBarController(_ tabs: UITabBarController, didSelect controller: UIViewController) {
            guard reselectedSearch else { return }
            reselectedSearch = false
            guard !hasBlockingPresentation else { return }
            SearchFieldFocus.shared.requestFocus()
            focusTask = Task { @MainActor [weak self, weak controller] in
                // SearchView first activates its search presentation and pops
                // back from any product. Select only its visible input field.
                for _ in 0..<30 {
                    do { try await Task.sleep(for: .milliseconds(50)) } catch { return }
                    guard let self, let controller, selectedViewController === controller,
                          !hasBlockingPresentation, controller.viewIfLoaded?.window != nil else { return }
                    if let field = Self.searchField(in: controller.view), field.becomeFirstResponder() {
                        do { try await Task.sleep(for: .milliseconds(50)) } catch { return }
                        guard selectedViewController === controller, !hasBlockingPresentation,
                              field.isFirstResponder else { continue }
                        field.selectAll(nil)
                        return
                    }
                }
            }
        }

        private var hasBlockingPresentation: Bool {
            // Activating UISearchController is part of focusing search, not
            // an unrelated modal that should cancel the focus request.
            guard let presented = presentedViewController else { return false }
            return !(presented is UISearchController)
        }

        func cancelFocus() {
            focusTask?.cancel()
            focusTask = nil
        }

        private static func searchField(in view: UIView) -> UISearchTextField? {
            guard !view.isHidden, view.alpha > 0.01, view.window != nil else { return nil }
            if let field = view as? UISearchTextField { return field }
            if let bar = view as? UISearchBar { return bar.searchTextField }
            for child in view.subviews {
                if let field = searchField(in: child) { return field }
            }
            return nil
        }
    }
}
