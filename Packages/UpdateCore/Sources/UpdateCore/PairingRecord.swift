import Foundation

public enum PairingRecordKind: Equatable, Sendable {
    case remote
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
            throw PairingRecordError.unsupported
        }
        throw PairingRecordError.invalid
    }
}

public enum PairingRecordError: LocalizedError, Equatable {
    case invalid, unsupported
    public var errorDescription: String? {
        switch self {
        case .invalid: return "配对文件无效，原文件已保留。请重新配对或导入。"
        case .unsupported: return "仅支持 Remote Pairing，请创建或导入对应的配对文件。"
        }
    }
}

