import Foundation
import Kingfisher
import UpdateCore

@MainActor
enum AppCacheCleaner {
    static func clear(keeping protected: [URL], downloadIDs: Set<UUID>) async throws {
        ImageCache.default.clearMemoryCache()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            ImageCache.default.clearDiskCache { continuation.resume() }
        }
        try await Task.detached(priority: .utility) {
            URLCache.shared.removeAllCachedResponses()
            let cache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            let cutoff = Date().addingTimeInterval(-86400)
            for name in ["ssstore-icons", "ssstore-inspection"] {
                _ = try CacheCleanup.removeUnusedFiles(in: cache.appendingPathComponent(name), keeping: protected, olderThan: cutoff)
            }
            _ = try CacheCleanup.removeUnusedFiles(in: temporaryDirectory, keeping: protected, olderThan: cutoff)
            _ = try CacheCleanup.removeUnusedFiles(in: cache.appendingPathComponent("ssstore-transfers"),
                                                  keeping: [], olderThan: cutoff, downloadIdentifiers: downloadIDs)
        }.value
    }
}
