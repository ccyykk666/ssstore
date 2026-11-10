import Foundation
import UpdateCore

extension Installer {
    /// The system will fetch this public URL again. Never hand off an HTML login
    /// page, provider error, or manifest targeting a different package.
    func checkCompatibleManifest() async throws {
        guard isCompatible, let remoteManifestEndpoint, let packageMetadata else {
            throw InstallationManifest.ManifestError.invalidEndpoint
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 20
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        logger.info("Compatible install [\(id)]: checking public manifest service host=\(remoteManifestEndpoint.host ?? "unknown") path=\(remoteManifestEndpoint.path)")
        do {
            let (data, response) = try await session.data(from: remoteManifestEndpoint)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            logger.info("Compatible install [\(id)]: manifest service HTTP \(status), bytes=\(data.count)")
            guard status == 200 else {
                let body = String(decoding: data.prefix(256), as: UTF8.self)
                if let range = body.range(of: "error code: [0-9]{1,8}", options: .regularExpression) {
                    logger.warning("Compatible install [\(id)]: provider \(body[range])")
                }
                throw NSError(domain: "ssstore.install.manifest", code: status,
                    userInfo: [NSLocalizedDescriptionKey: "兼容安装清单服务访问失败（HTTP \(status)）。请复制日志以便排查。"])
            }
            try InstallationManifest.validate(data, metadata: packageMetadata, payload: payloadEndpoint)
            logger.info("Compatible install [\(id)]: manifest validated; internal build=\(packageMetadata.version), IPA remains on loopback HTTP")
        } catch {
            logger.error("Compatible install [\(id)]: manifest preflight failed: \(DiagnosticLog.errorDetails(error))")
            throw error
        }
    }
}
