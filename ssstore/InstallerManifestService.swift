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
        _ = try await prepare(endpoint: endpoint(), metadata: metadata, payload: payload, logID: "service-test")
    }

    static func prepare(endpoint: URL, metadata: InstallationManifest.Metadata, payload: URL, logID: String) async throws -> URL {
        // Validate before disclosing any metadata, including in the private flow.
        let publicURL = try InstallationManifest.serviceURL(endpoint: endpoint, metadata: metadata, payload: payload)
        let token: String?
        // Our existing public endpoint never requires a credential. Avoid
        // querying the Keychain at all for the default installation flow.
        if endpoint == defaultEndpoint { token = nil }
        else { token = try await ManifestAPICredentials.load(for: endpoint) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 20
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        // Reject redirects even to another path: a credential must only be sent
        // to the exact endpoint the user configured.
        let session = URLSession(configuration: configuration, delegate: ManifestRedirectPolicy(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        logger.info("Compatible install [\(logID)]: checking manifest service host=\(endpoint.host ?? "unknown") private=\(token != nil)")
        do {
            let url: URL
            if let token {
                var request = URLRequest(url: endpoint)
                request.httpMethod = "POST"
                request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = try JSONSerialization.data(withJSONObject: [
                    "bundleid": metadata.bundleID, "name": metadata.name,
                    "version": metadata.version, "fetchurl": payload.absoluteString,
                ])
                let (data, response) = try await session.data(for: request)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                logger.info("Compatible install [\(logID)]: private ticket issuance HTTP \(status)")
                guard status == 201 else { throw serviceError(status) }
                url = try InstallationManifest.ticketURL(data, endpoint: endpoint)
            } else { url = publicURL }
            // The system installer cannot send our Authorization header. Only a
            // bounded, expiring capability is handed to it; never the API token.
            let (data, response) = try await session.data(from: url)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            logger.info("Compatible install [\(logID)]: manifest service HTTP \(status), bytes=\(data.count)")
            guard status == 200 else {
                let body = String(decoding: data.prefix(256), as: UTF8.self)
                if let range = body.range(of: "error code: [0-9]{1,8}", options: .regularExpression) {
                    logger.warning("Compatible install [\(logID)]: provider \(body[range])")
                }
                throw serviceError(status)
            }
            try InstallationManifest.validate(data, metadata: metadata, payload: payload)
            logger.info("Compatible install [\(logID)]: manifest validated; internal build=\(metadata.version), IPA remains on loopback HTTP")
            return url
        } catch {
            logger.error("Compatible install [\(logID)]: manifest preflight failed: \(DiagnosticLog.errorDetails(error))")
            throw error
        }
    }

    private static func serviceError(_ status: Int) -> NSError {
        let message: String
        switch status {
        case 401, 403: message = "清单服务拒绝访问，请检查设置中当前地址的访问令牌（HTTP \(status)）。"
        case 429: message = "清单服务请求过于频繁，请稍后重试。"
        default: message = "兼容安装清单服务访问失败（HTTP \(status)）。请复制日志以便排查。"
        }
        return NSError(domain: "ssstore.install.manifest", code: status, userInfo: [NSLocalizedDescriptionKey: message])
    }
}

private final class ManifestRedirectPolicy: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
