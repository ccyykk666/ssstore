import Foundation
import Kingfisher
import UpdateCore

@MainActor
enum AppCacheCleaner {
    static func clear(downloadIDs: Set<UUID>, startedAt: Date) async throws {
        ImageCache.default.clearMemoryCache()
        let imageBytes = try? await ImageCache.default.diskStorageSize
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            ImageCache.default.clearDiskCache { continuation.resume() }
        }
        try await Task.detached(priority: .utility) {
            let responseBytes = URLCache.shared.currentDiskUsage
            URLCache.shared.removeAllCachedResponses()
            let cache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            try StoreHistoryCacheStorage.clear()
            let icons = try CacheCleanup.removeUnusedFiles(in: cache.appendingPathComponent("ssstore-icons"), keeping: [],
                                                           olderThan: startedAt, createdBefore: startedAt)
            let reports = try CacheCleanup.removeUnusedFiles(in: cache.appendingPathComponent("ssstore-inspection"), keeping: [],
                                                             olderThan: startedAt, createdBefore: startedAt)
            let temporary = try CacheCleanup.removeUnusedFiles(in: temporaryDirectory, keeping: [],
                                                               olderThan: startedAt, createdBefore: startedAt)
            var orphanedDownloads: Int64 = 0
            for directory in [cache.appendingPathComponent("ssstore-transfers"), documentsDirectory.appendingPathComponent("Packages")] {
                orphanedDownloads += try CacheCleanup.removeUnusedFiles(in: directory, keeping: [], olderThan: startedAt,
                                                                       downloadIdentifiers: downloadIDs, createdBefore: startedAt)
            }
            logger.info("Cache cleanup: localIconBytes=\(icons) inspectionBytes=\(reports) temporaryBytes=\(temporary) orphanedDownloadBytes=\(orphanedDownloads) imageCacheBytesBefore=\(imageBytes.map { String($0) } ?? "unknown") responseCacheBytesBefore=\(responseBytes)")
        }.value
    }
}
