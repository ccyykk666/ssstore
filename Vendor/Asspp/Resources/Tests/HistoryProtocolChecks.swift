import Foundation

enum HistoryProtocolChecks {
    static func run() async throws {
        for code in ["2034", 2042] as [Any] {
            precondition(StoreHistoryProtocol.isExpiredSession(["failureType": code]))
        }
        precondition(StoreHistoryProtocol.isExpiredSession(["metrics": ["messageCode": 2042]]))
        precondition(!StoreHistoryProtocol.isExpiredSession(["failureType": "9610"]))
        precondition(StoreHistoryProtocol.canAcquireLicense(price: 0))
        for price in [nil, -1, 0.99, 6] as [Double?] {
            precondition(!StoreHistoryProtocol.canAcquireLicense(price: price))
        }
        // The purchase endpoint's 5002 means already licensed, not a failed purchase.
        for code in ["5002", 5002] as [Any] {
            try StoreHistoryProtocol.checkPurchaseResponse(["failureType": code], status: 200)
        }
        try StoreHistoryProtocol.checkPurchaseResponse(["jingleDocType": "purchaseSuccess", "status": 0], status: 200)
        for response in [[:], ["status": 0], ["jingleDocType": "purchaseSuccess", "status": -1],
            ["failureType": "9610"], ["action": ["url": "https://example.invalid/termsPage"]]] as [[String: Any]] {
            do {
                try StoreHistoryProtocol.checkPurchaseResponse(response, status: 200)
                fatalError("Accepted an incomplete or rejected purchase")
            } catch {}
        }
        do {
            try StoreHistoryProtocol.checkPurchaseResponse([:], status: 500)
            fatalError("Treated an unknown HTTP 500 as an owned license")
        } catch StoreDownloadError.response(500) {}

        // Refresh at most once; missing licenses and arbitrary failures never rotate credentials.
        var requests = 0, refreshes = 0
        let result = try await StoreHistoryProtocol.withSessionRecovery {
            requests += 1
            if requests == 1 { throw StoreDownloadError.sessionExpired }
            return "history"
        } refresh: { refreshes += 1 }
        precondition(result == "history" && requests == 2 && refreshes == 1)
        requests = 0; refreshes = 0
        do {
            let _: String = try await StoreHistoryProtocol.withSessionRecovery {
                requests += 1
                throw StoreDownloadError.sessionExpired
            } refresh: { refreshes += 1 }
            fatalError("Session recovery did not stop after one retry")
        } catch StoreDownloadError.sessionExpired {}
        precondition(requests == 2 && refreshes == 1)
        requests = 0; refreshes = 0
        do {
            let _: String = try await StoreHistoryProtocol.withSessionRecovery {
                requests += 1
                throw StoreDownloadError.rejected("9610", "License required")
            } refresh: { refreshes += 1 }
            fatalError("License error became success")
        } catch StoreDownloadError.rejected("9610", _) {}
        precondition(requests == 1 && refreshes == 0)

        let identifiers = try StoreHistoryProtocol.identifiers(["metadata": [
            "softwareVersionExternalIdentifiers": ["10", 20, "10", "", "bad", "0", "000", "30"] as [Any],
        ]])
        precondition(identifiers == ["10", "20", "30"])
        for item in [[:], ["metadata": [:]], ["metadata": ["softwareVersionExternalIdentifiers": ["bad", 0]]]] as [[String: Any]] {
            do {
                _ = try StoreHistoryProtocol.identifiers(item)
                fatalError("Accepted an empty version history")
            } catch StoreDownloadError.noVersions {}
        }
        let purchase = "https://buy.itunes.apple.com/WebObjects/MZFinance.woa/wa/buyProduct"
        _ = try StoreHistoryProtocol.validatedPurchaseURL(URL(string: purchase)!)
        _ = try StoreHistoryProtocol.validatedPurchaseURL(URL(string: purchase.replacingOccurrences(of: "buy.", with: "p71-buy."))!)
        for url in [purchase.replacingOccurrences(of: "https:", with: "http:"),
                    purchase.replacingOccurrences(of: "buy.itunes.apple.com", with: "attacker.invalid"),
                    purchase.replacingOccurrences(of: "buy.itunes.apple.com", with: "buy.itunes.apple.com.attacker.invalid"),
                    purchase.replacingOccurrences(of: "buy.itunes.apple.com", with: "user:password@buy.itunes.apple.com"),
                    purchase + "#fragment", purchase.replacingOccurrences(of: "buyProduct", with: "other")] {
            do {
                _ = try StoreHistoryProtocol.validatedPurchaseURL(URL(string: url)!)
                fatalError("Leaked a license request to an untrusted redirect")
            } catch StoreDownloadError.invalidRedirect {}
        }
        print("History license and session recovery checks passed.")
    }
}
