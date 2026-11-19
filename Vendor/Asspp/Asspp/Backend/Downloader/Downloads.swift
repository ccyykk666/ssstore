//
//  Downloads.swift
//  Asspp
//
//  Created by 秋星桥 on 2024/7/11.
//

import ApplePackage
import Foundation
import Logging

@Observable
@MainActor
class Downloads {
    static let this = Downloads()

    @ObservationIgnored
    private var _manifests = Persist<[PackageManifest]>(key: "DownloadRequests", defaultValue: [])

    @ObservationIgnored
    private let transfer = PackageTransfer(directory: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("ssstore-transfers", isDirectory: true))

    @ObservationIgnored
    var preparingDownloads: [String: Task<PackageManifest, Error>] = [:]

    @ObservationIgnored
    private var processingTasks: [UUID: Task<Void, Never>] = [:]

    var backgroundNotice: String?

    private static let speedFormatter: ByteCountFormatter = {
        let fmt = ByteCountFormatter()
        fmt.allowedUnits = .useAll
        fmt.countStyle = .file
        return fmt
    }()

    var manifests: [PackageManifest] {
        get {
            access(keyPath: \.manifests)
            return _manifests.wrappedValue
        }
        set {
            withMutation(keyPath: \.manifests) {
                _manifests.wrappedValue = newValue
            }
        }
    }

    /// Stored, not computed: a computed property would read each manifest's
    /// `state`, so every download progress tick would invalidate the badge,
    /// sidebar, and AppDelegate observers and re-render the whole TabView.
    /// Refresh it only when a status actually transitions.
    private(set) var runningTaskCount: Int = 0

    private func refreshRunningTaskCount() {
        runningTaskCount = manifests.count(where: { [.pending, .downloading, .processing].contains($0.state.status) })
    }

    private init() {
        for idx in manifests.indices {
            manifests[idx].state.resetIfNotCompleted()
        }
        refreshRunningTaskCount()
    }

    func saveManifests() {
        _manifests.save()
    }

    func downloadRequest(forArchive archive: AppStore.AppPackage, accountID: String) -> PackageManifest? {
        manifests.lazy.filter { request in
            let saved = request.package
            guard request.account.id == accountID,
                  saved.id == archive.id,
                  saved.externalVersionID == archive.externalVersionID,
                  (saved.entityType ?? .iPhone) == (archive.entityType ?? .iPhone),
                  StoreDownloadProtocol.matchesRequestedRelease(saved.software.version, expected: archive.software.version,
                                                               allowsNewer: archive.externalVersionID == nil)
            else { return false }
            // Older manifests used the UI version as their label, even when the
            // server's metadata identified a different release.
            if let metadata = try? PropertyListSerialization.propertyList(from: request.iTunesMetadata, format: nil) as? [String: Any],
               let actual = metadata["bundleShortVersionString"] as? String, actual != saved.software.version {
                return false
            }
            return !request.completed || FileManager.default.fileExists(atPath: request.targetLocation.path)
        }.max { left, right in
            let order = left.package.software.version.compare(right.package.software.version, options: .numeric)
            return order == .orderedSame ? left.creation < right.creation : order == .orderedAscending
        }
    }

    func add(request: PackageManifest) -> PackageManifest {
        logger.info("adding download request \(request.id) - \(request.package.software.name)")
        manifests.removeAll { $0.id == request.id }
        manifests.append(request)
        return request
    }

    func suspend(request: PackageManifest) {
        logger.info("Download [\(request.id)] paused")
        transfer.pause(id: request.id)
        if let processing = processingTasks[request.id] {
            processing.cancel()
            request.state.percent = 0
        }
        request.state.resetIfNotCompleted()
        request.state.speed = ""
        if #available(iOS 26.0, *) { DownloadBackgroundExecution.shared.finish(request) }
        refreshRunningTaskCount()
        saveManifests()
    }

