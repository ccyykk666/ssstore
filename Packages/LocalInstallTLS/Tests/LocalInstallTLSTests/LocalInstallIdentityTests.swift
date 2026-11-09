import XCTest
import Foundation
import Security
import Crypto
import X509
@testable import LocalInstallTLS

final class LocalInstallIdentityTests: XCTestCase {
    func testRealCertificateChainMatchesOnlyLoopbackIPAndServerPrivateKey() throws {
        let now = Date()
        let record = try IdentityRecord.generate(now: now)
        let identity = try LocalInstallIdentity(record: record)
        XCTAssertTrue(try trusts(identity, host: "127.0.0.1", at: now))
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
