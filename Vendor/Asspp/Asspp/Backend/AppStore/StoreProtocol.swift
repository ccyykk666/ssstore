import Foundation

/// Serialization and cookie conventions shared by store authentication and product requests.
enum StoreProtocol {
    struct SessionCookie {
        var name: String
        var value: String
        var path: String
        var domain: String?
        var expiresAt: TimeInterval?
        var secure: Bool
    }

    /// Work around ApplePackage 2.0.3 matching '.itunes.apple.com' literally.
    /// RFC 6265 ignores the leading domain dot. Keep expiry and path boundaries.
    static func cookieHeader(_ cookies: [SessionCookie], for url: URL, now: Date = Date()) -> String? {
        guard url.scheme == "https", let host = url.host?.lowercased(),
              host == "itunes.apple.com" || host.hasSuffix(".itunes.apple.com")
        else { return nil }
        let requestPath = url.path.isEmpty ? "/" : url.path
        let eligible = cookies.filter { cookie in
            guard !cookie.name.isEmpty, !cookie.value.isEmpty,
                  !cookie.name.contains(where: { $0.isWhitespace || $0 == ";" || $0 == "=" || $0.asciiValue.map({ $0 < 32 || $0 == 127 }) == true }),
                  !cookie.value.contains(where: { $0 == ";" || $0.asciiValue.map({ $0 < 32 || $0 == 127 }) == true })
            else { return false }
            if let domain = storeCookieDomain(cookie.domain) {
                guard domain == "apple.com" || domain.hasSuffix(".apple.com"),
                      host == domain || host.hasSuffix("." + domain) else { return false }
            }
            if let expiry = cookie.expiresAt, expiry <= now.timeIntervalSince1970 { return false }
            let path = cookie.path.isEmpty ? "/" : cookie.path
            return requestPath == path || (requestPath.hasPrefix(path) &&
                (path.hasSuffix("/") || requestPath.dropFirst(path.count).first == "/"))
        }
        // RFC ordering: most specific paths first; preserve original order for equal paths.
        let ordered = eligible.enumerated().sorted {
            $0.element.path.count == $1.element.path.count ? $0.offset < $1.offset : $0.element.path.count > $1.element.path.count
        }.map { "\($0.element.name)=\($0.element.value)" }
        return ordered.isEmpty ? nil : ordered.joined(separator: "; ")
    }

    static func plist(_ data: Data) -> [String: Any]? {
        var payload = data
        // bag.xml wraps a plist in Document/Protocol; login replies are ordinary plists.
        if let xml = String(data: data, encoding: .utf8),
           let start = xml.range(of: "<plist"), let end = xml.range(of: "</plist>"),
           start.lowerBound < end.upperBound
        {
            payload = Data(xml[start.lowerBound ..< end.upperBound].utf8)
        }
        return (try? PropertyListSerialization.propertyList(from: payload, format: nil)) as? [String: Any]
    }

    static func storeCookieDomain(_ domain: String?) -> String? {
        domain.map { String($0.drop(while: { $0 == "." })).lowercased() }
    }

    static func foundationCookieDomain(_ domain: String?) -> String? {
        guard let domain = storeCookieDomain(domain),
              domain == "itunes.apple.com" || domain.hasSuffix(".itunes.apple.com")
        else { return nil }
        return "." + domain
    }

    static func string(_ value: Any?) -> String {
        if let string = value as? String {
            return string
        }
        if let number = value as? NSNumber {
            return number.stringValue
        }
        return ""
    }
}


