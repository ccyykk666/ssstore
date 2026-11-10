import Foundation
import UpdateCore
import ZIPFoundation

extension Installer {
    static func readMetadata(at url: URL, bundleID: String, fallbackName: String) throws -> InstallationManifest.Metadata {
        let archive = try Archive(url: url, accessMode: .read)
        let entries = archive.filter { entry in
            let path = entry.path.split(separator: "/", omittingEmptySubsequences: false)
            return path.count == 3 && path[0] == "Payload" && path[1].hasSuffix(".app") && path[2] == "Info.plist"
        }
        guard entries.count == 1, let entry = entries.first, entry.uncompressedSize <= 2 * 1024 * 1024 else {
            throw InstallationManifest.ManifestError.invalidPackage
        }
        var data = Data()
        _ = try archive.extract(entry) { chunk in
            guard data.count + chunk.count <= 2 * 1024 * 1024 else { throw InstallationManifest.ManifestError.invalidPackage }
            data.append(chunk)
        }
        guard let info = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw InstallationManifest.ManifestError.invalidPackage
        }
        return try .init(info: info, expectedBundleID: bundleID, fallbackName: fallbackName)
    }
}