    func resume(request: PackageManifest) {
        request.state.start()
        if let processing = processingTasks[request.id] {
            refreshRunningTaskCount(); saveManifests()
            Task { [weak self] in
                await processing.value
                guard let self, request.state.status == .pending,
                      self.manifests.contains(where: { $0.id == request.id }) else { return }
                self.resume(request: request)
            }
            return
        }
        refreshRunningTaskCount()
        if #available(iOS 26.0, *) {
            DownloadBackgroundExecution.shared.begin(request) { [weak self] in self?.startTransfer(request: request) }
        } else { startTransfer(request: request) }
        saveManifests()
    }

    private func startTransfer(request: PackageManifest) {
        logger.info("Download [\(request.id)] transfer started scheme=\(request.url.scheme ?? "unknown")")
        transfer.resume(id: request.id, url: request.url) { [weak self] fraction, speed in
            guard let self, [.pending, .downloading].contains(request.state.status) else { return }
            let wasDownloading = request.state.status == .downloading
            var state = request.state
            state.status = .downloading; state.percent = fraction
            state.speed = Self.speedFormatter.string(fromByteCount: speed) + "/s"
            request.state = state
            if #available(iOS 26.0, *) { DownloadBackgroundExecution.shared.update(request) }
            if !wasDownloading { self.refreshRunningTaskCount() }
        } completion: { [weak self] result in
            guard let self else { return }
            guard self.manifests.contains(where: { $0.id == request.id }),
                  [.pending, .downloading].contains(request.state.status) else {
                if case let .success(file) = result { try? FileManager.default.removeItem(at: file) }
                return
            }
            switch result {
            case let .success(file):
                logger.info("Download [\(request.id)] transfer finished, validating package")
                request.state.status = .processing; request.state.percent = 1; request.state.speed = ""
                if #available(iOS 26.0, *) { DownloadBackgroundExecution.shared.update(request) }
                self.refreshRunningTaskCount()
                let package = request.package
                let target = request.targetLocation
                let signatures = request.signatures
                let metadata = request.iTunesMetadata
                // ZIP validation and signature injection must not run on MainActor.
                self.processingTasks[request.id] = Task {
                    let work = Task.detached(priority: .utility) {
                        try await Self.finalize(package: package, target: target, signatures: signatures, metadata: metadata, downloadedFile: file)
                    }
                    do {
                        try await withTaskCancellationHandler {
                            try await work.value
                            try Task.checkCancellation()
                        } onCancel: { work.cancel() }
                        guard self.manifests.contains(where: { $0.id == request.id }) else {
                            request.delete(); self.processingTasks.removeValue(forKey: request.id); return
                        }
                        request.state.complete()
                        logger.info("Download [\(request.id)] completed")
                    } catch {
                        if Task.isCancelled {
                            if request.state.status == .processing { request.state.resetIfNotCompleted() }
                            if !self.manifests.contains(where: { $0.id == request.id }) { request.delete() }
                        } else {
                            logger.error("Download [\(request.id)] failed stage=finalize \(StoreDiagnostics.errorSummary(error))")
                            request.state.error = error.localizedDescription
                        }
                    }
                    self.processingTasks.removeValue(forKey: request.id)
                    if #available(iOS 26.0, *) { DownloadBackgroundExecution.shared.finish(request) }
                    self.refreshRunningTaskCount(); self.saveManifests()
                }
            case let .failure(error):
                logger.error("Download [\(request.id)] failed stage=transfer \(StoreDiagnostics.errorSummary(error))")
                request.state.error = error.localizedDescription
                if #available(iOS 26.0, *) { DownloadBackgroundExecution.shared.finish(request) }
                self.refreshRunningTaskCount(); self.saveManifests()
            }
        }
    }

    private nonisolated static func finalize(package: AppStore.AppPackage, target: URL, signatures: [Sinf], metadata: Data, downloadedFile: URL) async throws {
        defer { try? FileManager.default.removeItem(at: downloadedFile) }
        try Task.checkCancellation()
        // Verify the main bundle identity and platform before signature injection.
        try StorePackageValidator.validate(at: downloadedFile, package: package)
        try Task.checkCancellation()
        try? FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(),
            withIntermediateDirectories: true,
        )
        try? FileManager.default.removeItem(at: target)

        let tempFile = target
            .deletingLastPathComponent()
            .appendingPathComponent(".\(target.lastPathComponent).unsigned")
        try? FileManager.default.removeItem(at: tempFile)

        logger.info("preparing signature: \(package.software.bundleID)")
        try FileManager.default.moveItem(at: downloadedFile, to: tempFile)
        defer { try? FileManager.default.removeItem(at: tempFile) }

        logger.info("injecting signatures: \(package.software.bundleID)")
        try await SignatureInjector.inject(
            sinfs: signatures,
            iTunesMetadata: metadata,
            into: tempFile.path,
        )

        try Task.checkCancellation()

        logger.info("moving finalized file: \(package.software.bundleID)")
        try FileManager.default.moveItem(at: tempFile, to: target)
    }

    func delete(request: PackageManifest) {
        logger.info("deleting download request id: \(request.id)")
        transfer.cancel(id: request.id)
        processingTasks[request.id]?.cancel()
        request.state.resetIfNotCompleted()
        if #available(iOS 26.0, *) { DownloadBackgroundExecution.shared.finish(request) }
        request.delete()
        manifests.removeAll(where: { $0.id == request.id })
        refreshRunningTaskCount()
    }

    func restart(request: PackageManifest) {
        logger.info("restarting download request id: \(request.id)")
        transfer.cancel(id: request.id)
        processingTasks[request.id]?.cancel()
        request.delete()
        request.state = .init()
        resume(request: request)
    }

    func removeAll() {
        for request in manifests { delete(request: request) }
    }
}

