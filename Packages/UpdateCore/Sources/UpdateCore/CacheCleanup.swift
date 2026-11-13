import Foundation

public enum CacheCleanup {
    /// Only call for an App-owned cache subdirectory. Never follows symlinks,
    /// removes directories, or touches recent / still-referenced files.
    public static func removeUnusedFiles(in root: URL, keeping protected: [URL],
                                         olderThan cutoff: Date,
                                         downloadIdentifiers: Set<UUID>? = nil) throws -> Int64 {
        let manager = FileManager.default
        guard manager.fileExists(atPath: root.path) else { return 0 }
        let keys: Set<URLResourceKey> = [.isSymbolicLinkKey, .isDirectoryKey, .isRegularFileKey,
                                       .contentModificationDateKey, .fileSizeKey]
        let rootValues = try root.resourceValues(forKeys: keys)
        guard rootValues.isSymbolicLink != true, rootValues.isDirectory == true else { return 0 }
        let protectedPaths = protected.map { $0.standardizedFileURL.path }
        guard let entries = manager.enumerator(at: root, includingPropertiesForKeys: Array(keys)) else { return 0 }
        var removed: Int64 = 0
        for case let file as URL in entries {
            let values = try file.resourceValues(forKeys: keys)
            if values.isSymbolicLink == true { entries.skipDescendants(); continue }
            let path = file.standardizedFileURL.path
            if protectedPaths.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) {
                if values.isDirectory == true { entries.skipDescendants() }
                continue
            }
            guard values.isRegularFile == true, let date = values.contentModificationDate, date < cutoff else { continue }
            if let downloadIdentifiers {
                let parts = file.lastPathComponent.split(separator: ".")
                guard parts.count == 2, let id = UUID(uuidString: String(parts[0])),
                      ["resume", "download", "partial", "ranges"].contains(String(parts[1])),
                      !downloadIdentifiers.contains(id) else { continue }
            }
            do {
                try manager.removeItem(at: file)
                removed += Int64(values.fileSize ?? 0)
            } catch {
                let failure = error as NSError
                if failure.domain == NSCocoaErrorDomain, failure.code == NSFileNoSuchFileError { continue }
                throw error
            }
        }
        return removed
    }
}
