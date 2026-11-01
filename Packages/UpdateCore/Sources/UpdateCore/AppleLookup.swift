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

public struct LookupBatch: Sendable {
    public var releases: [String: StoreRelease]
    public var catalogWarning: String? = nil
}

public enum AppleLookup {
    public static let batchSize = 25
    public static let cacheLifetime: TimeInterval = 300
    private static let lookupRateLimit = LookupRateLimit()

    public static func batches(bundleIDs: [String]) -> [[String]] {
        var seen = Set<String>()
        let unique = bundleIDs.filter { !$0.isEmpty && seen.insert($0).inserted }
        return stride(from: 0, to: unique.count, by: batchSize).map {
            Array(unique[$0..<min($0 + batchSize, unique.count)])
        }
    }

    public static func isFresh(_ release: StoreRelease?, country: String, now: Date = Date()) -> Bool {
        guard let release, release.country == country, release.source == "Apple Catalog" else { return false }
        let age = now.timeIntervalSince(release.fetchedAt)
        return age >= 0 && age < cacheLifetime
    }

    public static func request(bundleID: String, country: String) -> URLRequest {
        request(bundleIDs: [bundleID], country: country)
    }

    public static func request(bundleIDs: [String], country: String) -> URLRequest {
        var url = URLComponents(string: "https://itunes.apple.com/lookup")!
        url.queryItems = [URLQueryItem(name: "bundleId", value: bundleIDs.joined(separator: ",")),
                         URLQueryItem(name: "country", value: country),
                         URLQueryItem(name: "entity", value: "software"),
                         URLQueryItem(name: "limit", value: "200")]
        return jsonRequest(url.url!)
    }

    public static func catalogRequest(storeIDs: [String], country: String) -> URLRequest {
        var url = URLComponents(string: "https://uclient-api.itunes.apple.com/WebObjects/MZStorePlatform.woa/wa/lookup")!
        url.queryItems = [URLQueryItem(name: "version", value: "2"),
                         URLQueryItem(name: "id", value: storeIDs.joined(separator: ",")),
                         URLQueryItem(name: "p", value: "mdm-lockup"),
                         URLQueryItem(name: "caller", value: "MDM"),
                         URLQueryItem(name: "platform", value: "enterprisestore"),
                         URLQueryItem(name: "cc", value: country.lowercased()),
                         URLQueryItem(name: "l", value: "zh")]
        return jsonRequest(url.url!)
    }

    private static func jsonRequest(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    private static func load(_ request: URLRequest) async throws -> Data {
        if request.url?.host == "itunes.apple.com" { try await lookupRateLimit.wait() }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw LookupError.invalidResponse }
        guard http.statusCode == 200 else { throw LookupError.http(http.statusCode) }
        return data
    }

    public static func fetch(bundleID: String, country: String) async throws -> StoreRelease {
        let batch = try await fetchBatch(bundleIDs: [bundleID], country: country)
        guard let release = batch.releases[bundleID] else { throw LookupError.notFound }
        return release
    }

    // Rechecks use saved numeric IDs. Discover unknown IDs in one multi-bundle
    // request, then query the same public catalog used by AssppWeb.
    public static func fetchBatch(bundleIDs: [String], country: String,
                                  knownStoreIDs: [String: String] = [:]) async throws -> LookupBatch {
        let ids = Array(Set(bundleIDs)).sorted()
        let known = knownStoreIDs.filter { ids.contains($0.key) && validID($0.value) }
        let unknown = ids.filter { known[$0] == nil }
        var releases: [String: StoreRelease] = [:]
        if !unknown.isEmpty {
            releases = try decodeBatch(try await load(request(bundleIDs: unknown, country: country)),
                                       bundleIDs: unknown, country: country)
        }
        var storeIDs = known
        for (bundle, release) in releases { if let id = release.storeID { storeIDs[bundle] = id } }
        guard !storeIDs.isEmpty else { return LookupBatch(releases: releases) }
        do {
            let data = try await load(catalogRequest(storeIDs: Array(Set(storeIDs.values)).sorted(), country: country))
            let catalog = try decodeCatalog(data, expected: storeIDs, country: country)
            releases.merge(catalog) { _, new in new }
            let missing = ids.filter { releases[$0] == nil }
            if !missing.isEmpty {
                let fallback = try decodeBatch(try await load(request(bundleIDs: missing, country: country)),
                                               bundleIDs: missing, country: country)
                releases.merge(fallback) { _, new in new }
            }
            return LookupBatch(releases: releases)
        } catch is CancellationError { throw CancellationError() }
        catch {
            if Task.isCancelled { throw CancellationError() }
            if case LookupError.http(429) = error { throw error }
            let missing = ids.filter { releases[$0] == nil }
            if !missing.isEmpty {
                let fallback = try decodeBatch(try await load(request(bundleIDs: missing, country: country)),
                                               bundleIDs: missing, country: country)
                releases.merge(fallback) { _, new in new }
            }
            return LookupBatch(releases: releases, catalogWarning: "苹果目录暂不可用，本批使用公开 Lookup：\(error.localizedDescription)")
        }
    }

