import Foundation

@main
struct DownloadProtocolChecks {
    static func main() async throws {
        try await machineProvisioningChecks()
        precondition(StoreProtocol.storefrontIdentifier(" 143441-1,34 ") == "143441")
        precondition(StoreProtocol.storefrontIdentifier("143443,34") == "143443")
        precondition(StoreProtocol.dialogMessage(["dialog": ["message": "Account action required", "explanation": "Review your account"]]) == "Account action required\nReview your account")
        precondition(StoreProtocol.dialogMessage(["dialog": ["message": "  ", "explanation": "Review your account"], "customerMessage": "Account action required"]) == "Account action required\nReview your account")
        do {
            _ = try StoreDownloadProtocol.packageItem(["dialog": ["message": "Account locked", "explanation": "Reset your password"]], bundleID: "test.app")
            fatalError("An account dialog must stop the package request")
        } catch StoreDownloadError.rejected(_, let message) { precondition(message.contains("Reset your password")) }
        try await HistorySupportChecks.run()
        var sessionAttempts = 0
        var sessionRefreshes = 0
        let recovered = try await StoreDownloadProtocol.retryExpiredSession {
            sessionAttempts += 1
            if sessionAttempts == 1 { throw StoreDownloadError.rejected("2034", "expired") }
            return "ready"
        } refresh: { sessionRefreshes += 1 }
        precondition(recovered == "ready" && sessionAttempts == 2 && sessionRefreshes == 1)
        precondition(StoreDownloadProtocol.isExpiredSession(NSError(domain: "purchase-fixture", code: 0,
            userInfo: [NSLocalizedDescriptionKey: "password token is expired (failureType: 2034)"])))
        sessionAttempts = 0; sessionRefreshes = 0
        do {
            let _: String = try await StoreDownloadProtocol.retryExpiredSession {
                sessionAttempts += 1; throw StoreDownloadError.rejected("2034", "expired")
            } refresh: { sessionRefreshes += 1 }
            fatalError("Repeated expiry must reach the caller")
        } catch {}
        precondition(sessionAttempts == 2 && sessionRefreshes == 1, "Refresh must never loop")
        for failure in [StoreDownloadError.serviceResponse(403, "volumeStore"), .rejected("9610", "license"), .rejected("2042", "other")] {
            do {
                let _: String = try await StoreDownloadProtocol.retryExpiredSession { throw failure }
                    refresh: { fatalError("Unrelated failures must not authenticate") }
                fatalError("Expected the original failure")
            } catch {}
        }
        // Domain cookies from login may retain the leading dot. They must reach the wire.
        let storeURL = URL(string: "https://p71-buy.itunes.apple.com/WebObjects/MZFinance.woa/wa/volumeStoreDownloadProduct")!
        let dispatchURL = URL(string: "https://downloaddispatch.itunes.apple.com/r/redownload")!
        let fixtureNow = Date(timeIntervalSince1970: 1000)
        func cookie(_ name: String, domain: String? = ".itunes.apple.com", path: String = "/",
                    expires: TimeInterval? = nil) -> StoreProtocol.SessionCookie {
            .init(name: name, value: "synthetic", path: path, domain: domain, expiresAt: expires, secure: true)
        }
        for domain in [".itunes.apple.com", "itunes.apple.com", ".ITUNES.APPLE.COM"] {
            var request = URLRequest(url: storeURL)
            request.setValue(StoreProtocol.cookieHeader([cookie("session", domain: domain)], for: storeURL, now: fixtureNow), forHTTPHeaderField: "Cookie")
            precondition(request.value(forHTTPHeaderField: "Cookie") == "session=synthetic")
            precondition(StoreProtocol.cookieHeader([cookie("session", domain: domain)], for: dispatchURL, now: fixtureNow) == "session=synthetic")
        }
        let selected = StoreProtocol.cookieHeader([
            cookie("expired", expires: 999), cookie("session"), cookie("wrong-path", path: "/r"),
            cookie("other-pod", domain: "p25-buy.itunes.apple.com"), cookie("parent", domain: ".apple.com"),
            cookie("wrong-domain", domain: "itunes.apple.com.attacker.invalid"), cookie("public-suffix", domain: "com"),
        ], for: storeURL, now: fixtureNow)
        precondition(selected == "session=synthetic; parent=synthetic")
        precondition(StoreProtocol.cookieHeader([cookie("scope", path: "/r")], for: dispatchURL, now: fixtureNow) == "scope=synthetic")
        precondition(StoreProtocol.cookieHeader([cookie("boundary", path: "/red")], for: dispatchURL, now: fixtureNow) == nil)
        precondition(StoreProtocol.cookieHeader([cookie("expired", expires: 1000)], for: storeURL, now: fixtureNow) == nil)
        precondition(StoreProtocol.cookieHeader([cookie("bad\r\nInjected")], for: storeURL, now: fixtureNow) == nil)
        precondition(StoreProtocol.cookieHeader([cookie("session")], for: URL(string: "http://buy.itunes.apple.com/")!, now: fixtureNow) == nil)
        precondition(StoreProtocol.cookieHeader([cookie("session")], for: URL(string: "https://itunes.apple.com.attacker.invalid/")!, now: fixtureNow) == nil)
        let noPodHost = try StoreDownloadProtocol.storeHost(pod: nil)
        let emptyPodHost = try StoreDownloadProtocol.storeHost(pod: "")
        let assignedPodHost = try StoreDownloadProtocol.storeHost(pod: "71")
        precondition(noPodHost == "buy.itunes.apple.com" && emptyPodHost == noPodHost)
        precondition(assignedPodHost == "p71-buy.itunes.apple.com")
        do {
            _ = try StoreDownloadProtocol.storeHost(pod: "71.attacker.invalid")
            fatalError("Accepted an invalid account pod")
        } catch StoreDownloadError.invalidRedirect {}
        // A transport 403 remains 403; it never becomes a missing-license recovery.
        var deniedCalls = 0
        do {
            _ = try await StoreDownloadProtocol.fetchWithFallback(version: "123", hasUpdateEndpoint: { true }) { _, _ in
                deniedCalls += 1
                throw StoreDownloadError.serviceResponse(403, "volumeStore")
            } onFallback: { _, _ in fatalError("403 must not blindly retry other endpoints") }
            fatalError("Ignored HTTP 403")
        } catch StoreDownloadError.serviceResponse(403, "volumeStore", false) {}
        precondition(deniedCalls == 1)

        let empty: [String: Any] = ["songList": [], "status": 0, "jingleDocType": "purchaseSuccess"]
        let success: [String: Any] = ["songList": [["metadata": ["softwareVersionBundleId": "example.app"]]]]
        var requests: [(StoreDownloadProtocol.Endpoint, String)] = []
        let result = try await StoreDownloadProtocol.fetchWithFallback(version: "890598805", hasUpdateEndpoint: { true }) { endpoint, version in
            requests.append((endpoint, version))
            return endpoint == .volumeStore ? empty : success
        } onFallback: { _, reason in precondition(reason == "empty-songList") }
        precondition(requests.map(\.0) == [.volumeStore, .redownload])
        precondition(requests.allSatisfy { $0.1 == "890598805" })
        _ = try StoreDownloadProtocol.packageItem(result, bundleID: "example.app")

        // Preserve historical IDs on both endpoints; numeric 5002 is retryable.
        requests = []
        _ = try await StoreDownloadProtocol.fetchWithFallback(version: "12345", hasUpdateEndpoint: { true }) { endpoint, version in
            requests.append((endpoint, version))
            return endpoint == .volumeStore ? ["failureType": 5002] : success
        } onFallback: { _, reason in precondition(reason == "failure-5002") }
        precondition(requests.count == 2 && requests.allSatisfy { $0.1 == "12345" })

        for (failure, expectedReason) in [
            (StoreDownloadError.emptyResponse(500), "empty-redownload-http500"),
            (.serviceResponse(403, "redownload", canTryUpdate: true), "empty-redownload-http403"),
        ] {
            requests = []
            _ = try await StoreDownloadProtocol.fetchWithFallback(version: "12345", hasUpdateEndpoint: { true }) { endpoint, version in
                requests.append((endpoint, version))
                switch endpoint {
                case .volumeStore: return empty
                case .redownload: throw failure
                case .update: return success
                }
            } onFallback: { endpoint, reason in
                if endpoint == .update { precondition(reason == expectedReason) }
            }
            precondition(requests.map(\.0) == [.volumeStore, .redownload, .update])
            precondition(requests.allSatisfy { $0.1 == "12345" })
        }

        requests = []
        do {
            _ = try await StoreDownloadProtocol.fetchWithFallback(version: "12345", hasUpdateEndpoint: { false }) { endpoint, version in
                requests.append((endpoint, version))
                if endpoint == .volumeStore { return empty }
                throw StoreDownloadError.serviceResponse(403, "redownload", canTryUpdate: true)
            } onFallback: { endpoint, _ in precondition(endpoint == .redownload) }
            fatalError("Ignored HTTP 403 when Apple advertised no update endpoint")
        } catch StoreDownloadError.serviceResponse(403, "redownload", true) {}
        precondition(requests.map(\.0) == [.volumeStore, .redownload])

        // Other failures do not qualify, and a failed update never loops.
        for failure in [StoreDownloadError.serviceResponse(403, "redownload"), .response(500), .emptyResponse(503), .emptyResponse(500)] {
            requests = []
            do {
                _ = try await StoreDownloadProtocol.fetchWithFallback(version: "12345", hasUpdateEndpoint: { true }) { endpoint, version in
                    requests.append((endpoint, version))
                    if endpoint == .volumeStore {
                        return empty
                    }
                    throw failure
                } onFallback: { _, _ in }
                fatalError("Ignored a failed download response")
            } catch {
                if case StoreDownloadError.emptyResponse(500) = failure {
                    precondition(requests.count == 3 && requests.last?.0 == .update)
                } else {
                    precondition(requests.count == 2)
                }
            }
        }

        // A missing version ID fails before any endpoint request.
        requests = []
        do {
            _ = try await StoreDownloadProtocol.fetchWithFallback(version: "", hasUpdateEndpoint: { true }) { endpoint, version in
                requests.append((endpoint, version))
                return empty
            } onFallback: { _, _ in fatalError("Unexpected fallback") }
            fatalError("Ignored missing version")
        } catch StoreDownloadError.catalogUnavailable {}
        precondition(requests.isEmpty)

        // Successful, rejected and malformed primary responses are not retried.
        for response in [success, ["failureType": "9610"], ["failureType": 2034],
                         ["metrics": ["messageCode": 2042]], ["customerMessage": "Unavailable"],
                         ["songList": [], "dialog": ["kind": "authorization"]],
                         ["action": ["url": "https://example.invalid/termsPage"]],
                         ["status": -1], ["songList": "malformed"]]
        {
            requests = []
            _ = try await StoreDownloadProtocol.fetchWithFallback(version: "890598805", hasUpdateEndpoint: { true }) { endpoint, version in
                requests.append((endpoint, version))
                return response
            } onFallback: { _, _ in fatalError("Unexpected fallback") }
            precondition(requests.count == 1)
        }

        // Even when both endpoints are empty, there is no retry loop.
        requests = []
        let stillEmpty = try await StoreDownloadProtocol.fetchWithFallback(version: "123", hasUpdateEndpoint: { true }) { endpoint, version in
            requests.append((endpoint, version))
            return empty
        } onFallback: { _, _ in }
        precondition(requests.count == 2)
        do {
            _ = try StoreDownloadProtocol.packageItem(stillEmpty, bundleID: "example.app")
            fatalError("Accepted an empty package list")
        } catch StoreDownloadError.empty {}
        do {
            _ = try StoreDownloadProtocol.packageItem(success, bundleID: "other.app")
            fatalError("Accepted another app's package")
        } catch StoreDownloadError.invalidPackage {}
        do {
            _ = try StoreDownloadProtocol.packageItem(["failureType": 9610, "customerMessage": "License required"], bundleID: "example.app")
            fatalError("Lost numeric failure code")
        } catch StoreDownloadError.rejected("9610", "License required") {}

        for endpoint in [StoreDownloadProtocol.Endpoint.volumeStore, .redownload, .update] {
            let data = try PropertyListSerialization.data(fromPropertyList: StoreDownloadProtocol.payload(endpoint: endpoint, appID: 123,
                                                                                                          guid: "synthetic", version: "456"), format: .xml, options: 0)
            let payload = StoreProtocol.plist(data)!
            precondition(payload[endpoint.versionKey] as? String == "456")
            precondition(payload[endpoint == .volumeStore ? "appExtVrsId" : "externalVersionId"] == nil)
            precondition(payload["salableAdamId"] as? Int64 == 123)
        }

        let primary = "https://p25-buy.itunes.apple.com/WebObjects/MZFinance.woa/wa/volumeStoreDownloadProduct"
        func downloadRequest(_ url: String) throws -> URLRequest {
            try StoreDownloadProtocol.request(url: URL(string: url)!, body: Data(), userAgent: "fixture-user-agent",
                dsid: "123456789", storefront: "143465-1,34", token: "fixture-token", cookies: [])
        }
        for url in [primary, "https://downloaddispatch.itunes.apple.com/r/redownload?guid=fixture",
                    "https://downloaddispatch.itunes.apple.com/up/updateProduct?guid=fixture",
                    "https://p71-buy.itunes.apple.com/WebObjects/MZFinance.woa/wa/redownloadProduct"]
        {
            let request = try downloadRequest(url)
            precondition(request.httpMethod == "POST" && request.url?.absoluteString == url)
            precondition(request.value(forHTTPHeaderField: "X-Token") == "fixture-token")
            precondition(request.value(forHTTPHeaderField: "X-Apple-Store-Front") == "143465-1,34")
            precondition(request.value(forHTTPHeaderField: "X-Dsid") == "123456789")
        }
        for url in [primary.replacingOccurrences(of: "https:", with: "http:"),
                    primary.replacingOccurrences(of: "p25-buy.itunes.apple.com", with: "p25-buy.itunes.apple.com.attacker.invalid"),
                    primary.replacingOccurrences(of: "p25-buy.", with: "user:password@p25-buy."),
                    primary.replacingOccurrences(of: "/wa/volumeStoreDownloadProduct", with: "/wa/buyProduct"),
                    primary + "#fragment", primary.replacingOccurrences(of: ".com/", with: ".com:8080/")]
        {
            do {
                _ = try downloadRequest(url)
                fatalError("Accepted a credential redirect outside the download endpoints")
            } catch StoreDownloadError.invalidRedirect {}
        }

        // Unknown fields and sensitive values must never reach diagnostic logs.
        let secret = "SECRET-user@example.invalid-cookie-token-url"
        let summary = StoreDownloadProtocol.summary([
            "songList": [["URL": secret, "sinfs": [secret]]], "failureType": secret,
            "customerMessage": secret, "passwordToken": secret, "dialog": ["message": secret],
            "status": secret, secret: secret,
        ])
        precondition(!summary.contains(secret) && summary.contains("songList=1") && summary.contains("failure=other"))
        precondition(StoreDownloadProtocol.fallbackReason(["metrics": ["messageCode": 0]]) == "missing-songList")
        // Catalog IDs accept both current offer shapes, never another app's entry.
        func catalog(_ offers: [[String: Any]], id: String = "123") throws -> Data {
            try JSONSerialization.data(withJSONObject: ["results": [id: ["bundleId": "example.app", "offers": offers]]])
        }
        for offers in [[["version": ["externalId": 456]]],
                       [["version": ["externalId": "456"]]],
                       [["buyParams": "price=0&appExtVrsId=456"]],
                       [["version": ["externalId": "invalid"]], ["buyParams": "appExtVrsId=456"]]]
        {
            let version = try StoreDownloadProtocol.catalogVersion(catalog(offers), appID: 123)
            precondition(version.externalVersionID == "456" && version.bundleID == "example.app")
        }
        for data in try [catalog([]), catalog([["buyParams": "appExtVrsId=secret%20value"]]),
                         catalog([["version": ["externalId": 456]]], id: "999")]
        {
            do {
                _ = try StoreDownloadProtocol.catalogVersion(data, appID: 123)
                fatalError("Accepted missing or invalid catalog data")
            } catch StoreDownloadError.catalogUnavailable {}
        }
        do {
            _ = try StoreDownloadProtocol.packageItem(["songList": "invalid"], bundleID: "example.app")
            fatalError("Misclassified a malformed song list")
        } catch StoreDownloadError.invalidPackage {}
        do {
            _ = try StoreDownloadProtocol.packageItem(["songList": [["metadata": [
                "softwareVersionBundleId": "example.app", "softwareVersionExternalIdentifier": 456,
            ]]]], bundleID: "example.app", version: "123")
            fatalError("Accepted a different historical version")
        } catch StoreDownloadError.invalidPackage {}

        // An earlier “latest” download does not satisfy a new listing, while
        // a newer response may legitimately arrive after the listing was loaded.
        precondition(!StoreDownloadProtocol.matchesRequestedRelease("20.9.8", expected: "21.0.0", allowsNewer: true))
        precondition(StoreDownloadProtocol.matchesRequestedRelease("21.0.0", expected: "21.0.0", allowsNewer: true))
        precondition(StoreDownloadProtocol.matchesRequestedRelease("21.0.10", expected: "21.0.2", allowsNewer: true))
        precondition(!StoreDownloadProtocol.matchesRequestedRelease("21.0.10", expected: "21.0.2", allowsNewer: false))
        precondition(!StoreDownloadProtocol.matchesRequestedRelease("unknown", expected: "21.0.0", allowsNewer: true))

        // Ignore extension/Watch metadata; validate the main IPA's actual platform.
        precondition(StoreDownloadProtocol.isMainInfoPlist("Payload/Example.app/Info.plist"))
        for path in ["Payload/Example.app/Watch/Watch.app/Info.plist", "Payload/Example.app/PlugIns/Widget.appex/Info.plist",
                     "Payload/../Info.plist", "Payload//Example.app/Info.plist", "Info.plist"]
        {
            precondition(!StoreDownloadProtocol.isMainInfoPlist(path))
        }
        for info in [
            ["CFBundleIdentifier": "example.app", "CFBundleSupportedPlatforms": ["iPhoneOS"], "CFBundleShortVersionString": "21.0.0"],
            ["CFBundleIdentifier": "example.app", "DTPlatformName": "iphoneos", "CFBundleShortVersionString": "21.0.0"],
        ] as [[String: Any]] {
            try StoreDownloadProtocol.validatePackageInfo(info, bundleID: "example.app", platform: "iPhoneOS", version: "21.0.0")
        }
        for info in [
            ["CFBundleIdentifier": "other.app", "CFBundleSupportedPlatforms": ["iPhoneOS"]],
            ["CFBundleIdentifier": "example.app", "CFBundleSupportedPlatforms": ["AppleTVOS"]],
            ["CFBundleIdentifier": "example.app"],
            ["CFBundleIdentifier": "example.app", "CFBundleSupportedPlatforms": ["iPhoneOS"]],
        ] as [[String: Any]] {
            do {
                try StoreDownloadProtocol.validatePackageInfo(info, bundleID: "example.app", platform: "iPhoneOS", version: "21.0.0")
                fatalError("Accepted mismatched or missing package identity")
            } catch StoreDownloadError.invalidPackage {}
        }
        do {
            let earlier: [String: Any] = ["CFBundleIdentifier": "example.app", "CFBundleSupportedPlatforms": ["iPhoneOS"],
                                          "CFBundleShortVersionString": "20.9.8"]
            try StoreDownloadProtocol.validatePackageInfo(earlier, bundleID: "example.app", platform: "iPhoneOS", version: "21.0.0")
            fatalError("Accepted an earlier IPA as the new release")
        } catch StoreDownloadError.versionMismatch(let expected, let actual) {
            precondition(expected == "21.0.0" && actual == "20.9.8")
        }
        let error = NSError(domain: secret, code: 403, userInfo: [NSLocalizedDescriptionKey: secret, NSURLErrorKey: secret])
        precondition(!StoreDiagnostics.errorSummary(error).contains(secret))
        print("Download protocol regression checks passed.")
    }

