import Foundation

enum StoreDiagnostics {
    /// NSError userInfo and localized descriptions may contain account names,
    /// signed URLs or Apple response messages. Keep those out of retained logs.
    static func errorSummary(_ error: Error) -> String {
        "type=\(String(describing: type(of: error))) code=\((error as NSError).code)"
    }

    static func isInvalidVerificationCode(_ error: Error) -> Bool {
        error.localizedDescription.contains("(failureType: 5005)")
    }

    static func authenticationErrorSummary(_ error: Error) -> String {
        let summary = errorSummary(error)
        if isInvalidVerificationCode(error) { return summary + " reason=invalid-verification-code" }
        let prefix = "authentication failed: HTTP "
        let message = error.localizedDescription
        if message.hasPrefix(prefix), let status = Int(message.dropFirst(prefix.count)), (100...599).contains(status) {
            return summary + " HTTP=\(status)"
        }
        return summary
    }
}