    public static func decode(_ data: Data, bundleID: String, country: String) throws -> StoreRelease {
        let releases = try decodeBatch(data, bundleIDs: [bundleID], country: country)
        guard let release = releases[bundleID] else {
            let envelope = try JSONDecoder().decode(Envelope.self, from: data)
            throw envelope.results.isEmpty ? LookupError.notFound : LookupError.invalidResponse
        }
        return release
    }

    public static func decodeBatch(_ data: Data, bundleIDs: [String], country: String) throws -> [String: StoreRelease] {
        let envelope = try JSONDecoder().decode(Envelope.self, from: data)
        let expected = Set(bundleIDs)
        var releases: [String: StoreRelease] = [:]
        for app in envelope.results {
            guard let bundle = app.bundleId, expected.contains(bundle), let version = app.version, !version.isEmpty else { continue }
            releases[bundle] = StoreRelease(bundleID: bundle, name: app.trackName ?? bundle, version: version,
                notes: app.releaseNotes, releasedAt: app.currentVersionReleaseDate, minimumOS: app.minimumOsVersion,
                iconURL: app.artworkUrl512 ?? app.artworkUrl100, storeURL: app.trackViewUrl, country: country,
                storeID: app.trackId.map { String($0) }, source: "iTunes Lookup")
        }
        return releases
    }

    public static func decodeCatalog(_ data: Data, expected: [String: String], country: String) throws -> [String: StoreRelease] {
        let envelope = try JSONDecoder().decode(CatalogEnvelope.self, from: data)
        var releases: [String: StoreRelease] = [:]
        for (bundle, id) in expected {
            guard let item = envelope.results[id], item.bundleId == bundle,
                  let offer = item.offers?.first, let display = offer.version?.display, !display.isEmpty else { continue }
            var external = offer.version?.externalId?.value
            if external == nil, let params = offer.buyParams {
                external = URLComponents(string: "https://apple.invalid/?" + params)?.queryItems?.first { $0.name == "appExtVrsId" }?.value
            }
            guard let external, validID(external) else { continue }
            let icon = (item.artwork?.url ?? item.iconArtwork?.url)?
                .replacingOccurrences(of: "{w}", with: "128").replacingOccurrences(of: "{h}", with: "128")
                .replacingOccurrences(of: "{f}", with: "png").replacingOccurrences(of: "{c}", with: "bb")
            releases[bundle] = StoreRelease(bundleID: bundle, name: item.name ?? bundle, version: display,
                notes: item.whatsNew, releasedAt: item.latestVersionReleaseDate, minimumOS: item.minimumOSVersion,
                iconURL: icon.flatMap { URL(string: $0) }, storeURL: item.url, country: country,
                storeID: id, externalVersionID: external, source: "Apple Catalog")
        }
        return releases
    }

    private static func validID(_ id: String) -> Bool {
        !id.isEmpty && id != "0" && id.utf8.allSatisfy { (48...57).contains($0) }
    }

    private struct Envelope: Decodable { var results: [Result] }
    private struct Result: Decodable {
        var bundleId: String?
        var trackId: Int64?
        var trackName: String?
        var version: String?
        var releaseNotes: String?
        var currentVersionReleaseDate: String?
        var minimumOsVersion: String?
        var artworkUrl100: URL?
        var artworkUrl512: URL?
        var trackViewUrl: URL?
    }
    private struct CatalogEnvelope: Decodable { var results: [String: CatalogItem] }
    private struct CatalogItem: Decodable {
        var bundleId: String?
        var name: String?
        var offers: [Offer]?
        var artwork: Artwork?
        var iconArtwork: Artwork?
        var whatsNew: String?
        var latestVersionReleaseDate: String?
        var minimumOSVersion: String?
        var url: URL?
    }
    private struct Artwork: Decodable { var url: String? }
    private struct Offer: Decodable {
        var version: CatalogVersion?
        var buyParams: String?
    }
    private struct CatalogVersion: Decodable {
        var display: String?
        var externalId: Identifier?
    }
    private struct Identifier: Decodable {
        var value: String
        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let string = try? container.decode(String.self) { value = string }
            else { value = String(try container.decode(Int64.self)) }
        }
    }
}

private actor LookupRateLimit {
    private var next = Date.distantPast
    func wait() async throws {
        let scheduled = max(Date(), next)
        next = scheduled.addingTimeInterval(3.2)
        let delay = scheduled.timeIntervalSinceNow
        if delay > 0 { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
        try Task.checkCancellation()
    }
}