    static func machineProvisioningChecks() async throws {
        let challenge: [String: Any] = ["customerMessage": "AMD-Action:ent/download:SP"]
        for response in [challenge, ["failureType": 0, "customerMessage": "AMD-Action:ent/download:SP"],
                         ["dialog": ["message": "AMD-Action:ent/download:SP"]],
                         ["customerMessage": "AMD-Action:downloadProduct:RP"]] {
            precondition(StoreDownloadProtocol.requiresDeviceVerification(response))
            do {
                _ = try StoreDownloadProtocol.packageItem(response, bundleID: "example.app")
                fatalError("A provisioning instruction cannot be a package")
            } catch StoreDownloadError.deviceVerificationRequired {}
        }
        precondition(StoreDownloadProtocol.requiresDeviceVerification([:], actionHeader: " SP "))
        precondition(!StoreDownloadProtocol.requiresDeviceVerification([:], actionHeader: "unknown"))
        precondition(!StoreDownloadProtocol.requiresDeviceVerification(["customerMessage": "Please complete account verification"]))
        precondition(!StoreDownloadProtocol.isExpiredSession(StoreDownloadError.deviceVerificationRequired))
        precondition(!StoreDownloadError.rejected("", "AMD-Action:ent/download:SP").localizedDescription.contains("AMD-Action"))
        for code in ["9610", "2034", "2042"] {
            let response: [String: Any] = ["failureType": code, "customerMessage": "AMD-Action:ent/download:SP"]
            precondition(!StoreDownloadProtocol.requiresDeviceVerification(response, actionHeader: "SP"))
            precondition(StoreDownloadProtocol.fallbackReason(response) == nil)
            do {
                _ = try StoreDownloadProtocol.packageItem(response, bundleID: "example.app")
                fatalError("Lost explicit account/license verdict")
            } catch StoreDownloadError.rejected(let received, _) { precondition(received == code) }
        }

        for headerOnly in [false, true] {
            var requests: [(StoreDownloadProtocol.Endpoint, String)] = []
            let result = try await StoreDownloadProtocol.fetchWithFallback(version: "historical-id", hasUpdateEndpoint: { true }) { endpoint, version in
                requests.append((endpoint, version))
                if endpoint == .volumeStore && headerOnly { throw StoreDownloadError.deviceVerificationRequired }
                return challenge
            } onFallback: { _, reason in precondition(reason == "device-verification") }
            precondition(requests.count == 2 && requests[0].0 == .volumeStore && requests[1].0 == .redownload)
            precondition(requests.allSatisfy { $0.1 == "historical-id" })
            precondition(StoreDownloadProtocol.requiresDeviceVerification(result))
        }
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await StoreDownloadProtocol.fetchWithFallback(version: "historical-id", hasUpdateEndpoint: { true }) { _, _ in
                fatalError("A cancelled request must not start")
            } onFallback: { _, _ in fatalError("A cancelled request must not fall back") }
        }
        do { _ = try await cancelled.value; fatalError("Lost cancellation") } catch is CancellationError {}
        print("Machine provisioning classification and bounded compatibility checks passed.")
    }
}


