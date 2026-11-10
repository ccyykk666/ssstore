import Foundation
import UpdateCore

extension Installer {
    func checkCompatibleManifest() async throws {
        guard isCompatible, let manifestServiceEndpoint, let packageMetadata else {
            throw InstallationManifest.ManifestError.invalidEndpoint
        }
        let url = try await InstallerManifestService.prepare(endpoint: manifestServiceEndpoint, metadata: packageMetadata,
            payload: payloadEndpoint, logID: id.uuidString)
        setPreparedManifestEndpoint(url)
    }
}
