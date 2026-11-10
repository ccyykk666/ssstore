import Foundation
import UpdateCore

extension Installer {
    func checkCompatibleManifest() async throws {
        guard isCompatible, let remoteManifestEndpoint, let packageMetadata else {
            throw InstallationManifest.ManifestError.invalidEndpoint
        }
        try await InstallerManifestService.verify(url: remoteManifestEndpoint, metadata: packageMetadata,
            payload: payloadEndpoint, logID: id.uuidString)
    }
}
