import UIKit
import UpdateCore

@MainActor
final class NativeInstalledIcon: NativePage, UIColorPickerViewControllerDelegate {
    private let bundleID: String
    private let resourceName: String?
    private var tint = UIColor(red: 0.27, green: 0.52, blue: 0.94, alpha: 1)
    private var appearance = SSIconAppearance.standard
    private var capabilities: SSIconCapabilities = []
    private var output: (file: URL, source: String)?
    private var failure: String?

    init(_ model: AppModel, bundleID: String, resourceName: String? = nil) {
        self.bundleID = bundleID
        self.resourceName = resourceName
        super.init(model, title: "提取本机图标")
        navigationItem.largeTitleDisplayMode = .never
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        guard #available(iOS 18, *) else { return }
        Task { [weak self, bundleID, resourceName] in
            let supported = await Task.detached(priority: .utility) {
                InstalledAppIcon.capabilities(bundleID: bundleID, resourceName: resourceName)
            }.value
            self?.capabilities = supported
            self?.reload()
        }
    }

    private var styles: [(SSIconAppearance, String, String)] {
        var result: [(SSIconAppearance, String, String)] = [(.standard, "默认", "default")]
        if capabilities.contains(.dark) { result.append((.dark, "深色", "dark")) }
        if #available(iOS 26, *) {
            if capabilities.contains(.tintedDark) { result.append((.tintedDark, "深色着色", "tinted-dark")) }
            if capabilities.contains(.tintedLight) { result.append((.tintedLight, "浅色着色", "tinted-light")) }
        } else if capabilities.contains(.tinted) {
            result.append((.tinted, "着色", "tinted"))
        }
        return result
    }

    private var isTinted: Bool { appearance != .standard && appearance != .dark }

    override func rows() -> [NativeSection] {
        let styles = self.styles
        let selection = styles.first { $0.0 == appearance } ?? styles[0]
        var controls: [NativeRow] = []
        if styles.count > 1 {
            controls.append(NativeRow(title: "外观", detail: selection.1, action: working ? nil : { [weak self] in
                guard let self else { return }
                let choices = styles.map { ($0.2, $0.1) }
                push(NativeChoices(model, title: "图标外观", items: choices) { [weak self] key in
                    guard let self, let style = styles.first(where: { $0.2 == key }) else { return }
                    appearance = style.0
                    clearResult()
                })
            }))
        }
        if isTinted {
            controls.append(NativeRow(title: "着色颜色", action: working ? nil : { [weak self] in self?.pickColor() }))
        }
        controls.append(NativeRow(title: working ? "正在提取…" : "提取 PNG", color: .systemBlue,
                                  action: working ? nil : { [weak self] in self?.extract(suffix: selection.2) }))
        if failure != nil, appearance == .standard, model.hasPairing {
            controls.append(NativeRow(title: "通过配对读取默认图标", color: .systemBlue,
                                      action: working || model.busy ? nil : { [weak self] in self?.readPairedIcon() }))
        }
        var sections = [NativeSection(rows: controls)]
        if let output {
            sections.append(NativeSection(rows: [
                NativeRow(title: "预览图标", detail: output.source, icon: output.file,
                          action: { [weak self] in self?.preview(output.file) }),
                link("导出 PNG") { [weak self] in self?.share(output.file) },
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
        output = nil
        failure = nil
        reload()
    }

    private func extract(suffix: String) {
        clearResult()
        let color = isTinted ? tint.resolvedColor(with: traitCollection) : nil
        let app = model.records.first(where: { $0.id == bundleID })?.installed
        let cached = appearance == .standard ? app.flatMap { model.localIconURL(for: $0) } : nil
        run { [self, bundleID, resourceName, appearance] in
            do {
                output = try await Task.detached(priority: .userInitiated) {
                    let data: Data
                    let source: String
                    do {
                        data = try InstalledAppIcon.readPNG(bundleID: bundleID, resourceName: resourceName,
                                                            appearance: appearance, tint: color)
                        source = "本机系统"
                    } catch {
                        guard let cached, let stored = try? Data(contentsOf: cached), InstalledAppIcon.isUsablePNG(stored) else {
                            throw error
                        }
                        data = stored
                        source = "已缓存的默认图标"
                    }
                    let folder = temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    let output = folder.appendingPathComponent("app-icon-\(suffix).png")
                    try data.write(to: output, options: [.atomic, .completeFileProtection])
                    return (output, source)
                }.value
            } catch {
                logger.warning("Installed icon extraction failed bundle=\(bundleID) appearance=\(suffix): \(DiagnosticLog.errorDetails(error))")
                failure = error.localizedDescription
            }
        }
    }

    private func readPairedIcon() {
        clearResult()
        run { [self] in
            do {
                let (result, _) = try await model.inspect(.icon, bundleID: bundleID)
                guard let saved = result.files.first else { throw CocoaError(.fileReadCorruptFile) }
                let file = URL(fileURLWithPath: saved.path)
                let usable = try await Task.detached(priority: .utility) {
                    try InstalledAppIcon.isUsablePNG(Data(contentsOf: file))
                }.value
                if usable {
                    output = (file, "配对设备的默认图标")
                } else {
                    failure = "配对设备未返回可用的图标内容。"
                }
            } catch {
                failure = error.localizedDescription
            }
        }
    }
}
