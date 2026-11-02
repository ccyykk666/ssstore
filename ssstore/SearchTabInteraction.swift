import SwiftUI
import UIKit

/// Observes native tab reselection without replacing the system tab bar.
struct SearchTabInteraction: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> ObserverController { ObserverController() }
    func updateUIViewController(_ controller: ObserverController, context: Context) {
        DispatchQueue.main.async { [weak controller] in controller?.install() }
    }

    static func dismantleUIViewController(_ controller: ObserverController, coordinator: ()) {
        controller.restoreDelegate()
    }

    final class ObserverController: UIViewController {
        private let proxy = DelegateProxy()
        private weak var observedTabs: UITabBarController?

        override func loadView() {
            view = UIView()
            view.isUserInteractionEnabled = false
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            install()
        }

        override func didMove(toParent parent: UIViewController?) {
            super.didMove(toParent: parent)
            DispatchQueue.main.async { [weak self] in self?.install() }
        }

        func install() {
            guard viewIfLoaded?.window != nil else { return }
            var ancestor: UIViewController = self
            while let parent = ancestor.parent { ancestor = parent }
            guard let tabs = findTabs(in: ancestor) else { return }
            if observedTabs !== tabs {
                restoreDelegate()
                observedTabs = tabs
            }
            guard tabs.delegate !== proxy else { return }
            proxy.original = tabs.delegate
            tabs.delegate = proxy
        }

        func restoreDelegate() {
            proxy.focusTask?.cancel()
            if let tabs = observedTabs, tabs.delegate === proxy {
                tabs.delegate = proxy.original
            }
            observedTabs = nil
        }

        private func findTabs(in controller: UIViewController) -> UITabBarController? {
            if let tabs = controller as? UITabBarController { return tabs }
            for child in controller.children {
                if let tabs = findTabs(in: child) { return tabs }
            }
            return nil
        }
    }

    /// Forward unhandled optional delegate methods to SwiftUI's existing delegate.
    final class DelegateProxy: NSObject, UITabBarControllerDelegate {
        weak var original: (any UITabBarControllerDelegate)?
        var focusTask: Task<Void, Never>?
        private var reselectedSearch = false

        override func responds(to selector: Selector!) -> Bool {
            super.responds(to: selector) || (original?.responds(to: selector) ?? false)
        }

        override func forwardingTarget(for selector: Selector!) -> Any? {
            original?.responds(to: selector) == true ? original : super.forwardingTarget(for: selector)
        }

        func tabBarController(_ tabs: UITabBarController, shouldSelect controller: UIViewController) -> Bool {
            let isReselection = tabs.selectedViewController === controller &&
                tabs.viewControllers?.last === controller && tabs.viewControllers?.count == 4
            let allowed = original?.tabBarController?(tabs, shouldSelect: controller) ?? true
            reselectedSearch = allowed && isReselection
            return allowed
        }

        func tabBarController(_ tabs: UITabBarController, didSelect controller: UIViewController) {
            original?.tabBarController?(tabs, didSelect: controller)
            guard reselectedSearch else { return }
            reselectedSearch = false
            guard tabs.presentedViewController == nil else { return }
            SearchFieldFocus.shared.requestFocus()
            focusTask?.cancel()
            focusTask = Task { @MainActor [weak tabs, weak controller] in
                // Wait for the navigation stack to return to search and for
                // SwiftUI to mount its search field. Never search another window.
                for _ in 0..<12 {
                    do { try await Task.sleep(for: .milliseconds(50)) } catch { return }
                    guard let tabs, let controller, tabs.selectedViewController === controller,
                          tabs.presentedViewController == nil else { return }
                    if let field = Self.searchField(in: controller.view), field.window != nil {
                        if field.becomeFirstResponder() {
                            do { try await Task.sleep(for: .milliseconds(50)) } catch { return }
                            guard tabs.selectedViewController === controller, field.isFirstResponder else { return }
                            field.selectAll(nil)
                            return
                        }
                    }
                }
            }
        }

        private static func searchField(in view: UIView) -> UISearchTextField? {
            guard !view.isHidden, view.alpha > 0.01 else { return nil }
            if let field = view as? UISearchTextField { return field }
            if let bar = view as? UISearchBar { return bar.searchTextField }
            for child in view.subviews {
                if let field = searchField(in: child) { return field }
            }
            return nil
        }
    }
}
