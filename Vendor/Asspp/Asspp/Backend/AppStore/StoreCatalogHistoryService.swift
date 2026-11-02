import Foundation

/// Token-free metadata from Apple's public App Store catalog. This session
/// never receives an Apple Account, Cookie, DSID, kbsync blob, or password token.
enum StoreCatalogHistoryService {
    private final class NoRedirect: NSObject, URLSessionTaskDelegate {
        func urlSession(_: URLSession, task _: URLSessionTask,
                        willPerformHTTPRedirection _: HTTPURLResponse,
                        newRequest _: URLRequest,
                        completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 8
        configuration.timeoutIntervalForResource = 12
        return URLSession(configuration: configuration, delegate: NoRedirect(), delegateQueue: nil)
    }()

    static func request(appID: Int64, region: String, platform: String) throws -> URLRequest {
        let country = region.lowercased()
        guard appID > 0, country.utf8.count == 2,
              country.utf8.allSatisfy({ (97...122).contains($0) }),
              ["iphone", "ipad", "appletv"].contains(platform)
        else { throw StoreDownloadError.invalidPackage }
        var components = URLComponents()
        components.scheme = "https"
        components.host = "apps.apple.com"
        components.path = "/api/apps/v1/catalog/\(country)/apps/\(appID)"
        components.queryItems = [
            URLQueryItem(name: "platform", value: "web"),
            URLQueryItem(name: "extend", value: "versionHistory"),
            URLQueryItem(name: "additionalPlatforms", value: platform),
        ]
        guard let url = components.url else { throw StoreDownloadError.invalidPackage }
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    static func history(appID: Int64, bundleID: String, region: String, platform: String,
                        onEvent: @Sendable (String) -> Void = { _ in }) async throws -> StoreHistorySupport.Index {
        let started = DispatchTime.now().uptimeNanoseconds
        defer {
            let ms = (DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
            onEvent("Store history catalog: app=\(appID) elapsedMs=\(ms)")
        }
        let request = try Self.request(appID: appID, region: region, platform: platform)
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard let response = response as? HTTPURLResponse,
              response.url == request.url, response.statusCode == 200,
              data.count <= 2 * 1024 * 1024 else { throw StoreDownloadError.catalogUnavailable }
        let index = try StoreHistorySupport.catalogIndex(data, appID: appID, bundleID: bundleID, platform: platform)
        onEvent("Store history catalog: app=\(appID) versions=\(index.identifiers.count) HTTP=200")
        return index
    }
}
