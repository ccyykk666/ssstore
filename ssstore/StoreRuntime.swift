import ApplePackage
import Foundation
import Logging
import Kingfisher

let logger = Logger(label: "dev.personal.ssstore.store")
let documentsDirectory: URL = {
    let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Asspp", isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}()
let temporaryDirectory: URL = {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("ssstore-store", isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}()

@MainActor
enum StoreRuntime {
    private static var prepared = false

    static func prepare() {
        guard !prepared else { return }
        prepared = true
        var images = ImageCache.default.memoryStorage.config
        images.totalCostLimit = 24 * 1024 * 1024
        images.countLimit = 256
        images.expiration = .seconds(180)
        images.keepWhenEnteringBackground = false
        ImageCache.default.memoryStorage.config = images
        URLCache.shared.memoryCapacity = min(URLCache.shared.memoryCapacity, 4 * 1024 * 1024)
        LoggingSystem.bootstrap { LogManagerHandler(label: $0) }
        APLogger.verbose = false
        APLogger.logger = Logger(label: "dev.personal.ssstore.applepackage")
        _ = documentsDirectory
        _ = temporaryDirectory
        _ = AppStore.this
        if #available(iOS 26.0, *) { DownloadBackgroundExecution.shared.register() }
    }
    static func releaseTransientMemory() { ImageCache.default.clearMemoryCache() }
}
