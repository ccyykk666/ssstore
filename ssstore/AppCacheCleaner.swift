import Foundation
import Kingfisher
import UpdateCore

@MainActor
enum AppCacheCleaner {
    static func clear(keeping protected: [URL], downloadIDs: Set<UUID>, startedAt: Date) async throws {
        ImageCache.default.clearMemoryCache()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            ImageCache.default.clearDiskCache { continuation.resume() }
        }
        try await Task.detached(priority: .utility) {
            URLCache.shared.removeAllCachedResponses()
            let cache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            try StoreHistoryCacheStorage.clear()
            for name in ["ssstore-icons", "ssstore-inspection"] {
                _ = try CacheCleanup.removeUnusedFiles(in: cache.appendingPathComponent(name), keeping: protected,
                                                       olderThan: startedAt, createdBefore: startedAt)
            }
            _ = try CacheCleanup.removeUnusedFiles(in: temporaryDirectory, keeping: protected,
                                                   olderThan: startedAt.addingTimeInterval(-86400))
            for directory in [cache.appendingPathComponent("ssstore-transfers"), documentsDirectory.appendingPathComponent("Packages")] {
                _ = try CacheCleanup.removeUnusedFiles(in: directory, keeping: [], olderThan: startedAt,
                                                       downloadIdentifiers: downloadIDs, createdBefore: startedAt)
            }
        }.value
    }
}
