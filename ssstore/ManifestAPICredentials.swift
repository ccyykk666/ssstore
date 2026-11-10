import Foundation
import Security

/// Kept on this device, isolated by the complete service endpoint. Changing the
/// address never forwards an existing credential to another service.
enum ManifestAPICredentials {
    private static let service = "dev.personal.ssstore.manifest-api"

    static func load(for endpoint: URL) throws -> String? {
        var query = attributes(for: endpoint)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data,
              let token = String(data: data, encoding: .utf8) else { throw failure() }
        return token
    }

    static func save(_ input: String, for endpoint: URL) throws {
        let token = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard token.range(of: "^[A-Za-z0-9._~+/\\-]{32,512}={0,2}\\z", options: .regularExpression) != nil else {
            throw NSError(domain: service, code: 1, userInfo: [NSLocalizedDescriptionKey:
                "访问令牌格式无效，请使用服务器生成的随机令牌。"])
        }
        let query = attributes(for: endpoint)
        let data = Data(token.utf8)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw failure() }
        var item = query
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw failure() }
    }

    static func clear(for endpoint: URL) throws {
        let status = SecItemDelete(attributes(for: endpoint) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw failure() }
    }

    private static func attributes(for endpoint: URL) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service, kSecAttrAccount as String: endpoint.absoluteString,
         kSecAttrSynchronizable as String: false]
    }

    private static func failure() -> NSError {
        NSError(domain: service, code: 2, userInfo: [NSLocalizedDescriptionKey: "无法读取或保存清单服务令牌，请解锁设备后重试。"])
    }
}
