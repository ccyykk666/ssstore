import Foundation

/// Account recovery and history response rules; no credentials or networking.
enum StoreHistoryProtocol {
    static func isExpiredSession(_ response: [String: Any]) -> Bool {
        ["2034", "2042"].contains(StoreDownloadProtocol.failureCode(response))
    }

    static func withSessionRecovery<T>(request: () async throws -> T,
                                       refresh: () async throws -> Void) async throws -> T {
        do { return try await request() }
        catch StoreDownloadError.sessionExpired {
            try Task.checkCancellation()
            try await refresh()
            try Task.checkCancellation()
            return try await request() // exactly one retry, never a recursion loop
        }
    }

    static func canAcquireLicense(price: Double?) -> Bool { price == 0 }

    static func checkPurchaseResponse(_ response: [String: Any], status: Int) throws {
        let code = StoreDownloadProtocol.failureCode(response)
        if code == "5002" { return } // ipatool: the account already owns this license
        if isExpiredSession(response) { throw StoreDownloadError.sessionExpired }
        guard status == 200 else { throw StoreDownloadError.response(status) }
        if !code.isEmpty {
            throw StoreDownloadError.rejected(code, StoreProtocol.string(response["customerMessage"]))
        }
        guard response["action"] == nil, response["dialog"] == nil else {
            throw StoreDownloadError.actionRequired
        }
        let message = StoreProtocol.string(response["customerMessage"])
        guard message.isEmpty else { throw StoreDownloadError.rejected("", message) }
        guard response["jingleDocType"] as? String == "purchaseSuccess",
              StoreProtocol.string(response["status"]) == "0"
        else { throw StoreDownloadError.invalidPackage }
    }

    static func validatedPurchaseURL(_ url: URL) throws -> URL {
        let host = url.host?.lowercased() ?? ""
        guard url.scheme == "https", url.user == nil, url.password == nil,
              url.fragment == nil, url.port == nil || url.port == 443,
              url.path == "/WebObjects/MZFinance.woa/wa/buyProduct",
              host == "buy.itunes.apple.com" || host.range(of: #"^p[0-9]+-buy\.itunes\.apple\.com$"#, options: .regularExpression) != nil
        else { throw StoreDownloadError.invalidRedirect }
        return url
    }

    static func identifiers(_ item: [String: Any]) throws -> [String] {
        guard let metadata = item["metadata"] as? [String: Any],
              let values = metadata["softwareVersionExternalIdentifiers"] as? [Any]
        else { throw StoreDownloadError.noVersions }
        var seen = Set<String>()
        let identifiers = values.map { StoreProtocol.string($0) }.filter { value in
            !value.isEmpty && value.allSatisfy { $0.isASCII && $0.isNumber }
                && value.contains { $0 != "0" } && seen.insert(value).inserted
        }
        guard !identifiers.isEmpty else { throw StoreDownloadError.noVersions }
        return identifiers
    }
}
