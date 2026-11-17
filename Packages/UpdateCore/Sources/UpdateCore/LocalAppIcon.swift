import Foundation

public enum LocalAppIcon {
    /// A cache key is not evidence that a file still exists. Returning nil here
    /// permits the saved store image to be selected after cache eviction.
    public static func url(for app: InstalledApp, in directory: URL) -> URL? {
        guard let key = app.localIconKey, key.count == 64,
              key.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { return nil }
        let file = directory.appendingPathComponent(key).appendingPathExtension("png")
        return FileManager.default.isReadableFile(atPath: file.path) ? file : nil
    }
}
