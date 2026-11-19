import Foundation

enum StoreAuthenticationRetry {
    static func isTemporary(_ error: Error) -> Bool {
        switch StoreDiagnostics.authenticationHTTPStatus(error) {
        case 204, 503: true
        default: false
        }
    }

    static func run<Value>(
        wait: (Int64) async throws -> Void = { try await Task.sleep(for: .seconds($0)) },
        operation: () async throws -> Value
    ) async throws -> Value {
        for delay in [10, 20] as [Int64] {
            try Task.checkCancellation()
            do {
                return try await operation()
            } catch where isTemporary(error) {
                try await wait(delay)
            }
        }
        try Task.checkCancellation()
        return try await operation()
    }
}
