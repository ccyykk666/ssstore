import XCTest
@testable import UpdateCore

final class DiagnosticLogTests: XCTestCase {
    func testSecretsAreRemovedWithoutRemovingUsefulErrorAndEndpointDetails() {
        let source = """
        Authorization: Bearer bearer-secret
        Cookie: session=cookie-secret; other=second-cookie-secret
        Embedded headers Cookie: a=embedded-cookie-secret; b=embedded-second-secret
        {"password":"password with spaces", "passwordToken":"token-secret", "kbsync":"blob-secret"}
        X-Apple-AMD-Data: amd-data-secret
        X-Apple-AMD-Action: SP
        <key>HostPrivateKey</key><data>pairing-key-secret</data>
        -----BEGIN PRIVATE KEY-----
        pem-key-secret
        -----END PRIVATE KEY-----
        user@example.invalid failureType=2034
        request=https://user:url-password@localhost:4567/request.plist?token=url-token-secret#fragment-secret
        AMD-Action:ent/download:SP version=1234567890
        """
        let redacted = DiagnosticLog.redact(source)
        for secret in ["bearer-secret", "cookie-secret", "second-cookie-secret", "embedded-cookie-secret", "embedded-second-secret", "password with spaces", "token-secret",
                       "blob-secret", "amd-data-secret", "pairing-key-secret", "pem-key-secret", "user@example.invalid",
                       "url-password", "url-token-secret", "fragment-secret"] {
            XCTAssertFalse(redacted.contains(secret), secret)
        }
        XCTAssertTrue(redacted.contains("https://localhost:4567/request.plist"))
        XCTAssertTrue(redacted.contains("AMD-Action:ent/download:SP"))
        XCTAssertTrue(redacted.contains("X-Apple-AMD-Action: SP"))
        XCTAssertTrue(redacted.contains("failureType=2034"))
        XCTAssertTrue(redacted.contains("version=1234567890"))
        XCTAssertTrue(DiagnosticLog.isSensitiveKey("X-Apple-AMD-Data"))
        XCTAssertFalse(DiagnosticLog.isSensitiveKey("X-Apple-AMD-Action"))
    }

    func testOnlyMissingOptionalDotenvDebugNoiseIsSuppressed() {
        XCTAssertFalse(DiagnosticLog.shouldInclude(level: "debug", label: "codes.vapor.application",
            message: "Could not load .env.development file: No such file or directory"))
        XCTAssertTrue(DiagnosticLog.shouldInclude(level: "error", label: "codes.vapor.application",
            message: "Could not load .env file: No such file or directory"))
        XCTAssertTrue(DiagnosticLog.shouldInclude(level: "debug", label: "codes.vapor.application",
            message: "Could not load .env file: Permission denied"))
        XCTAssertTrue(DiagnosticLog.shouldInclude(level: "error", label: "codes.vapor.http-server",
            message: "TLS handshake failed: certificate unknown"))
    }

    func testExportContainsSessionContextAndAllRetainedEntriesInOrder() {
        let report = DiagnosticLog.report(messages: ["first request", "second failure code=-1202 user@example.invalid"],
            version: "0.6.0", build: "59", system: "iOS 27.0", device: "iPhone", capacity: 2000,
            date: Date(timeIntervalSince1970: 0))
        XCTAssertTrue(report.contains("ssstore 0.6.0 (59)"))
        XCTAssertTrue(report.contains("iOS 27.0"))
        XCTAssertTrue(report.contains("2 条"))
        XCTAssertTrue(report.contains("first request\n\nsecond failure code=-1202"))
        XCTAssertFalse(report.contains("user@example.invalid"))
    }

    func testUnderlyingTransportCodesRemainAvailableWithoutSignedURLSecrets() {
        let underlying = NSError(domain: "NSOSStatusErrorDomain", code: -9807,
            userInfo: [NSLocalizedDescriptionKey: "Certificate chain validation failed"])
        let error = NSError(domain: NSURLErrorDomain, code: -1202, userInfo: [
            NSLocalizedDescriptionKey: "Server certificate untrusted",
            NSUnderlyingErrorKey: underlying,
            NSURLErrorFailingURLErrorKey: URL(string: "https://localhost:5678/app.plist?token=secret-download-token")!,
        ])
        let report = DiagnosticLog.errorDetails(error)
        XCTAssertTrue(report.contains("-1202"))
        XCTAssertTrue(report.contains("-9807"))
        XCTAssertTrue(report.contains("Certificate chain validation failed"))
        XCTAssertTrue(report.contains("https://localhost:5678/app.plist"))
        XCTAssertFalse(report.contains("secret-download-token"))
    }
}
