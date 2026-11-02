import SwiftUI
import UIKit

/// Owns the native navigation search controller, including its dismissal.
struct NativeSearchBridge: UIViewControllerRepresentable {
    @Binding var text: String
    @Binding var presented: Bool
    var focused: FocusState<Bool>.Binding
    var onSubmit: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIViewController(context: Context) -> Anchor {
        let anchor = Anchor()
        anchor.install = { [weak coordinator = context.coordinator] controller in
            coordinator?.attach(to: controller)
        }
        return anchor
    }

    func updateUIViewController(_ anchor: Anchor, context: Context) {
        context.coordinator.parent = self
        context.coordinator.attach(to: anchor)
        context.coordinator.update()
    }

    static func dismantleUIViewController(_ anchor: Anchor, coordinator: Coordinator) {
        coordinator.detach()
    }

    final class Anchor: UIViewController {
        var install: ((UIViewController) -> Void)?
        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            install?(self)
        }
        override func didMove(toParent parent: UIViewController?) {
            super.didMove(toParent: parent)
            install?(self)
        }
    }

    final class Coordinator: NSObject, UISearchResultsUpdating, UISearchControllerDelegate, UISearchBarDelegate {
        var parent: NativeSearchBridge
        let search = UISearchController(searchResultsController: nil)
        weak var owner: UIViewController?
        private var syncing = false

        init(_ parent: NativeSearchBridge) {
            self.parent = parent
            super.init()
            search.obscuresBackgroundDuringPresentation = false
            search.hidesNavigationBarDuringPresentation = true
            search.searchResultsUpdater = self
            search.delegate = self
            search.searchBar.delegate = self
            search.searchBar.placeholder = NSLocalizedString("Keyword", comment: "")
        }

        func attach(to anchor: UIViewController) {
            guard let navigation = anchor.navigationController,
                  let host = navigation.viewControllers.first,
                  host.viewIfLoaded?.window != nil else { return }
            if owner !== host {
                detach()
                owner = host
                host.navigationItem.searchController = search
                host.navigationItem.hidesSearchBarWhenScrolling = false
                host.definesPresentationContext = true
            }
            update()
        }

        func detach() {
            if owner?.navigationItem.searchController === search {
                owner?.navigationItem.searchController = nil
            }
            owner = nil
        }

        func update() {
            guard owner != nil, !syncing else { return }
            if search.searchBar.text != parent.text { search.searchBar.text = parent.text }
            if parent.presented && !search.isActive {
                search.isActive = true
            }
            if parent.focused.wrappedValue && search.isActive && !search.searchBar.isFirstResponder {
                search.searchBar.becomeFirstResponder()
            }
        }

        func updateSearchResults(for searchController: UISearchController) {
            let value = searchController.searchBar.text ?? ""
            guard parent.text != value else { return }
            syncing = true
            parent.text = value
            syncing = false
        }

        func willPresentSearchController(_ searchController: UISearchController) {
            parent.presented = true
        }

        func didDismissSearchController(_ searchController: UISearchController) {
            parent.focused.wrappedValue = false
            parent.presented = false
        }

        func searchBarSearchButtonClicked(_ searchBar: UISearchBar) {
            parent.text = searchBar.text ?? ""
            searchBar.resignFirstResponder()
            parent.onSubmit()
        }
    }
}
