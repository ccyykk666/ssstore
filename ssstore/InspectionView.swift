import SwiftUI
import QuickLook
import UpdateCore

struct InspectionView: View {
    @EnvironmentObject private var model: AppModel
    var bundleID: String? = nil
    @State private var search = ""
    private var operations: [InspectionOperation] {
        InspectionOperation.menu.filter {
            (bundleID == nil || $0.requiresApp) &&
            (search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) || $0.service.localizedCaseInsensitiveContains(search))
        }
    }
    var body: some View {
        List {
            ForEach(InspectionOperation.groups, id: \.self) { group in
                let items = operations.filter { $0.group == group }
                if !items.isEmpty {
                    Section(group) {
                        ForEach(items) { operation in
                            NavigationLink { InspectionDetailView(operation: operation, initialBundleID: bundleID ?? "") } label: {
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(operation.title)
                                    if let receipt = model.inspectionReceipts[operation.rawValue + "|" + (bundleID ?? "")], !receipt.success {
                                        Text(receipt.message).font(.caption).foregroundStyle(.orange)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            if bundleID == nil {
                Section("接口资料") {
                    NavigationLink("接口索引") { NativeAPIIndexView() }
                }.font(.footnote)
            }
        }
        .navigationTitle(bundleID == nil ? "设备数据" : "应用数据")
        .searchable(text: $search, prompt: "搜索数据或服务")
    }
}

struct InspectionDetailView: View {
    @EnvironmentObject private var model: AppModel
    let operation: InspectionOperation
    var initialBundleID = ""
    var initialPath = "/"
    var autoRead = false
    var initialDomain = 1
    var initialGroupID = ""
    @State private var bundleID = ""
    @State private var path = "/"
    @State private var domain = 1
    @State private var groupID = ""
    @State private var result: InspectionResult?
    @State private var reportURL: URL?
    @State private var failure: String?
    @State private var loading = false
    @State private var initialized = false
    @State private var choosingApp = false
    private var needsApp: Bool { operation.requiresApp && !(operation == .coreFiles && domain != 1) }

    init(operation: InspectionOperation, initialBundleID: String = "", initialPath: String = "/", autoRead: Bool = false,
         initialDomain: Int = 1, initialGroupID: String = "") {
        self.operation = operation; self.initialBundleID = initialBundleID; self.initialPath = initialPath
        self.autoRead = autoRead; self.initialDomain = initialDomain; self.initialGroupID = initialGroupID
        _bundleID = State(initialValue: initialBundleID); _path = State(initialValue: initialPath)
        _domain = State(initialValue: initialDomain); _groupID = State(initialValue: initialGroupID)
    }

    var body: some View {
        List {
            Section {
                if !operation.note.isEmpty {
                    Text(operation.note).font(.footnote).foregroundStyle(.secondary)
                }
                if needsApp {
                    Button { choosingApp = true } label: {
                        HStack {
                            Text("应用").foregroundStyle(.primary)
                            Spacer()
                            Text(model.records.first { $0.id == bundleID }?.installed.name ?? "请选择")
                                .foregroundStyle(.secondary).lineLimit(1)
                            if initialBundleID.isEmpty { Image(systemName: "chevron.up.chevron.down").font(.caption) }
                        }
                    }.disabled(!initialBundleID.isEmpty)
                }
                if operation.isBrowser {
                    TextField("目录路径", text: $path).textInputAutocapitalization(.never).autocorrectionDisabled()
                }
                if operation == .coreFiles {
                    Picker("文件域", selection: $domain) {
                        Text("应用数据").tag(1); Text("App Group").tag(2)
                        Text("临时目录").tag(3); Text("崩溃日志").tag(5)
                    }
                    if domain == 2 {
                        TextField("App Group 标识", text: $groupID).textInputAutocapitalization(.never).autocorrectionDisabled()
                    }
                }
                Button { Task { await read() } } label: {
                    HStack { if loading { ProgressView() }; Text(loading ? "正在读取…" : "读取") }
                }.disabled(model.busy || loading || (needsApp && bundleID.isEmpty) || (operation == .coreFiles && domain == 2 && groupID.isEmpty))
            }.disabled(loading)
            if let failure { Section("未取得数据") { Text(failure).foregroundStyle(.orange).textSelection(.enabled) } }
            if let result {
                if let message = result.message, !message.isEmpty,
                   !["连接结果不代表已获全部读取权限。", "广播服务的读取权限需单独验证。",
                     "读取失败的字段会显示错误原因。", "文件已读取，可预览或导出。"].contains(message) {
                    Section { Text(message).font(.footnote).foregroundStyle(.secondary) }
                }
                if !result.entries.isEmpty {
                    Section("目录 · \(result.entries.count) 项") {
                        ForEach(result.entries.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }) { entry in
                            if operation == .coreFiles {
                                NavigationLink(entry.name) {
                                    InspectionDetailView(operation: operation, initialBundleID: bundleID, initialPath: entry.path,
                                                         autoRead: true, initialDomain: domain, initialGroupID: groupID)
                                }
                            } else {
                                NavigationLink { InspectionFileEntryView(source: operation, bundleID: bundleID, entry: entry) } label: {
                                    Label(entry.name, systemImage: "doc")
                                }
                            }
                        }
                    }
                }
                if !result.files.isEmpty {
                    Section("已读取文件") {
                        ForEach(result.files) { file in
                            VStack(alignment: .leading, spacing: 8) {
                                Button(file.name) { model.filePresentation = FilePresentation(url: URL(fileURLWithPath: file.path), kind: .preview) }
                                ShareFileButton(title: "导出文件", url: URL(fileURLWithPath: file.path))
                            }
                        }
                    }
                }
                Section { InspectionRows(value: result.value) }
                if let reportURL { Section { ShareFileButton(title: "导出 JSON 报告", url: reportURL) } }
            }
            Section("服务") {
                Text(operation.service).font(.caption.monospaced()).textSelection(.enabled)
            }
        }
        .navigationTitle(operation.title).navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $choosingApp) { ApplicationPickerView(selection: $bundleID) }
        .onChange(of: bundleID) { _, _ in clearResult() }
        .onChange(of: path) { _, _ in clearResult() }
        .onChange(of: domain) { _, _ in clearResult() }
        .onChange(of: groupID) { _, _ in clearResult() }
        .task {
            guard !initialized else { return }; initialized = true
            if autoRead { await read() }
        }
    }

    private func read() async {
        loading = true; failure = nil; result = nil; reportURL = nil
        defer { loading = false }
        do { let response = try await model.inspect(operation, bundleID: bundleID, path: path, domain: domain, groupID: groupID); result = response.0; reportURL = response.1 }
        catch { failure = error.localizedDescription }
    }
    private func clearResult() { result = nil; reportURL = nil; failure = nil }
}

private struct InspectionFileEntryView: View {
    @EnvironmentObject private var model: AppModel
    let source: InspectionOperation
    let bundleID: String
    let entry: RemoteInspectionEntry
    @State private var result: InspectionResult?
    @State private var failure: String?
    @State private var loading = false
    private var directory: Bool { result?.value["isDirectory"] == .bool(true) }
    var body: some View {
        List {
            Section { Text(entry.path).font(.caption.monospaced()).textSelection(.enabled) }
            if loading { ProgressView("正在读取…") }
            if let failure { Text(failure).foregroundStyle(.orange).textSelection(.enabled) }
            if let result {
                Section("文件属性") { InspectionRows(value: result.value) }
                if directory {
                    NavigationLink("打开目录") { InspectionDetailView(operation: source, initialBundleID: bundleID, initialPath: entry.path, autoRead: true) }
                } else {
                    Button("读取文件") { Task { await perform(.fileRead) } }.disabled(model.busy || loading)
                }
                ForEach(result.files) { file in
                    Button("预览 \(file.name)") { model.filePresentation = FilePresentation(url: URL(fileURLWithPath: file.path), kind: .preview) }
                    ShareFileButton(title: "导出文件", url: URL(fileURLWithPath: file.path))
                }
            }
        }
        .navigationTitle(entry.name).navigationBarTitleDisplayMode(.inline)
        .task { if result == nil && !loading { await perform(.fileInfo) } }
    }
    private func perform(_ operation: InspectionOperation) async {
        loading = true; failure = nil; defer { loading = false }
        do { result = try await model.inspect(operation, bundleID: bundleID, path: entry.path, source: source.rawValue).0 }
        catch { failure = error.localizedDescription }
    }
}

private struct InspectionValueScreen: View {
    let title: String
    let value: InspectionValue
    var body: some View { List { InspectionRows(value: value) }.navigationTitle(title).navigationBarTitleDisplayMode(.inline) }
}

private struct InspectionRows: View {
    let value: InspectionValue
    var body: some View {
        switch value {
        case .object(let object):
            ForEach(object.keys.sorted(), id: \.self) { key in
                if let child = object[key] { row(key, value: child) }
            }
        case .array(let array):
            ForEach(array.indices, id: \.self) { index in row(label(array[index], index: index), value: array[index]) }
        default: Text(value.text).textSelection(.enabled)
        }
    }
    @ViewBuilder private func row(_ title: String, value: InspectionValue) -> some View {
        switch value {
        case .object, .array:
            NavigationLink { InspectionValueScreen(title: title, value: value) } label: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).lineLimit(2)
                    Text(storageSummary(value) ?? value.text).font(.caption).foregroundStyle(.secondary)
                }
            }
        default:
            VStack(alignment: .leading, spacing: 5) {
                Text(displayLabel(title)).font(.caption).foregroundStyle(.secondary)
                Text(formatted(value, key: title)).textSelection(.enabled)
            }.padding(.vertical, 2)
        }
    }
    private func label(_ value: InspectionValue, index: Int) -> String {
        for key in ["CFBundleDisplayName", "CFBundleName", "name", "Name", "服务", "文件", "bundleIdentifier", "CFBundleIdentifier", "pid"] {
            if let field = value[key], field != .null, !field.text.isEmpty { return field.text }
        }
        return "第 \(index + 1) 项"
    }
    private func displayLabel(_ key: String) -> String {
        switch key {
        case "字节数", "size": return "大小"
        case "总字节数": return "总容量"
        case "可用字节数": return "可用容量"
        default: return key
        }
    }
    private func formatted(_ value: InspectionValue, key: String) -> String {
        let sizeKeys = ["StaticDiskUsage", "DynamicDiskUsage", "size", "总字节数", "可用字节数", "字节数", "块大小",
                        "TotalSystemCapacity", "TotalDataCapacity", "AmountDataAvailable", "AmountDataReserved", "BlockSize"]
        let count: Double?
        switch value {
        case .number(let number): count = number
        case .string(let text): count = Double(text)
        default: count = nil
        }
        if sizeKeys.contains(key), let count, count >= 0 && count < Double(Int64.max) {
            return ByteCountFormatter.string(fromByteCount: Int64(count), countStyle: .file)
        }
        return value.text
    }
    private func storageSummary(_ value: InspectionValue) -> String? {
        guard let a = value["StaticDiskUsage"], let b = value["DynamicDiskUsage"] else { return nil }
        return "应用 \(formatted(a, key: "StaticDiskUsage")) · 数据 \(formatted(b, key: "DynamicDiskUsage"))"
    }
}

