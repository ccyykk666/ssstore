import ApplePackage
import Foundation

/// Download metadata transport. Keep Apple's raw bodies, cookies and signed
/// asset URLs out of both the Xcode console and the in-app log viewer.
enum StoreDownloadService {
    private static let prepared = StorePreparedDownloadCache<DownloadOutput>()
    private static func cacheKey(account: Account, package: AppStore.AppPackage, version: String) -> StorePreparedDownloadCache<DownloadOutput>.Key {
        .init(account: account.directoryServicesIdentifier, token: account.passwordToken,
              guid: Configuration.deviceIdentifier.lowercased(), store: account.store,
              app: package.software.bundleID, platform: (package.entityType ?? .iPhone).rawValue, version: version)
    }
    private final class NoRedirect: NSObject, URLSessionTaskDelegate {
        func urlSession(_: URLSession, task _: URLSessionTask,
                        willPerformHTTPRedirection _: HTTPURLResponse,
                        newRequest _: URLRequest,
                        completionHandler: @escaping (URLRequest?) -> Void)
        {
            completionHandler(nil)
        }
    }

    static func download(account: inout Account, package: AppStore.AppPackage) async throws -> DownloadOutput {
        if let version = package.externalVersionID,
           let output = await prepared.take(for: cacheKey(account: account, package: package, version: version)) {
            try Task.checkCancellation()
            logger.info("Store download: reusing recent historical download reply")
            return output
        }
        let email = account.email
        return try await product(account: &account, package: package, version: package.externalVersionID, operation: "download") { item in
            try output(item: item, email: email)
        }
    }

    struct VersionIndex: Sendable {
        let identifiers: [String]
        let metadata: [String: StoreHistorySupport.Metadata]
    }

    static func versions(account: inout Account, package: AppStore.AppPackage) async throws -> [String] {
        try await versionIndex(account: &account, package: package).identifiers
    }

    static func versionIndex(account: inout Account, package: AppStore.AppPackage) async throws -> VersionIndex {
        try await product(account: &account, package: package, version: nil, operation: "versions") { item in
            let index = try StoreHistorySupport.index(item)
            return VersionIndex(identifiers: index.identifiers, metadata: index.metadata)
        }
    }

    static func versionMetadata(account: inout Account, package: AppStore.AppPackage, versionID: String) async throws -> StoreHistorySupport.Metadata {
        let email = account.email
        var download: DownloadOutput?
        let result = try await product(account: &account, package: package, version: versionID, operation: "version-metadata") { item in
            guard let metadata = item["metadata"] as? [String: Any] else { throw StoreDownloadError.invalidPackage }
            download = try? output(item: item, email: email)
            return try StoreHistorySupport.details(metadata)
        }
        if let download {
            await prepared.insert(download, for: cacheKey(account: account, package: package, version: versionID))
        }
        return result
    }

