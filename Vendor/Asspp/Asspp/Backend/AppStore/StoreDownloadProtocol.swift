import Foundation

enum StoreDownloadError: LocalizedError {
    case invalidRedirect
    case response(Int)
    case serviceResponse(Int, String)
    case emptyResponse(Int)
    case invalidPackage
    case empty
    case catalogUnavailable
    case actionRequired
    case noVersions
    case rejected(String, String)

    var errorDescription: String? {
        switch self {
        case .invalidRedirect:
            String(localized: "Apple returned an invalid download redirect.")
        case let .response(status), let .emptyResponse(status):
            String(localized: "Apple's download service returned an invalid response (HTTP \(status)).")
        case let .serviceResponse(status, endpoint):
            String(localized: "Apple rejected the \(endpoint) request (HTTP \(status)).")
        case .invalidPackage:
            String(localized: "Apple returned incomplete or mismatched package information.")
        case .empty:
            String(localized: "Apple returned no downloadable package from either download service. This does not mean the app does not exist. Check this account's license, store region, and the requested version. See Settings > Logs for details.")
        case .catalogUnavailable:
            String(localized: "Unable to determine the current version for this platform. Try again later or select a specific historical version.")
        case .actionRequired:
            String(localized: "Apple requires an account confirmation. Open the App Store with this account, complete any prompts, then try again.")
        case .noVersions:
            String(localized: "Apple returned no version history for this app and platform.")
        case let .rejected(code, message):
            message.isEmpty ? String(localized: "Apple rejected the download (code: \(code)).") : message
        }
    }
}

/// Response classification and request rules without credentials or networking.
enum StoreDownloadProtocol {
    static func isExpiredSession(_ error: Error) -> Bool {
        if case StoreDownloadError.rejected("2034", _) = error { return true }
        // ApplePackage's purchase API exposes this verdict as a localized NSError.
        let message = error.localizedDescription.lowercased()
        return message.contains("failuretype: 2034") || message.contains("password token is expired")
    }

    static func retryExpiredSession<Value>(operation: () async throws -> Value, refresh: () async throws -> Void) async throws -> Value {
        do { return try await operation() }
        catch {
            guard isExpiredSession(error) else { throw error }
            try Task.checkCancellation()
            try await refresh()
            try Task.checkCancellation()
            return try await operation()
        }
    }

    static let entPath = "/WebObjects/DownloadDispatch.woa/wa/ent/download"

    /// Current bags advertise ent/download under volumeStoreDownloadProduct.
    static func entEndpoint(in bag: [String: Any]) -> URL? {
        let urls = bag["urlBag"] as? [String: Any] ?? [:]
        let value = urls["volumeStoreDownloadProduct"] ?? bag["volumeStoreDownloadProduct"]
            ?? urls["loc-volumeStoreDownloadProduct"] ?? bag["loc-volumeStoreDownloadProduct"]
        guard let raw = value as? String, let components = URLComponents(string: raw),
              components.scheme == "https", components.host == "downloaddispatch.itunes.apple.com",
              components.percentEncodedPath == entPath,
              components.user == nil, components.password == nil, components.query == nil, components.fragment == nil,
              components.port == nil || components.port == 443
        else { return nil }
        return components.url
    }