struct QuickLookFile: UIViewControllerRepresentable {
    let url: URL
    func makeCoordinator() -> Coordinator { Coordinator(url: url) }
    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController(); controller.dataSource = context.coordinator; return controller
    }
    func updateUIViewController(_ controller: QLPreviewController, context: Context) {}
    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        let url: URL
        init(url: URL) { self.url = url }
        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }
        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem { url as NSURL }
    }
}

private struct NativeAPIEntry: Decodable, Identifiable {
    let name: String
    let signature: String
    let summary: String
    let used: Bool
    var id: String { name }
}
private struct NativeAPIIndexView: View {
    @State private var search = ""
    @State private var onlyUsed = false
    @State private var entries: [NativeAPIEntry] = []
    private var visible: [NativeAPIEntry] { entries.filter { (!onlyUsed || $0.used) && (search.isEmpty || $0.name.localizedCaseInsensitiveContains(search)) } }
    var body: some View {
        List {
            Section {
                Text("idevice v0.1.68 · \(entries.count) 个 C 接口").font(.headline)
                Text("索引仅供参考，列出的接口不一定可用。")
                    .font(.footnote).foregroundStyle(.secondary)
                Toggle("仅显示本版使用的接口", isOn: $onlyUsed)
            }
            ForEach(visible) { entry in
                NavigationLink {
                    List {
                        Text(entry.used ? "用于本版读取流程" : "仅供参考，无执行入口")
                        Text(entry.signature).font(.caption.monospaced()).textSelection(.enabled)
                        Text(entry.summary).font(.footnote).textSelection(.enabled)
                        Link("接口源代码", destination: URL(string: "https://github.com/jkcoxson/idevice/tree/v0.1.68/ffi/src")!)
                    }.navigationTitle(entry.name).navigationBarTitleDisplayMode(.inline)
                } label: { VStack(alignment: .leading, spacing: 4) {
                    Text(entry.name).font(.caption.monospaced())
                    Text(entry.used ? "本版使用" : "仅索引").font(.caption2).foregroundStyle(.secondary)
                } }
            }
        }
        .navigationTitle("接口索引").searchable(text: $search, prompt: "搜索接口")
        .task {
            if let url = Bundle.main.url(forResource: "DeviceAPIIndex", withExtension: "json"),
               let data = try? Data(contentsOf: url), let values = try? JSONDecoder().decode([NativeAPIEntry].self, from: data) { entries = values }
        }
    }
}