    // Explicit per-request cookies/tokens remain isolated. Sharing the ephemeral
    // session reuses TLS/HTTP connections without automatic cookies or storage.
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60
        configuration.httpMaximumConnectionsPerHost = 4
        return URLSession(configuration: configuration, delegate: NoRedirect(), delegateQueue: nil)
    }()
    private static let bagCache = StoreBagCache()

    private static func elapsed(_ start: UInt64) -> UInt64 {
        (DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
    }

    private static func product<Result>(account: inout Account, package: AppStore.AppPackage, version: String?, operation: String, parse: ([String: Any]) throws -> Result) async throws -> Result {
        let trace = String(UUID().uuidString.prefix(8))
        let app = package.software
        let version = version.flatMap { $0.isEmpty ? nil : $0 }
        let platform = package.entityType ?? .iPhone
        logger.info("Store download [\(trace)]: operation=\(operation) app=\(app.id) platform=\(platform.rawValue) store=\(account.store) version=\(version ?? "latest")")
        let started = DispatchTime.now().uptimeNanoseconds
        defer { logger.info("Store download [\(trace)]: operation=\(operation) elapsedMs=\(elapsed(started))") }
        let session = Self.session
        do {
            let region = Configuration.countryCode(for: StoreProtocol.storefrontIdentifier(account.store))
            var effectiveVersion = version
            func resolveVersion() async throws -> String {
                // An unpinned redownload can return a tvOS build for an iOS app.
                guard let region else { throw StoreDownloadError.catalogUnavailable }
                let metadata: StoreDownloadProtocol.CatalogVersion
                do {
                    metadata = try await catalogVersion(session: session, appID: app.id, region: region, platform: platform, trace: trace)
                } catch {
                    try Task.checkCancellation()
                    throw StoreDownloadError.catalogUnavailable
                }
                guard !metadata.externalVersionID.isEmpty,
                      metadata.bundleID == nil || metadata.bundleID == app.bundleID
                else { throw StoreDownloadError.catalogUnavailable }
                logger.info("Store download [\(trace)]: catalog version=\(metadata.externalVersionID)")
                return metadata.externalVersionID

            }
            func compatibilityResponse(account compatibilityAccount: inout Account) async throws -> [String: Any] {
                try await StoreDownloadProtocol.fetchWithFallback(version: effectiveVersion) { endpoint, requestedVersion in
                    effectiveVersion = requestedVersion
                    return try await fetch(session: session, endpoint: endpoint, account: &compatibilityAccount,
                        appID: app.id, version: requestedVersion, trace: trace)
                } resolveVersion: { try await resolveVersion() } onFallback: { reason in
                    logger.info("Store download [\(trace)]: trying \(reason == "empty-redownload-http500" ? "update" : "redownload"), reason=\(reason)")
                }
            }
            let guid = Configuration.deviceIdentifier
            let response: [String: Any]
            if let endpoint = try await preferredEndpoint(session: session, guid: guid, trace: trace) {
                let dsid = account.directoryServicesIdentifier
                let cached = await KBSyncStore.shared.cached(guid: guid, dsid: dsid)
                logger.info("Store download [\(trace)]: preferred=ent/download kbsyncCached=\(cached != nil)")
                func generateBlob() async throws -> String {
                    logger.info("Store download [\(trace)]: local kbsync generation started")
                    let generationStart = DispatchTime.now().uptimeNanoseconds
                    let blob = try await KBSyncStore.shared.generate(guid: guid, dsid: dsid)
                    logger.info("Store download [\(trace)]: kbsync elapsedMs=\(elapsed(generationStart))")
                    logger.info("Store download [\(trace)]: local kbsync generation ready")
                    return blob
                }
                let generationTask: Task<String, Error>? = cached == nil ? Task { try await generateBlob() } : nil
                defer { generationTask?.cancel() }
                let pinned: String
                if let version { pinned = version }
                else { pinned = try await resolveVersion() }
                effectiveVersion = pinned
                response = try await StoreDownloadProtocol.preferredOrCompatibility {
                    try await StoreDownloadProtocol.preferredDownload(cached: cached) {
                        if let generationTask { return try await generationTask.value }
                        return try await generateBlob()
                    } invalidate: { blob in
                        await KBSyncStore.shared.invalidate(guid: guid, dsid: dsid, expected: blob)
                    } fetch: { blob in
                        let result = try await fetchPreferred(session: session, endpoint: endpoint, account: &account,
                            appID: app.id, guid: guid, version: pinned, blob: blob, trace: trace)
                        if StoreDownloadProtocol.failureCode(result).isEmpty {
                            try StoreDownloadProtocol.validateEntResponse(result, appID: app.id, bundleID: app.bundleID, version: pinned)
                        }
                        return result
                    }
                } compatibility: {
                    logger.info("Store download [\(trace)]: machine provisioning requested; using compatibility endpoints")
                    return try await compatibilityResponse(account: &account)
                }
            } else {
                response = try await compatibilityResponse(account: &account)
            }
            // Let the download caller handle missing licenses.
            if StoreDownloadProtocol.failureCode(response) == "9610" {
                throw ApplePackageError.licenseRequired
            }
            let item = try StoreDownloadProtocol.packageItem(response, bundleID: app.bundleID, version: effectiveVersion)
            try Task.checkCancellation()
            let result = try parse(item)
            logger.info("Store download [\(trace)]: product metadata ready")
            return result
        } catch {
            // localizedDescription and NSError.userInfo can contain Apple messages
            // or a credential-bearing URL. Log only the error type and numeric code.
            logger.error("Store download [\(trace)]: failed, \(StoreDiagnostics.errorSummary(error))")
            throw error
        }
    }


    private static func preferredEndpoint(session: URLSession, guid: String, trace: String) async throws -> URL? {
        let started = DispatchTime.now().uptimeNanoseconds
        defer { logger.info("Store download [\(trace)]: bag lookup elapsedMs=\(elapsed(started))") }
        return try await bagCache.endpoint(for: guid) {
            try await fetchPreferredEndpoint(session: session, guid: guid, trace: trace)
        }
    }

    private static func fetchPreferredEndpoint(session: URLSession, guid: String, trace: String) async throws -> URL? {
        var url = URLComponents(string: "https://init.itunes.apple.com/bag.xml")!
        url.queryItems = [URLQueryItem(name: "guid", value: guid)]
        var request = URLRequest(url: url.url!)
        request.setValue(Configuration.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/xml", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        logger.info("Store download [\(trace)]: bag HTTP=\(status) bytes=\(data.count)")
        guard status == 200, let bag = StoreProtocol.plist(data) else { throw StoreDownloadError.response(status) }
        return StoreDownloadProtocol.entEndpoint(in: bag)
    }

    private static func fetchPreferred(session: URLSession, endpoint: URL, account: inout Account,
        appID: Int64, guid: String, version: String, blob: String, trace: String) async throws -> [String: Any] {
        var request = try StoreDownloadProtocol.entRequest(endpoint: endpoint, appID: appID, guid: guid,
            dsid: account.directoryServicesIdentifier, store: account.store, token: account.passwordToken,
            version: version, blob: blob)
        let cookies = account.cookie.map {
            StoreProtocol.SessionCookie(name: $0.name, value: $0.value, path: $0.path, domain: $0.domain,
                expiresAt: $0.expiresAt, secure: $0.secure)
        }
        request.setValue(StoreProtocol.cookieHeader(cookies, for: request.url!), forHTTPHeaderField: "Cookie")
        logger.info("Store download [\(trace)]: endpoint=ent/download request ready")
        let started = DispatchTime.now().uptimeNanoseconds
        defer { logger.info("Store download [\(trace)]: ent/download elapsedMs=\(elapsed(started))") }
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw StoreDownloadError.response(0) }
        mergeCookies(response: response, url: request.url!, account: &account)
        logger.info("Store download [\(trace)]: endpoint=ent/download HTTP=\(response.statusCode) bytes=\(data.count)")
        // NoRedirect rejects every 30x: never forward X-Token to a Location.
        if (300 ..< 400).contains(response.statusCode) { throw StoreDownloadError.invalidRedirect }
        let plist = StoreProtocol.plist(data)
        if let plist, !StoreDownloadProtocol.failureCode(plist).isEmpty {
            logger.info("Store download [\(trace)]: \(StoreDownloadProtocol.summary(plist))")
            return plist
        }
        if StoreDownloadProtocol.requiresDeviceVerification(plist ?? [:],
            actionHeader: response.value(forHTTPHeaderField: "X-Apple-AMD-Action")) {
            logger.info("Store download [\(trace)]: endpoint=ent/download requires machine provisioning")
            throw StoreDownloadError.deviceVerificationRequired
        }
        guard response.statusCode == 200, let plist else {
            throw StoreDownloadError.serviceResponse(response.statusCode, "ent/download")
        }
        logger.info("Store download [\(trace)]: \(StoreDownloadProtocol.summary(plist))")
        return plist
    }

    private static func catalogVersion(session: URLSession, appID: Int64, region: String, platform: EntityType, trace: String) async throws -> StoreDownloadProtocol.CatalogVersion {
        let started = DispatchTime.now().uptimeNanoseconds
        defer { logger.info("Store download [\(trace)]: catalog elapsedMs=\(elapsed(started))") }
        var url = URLComponents(string: "https://uclient-api.itunes.apple.com/WebObjects/MZStorePlatform.woa/wa/lookup")!
        url.queryItems = [
            URLQueryItem(name: "version", value: "2"), URLQueryItem(name: "id", value: String(appID)),
            URLQueryItem(name: "p", value: "mdm-lockup"), URLQueryItem(name: "caller", value: "MDM"),
            URLQueryItem(name: "platform", value: platform == .appleTV ? "atv9" : "enterprisestore"),
            URLQueryItem(name: "cc", value: region.lowercased()), URLQueryItem(name: "l", value: "en"),
        ]
        var request = URLRequest(url: url.url!)
        request.setValue(Configuration.userAgent, forHTTPHeaderField: "User-Agent")
        // No credentials and no automatic redirects. Foundation verifies TLS in
        // Debug too (ApplePackage 1.2.7 disables verification in its Debug client).
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        logger.info("Store download [\(trace)]: catalog HTTP=\(status) bytes=\(data.count)")
        guard status == 200 else { throw StoreDownloadError.catalogUnavailable }
        return try StoreDownloadProtocol.catalogVersion(data, appID: appID)
    }

    private static func fetch(session: URLSession, endpoint: StoreDownloadProtocol.Endpoint,
                              account: inout Account, appID: Int64, version: String?, trace: String) async throws -> [String: Any]
    {
        var components = URLComponents()
        components.scheme = "https"
        if endpoint == .volumeStore {
            components.host = try StoreDownloadProtocol.storeHost(pod: account.pod)
        } else {
            components.host = "downloaddispatch.itunes.apple.com"
        }
        components.path = endpoint.path
        if endpoint == .update {
            let bag = try? await Bag.fetchBag()
            guard let update = bag?.updateEndpoint,
                  let advertised = URLComponents(url: update, resolvingAgainstBaseURL: false)
            else { throw StoreDownloadError.emptyResponse(500) }
            components = advertised
        }
        components.queryItems = [URLQueryItem(name: "guid", value: Configuration.deviceIdentifier)]
        guard var url = components.url else { throw StoreDownloadError.invalidRedirect }
        let body = try PropertyListSerialization.data(
            fromPropertyList: StoreDownloadProtocol.payload(endpoint: endpoint, appID: appID,
                                                            guid: Configuration.deviceIdentifier, version: version),
            format: .xml, options: 0,
        )
        for redirect in 0 ... 3 {
            try Task.checkCancellation()
            url = try StoreDownloadProtocol.validatedURL(url)
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.httpBody = body
            request.setValue("application/x-apple-plist", forHTTPHeaderField: "Content-Type")
            request.setValue(Configuration.userAgent, forHTTPHeaderField: "User-Agent")
            request.setValue(Locale.preferredLanguages.prefix(3).joined(separator: ", "), forHTTPHeaderField: "Accept-Language")
            request.setValue(account.directoryServicesIdentifier, forHTTPHeaderField: "iCloud-DSID")
            request.setValue(account.directoryServicesIdentifier, forHTTPHeaderField: "X-Dsid")
            let cookies = account.cookie.map {
                StoreProtocol.SessionCookie(name: $0.name, value: $0.value, path: $0.path, domain: $0.domain,
                                            expiresAt: $0.expiresAt, secure: $0.secure)
            }
            request.setValue(StoreProtocol.cookieHeader(cookies, for: url), forHTTPHeaderField: "Cookie")
            let dottedDomains = cookies.filter { $0.domain?.hasPrefix(".") == true }.count
            logger.info("Store download [\(trace)]: endpoint=\(endpoint.rawValue) host=\(url.host ?? "unknown") hop=\(redirect) sessionCookie=\(request.value(forHTTPHeaderField: "Cookie") != nil) storedCookies=\(cookies.count) dottedDomains=\(dottedDomains)")
            let (data, response) = try await session.data(for: request)
            guard let response = response as? HTTPURLResponse else { throw StoreDownloadError.response(0) }
            mergeCookies(response: response, url: url, account: &account)
            logger.info("Store download [\(trace)]: endpoint=\(endpoint.rawValue) HTTP=\(response.statusCode) bytes=\(data.count)")
            if [301, 302, 303, 307, 308].contains(response.statusCode) {
                guard redirect < 3, let location = response.value(forHTTPHeaderField: "Location"),
                      let next = URL(string: location, relativeTo: url)?.absoluteURL
                else { throw StoreDownloadError.invalidRedirect }
                url = try StoreDownloadProtocol.validatedURL(next)
                continue
            }
            let plist = StoreProtocol.plist(data)
            if let plist {
                logger.info("Store download [\(trace)]: \(StoreDownloadProtocol.summary(plist))")
                if !StoreDownloadProtocol.failureCode(plist).isEmpty { return plist }
            }
            if StoreDownloadProtocol.requiresDeviceVerification(plist ?? [:],
                actionHeader: response.value(forHTTPHeaderField: "X-Apple-AMD-Action")) {
                logger.info("Store download [\(trace)]: endpoint=\(endpoint.rawValue) requires machine provisioning")
                throw StoreDownloadError.deviceVerificationRequired
            }
            guard response.statusCode == 200, let plist else {
                if response.statusCode == 403 {
                    let bodyKind = data.isEmpty ? "empty" : (plist == nil ? "non-plist" : "plist")
                    logger.error("Store download [\(trace)]: HTTP denial endpoint=\(endpoint.rawValue) host=\(url.host ?? "unknown") status=403 response=\(bodyKind)")
                    throw StoreDownloadError.serviceResponse(403, endpoint.rawValue)
                }
                if data.isEmpty {
                    throw StoreDownloadError.emptyResponse(response.statusCode)
                }
                throw StoreDownloadError.response(response.statusCode)
            }
            return plist
        }
        throw StoreDownloadError.invalidRedirect
    }

    private static func mergeCookies(response: HTTPURLResponse, url: URL, account: inout Account) {
        let headers = response.allHeaderFields.reduce(into: [String: String]()) { result, field in
            if let name = field.key as? String, let value = field.value as? String {
                result[name] = value
            }
        }
        for cookie in HTTPCookie.cookies(withResponseHeaderFields: headers, for: url) {
            let domain = StoreProtocol.storeCookieDomain(cookie.domain)
            account.cookie.removeAll { $0.name == cookie.name && $0.path == cookie.path && StoreProtocol.storeCookieDomain($0.domain) == domain }
            if let expiry = cookie.expiresDate, expiry <= Date() {
                continue
            }
            account.cookie.append(Cookie(name: cookie.name, value: cookie.value, path: cookie.path, domain: domain,
                                         expiresAt: cookie.expiresDate?.timeIntervalSince1970, httpOnly: cookie.isHTTPOnly, secure: cookie.isSecure))
        }
    }

    /// ApplePackage's DownloadOutput format, also consumed by SignatureInjector.
    private static func output(item: [String: Any], email: String) throws -> DownloadOutput {
        guard let url = item["URL"] as? String, let asset = URL(string: url),
              ["https", "http"].contains(asset.scheme), asset.host != nil,
              var metadata = item["metadata"] as? [String: Any],
              let version = metadata["bundleShortVersionString"] as? String,
              let build = metadata["bundleVersion"] as? String,
              let signatures = item["sinfs"] as? [[String: Any]], !signatures.isEmpty
        else { throw StoreDownloadError.invalidPackage }
        let sinfs = try signatures.map { signature -> Sinf in
            guard let id = signature["id"] as? Int64, let data = signature["sinf"] as? Data else {
                throw StoreDownloadError.invalidPackage
            }
            return Sinf(id: id, sinf: data)
        }
        metadata["apple-id"] = email
        metadata["userName"] = email
        return try DownloadOutput(downloadURL: url, sinfs: sinfs, bundleShortVersionString: version,
                                  bundleVersion: build, iTunesMetadata: PropertyListSerialization.data(fromPropertyList: metadata, format: .binary, options: 0))
    }
}


