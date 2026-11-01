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
        "后台配对配置与当前应用标识不匹配。请在自签时保留原 Bundle ID，或让签名工具同步更新后台任务标识后重新安装。"
    }
}
