import Foundation

public struct AppStoreLink: Equatable, Sendable {
    public let appID: Int64
    public let country: String?

    public init?(url: URL) {
        let parts = url.pathComponents.filter { $0 != "/" }
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let id: String?
        let region: String?
        if url.scheme?.lowercased() == "ssstore", url.host?.lowercased() == "app" {
            id = components?.queryItems?.first(where: { $0.name == "id" })?.value
            region = components?.queryItems?.first(where: { $0.name == "country" })?.value
        } else {
            guard ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
                  ["apps.apple.com", "itunes.apple.com"].contains(url.host?.lowercased() ?? ""),
                  parts.contains("app"), let last = parts.last, last.hasPrefix("id") else { return nil }
            id = String(last.dropFirst(2))
            region = parts.first == "app" ? nil : parts.first
        }
        guard let id, !id.isEmpty, id.utf8.allSatisfy({ (48...57).contains($0) }),
              let number = Int64(id), number > 0 else { return nil }
        if let region {
            guard region.utf8.count == 2, region.lowercased().utf8.allSatisfy({ (97...122).contains($0) }) else { return nil }
        }
        appID = number; country = region?.uppercased()
    }

    public static func parse(_ text: String) -> AppStoreLink? {
        if let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)), let link = Self(url: url) { return link }
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        return detector?.matches(in: text, range: NSRange(text.startIndex..., in: text))
            .compactMap { $0.url.flatMap(Self.init(url:)) }.first
    }

    public var deepLink: URL {
        var components = URLComponents()
        components.scheme = "ssstore"; components.host = "app"
        components.queryItems = [URLQueryItem(name: "id", value: String(appID))]
        if let country { components.queryItems?.append(URLQueryItem(name: "country", value: country)) }
        return components.url!
    }

    public var storeURL: URL {
        URL(string: "https://apps.apple.com/\(country.map { $0.lowercased() + "/" } ?? "")app/id\(appID)")!
    }

    public func lookupURL(country: String) -> URL {
        var components = URLComponents(string: "https://itunes.apple.com/lookup")!
        components.queryItems = [URLQueryItem(name: "id", value: String(appID)),
            URLQueryItem(name: "country", value: country), URLQueryItem(name: "media", value: "software"),
            URLQueryItem(name: "entity", value: "software,iPadSoftware"), URLQueryItem(name: "limit", value: "1")]
        return components.url!
    }
}
