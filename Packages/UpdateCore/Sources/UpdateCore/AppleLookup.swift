import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum LookupError: LocalizedError {
    case notFound, http(Int), invalidResponse
    public var errorDescription: String? {
        switch self {
        case .notFound: return "该地区未查到此 Bundle ID。可能已下架、来自其他地区，或自签时修改了标识。"
        case .http(let code): return "苹果接口返回 HTTP \(code)，请稍后重试。"
        case .invalidResponse: return "苹果返回的数据缺少匹配的应用或版本号。"
        }
    }
}

public enum AppleLookup {
    public static func request(bundleID: String, country: String) -> URLRequest {
        var url = URLComponents(string: "https://itunes.apple.com/lookup")!
        url.queryItems = [URLQueryItem(name: "bundleId", value: bundleID),
                         URLQueryItem(name: "country", value: country),
                         URLQueryItem(name: "entity", value: "software")]
        var request = URLRequest(url: url.url!, timeoutInterval: 30)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    public static func fetch(bundleID: String, country: String) async throws -> StoreRelease {
        let (data, response) = try await URLSession.shared.data(for: request(bundleID: bundleID, country: country))
        guard let http = response as? HTTPURLResponse else { throw LookupError.invalidResponse }
        guard http.statusCode == 200 else { throw LookupError.http(http.statusCode) }
        return try decode(data, bundleID: bundleID, country: country)
    }

    public static func decode(_ data: Data, bundleID: String, country: String) throws -> StoreRelease {
        let envelope = try JSONDecoder().decode(Envelope.self, from: data)
        guard !envelope.results.isEmpty else { throw LookupError.notFound }
        guard let app = envelope.results.first(where: { $0.bundleId == bundleID }),
              let version = app.version, !version.isEmpty else { throw LookupError.invalidResponse }
        return StoreRelease(bundleID: bundleID, name: app.trackName ?? bundleID, version: version,
                            notes: app.releaseNotes, releasedAt: app.currentVersionReleaseDate,
                            minimumOS: app.minimumOsVersion, iconURL: app.artworkUrl100,
                            storeURL: app.trackViewUrl, country: country)
    }

    private struct Envelope: Decodable { var results: [Result] }
    private struct Result: Decodable {
        var bundleId: String?
        var trackName: String?
        var version: String?
        var releaseNotes: String?
        var currentVersionReleaseDate: String?
        var minimumOsVersion: String?
        var artworkUrl100: URL?
        var trackViewUrl: URL?
    }
}
