import Foundation

enum StoreAuthenticationRetry {
    static func run<Value>(
        verifyingCode: Bool = false,
        response: (Error) -> (status: Int, retryAfter: String?)?,
        now: () -> Date = Date.init,
        wait: (Int64) async throws -> Void = { try await Task.sleep(for: .milliseconds($0)) },
        operation: () async throws -> Value
    ) async throws -> Value {
        var remainingWait: Int64 = 10_000
        for fallback in (verifyingCode ? [2.0, 4.0, 4.0] : [2.0, 4.0]) {
            try Task.checkCancellation()
            do {
                return try await operation()
            } catch {
                guard let response = response(error),
                      [204, 301, 302, 303, 307, 308, 404, 500, 502, 503, 504].contains(response.status) else { throw error }
                let seconds = max(1, retryDelay(response.retryAfter, now: now()) ?? fallback)
                guard seconds <= Double(remainingWait) / 1000 else { throw error }
                let delay = Int64((seconds * 1000).rounded(.up))
                remainingWait -= delay
                try await wait(delay)
            }
        }
        try Task.checkCancellation()
        return try await operation()
    }

    private static func retryDelay(_ header: String?, now: Date) -> TimeInterval? {
        guard let value = header?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        if let seconds = Double(value), seconds.isFinite, seconds >= 0 { return seconds }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss z"
        return formatter.date(from: value).map { max(0, $0.timeIntervalSince(now)) }
    }
}
