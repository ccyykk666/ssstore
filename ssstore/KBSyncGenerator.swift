import Foundation
import WebKit

enum KBSyncPreparationError: LocalizedError {
    case unavailable, invalidIdentity, generation, timeout
    var errorDescription: String? {
        switch self {
        case .unavailable: "下载验证组件不可用，请重新安装最新版。"
        case .invalidIdentity: "下载验证所需的账号或设备标识无效。"
        case .generation: "下载验证数据生成失败，请重试。"
        case .timeout: "下载验证数据生成超时，请保持应用在前台后重试。"
        }
    }
}

/// Local TCI/WASM in WebKit's content process, without app JIT permissions.
@MainActor
final class KBSyncGenerator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    private var webView: WKWebView?
    private var continuation: CheckedContinuation<String, Error>?
    private var deadline: Task<Void, Never>?
    private var identity: (guid: String, dsid: String)?
    private var started = false

    static func generate(guid: String, dsid: String, runtimeRoot: URL? = nil) async throws -> String {
        guard guid.count == 12, guid.allSatisfy(\.isHexDigit),
              let numeric = UInt64(dsid), numeric > 0, numeric <= 9_007_199_254_740_991
        else { throw KBSyncPreparationError.invalidIdentity }
        let generator = KBSyncGenerator()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                generator.continuation = continuation
                generator.start(guid: guid, dsid: dsid, root: runtimeRoot)
            }
        } onCancel: {
            Task { @MainActor in generator.finish(.failure(CancellationError())) }
        }
    }

    private func start(guid: String, dsid: String, root: URL?) {
        guard let root = root ?? Bundle.main.resourceURL?.appendingPathComponent("KBSyncRuntime"),
              FileManager.default.fileExists(atPath: root.appendingPathComponent("index.html").path)
        else { finish(.failure(KBSyncPreparationError.unavailable)); return }
        identity = (guid, dsid)
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.setURLSchemeHandler(BundledKBSyncResources(root: root), forURLScheme: "ssstore-kbsync")
        configuration.userContentController.add(self, name: "kbsync")
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = self
        webView = view
        deadline = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(360)) }
            catch { return }
            self?.finish(.failure(KBSyncPreparationError.timeout))
        }
        view.load(URLRequest(url: URL(string: "ssstore-kbsync://local/index.html")!))
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, message.frameInfo.request.url?.scheme == "ssstore-kbsync",
              let body = message.body as? [String: Any], let type = body["type"] as? String
        else { return }
        switch type {
        case "ready":
            guard !started, let identity else { return }
            started = true
            guard let arguments = try? JSONSerialization.data(withJSONObject: [identity.guid, identity.dsid]),
                  let json = String(data: arguments, encoding: .utf8) else {
                finish(.failure(KBSyncPreparationError.invalidIdentity)); return
            }
            webView?.evaluateJavaScript("window.ssstoreGenerate(...\(json))") { [weak self] _, error in
                if error != nil { self?.finish(.failure(KBSyncPreparationError.generation)) }
            }
        case "result":
            guard let blob = body["blob"] as? String, blob.count <= 1_398_104,
                  let data = Data(base64Encoded: blob), !data.isEmpty, data.count <= 1_048_576
            else { finish(.failure(KBSyncPreparationError.generation)); return }
            finish(.success(blob))
        default:
            finish(.failure(KBSyncPreparationError.generation))
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        let url = navigationAction.request.url
        decisionHandler(url?.scheme == "ssstore-kbsync" && url?.host == "local" && url?.path == "/index.html" ? .allow : .cancel)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finish(.failure(KBSyncPreparationError.generation))
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        finish(.failure(KBSyncPreparationError.generation))
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        finish(.failure(KBSyncPreparationError.generation))
    }

    private func finish(_ result: Result<String, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        deadline?.cancel()
        deadline = nil
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: "kbsync")
        webView?.stopLoading()
        webView?.navigationDelegate = nil
        webView = nil
        identity = nil
        continuation.resume(with: result)
    }
}

private final class BundledKBSyncResources: NSObject, WKURLSchemeHandler {
    private let root: URL
    private let names: Set<String> = ["index.html", "runtime.js", "unicorn.wasm", "CommerceKit", "CommerceCore", "CoreFP", "CoreFP.icxs", "storeagent"]

    init(root: URL) { self.root = root }

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url, url.host == "local", url.query == nil,
              url.pathComponents.count == 2, names.contains(url.lastPathComponent),
              let data = try? Data(contentsOf: root.appendingPathComponent(url.lastPathComponent))
        else { urlSchemeTask.didFailWithError(KBSyncPreparationError.unavailable); return }
        let type: String
        switch url.pathExtension {
        case "html": type = "text/html; charset=utf-8"
        case "js": type = "application/javascript; charset=utf-8"
        case "wasm": type = "application/wasm"
        default: type = "application/octet-stream"
        }
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": type, "Content-Length": String(data.count), "Access-Control-Allow-Origin": "*"])!
        urlSchemeTask.didReceive(response)
        urlSchemeTask.didReceive(data)
        urlSchemeTask.didFinish()
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {}
}

/// Serialize the large interpreter and bind its memory-only cache to DSID/GUID.
actor KBSyncStore {
    static let shared = KBSyncStore()
    private var cache: [String: String] = [:]
    private var active: (id: UUID, key: String, task: Task<String, Error>)?

    func cached(guid: String, dsid: String) -> String? { cache[dsid + ":" + guid.lowercased()] }

    func invalidate(guid: String, dsid: String, expected: String) {
        let key = dsid + ":" + guid.lowercased()
        if cache[key] == expected { cache.removeValue(forKey: key) }
    }

    func generate(guid: String, dsid: String) async throws -> String {
        let key = dsid + ":" + guid.lowercased()
        while let pending = active {
            let result = await pending.task.result
            if active?.id == pending.id {
                if case let .success(blob) = result { cache[pending.key] = blob }
                active = nil
            }
            try Task.checkCancellation()
            if pending.key == key { return try result.get() }
        }
        if let blob = cache[key] { return blob }
        let id = UUID()
        let job = Task { try await KBSyncGenerator.generate(guid: guid, dsid: dsid) }
        active = (id, key, job)
        let result = await job.result
        if active?.id == id { active = nil }
        if case let .success(blob) = result { cache[key] = blob }
        try Task.checkCancellation()
        return try result.get()
    }
}
