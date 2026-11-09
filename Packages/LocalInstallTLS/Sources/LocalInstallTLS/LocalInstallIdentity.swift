import Foundation
import Security
import Crypto
import SwiftASN1
import X509

/// A device-local CA and server identity. No CA or server private key is bundled or exported.
public struct LocalInstallIdentity: Sendable {
    public static let host = "127.0.0.1"
    private static let store = IdentityStore(service: "dev.personal.ssstore.loopback-tls")

    public let rootName: String
    public let rootDER: Data
    public let certificateDER: Data
    public let certificateChainPEM: String
    public let privateKeyPEM: String
    public let profile: Data

    public static func current() throws -> Self { try store.load() }

    /// Uses the system trust store, without injecting our CA as a trusted anchor.
    public var isTrusted: Bool {
        guard let leaf = SecCertificateCreateWithData(nil, certificateDER as CFData),
              let root = SecCertificateCreateWithData(nil, rootDER as CFData) else { return false }
        var trust: SecTrust?
        guard SecTrustCreateWithCertificates([leaf, root] as CFArray,
            SecPolicyCreateSSL(true, Self.host as CFString), &trust) == errSecSuccess,
            let trust else { return false }
        SecTrustSetNetworkFetchAllowed(trust, false)
        return SecTrustEvaluateWithError(trust, nil)
    }

    init(record: IdentityRecord) throws {
        let root = try Certificate(derEncoded: Array(record.rootCertificate))
        let leaf = try Certificate(derEncoded: Array(record.serverCertificate))
        rootName = record.rootName
        rootDER = record.rootCertificate
        certificateDER = record.serverCertificate
        certificateChainPEM = try leaf.serializeAsPEM().pemString + "\n" + root.serializeAsPEM().pemString
        privateKeyPEM = try P256.Signing.PrivateKey(rawRepresentation: record.serverKey).pemRepresentation
        let rootPayload: [String: Any] = [
            "PayloadType": "com.apple.security.root",
            "PayloadVersion": 1,
            "PayloadIdentifier": "dev.personal.ssstore.loopback-ca.root",
            "PayloadUUID": record.id.uuidString,
            "PayloadDisplayName": rootName,
            "PayloadCertificateFileName": "ssstore-loopback-ca.cer",
            "PayloadContent": rootDER,
        ]
        profile = try PropertyListSerialization.data(fromPropertyList: [
            "PayloadType": "Configuration",
            "PayloadVersion": 1,
            "PayloadIdentifier": "dev.personal.ssstore.loopback-ca",
            "PayloadUUID": record.profileID.uuidString,
            "PayloadDisplayName": "ssstore 本机安装证书",
            "PayloadDescription": "用于通过 127.0.0.1 安装应用。安装后，请在设置 → 通用 → 关于本机 → 证书信任设置中，启用 \(rootName) 的完整信任。",
            "PayloadContent": [rootPayload],
        ], format: .xml, options: 0)
    }
}

struct IdentityRecord: Codable {
    let id: UUID
    let profileID: UUID
    let rootKey: Data
    let rootCertificate: Data
    var serverKey: Data
    var serverCertificate: Data

    var rootName: String { "ssstore Loopback CA \(id.uuidString.prefix(8))" }

    static func generate(now: Date) throws -> Self {
        let id = UUID()
        let key = P256.Signing.PrivateKey()
        let name = try DistinguishedName { CommonName("ssstore Loopback CA \(id.uuidString.prefix(8))") }
        let root = try Certificate(
            version: .v3, serialNumber: .init(), publicKey: .init(key.publicKey),
            notValidBefore: now.addingTimeInterval(-3600),
            notValidAfter: now.addingTimeInterval(5 * 365 * 86400),
            issuer: name, subject: name, signatureAlgorithm: .ecdsaWithSHA256,
            extensions: Certificate.Extensions {
                Critical(BasicConstraints.isCertificateAuthority(maxPathLength: 0))
                Critical(KeyUsage(keyCertSign: true, cRLSign: true))
                SubjectKeyIdentifier(hash: .init(key.publicKey))
            }, issuerPrivateKey: .init(key)
        )
        var record = Self(id: id, profileID: UUID(), rootKey: key.rawRepresentation,
            rootCertificate: Data(try root.serializeAsPEM().derBytes), serverKey: Data(), serverCertificate: Data())
        try record.renewServer(now: now)
        return record
    }

