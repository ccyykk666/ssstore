import ApplePackage
import Foundation
import Logging

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
        LoggingSystem.bootstrap { LogManagerHandler(label: $0) }
        APLogger.verbose = false
        ApplePackage.Configuration.userAgent = StoreProtocol.userAgent
        APLogger.logger = Logger(label: "dev.personal.ssstore.applepackage")
        _ = documentsDirectory
        _ = temporaryDirectory
        _ = AppStore.this
        if #available(iOS 26.0, *) { DownloadBackgroundExecution.shared.register() }
        Task {
            do { _ = try await Installer.prepareCertificateServer() }
            catch { logger.error("Unable to start local installation service: \(error.localizedDescription)") }
        }
    }
}
