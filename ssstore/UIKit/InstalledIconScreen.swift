import UIKit
import UpdateCore

@MainActor
final class NativeInstalledIcon: NativePage, UIColorPickerViewControllerDelegate {
    private let bundleID: String
    private let resourceName: String?
    private var tint = UIColor(red: 0.27, green: 0.52, blue: 0.94, alpha: 1)
    private var appearance = SSIconAppearance.standard
    private var file: URL?
    private var failure: String?

    init(_ model: AppModel, bundleID: String, resourceName: String? = nil) {
        self.bundleID = bundleID
        self.resourceName = resourceName
        super.init(model, title: "提取本机图标")
        navigationItem.largeTitleDisplayMode = .never
    }

    required init?(coder: NSCoder) { fatalError() }

    private var styles: [(SSIconAppearance, String, String)] {
        let standard: [(SSIconAppearance, String, String)] = [(.standard, "默认", "default")]
        if #available(iOS 26, *) {
            return standard + [(.dark, "深色", "dark"), (.tintedDark, "深色着色", "tinted-dark"),
                               (.tintedLight, "浅色着色", "tinted-light")]
        }
        if #available(iOS 18, *) { return standard + [(.dark, "深色", "dark"), (.tinted, "着色", "tinted")] }
        return standard
    }

    private var isTinted: Bool { appearance != .standard && appearance != .dark }

    override func rows() -> [NativeSection] {
        let selection = styles.first { $0.0 == appearance } ?? (.standard, "默认", "default")
        var controls = [NativeRow(title: "外观", detail: selection.1, action: working ? nil : { [weak self] in
            guard let self else { return }
            let choices = styles.map { ($0.2, $0.1) }
            push(NativeChoices(model, title: "图标外观", items: choices) { [weak self] key in
                guard let self, let style = styles.first(where: { $0.2 == key }) else { return }
                appearance = style.0
                clearResult()
            })
        })]
        if isTinted {
            controls.append(NativeRow(title: "着色颜色", action: working ? nil : { [weak self] in self?.pickColor() }))
        }
        controls.append(NativeRow(title: working ? "正在提取…" : "提取 PNG", color: .systemBlue,
                                  action: working ? nil : { [weak self] in self?.extract(suffix: selection.2) }))
        var sections = [NativeSection(rows: controls)]
        if let file {
            sections.append(NativeSection(rows: [
                NativeRow(title: "预览图标", detail: file.lastPathComponent, icon: file,
                          action: { [weak self] in self?.preview(file) }),
                link("导出 PNG") { [weak self] in self?.share(file) },
            ]))
        }
        if let failure { sections.append(NativeSection(rows: [NativeRow(title: failure, color: .systemOrange)])) }
        return sections
    }

    private func pickColor() {
        let picker = UIColorPickerViewController()
        picker.selectedColor = tint
        picker.supportsAlpha = false
        picker.delegate = self
        present(picker, animated: true)
    }

    func colorPickerViewControllerDidFinish(_ viewController: UIColorPickerViewController) {
        tint = viewController.selectedColor
        clearResult()
    }

    private func clearResult() {
        file = nil
        failure = nil
        reload()
    }

    private func extract(suffix: String) {
        clearResult()
        let color = isTinted ? tint.resolvedColor(with: traitCollection) : nil
        run { [self, bundleID, resourceName, appearance] in
            do {
                file = try await Task.detached(priority: .userInitiated) {
                    let data = try InstalledAppIcon.readPNG(bundleID: bundleID, resourceName: resourceName,
                                                            appearance: appearance, tint: color)
                    let folder = temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    let output = folder.appendingPathComponent("app-icon-\(suffix).png")
                    try data.write(to: output, options: [.atomic, .completeFileProtection])
                    return output
                }.value
            } catch {
                logger.warning("Installed icon extraction failed bundle=\(bundleID) appearance=\(suffix): \(DiagnosticLog.errorDetails(error))")
                failure = error.localizedDescription
            }
        }
    }
}
