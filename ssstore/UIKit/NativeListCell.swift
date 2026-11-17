import UIKit

struct NativeIconRequest: Equatable, Sendable {
    let url: URL
    let size: CGFloat
    let scale: CGFloat
    let revision: Int
}

/// Keeps one display-sized image/request. Progress and text changes do not
/// restart decoding; callbacks from cancelled/reused requests are discarded.
@MainActor
final class NativeIconState {
    typealias Loader = (NativeIconRequest, @escaping (UIImage?) -> Void) -> (() -> Void)?
    private var request: NativeIconRequest?
    private var generation = UUID()
    private var cancel: (() -> Void)?
    private var loading = false
    private(set) var image: UIImage?

    deinit { cancel?() }
    func reset() {
        generation = UUID(); cancel?(); cancel = nil
        request = nil; image = nil; loading = false
    }
    func update(_ request: NativeIconRequest?, load: Loader, onChange: @escaping (UIImage) -> Void) -> UIImage? {
        guard let request else { reset(); return nil }
        if self.request != request { reset(); self.request = request }
        guard image == nil, !loading else { return image }
        let token = generation
        loading = true
        let cancellation = load(request) { [weak self] image in
            guard let self, self.generation == token else { return }
            self.loading = false; self.cancel = nil; self.image = image
            if let image { onChange(image) }
        }
        // The loader can finish synchronously from a memory cache.
        if loading { cancel = cancellation }
        return image
    }
}

@MainActor
final class NativeCell: UITableViewCell {
    let progressFill = NativeProgressFill(frame: .zero)
    let iconState = NativeIconState()
    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: .subtitle, reuseIdentifier: reuseIdentifier)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layoutSubviews() {
        accessoryView?.sizeToFit(); super.layoutSubviews()
    }
    override func prepareForReuse() {
        super.prepareForReuse(); releaseIcon(); progressFill.reset()
    }
    func releaseIcon() {
        iconState.reset()
        if var configuration = contentConfiguration as? UIListContentConfiguration {
            configuration.image = nil; contentConfiguration = configuration
        }
    }
}

@MainActor
final class NativeProgressFill: UIView {
    private let fill = UIView()
    private var fraction = 0.0
    private var hasValue = false
    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false; clipsToBounds = true
        fill.backgroundColor = UIColor.systemBlue.withAlphaComponent(0.28); addSubview(fill)
    }
    required init?(coder: NSCoder) { fatalError() }
    func update(_ value: Double) {
        let next = value.isFinite ? min(1, max(0, value)) : 0
        guard !hasValue || next != fraction else { return }
        let animate = hasValue && window != nil && !UIAccessibility.isReduceMotionEnabled && UIView.areAnimationsEnabled
        fraction = next; hasValue = true
        guard animate else { fill.layer.removeAllAnimations(); layoutFill(); return }
        UIView.animate(withDuration: 0.2, delay: 0, options: [.beginFromCurrentState, .curveLinear, .allowUserInteraction]) { self.layoutFill() }
    }
    func reset() { fill.layer.removeAllAnimations(); fraction = 0; hasValue = false; layoutFill() }
    override func layoutSubviews() { super.layoutSubviews(); layoutFill() }
    private func layoutFill() { fill.frame = CGRect(x: 0, y: 0, width: bounds.width * fraction, height: bounds.height) }
}
