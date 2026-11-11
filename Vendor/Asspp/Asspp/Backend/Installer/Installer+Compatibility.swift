import Foundation
import UpdateCore

extension Installer {
    func checkCompatibleManifest() async throws {
        let url = try await InstallerManifestService.prepare(endpoint: manifestServiceEndpoint, metadata: packageMetadata,
            payload: payloadEndpoint, logID: id.uuidString)
        setPreparedManifestEndpoint(url)
    }
}
