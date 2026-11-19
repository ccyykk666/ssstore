import Foundation

enum AuthenticationRoute {
    static func normalized(_ value: String, relativeTo base: URL? = nil) -> URL? {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, let resolved = URL(string: value, relativeTo: base)?.absoluteURL,
              var components = URLComponents(url: resolved, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "https", let host = components.host?.lowercased(),
              components.user == nil, components.password == nil, components.fragment == nil,
              components.port == nil || components.port == 443 else { return nil }

        let path = components.percentEncodedPath
        let legacy = "/WebObjects/MZFinance.woa/wa/authenticate"
        let native = "/auth/v1/native"
        if host == "buy.itunes.apple.com" || host.range(of: #"^p[0-9]+-buy[.]itunes[.]apple[.]com$"#, options: .regularExpression) != nil {
            guard path.hasPrefix(legacy), path.dropFirst(legacy.count).allSatisfy({ $0 == "/" }) else { return nil }
            components.percentEncodedPath = legacy + "/"
        } else if host == "auth.itunes.apple.com" {
            guard [native, native + "/", native + "/fast", native + "/fast/"].contains(path) else { return nil }
            components.percentEncodedPath = native + "/fast/"
        } else {
            return nil
        }
        return components.url
    }
}
