import XCTest
@testable import UpdateCore

final class InstallationManifestTests: XCTestCase {
    func testInstallationLinkPreservesCompleteHTTPSManifestURL() throws {
        for address in [
            "https://install.example:5678/manifest.plist?version=1&label=a%2Bb",
            "https://install.example/tickets/" + String(repeating: "a", count: 64) + ".plist",
        ] {
            let manifest = try XCTUnwrap(URL(string: address))
            let link = try InstallationManifest.installationLink(manifestURL: manifest)
            let components = try XCTUnwrap(URLComponents(url: link, resolvingAgainstBaseURL: false))
            XCTAssertEqual(components.scheme, "itms-services")
            XCTAssertNil(components.port)
            XCTAssertEqual(components.queryItems?.first { $0.name == "action" }?.value, "download-manifest")
            XCTAssertEqual(components.queryItems?.first { $0.name == "url" }?.value, manifest.absoluteString)
            XCTAssertTrue(components.percentEncodedQuery?.contains("https%3A%2F%2F") == true)
        }
    }

    func testInstallationLinkRejectsLocalHTTPAndEmbeddedCredentials() throws {
        for address in ["http://127.0.0.1:5678/app.plist", "file:///app.plist",
                        "https://user:secret@install.example/app.plist", "https://install.example/app.plist#fragment"] {
            XCTAssertThrowsError(try InstallationManifest.installationLink(manifestURL: XCTUnwrap(URL(string: address))))
        }
    }

    func testPrivateTicketCannotChangeOriginOrInjectPathOrQuery() throws {
        let endpoint = URL(string: "https://install.example:8443/prefix/manifest.plist")!
        let path = "tickets/" + String(repeating: "a", count: 64) + ".plist"
        func json(_ value: String) throws -> Data { try JSONSerialization.data(withJSONObject: ["path": value]) }
        XCTAssertEqual(try InstallationManifest.ticketURL(json(path), endpoint: endpoint).absoluteString,
                       "https://install.example:8443/prefix/" + path)
        for invalid in ["https://other.example/" + path, "//other.example/" + path,
                        "/" + path, "../" + path, path + "?token=secret", path + "#fragment",
                        path + "\n", path.replacingOccurrences(of: "/", with: "%2F"), "tickets/short.plist"] {
            XCTAssertThrowsError(try InstallationManifest.ticketURL(json(invalid), endpoint: endpoint), invalid)
        }
        XCTAssertThrowsError(try InstallationManifest.ticketURL(Data(repeating: 32, count: 8193), endpoint: endpoint))
        XCTAssertThrowsError(try InstallationManifest.ticketURL(json(path), endpoint: URL(string: "http://install.example/manifest.plist")!))
    }

    func testNormalizesCustomServiceWithoutWeakeningHTTPS() throws {
        XCTAssertEqual(try InstallationManifest.endpoint(from: "  install.example\n").absoluteString, "https://install.example/manifest.plist")
        XCTAssertEqual(try InstallationManifest.endpoint(from: "https://install.example/").absoluteString, "https://install.example/manifest.plist")
        XCTAssertEqual(try InstallationManifest.endpoint(from: "HTTPS://install.example/").absoluteString, "https://install.example/manifest.plist")
        XCTAssertEqual(try InstallationManifest.endpoint(from: "https://install.example:8443/ssstore/manifest.plist").absoluteString,
                       "https://install.example:8443/ssstore/manifest.plist")
        for address in ["", "http://install.example", "https://user:secret@install.example/manifest.plist",
                        "https://install.example/?token=secret", "https://install.example/#fragment", "https://bad host/manifest.plist"] {
            XCTAssertThrowsError(try InstallationManifest.endpoint(from: address), address)
        }
    }

    let payload = URL(string: "http://127.0.0.1:5678/00000000-0000-4000-8000-000000000001.ipa")!
    func metadata() throws -> InstallationManifest.Metadata {
        try .init(info: ["CFBundleIdentifier": "com.example.app", "CFBundleVersion": "123",
                         "CFBundleShortVersionString": "1.2.3", "CFBundleDisplayName": "应用 & + ? 🐱"],
                  expectedBundleID: "com.example.app", fallbackName: "Fallback")
    }
    func testUsesInternalBuildAndEncodesUnicodeAndNestedURLExactlyOnce() throws {
        let metadata = try metadata()
        XCTAssertEqual(metadata.version, "123")
        let url = try InstallationManifest.serviceURL(endpoint: URL(string: "https://install.example/manifest.plist")!, metadata: metadata, payload: payload)
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
        XCTAssertEqual(query.first { $0.name == "name" }?.value, metadata.name)
        XCTAssertEqual(query.first { $0.name == "fetchurl" }?.value, payload.absoluteString)
        XCTAssertEqual(query.first { $0.name == "version" }?.value, "123")
        XCTAssertTrue(URLComponents(url: url, resolvingAgainstBaseURL: false)!.percentEncodedQuery!.contains("%2B"))
        XCTAssertFalse(URLComponents(url: url, resolvingAgainstBaseURL: false)!.percentEncodedQuery!.contains("+"))
    }
    func testRejectsWrongBundleAndUnsafeEndpoints() throws {
        XCTAssertThrowsError(try InstallationManifest.Metadata(info: ["CFBundleIdentifier": "com.other.app", "CFBundleVersion": "1"], expectedBundleID: "com.example.app", fallbackName: "App"))
        let metadata = try metadata()
        for service in ["http://install.example/manifest.plist", "https://user:secret@install.example/manifest.plist", "https://install.example/manifest.plist?token=secret"] {
            XCTAssertThrowsError(try InstallationManifest.serviceURL(endpoint: URL(string: service)!, metadata: metadata, payload: payload))
        }
        XCTAssertThrowsError(try InstallationManifest.serviceURL(endpoint: URL(string: "https://install.example/manifest.plist")!, metadata: metadata, payload: URL(string: "http://example.com:5678/file.ipa")!))
    }
    func testRejectsHTMLOrChangedPayloadAndVersion() throws {
        let metadata = try metadata()
        func data(url: String, version: String) throws -> Data {
            try PropertyListSerialization.data(fromPropertyList: ["items": [[
                "assets": [["kind": "software-package", "url": url]],
                "metadata": ["kind": "software", "bundle-identifier": metadata.bundleID, "bundle-version": version, "title": metadata.name],
            ]]], format: .xml, options: 0)
        }
        XCTAssertNoThrow(try InstallationManifest.validate(data(url: payload.absoluteString, version: "123"), metadata: metadata, payload: payload))
        XCTAssertThrowsError(try InstallationManifest.validate(Data("<html>Sign in</html>".utf8), metadata: metadata, payload: payload))
        XCTAssertThrowsError(try InstallationManifest.validate(data(url: "https://other.example/other.ipa", version: "123"), metadata: metadata, payload: payload))
        XCTAssertThrowsError(try InstallationManifest.validate(data(url: payload.absoluteString, version: "124"), metadata: metadata, payload: payload))
    }
}
