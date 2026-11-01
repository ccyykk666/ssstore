import Foundation

public enum PairingRecordKind: Equatable, Sendable {
    case remote, lockdown
}

public enum PairingRecord {
    /// Validate before replacing an existing device trust record. Preserve all
    /// extra fields, including alt_irk used by newer remote-pairing records.
    public static func kind(of data: Data) throws -> PairingRecordKind {
        guard let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else {
            throw PairingRecordError.invalid
        }
        if let secret = plist["private_key"] as? Data, secret.count == 32,
           let publicKey = plist["public_key"] as? Data, publicKey.count == 32,
           let identifier = plist["identifier"] as? String,
           !identifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .remote
        }
        if let hostID = plist["HostID"] as? String, !hostID.isEmpty,
           let key = plist["HostPrivateKey"] as? Data, !key.isEmpty {
            return .lockdown
        }
        throw PairingRecordError.invalid
    }
}

public enum PairingRecordError: LocalizedError {
    case invalid
    public var errorDescription: String? {
        "配对记录格式无效，原有文件已保留。请创建新的 Remote Pairing 记录或导入有效文件。"
    }
}
