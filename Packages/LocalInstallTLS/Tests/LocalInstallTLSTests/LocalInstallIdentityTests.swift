import XCTest
import Foundation
import Security
import Crypto
import X509
import SwiftASN1
@testable import LocalInstallTLS

final class LocalInstallIdentityTests: XCTestCase {
    func testInstallationLinkPreservesNestedHTTPSURLPortAndQuery() throws {
        let manifest = try XCTUnwrap(URL(string: "https://localhost:5678/app.plist?version=1&label=a%2Bb"))
        let link = LocalInstallURL.installationLink(manifestURL: manifest)
        let components = try XCTUnwrap(URLComponents(url: link, resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.scheme, "itms-services")
        XCTAssertNil(components.port)
        XCTAssertEqual(components.queryItems?.first(where: { $0.name == "action" })?.value, "download-manifest")
        XCTAssertEqual(components.queryItems?.first(where: { $0.name == "url" })?.value, manifest.absoluteString)
        XCTAssertTrue(components.percentEncodedQuery?.contains("https%3A%2F%2Flocalhost%3A5678%2F") == true)
    }

    func testRealCertificateChainMatchesLoopbackAddressesAndServerPrivateKey() throws {
        let now = Date()
        let record = try IdentityRecord.generate(now: now)
        let identity = try LocalInstallIdentity(record: record)
        XCTAssertTrue(try trusts(identity, host: "127.0.0.1", at: now))
        XCTAssertTrue(try trusts(identity, host: "localhost", at: now))
        XCTAssertTrue(try trusts(identity, host: "::1", at: now))
        XCTAssertFalse(try trusts(identity, host: "127.0.0.2", at: now))
        XCTAssertFalse(try trusts(identity, host: "app.localhost.qaq.wiki", at: now))
        XCTAssertFalse(identity.isTrusted, "A generated CA must not become a system trust anchor automatically")
        let leaf = try Certificate(derEncoded: Array(identity.certificateDER))
        XCTAssertEqual(leaf.publicKey, .init(try P256.Signing.PrivateKey(rawRepresentation: record.serverKey).publicKey))
        XCTAssertLessThanOrEqual(leaf.notValidAfter.timeIntervalSince(leaf.notValidBefore), 366 * 86400)
    }

    func testProfileContainsOnlyThePublicRootAndStableIdentifiers() throws {
        let record = try IdentityRecord.generate(now: Date())
        let identity = try LocalInstallIdentity(record: record)
        let profile = try XCTUnwrap(PropertyListSerialization.propertyList(from: identity.profile, format: nil) as? [String: Any])
        XCTAssertEqual(profile["PayloadType"] as? String, "Configuration")
        XCTAssertEqual(profile["PayloadUUID"] as? String, record.profileID.uuidString)
        let payloads = try XCTUnwrap(profile["PayloadContent"] as? [[String: Any]])
        XCTAssertEqual(payloads.count, 1)
        XCTAssertEqual(payloads.first?["PayloadType"] as? String, "com.apple.security.root")
        XCTAssertEqual(payloads.first?["PayloadContent"] as? Data, identity.rootDER)
        XCTAssertEqual(payloads.first?["PayloadDisplayName"] as? String, identity.rootName)
        XCTAssertNil(payloads.first?["Password"])
        XCTAssertFalse(String(decoding: identity.profile, as: UTF8.self).contains("PRIVATE KEY"))
        let other = try LocalInstallIdentity(record: IdentityRecord.generate(now: Date()))
        XCTAssertNotEqual(other.rootDER, identity.rootDER)
    }

    func testKeychainSurvivesNewStoreAndRenewsLeafWithoutChangingTrustedRoot() throws {
        let service = "dev.personal.ssstore.loopback-tls.tests.\(UUID())"
        defer {
            SecItemDelete([kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service] as CFDictionary)
        }
        let now = Date()
        let first = try IdentityStore(service: service).load(now: now)
        let freshStore = IdentityStore(service: service)
        let reopened = try freshStore.load(now: now)
        XCTAssertEqual(first.rootDER, reopened.rootDER)
        XCTAssertEqual(first.privateKeyPEM, reopened.privateKeyPEM)
        XCTAssertEqual(try profileID(first), try profileID(reopened))
        let later = now.addingTimeInterval(340 * 86400)
        let renewed = try freshStore.load(now: later)
        XCTAssertEqual(first.rootDER, renewed.rootDER)
        XCTAssertEqual(try profileID(first), try profileID(renewed))
        XCTAssertNotEqual(first.certificateDER, renewed.certificateDER)
        XCTAssertNotEqual(first.privateKeyPEM, renewed.privateKeyPEM)
        XCTAssertTrue(try trusts(renewed, host: "127.0.0.1", at: later))
    }

    func testBuild56IPCertificateUpgradesWithoutReplacingTrustedRoot() throws {
        let now = Date()
        var record = try IdentityRecord.generate(now: now)
        let leaf = try Certificate(derEncoded: Array(record.serverCertificate))
        var extensions = leaf.extensions
        extensions.update(try SubjectAlternativeNames([
            .ipAddress(ASN1OctetString(contentBytes: [127, 0, 0, 1])),
        ]).makeCertificateExtension())
        let legacyLeaf = try Certificate(version: leaf.version, serialNumber: leaf.serialNumber,
            publicKey: leaf.publicKey, notValidBefore: leaf.notValidBefore, notValidAfter: leaf.notValidAfter,
            issuer: leaf.issuer, subject: leaf.subject, signatureAlgorithm: leaf.signatureAlgorithm,
            extensions: extensions, issuerPrivateKey: .init(try P256.Signing.PrivateKey(rawRepresentation: record.rootKey)))
        record.serverCertificate = Data(try legacyLeaf.serializeAsPEM().derBytes)
        XCTAssertFalse(try trusts(LocalInstallIdentity(record: record), host: "localhost", at: now))
        let service = "dev.personal.ssstore.loopback-tls.migration.\(UUID())"
        defer {
            SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service] as CFDictionary)
        }
        XCTAssertEqual(SecItemAdd([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "identity-v1",
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData as String: try JSONEncoder().encode(record),
        ] as CFDictionary, nil), errSecSuccess)
        let upgraded = try IdentityStore(service: service).load(now: now)
        XCTAssertEqual(upgraded.rootDER, record.rootCertificate)
        XCTAssertEqual(try profileID(upgraded), record.profileID.uuidString)
        XCTAssertNotEqual(upgraded.certificateDER, record.serverCertificate)
        XCTAssertTrue(try trusts(upgraded, host: "localhost", at: now))
        XCTAssertTrue(try trusts(upgraded, host: "127.0.0.1", at: now))
        XCTAssertTrue(try trusts(upgraded, host: "::1", at: now))
    }

    private func trusts(_ identity: LocalInstallIdentity, host: String, at date: Date) throws -> Bool {
        let leaf = try XCTUnwrap(SecCertificateCreateWithData(nil, identity.certificateDER as CFData))
        let root = try XCTUnwrap(SecCertificateCreateWithData(nil, identity.rootDER as CFData))
        var result: SecTrust?
        XCTAssertEqual(SecTrustCreateWithCertificates([leaf, root] as CFArray,
            SecPolicyCreateSSL(true, host as CFString), &result), errSecSuccess)
        let trust = try XCTUnwrap(result)
        // Explicit anchors are used only by this isolated chain-verification test.
        SecTrustSetAnchorCertificates(trust, [root] as CFArray)
        SecTrustSetAnchorCertificatesOnly(trust, true)
        SecTrustSetNetworkFetchAllowed(trust, false)
        SecTrustSetVerifyDate(trust, date as CFDate)
        return SecTrustEvaluateWithError(trust, nil)
    }

    private func profileID(_ identity: LocalInstallIdentity) throws -> String? {
        let profile = try XCTUnwrap(PropertyListSerialization.propertyList(from: identity.profile, format: nil) as? [String: Any])
        return profile["PayloadUUID"] as? String
    }
}
