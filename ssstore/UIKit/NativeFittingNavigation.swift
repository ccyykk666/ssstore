import UIKit

/// Native scrollable content shares the adaptive UIKit sheet container.
@MainActor
protocol NativeSheetContent: AnyObject {
    var sheetScrollView: UIScrollView { get }
    var sheetContentHeight: CGFloat { get }
}

@MainActor
final class NativeFittingNavigation: UINavigationController, UINavigationControllerDelegate {
    private var fittedHeight: CGFloat = 0
    private var updateQueued = false
    private var applyingHeight = false
    private var changingPage = false

    init(root: UIViewController & NativeSheetContent) {
        super.init(rootViewController: root)
        delegate = self
        modalPresentationStyle = .pageSheet
        sheetPresentationController?.detents = [.custom(identifier: .init("content")) { [weak self] context in
            // Resolving a detent only reads the last stable measurement. It
            // must never force layout or mutate UIKit's preferredContentSize.
            guard let height = self?.fittedHeight, height > 0 else { return context.maximumDetentValue }
            return min(height, context.maximumDetentValue)
        }]
        sheetPresentationController?.prefersGrabberVisible = true
        sheetPresentationController?.prefersEdgeAttachedInCompactHeight = true
    }
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        updateContentSize()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // A layout callback must not synchronously force the child's layout
        // and invalidate this same presentation controller again.
        updateContentSize()
    }

    func navigationController(_ navigationController: UINavigationController, willShow viewController: UIViewController, animated: Bool) {
        changingPage = true
    }

    func navigationController(_ navigationController: UINavigationController, didShow viewController: UIViewController, animated: Bool) {
        changingPage = false
        updateContentSize()
    }

    /// Coalesce notifications from both the navigation view and its scrollable
    /// child. All measurement and detent changes happen after the layout pass.
    func updateContentSize() {
        guard !updateQueued, !applyingHeight else { return }
        updateQueued = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.updateQueued = false
            self.applyContentSize()
        }
    }

    private func applyContentSize() {
        // Incoming and outgoing views temporarily have different frames during
        // a push/pop. Measuring those frames can feed the transition's changing
        // height back into the sheet. didShow requests a stable measurement.
        guard !changingPage, !isBeingDismissed, viewIfLoaded?.window != nil,
              presentedViewController == nil,
              let content = topViewController as? (UIViewController & NativeSheetContent), content.isViewLoaded else { return }
        let scroll = content.sheetScrollView
        guard scroll.bounds.width > 0, scroll.bounds.height > 0 else { return }
        applyingHeight = true
        defer { applyingHeight = false }
        let chrome = view.bounds.height - scroll.bounds.height
            + scroll.adjustedContentInset.top + scroll.adjustedContentInset.bottom - view.safeAreaInsets.bottom
        let height = content.sheetContentHeight + chrome
        guard height.isFinite, height > 0 else { return }
        let scale = max(1, traitCollection.displayScale)
        let rounded = ceil(height * scale) / scale
        guard abs(fittedHeight - rounded) >= 0.5 / scale else { return }
        fittedHeight = rounded
        sheetPresentationController?.invalidateDetents()
    }
}
