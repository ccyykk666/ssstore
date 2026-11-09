import Foundation

public enum LocalInstallURL {
    /// Encode the entire nested URL, including its scheme, port and query delimiters.
    public static func installationLink(manifestURL: URL) -> URL {
        let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        let encoded = manifestURL.absoluteString.addingPercentEncoding(withAllowedCharacters: unreserved)!
        var components = URLComponents()
        components.scheme = "itms-services"
        components.host = ""
        components.percentEncodedQuery = "action=download-manifest&url=" + encoded
        return components.url!
    }
}
