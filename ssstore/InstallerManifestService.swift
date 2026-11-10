import Foundation
import UpdateCore

/// Changing this setting affects future installation attempts only. A chosen
/// custom service is never silently replaced by another metadata recipient.
enum InstallerManifestService {
    static let defaultEndpoint = URL(string: "https://ssstore-install-manifest.kkkk0615.chatgpt.site/manifest.plist")!
    private static let preferenceKey = "installationManifestService"

    static var savedAddress: String? { UserDefaults.standard.string(forKey: preferenceKey) }
    static var displayAddress: String { savedAddress ?? defaultEndpoint.absoluteString }

    static func endpoint() throws -> URL {
        guard let address = savedAddress else { return defaultEndpoint }
        return try InstallationManifest.endpoint(from: address)
    }

    @MainActor
    static func setAddress(_ address: String) throws {
        if address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            UserDefaults.standard.removeObject(forKey: preferenceKey)
        } else {
            let endpoint = try InstallationManifest.endpoint(from: address)
            UserDefaults.standard.set(endpoint.absoluteString, forKey: preferenceKey)
        }
    }

    static func probe() async throws {
        let metadata = try InstallationManifest.Metadata(info: ["CFBundleIdentifier": "com.example.ssstore-probe",
            "CFBundleVersion": "1", "CFBundleDisplayName": "ssstore 连接测试"],
            expectedBundleID: "com.example.ssstore-probe", fallbackName: "ssstore")
        let payload = URL(string: "http://127.0.0.1:5678/00000000-0000-4000-8000-000000000001.ipa")!
        let url = try InstallationManifest.serviceURL(endpoint: endpoint(), metadata: metadata, payload: payload)
        try await verify(url: url, metadata: metadata, payload: payload, logID: "service-test")
    }

    static func verify(url: URL, metadata: InstallationManifest.Metadata, payload: URL, logID: String) async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 20
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        logger.info("Compatible install [\(logID)]: checking public manifest service host=\(url.host ?? "unknown") path=\(url.path)")
        do {
            let (data, response) = try await session.data(from: url)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            logger.info("Compatible install [\(logID)]: manifest service HTTP \(status), bytes=\(data.count)")
            guard status == 200 else {
                let body = String(decoding: data.prefix(256), as: UTF8.self)
                if let range = body.range(of: "error code: [0-9]{1,8}", options: .regularExpression) {
                    logger.warning("Compatible install [\(logID)]: provider \(body[range])")
                }
                throw NSError(domain: "ssstore.install.manifest", code: status,
                    userInfo: [NSLocalizedDescriptionKey: "兼容安装清单服务访问失败（HTTP \(status)）。请复制日志以便排查。"])
            }
            try InstallationManifest.validate(data, metadata: metadata, payload: payload)
            logger.info("Compatible install [\(logID)]: manifest validated; internal build=\(metadata.version), IPA remains on loopback HTTP")
        } catch {
            logger.error("Compatible install [\(logID)]: manifest preflight failed: \(DiagnosticLog.errorDetails(error))")
            throw error
        }
    }
}