    static func entRequest(endpoint: URL, appID: Int64, guid: String, dsid: String,
                           store: String, token: String, version: String, blob: String) throws -> URLRequest {
        guard entEndpoint(in: ["volumeStoreDownloadProduct": endpoint.absoluteString]) != nil,
              guid.count == 12, guid.allSatisfy(\.isHexDigit), !version.isEmpty, !blob.isEmpty
        else { throw StoreDownloadError.invalidPackage }
        var hardware: [UInt8] = []
        var index = guid.startIndex
        while index < guid.endIndex {
            let end = guid.index(index, offsetBy: 2)
            guard let byte = UInt8(guid[index ..< end], radix: 16) else { throw StoreDownloadError.invalidPackage }
            hardware.append(byte)
            index = end
        }
        var url = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
        url.queryItems = [URLQueryItem(name: "guid", value: guid)]
        var request = URLRequest(url: url.url!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue("Configurator/2.18 (Macintosh; OS X 15.3.2; 24D81) AppleWebKit/0620.2.4.11.6", forHTTPHeaderField: "User-Agent")
        request.setValue(store + "-1", forHTTPHeaderField: "X-Apple-Store-Front")
        request.setValue(token, forHTTPHeaderField: "X-Token")
        request.setValue(dsid, forHTTPHeaderField: "iCloud-DSID")
        request.setValue(dsid, forHTTPHeaderField: "X-Dsid")
        request.httpBody = try PropertyListSerialization.data(fromPropertyList: [
            "creditDisplay": "", "guid": guid, "kbsync": blob, "salableAdamId": String(appID),
            "serialNumber": Data([0x54, 0xc8, 0xb0, 0xa9, 0x88] + Array(hardware.dropFirst(2))).base64EncodedString(),
            "externalVersionId": version,
        ], format: .xml, options: 0)
        return request
    }

    /// Only a rejected cached blob permits one regeneration; fresh failures and
    /// explicit account/license verdicts never trigger signing or login loops.
    static func preferredDownload(cached: String?, generate: () async throws -> String,
                                  invalidate: (String) async -> Void,
                                  fetch: (String) async throws -> [String: Any]) async throws -> [String: Any] {
        if let cached {
            do { return try await fetch(cached) }
            catch StoreDownloadError.serviceResponse(403, "ent/download") {
                try Task.checkCancellation()
                await invalidate(cached)
            }
        }
        try Task.checkCancellation()
        let fresh = try await generate()
        try Task.checkCancellation()
        return try await fetch(fresh)
    }

    static func validateEntResponse(_ response: [String: Any], appID: Int64,
                                    bundleID: String, version: String) throws {
        let item = try packageItem(response, bundleID: bundleID, version: version)
        guard let list = response["songList"] as? [Any], list.count == 1,
              let metadata = item["metadata"] as? [String: Any],
              StoreProtocol.string(metadata["itemId"]) == String(appID),
              metadata["softwareVersionBundleId"] as? String == bundleID,
              StoreProtocol.string(metadata["softwareVersionExternalIdentifier"]) == version,
              let asset = item["URL"] as? String, !asset.isEmpty
        else { throw StoreDownloadError.invalidPackage }
    }
    /// Follow ipatool: let Apple's generic host route a session without an assigned pod.
    /// A guessed p25 pod can be unrelated to the account's actual store session.
    static func storeHost(pod: String?) throws -> String {
        guard let pod, !pod.isEmpty else { return "buy.itunes.apple.com" }
        guard pod.allSatisfy({ $0.isASCII && $0.isNumber }) else { throw StoreDownloadError.invalidRedirect }
        return "p\(pod)-buy.itunes.apple.com"
    }

    static func isMainInfoPlist(_ path: String) -> Bool {
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        return components.count == 3 && components[0] == "Payload"
            && components[1].hasSuffix(".app") && components[2] == "Info.plist"
    }

    static func validatePackageInfo(_ info: [String: Any], bundleID: String, platform: String) throws {
        let platforms = info["CFBundleSupportedPlatforms"] as? [String] ?? []
        let platformName = info["DTPlatformName"] as? String ?? ""
        guard info["CFBundleIdentifier"] as? String == bundleID,
              platforms.contains(platform) || platformName.lowercased() == platform.lowercased()
        else { throw StoreDownloadError.invalidPackage }
    }

    struct CatalogVersion {
        let bundleID: String?
        let externalVersionID: String
    }

    static func catalogVersion(_ data: Data, appID: Int64) throws -> CatalogVersion {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = root["results"] as? [String: Any],
              let item = results[String(appID)] as? [String: Any],
              let offers = item["offers"] as? [[String: Any]]
        else { throw StoreDownloadError.catalogUnavailable }
        for offer in offers {
            let version = offer["version"] as? [String: Any]
            var identifier = StoreProtocol.string(version?["externalId"])
            if identifier.isEmpty, let parameters = offer["buyParams"] as? String {
                let components = URLComponents(string: "?" + parameters)
                identifier = components?.queryItems?.first { $0.name == "appExtVrsId" }?.value ?? ""
            }
            if !identifier.isEmpty, identifier.allSatisfy({ $0.isASCII && $0.isNumber }) {
                return CatalogVersion(bundleID: item["bundleId"] as? String, externalVersionID: identifier)
            }
        }
        throw StoreDownloadError.catalogUnavailable
    }

    enum Endpoint: String {
        case volumeStore, redownload, update

        var versionKey: String {
            self == .volumeStore ? "externalVersionId" : "appExtVrsId"
        }

        var path: String {
            switch self {
            case .volumeStore: "/WebObjects/MZFinance.woa/wa/volumeStoreDownloadProduct"
            case .redownload: "/r/redownload"
            case .update: "/up/updateProduct"
            }
        }
    }

    static func validatedURL(_ url: URL) throws -> URL {
        let host = url.host?.lowercased() ?? ""
        let storeHost = host == "buy.itunes.apple.com"
            || host.range(of: #"^p[0-9]+-buy\.itunes\.apple\.com$"#, options: .regularExpression) != nil
        let storePath = [Endpoint.volumeStore.path, "/WebObjects/MZFinance.woa/wa/redownloadProduct"].contains(url.path)
        guard url.scheme == "https", url.user == nil, url.password == nil,
              url.fragment == nil, url.port == nil || url.port == 443,
              (storeHost && storePath) || (host == "downloaddispatch.itunes.apple.com"
                  && [Endpoint.redownload.path, Endpoint.update.path].contains(url.path))
        else { throw StoreDownloadError.invalidRedirect }
        return url
    }

    static func payload(endpoint: Endpoint, appID: Int64, guid: String, version: String?) -> [String: Any] {
        var result: [String: Any] = ["creditDisplay": "", "guid": guid, "salableAdamId": appID, "serialNumber": "0"]
        if let version, !version.isEmpty {
            result[endpoint.versionKey] = version
        }
        return result
    }

    static func failureCode(_ response: [String: Any]) -> String {
        let failure = StoreProtocol.string(response["failureType"])
        if !failure.isEmpty {
            return failure
        }
        let metrics = response["metrics"] as? [String: Any]
        let code = StoreProtocol.string(metrics?["messageCode"])
        return code == "0" ? "" : code
    }

    static func fallbackReason(_ response: [String: Any]) -> String? {
        let failure = failureCode(response)
        if failure == "5002" {
            return "failure-5002"
        }
        guard failure.isEmpty,
              StoreProtocol.string(response["customerMessage"]).isEmpty,
              response["dialog"] == nil, response["action"] == nil
        else { return nil }
        let status = StoreProtocol.string(response["status"])
        guard status.isEmpty || status == "0" else { return nil }
        if let items = response["songList"] as? [Any] {
            return items.isEmpty ? "empty-songList" : nil
        }
        return response["songList"] == nil ? "missing-songList" : nil
    }

    /// Each endpoint is attempted at most once. A failed catalog lookup must not turn into an
    /// unpinned redownload, and historical requests must keep their version ID.
    static func fetchWithFallback(
        version: String?,
        fetch: (Endpoint, String?) async throws -> [String: Any],
        resolveVersion: () async throws -> String,
        onFallback: (String) -> Void,
    ) async throws -> [String: Any] {
        let primary = try await fetch(.volumeStore, version)
        guard let reason = fallbackReason(primary) else { return primary }
        onFallback(reason)
        let resolved: String = if let version, !version.isEmpty {
            version
        } else {
            try await resolveVersion()
        }
        guard !resolved.isEmpty else { throw StoreDownloadError.catalogUnavailable }
        do {
            return try await fetch(.redownload, resolved)
        } catch StoreDownloadError.emptyResponse(500) {
            onFallback("empty-redownload-http500")
            return try await fetch(.update, resolved)
        }
    }

    /// Only structural fields and numeric codes are logged. Apple messages can
    /// contain account information; display those to the user, never dump them.
    static func summary(_ response: [String: Any]) -> String {
        func numeric(_ value: Any?) -> String {
            let text = StoreProtocol.string(value)
            if text.isEmpty {
                return "none"
            }
            return text.count <= 12 && text.allSatisfy { $0.isASCII && ($0.isNumber || $0 == "-") } ? text : "other"
        }
        let items: String = if let list = response["songList"] as? [Any] {
            String(list.count)
        } else {
            response["songList"] == nil ? "missing" : "invalid"
        }
        let message = !StoreProtocol.string(response["customerMessage"]).isEmpty
        return "songList=\(items) failure=\(numeric(failureCode(response))) status=\(numeric(response["status"])) customerMessage=\(message) dialog=\(response["dialog"] != nil) action=\(response["action"] != nil)"
    }

    static func packageItem(_ response: [String: Any], bundleID: String, version: String? = nil) throws -> [String: Any] {
        let code = failureCode(response)
        let message = StoreProtocol.string(response["customerMessage"])
        if !code.isEmpty {
            throw StoreDownloadError.rejected(code, message)
        }
        guard let items = response["songList"] as? [[String: Any]], !items.isEmpty else {
            if !message.isEmpty {
                throw StoreDownloadError.rejected("", message)
            }
            if response["dialog"] != nil || response["action"] != nil {
                throw StoreDownloadError.actionRequired
            }
            let status = StoreProtocol.string(response["status"])
            if !status.isEmpty, status != "0" {
                throw StoreDownloadError.rejected(status, "")
            }
            if response["songList"] != nil, !(response["songList"] is [[String: Any]]) {
                throw StoreDownloadError.invalidPackage
            }
            throw StoreDownloadError.empty
        }
        guard let item = items.first(where: {
            ($0["metadata"] as? [String: Any])?["softwareVersionBundleId"] as? String == bundleID
        }) ?? (items.count == 1 ? items.first : nil),
            let metadata = item["metadata"] as? [String: Any]
        else { throw StoreDownloadError.invalidPackage }
        if let returnedBundle = metadata["softwareVersionBundleId"] as? String, returnedBundle != bundleID {
            throw StoreDownloadError.invalidPackage
        }
        let returnedVersion = StoreProtocol.string(metadata["softwareVersionExternalIdentifier"])
        if let version, !returnedVersion.isEmpty, returnedVersion != version {
            throw StoreDownloadError.invalidPackage
        }
        return item
    }
}