    mutating func renewServer(now: Date) throws {
        let root = try Certificate(derEncoded: Array(rootCertificate))
        let key = P256.Signing.PrivateKey()
        let rootPrivateKey = try P256.Signing.PrivateKey(rawRepresentation: rootKey)
        let leaf = try Certificate(
            version: .v3, serialNumber: .init(), publicKey: .init(key.publicKey),
            notValidBefore: now.addingTimeInterval(-3600),
            notValidAfter: min(now.addingTimeInterval(365 * 86400), root.notValidAfter),
            issuer: root.subject,
            subject: try DistinguishedName { CommonName(LocalInstallIdentity.host) },
            signatureAlgorithm: .ecdsaWithSHA256,
            extensions: Certificate.Extensions {
                Critical(BasicConstraints.notCertificateAuthority)
                Critical(KeyUsage(digitalSignature: true))
                try ExtendedKeyUsage([.serverAuth])
                SubjectAlternativeNames([.ipAddress(ASN1OctetString(contentBytes: [127, 0, 0, 1]))])
                SubjectKeyIdentifier(hash: .init(key.publicKey))
                AuthorityKeyIdentifier(keyIdentifier: SubjectKeyIdentifier(hash: root.publicKey).keyIdentifier)
            }, issuerPrivateKey: .init(rootPrivateKey)
        )
        serverKey = key.rawRepresentation
        serverCertificate = Data(try leaf.serializeAsPEM().derBytes)
    }
}

/// Keep private material out of Documents, backups and the downloadable configuration profile.
final class IdentityStore: @unchecked Sendable {
    private let service: String
    private let lock = NSLock()
    private var cached: IdentityRecord?
    init(service: String) { self.service = service }

    func load(now: Date = Date()) throws -> LocalInstallIdentity {
        lock.lock()
        defer { lock.unlock() }
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: "identity-v1"]
        var record: IdentityRecord
        var changed = false
        if let cached { record = cached }
        else {
            var item: CFTypeRef?
            var readQuery = query
            readQuery[kSecReturnData as String] = true
            readQuery[kSecMatchLimit as String] = kSecMatchLimitOne
            let status = SecItemCopyMatching(readQuery as CFDictionary, &item)
            if status == errSecItemNotFound {
                record = try IdentityRecord.generate(now: now)
                changed = true
            } else {
                guard status == errSecSuccess, let data = item as? Data else { throw keychainError(status) }
                record = try JSONDecoder().decode(IdentityRecord.self, from: data)
            }
        }
        let root = try Certificate(derEncoded: Array(record.rootCertificate))
        if root.notValidAfter <= now.addingTimeInterval(30 * 86400) {
            record = try IdentityRecord.generate(now: now)
            changed = true
        } else if try Certificate(derEncoded: Array(record.serverCertificate)).notValidAfter <= now.addingTimeInterval(30 * 86400) {
            try record.renewServer(now: now)
            changed = true
        }
        if changed {
            let data = try JSONEncoder().encode(record)
            let update = [kSecValueData as String: data]
            var status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
            if status == errSecItemNotFound {
                var create = query
                create[kSecValueData as String] = data
                create[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
                create[kSecAttrSynchronizable as String] = false
                status = SecItemAdd(create as CFDictionary, nil)
            }
            guard status == errSecSuccess else { throw keychainError(status) }
        }
        cached = record
        return try LocalInstallIdentity(record: record)
    }

    private func keychainError(_ status: OSStatus) -> NSError {
        NSError(domain: NSOSStatusErrorDomain, code: Int(status), userInfo: [
            NSLocalizedDescriptionKey: "无法读取或保存本机安装证书（\(status)）。请解锁设备后重试。",
        ])
    }
}
