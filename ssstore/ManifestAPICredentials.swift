import Foundation
import Security

/// Kept on this device, isolated by the complete service endpoint. Changing the
/// address never forwards an existing credential to another service.
enum ManifestAPICredentials {
    private static let service = "dev.personal.ssstore.manifest-api"
    private static let worker = ManifestCredentialWorkQueue()

    static func load(for endpoint: URL) async throws -> String? {
        try await worker.perform { try loadBlocking(for: endpoint) }
    }

    static func save(_ input: String, for endpoint: URL) async throws {
        try await worker.perform { try saveBlocking(input, for: endpoint) }
    }

    static func clear(for endpoint: URL) async throws {
        try await worker.perform { try clearBlocking(for: endpoint) }
    }

    private static func loadBlocking(for endpoint: URL) throws -> String? {
        var query = attributes(for: endpoint)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        // These entries never require user presence. Fail rather than letting
        // securityd request authentication while navigating or installing.
        query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data,
              let token = String(data: data, encoding: .utf8) else {
            throw failure(status == errSecSuccess ? errSecDecode : status)
        }
        return token
    }

    private static func saveBlocking(_ input: String, for endpoint: URL) throws {
        let token = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard token.range(of: "^[A-Za-z0-9._~+/\\-]{32,512}={0,2}\\z", options: .regularExpression) != nil else {
            throw NSError(domain: service, code: 1, userInfo: [NSLocalizedDescriptionKey:
                "访问令牌格式无效，请使用服务器生成的随机令牌。"])
        }
        let query = attributes(for: endpoint)
        let data = Data(token.utf8)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw failure(status) }
        var item = query
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let added = SecItemAdd(item as CFDictionary, nil)
        guard added == errSecSuccess else { throw failure(added) }
    }

    private static func clearBlocking(for endpoint: URL) throws {
        let status = SecItemDelete(attributes(for: endpoint) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw failure(status) }
    }

    private static func attributes(for endpoint: URL) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service, kSecAttrAccount as String: endpoint.absoluteString,
         kSecAttrSynchronizable as String: false]
    }

    private static func failure(_ status: OSStatus) -> NSError {
        NSError(domain: service, code: 2, userInfo: [
            NSLocalizedDescriptionKey: "清单服务令牌暂时无法访问，请解锁设备后重试。",
            NSUnderlyingErrorKey: NSError(domain: NSOSStatusErrorDomain, code: Int(status)),
        ])
    }
}

/// Security.framework calls use synchronous IPC, even for a missing item.
/// Serialize them away from the UI executor; async callers cannot accidentally
/// run a Keychain operation inline while constructing table rows or alerts.
final class ManifestCredentialWorkQueue: @unchecked Sendable {
    private let queue = DispatchQueue(label: "dev.personal.ssstore.manifest-keychain", qos: .userInitiated)

    func perform<Value: Sendable>(_ work: @escaping @Sendable () throws -> Value) async throws -> Value {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { continuation.resume(with: Result(catching: work)) }
        }
    }
}
