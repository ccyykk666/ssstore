import UIKit
import UniformTypeIdentifiers
import UpdateCore

@MainActor
final class NativeFileContents: UIViewController {
    private let model: AppModel
    private let file: URL
    private let textView = UITextView()
    private let format = UISegmentedControl(items: ["文本", "十六进制"])
    private let notice = UILabel()
    private var content: FileContentPreview?
    init(model: AppModel, file: URL, name: String) { self.model = model; self.file = file; super.init(nibName: nil, bundle: nil); title = name }
    required init?(coder: NSCoder) { fatalError() }
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemGroupedBackground
        format.selectedSegmentIndex = 0
        format.addAction(UIAction { [weak self] _ in self?.render() }, for: .valueChanged)
        textView.isEditable = false; textView.isSelectable = true; textView.backgroundColor = .clear; textView.textColor = .label
        textView.font = UIFontMetrics(forTextStyle: .footnote).scaledFont(for: .monospacedSystemFont(ofSize: 13, weight: .regular))
        textView.adjustsFontForContentSizeCategory = true; textView.text = "正在读取…"
        notice.font = .preferredFont(forTextStyle: .footnote); notice.adjustsFontForContentSizeCategory = true
        notice.textColor = .secondaryLabel; notice.numberOfLines = 0
        let controls = UIStackView(arrangedSubviews: [format, notice]); controls.axis = .vertical; controls.spacing = 10
        controls.translatesAutoresizingMaskIntoConstraints = false; textView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(controls); view.addSubview(textView)
        let safe = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([controls.leadingAnchor.constraint(equalTo: safe.leadingAnchor, constant: 16),
            controls.trailingAnchor.constraint(equalTo: safe.trailingAnchor, constant: -16), controls.topAnchor.constraint(equalTo: safe.topAnchor, constant: 12),
            textView.topAnchor.constraint(equalTo: controls.bottomAnchor, constant: 8), textView.leadingAnchor.constraint(equalTo: safe.leadingAnchor, constant: 12),
            textView.trailingAnchor.constraint(equalTo: safe.trailingAnchor, constant: -12), textView.bottomAnchor.constraint(equalTo: safe.bottomAnchor)])
        configureMenu()
        Task { [weak self, file] in
            do {
                let result = try await Task.detached(priority: .userInitiated) { try FileContentPreview.load(file) }.value
                guard let self else { return }; content = result
                format.setEnabled(result.text != nil, forSegmentAt: 0)
                format.selectedSegmentIndex = result.text == nil ? 1 : 0
                configureMenu(); render()
            } catch { self?.textView.text = error.localizedDescription }
        }
    }
    private func render() {
        guard let content else { return }
        let hex = format.selectedSegmentIndex == 1
        textView.text = hex ? content.hex : content.text
        let shown = hex ? min(content.bytesShown, 16 * 1024) : content.bytesShown
        notice.text = content.truncated && !hex ? "内容较多，仅显示部分预览；可导出原文件。" : content.totalBytes > shown ? "预览前 \(ByteCountFormatter.string(fromByteCount: Int64(shown), countStyle: .file))；可导出原文件。" : ByteCountFormatter.string(fromByteCount: content.totalBytes, countStyle: .file)
        textView.scrollRangeToVisible(NSRange(location: 0, length: 0))
    }
    private func configureMenu() {
        var actions = [UIAction(title: "系统预览", image: UIImage(systemName: "eye")) { [weak self] _ in
            guard let self else { return }
            let preview = NativePreview(file)
            preview.navigationItem.rightBarButtonItem = UIBarButtonItem(systemItem: .done, primaryAction: UIAction { [weak preview] _ in preview?.dismiss(animated: true) })
            present(UINavigationController(rootViewController: preview), animated: true)
        }, UIAction(title: "导出原文件", image: UIImage(systemName: "square.and.arrow.up")) { [weak self] _ in
            guard let self else { return }
            let share = UIActivityViewController(activityItems: [file], applicationActivities: nil)
            share.popoverPresentationController?.sourceView = view
            share.popoverPresentationController?.sourceRect = CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 1, height: 1)
            present(share, animated: true)
        }, UIAction(title: "复制当前内容", image: UIImage(systemName: "doc.on.doc")) { [weak self] _ in UIPasteboard.general.string = self?.textView.text }]
        if let value = content?.structured {
            actions.insert(UIAction(title: content?.truncated == true ? "查看键值（部分）" : "查看键值", image: UIImage(systemName: "list.bullet.indent")) { [weak self] _ in
                guard let self else { return }; navigationController?.pushViewController(NativeValues(model, title: title ?? "键值", value: value), animated: true)
            }, at: 0)
        }
        navigationItem.rightBarButtonItem = UIBarButtonItem(image: UIImage(systemName: "ellipsis"), menu: UIMenu(children: actions))
    }
}
