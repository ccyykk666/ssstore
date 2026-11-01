import Foundation

public enum PairingBackgroundIdentifier {
    public static func make(bundleID: String?, permitted: [String], runID: String = UUID().uuidString) throws -> String {
        guard let bundleID, !bundleID.isEmpty,
              permitted.contains(bundleID + ".pairing.*") else {
            throw PairingBackgroundConfigurationError.signatureMismatch
        }
        return bundleID + ".pairing." + runID
    }
}

public enum PairingBackgroundConfigurationError: LocalizedError {
    case signatureMismatch
    public var errorDescription: String? {
        "后台任务标识不匹配。签名时请保留原 Bundle ID，或同步修改后台任务标识。"
    }
}
