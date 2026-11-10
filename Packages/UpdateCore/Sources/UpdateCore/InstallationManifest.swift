import Foundation

public enum InstallationManifest {
    /// Accept an HTTPS origin or an explicit endpoint behind a reverse proxy.
    public static func endpoint(from input: String) throws -> URL {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.utf8.count <= 2048,
              value.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else { throw ManifestError.invalidEndpoint }
        let address = value.contains("://") ? value : "https://" + value
        guard var parts = URLComponents(string: address), parts.scheme?.lowercased() == "https",
              let host = parts.host, !host.isEmpty,
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              host.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else { throw ManifestError.invalidEndpoint }
        parts.scheme = "https"
        if parts.path.isEmpty || parts.path == "/" { parts.path = "/manifest.plist" }
        guard let url = parts.url else { throw ManifestError.invalidEndpoint }
        return url
    }

    public struct Metadata: Equatable, Sendable {
        public let bundleID: String
        public let name: String
        public let version: String

        public init(info: [String: Any], expectedBundleID: String, fallbackName: String) throws {
            guard let bundleID = info["CFBundleIdentifier"] as? String, bundleID == expectedBundleID,
                  let version = info["CFBundleVersion"] as? String,
                  Self.valid(version, limit: 64), Self.valid(bundleID, limit: 255),
                  bundleID.range(of: "^[A-Za-z0-9-]+(\\.[A-Za-z0-9-]+)+$", options: .regularExpression) != nil
            else { throw ManifestError.invalidPackage }
            let name = (info["CFBundleDisplayName"] as? String).flatMap { Self.valid($0, limit: 256) ? $0 : nil }
                ?? (info["CFBundleName"] as? String).flatMap { Self.valid($0, limit: 256) ? $0 : nil }
                ?? fallbackName
            guard Self.valid(name, limit: 256) else { throw ManifestError.invalidPackage }
            self.bundleID = bundleID; self.version = version; self.name = name
        }

        private static func valid(_ string: String, limit: Int) -> Bool {
            !string.isEmpty && string.utf16.count <= limit && string.unicodeScalars.allSatisfy {
                $0.value == 9 || $0.value == 10 || $0.value == 13 ||
                (0x20...0xD7FF).contains($0.value) || (0xE000...0xFFFD).contains($0.value) || $0.value >= 0x10000
            }
        }
    }

    public static func serviceURL(endpoint: URL, metadata: Metadata, payload: URL) throws -> URL {
        guard var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false),
              components.scheme == "https", components.host?.isEmpty == false,
              components.user == nil, components.password == nil, components.query == nil, components.fragment == nil,
              payload.scheme == "http", payload.host == "127.0.0.1", payload.port != nil,
              payload.user == nil, payload.password == nil, payload.query == nil, payload.fragment == nil,
              payload.path.range(of: "^/[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\\.ipa$", options: .regularExpression) != nil
        else { throw ManifestError.invalidEndpoint }
        components.queryItems = [
            .init(name: "bundleid", value: metadata.bundleID), .init(name: "name", value: metadata.name),
            .init(name: "version", value: metadata.version), .init(name: "fetchurl", value: payload.absoluteString),
        ]
        // URLSearchParams on the service follows form decoding, where a raw +
        // means space. URLComponents otherwise leaves literal plus signs intact.
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        guard let url = components.url else { throw ManifestError.invalidEndpoint }
        return url
    }

    /// Reject HTML login/error pages and manifests pointing to another package.
    public static func validate(_ data: Data, metadata: Metadata, payload: URL) throws {
        guard data.count <= 64 * 1024,
              let root = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let items = root["items"] as? [[String: Any]], items.count == 1,
              let assets = items[0]["assets"] as? [[String: Any]], assets.count == 1,
              assets[0]["kind"] as? String == "software-package",
              assets[0]["url"] as? String == payload.absoluteString,
              let info = items[0]["metadata"] as? [String: Any], info["kind"] as? String == "software",
              info["bundle-identifier"] as? String == metadata.bundleID,
              info["bundle-version"] as? String == metadata.version,
              info["title"] as? String == metadata.name
        else { throw ManifestError.invalidResponse }
    }

    public enum ManifestError: LocalizedError {
        case invalidPackage, invalidEndpoint, invalidResponse
        public var errorDescription: String? {
            switch self {
            case .invalidPackage: "安装包的应用标识或内部版本信息无效。"
            case .invalidEndpoint: "兼容安装的清单服务或本机安装包地址无效。"
            case .invalidResponse: "清单服务未返回有效的安装清单，或清单与安装包不一致。"
            }
        }
    }
}
