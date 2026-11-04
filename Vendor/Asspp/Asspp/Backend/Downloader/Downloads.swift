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
        runningTaskCount = manifests.count(where: { [.downloading, .processing].contains($0.state.status) })
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

    func downloadRequest(forArchive archive: AppStore.AppPackage) -> PackageManifest? {
        manifests.first { $0.package.id == archive.id && $0.package.externalVersionID == archive.externalVersionID }
    }

    func add(request: PackageManifest) -> PackageManifest {
        logger.info("adding download request \(request.id) - \(request.package.software.name)")
        manifests.removeAll { $0.id == request.id }
        manifests.append(request)
        return request
    }

    func suspend(request: PackageManifest) {
        transfer.pause(id: request.id)
        request.state.resetIfNotCompleted()
        request.state.speed = ""
        refreshRunningTaskCount()
        saveManifests()
    }

    func resume(request: PackageManifest) {
        request.state.start()
        transfer.resume(id: request.id, url: request.url) { [weak self] fraction, speed in
            guard let self, [.pending, .downloading].contains(request.state.status) else { return }
            let wasDownloading = request.state.status == .downloading
            var state = request.state
            state.status = .downloading; state.percent = fraction
            state.speed = Self.speedFormatter.string(fromByteCount: speed) + "/s"
            request.state = state
            if !wasDownloading { self.refreshRunningTaskCount() }
        } completion: { [weak self] result in
            guard let self else { return }
            guard self.manifests.contains(where: { $0.id == request.id }) else {
                if case let .success(file) = result { try? FileManager.default.removeItem(at: file) }
                return
            }
            switch result {
            case let .success(file):
                request.state.status = .processing; request.state.percent = 1; request.state.speed = ""
                self.refreshRunningTaskCount()
                let package = request.package
                let target = request.targetLocation
                let signatures = request.signatures
                let metadata = request.iTunesMetadata
                // ZIP validation and signature injection must not run on MainActor.
                Task {
                    do {
                        try await Task.detached(priority: .utility) {
                            try await Self.finalize(package: package, target: target, signatures: signatures, metadata: metadata, downloadedFile: file)
                        }.value
                        guard self.manifests.contains(where: { $0.id == request.id }) else {
                            request.delete(); return
                        }
                        request.state.complete()
                    } catch { request.state.error = error.localizedDescription }
                    self.refreshRunningTaskCount(); self.saveManifests()
                }
            case let .failure(error):
                request.state.error = error.localizedDescription
                self.refreshRunningTaskCount(); self.saveManifests()
            }
        }
        saveManifests()
    }

    private nonisolated static func finalize(package: AppStore.AppPackage, target: URL, signatures: [Sinf], metadata: Data, downloadedFile: URL) async throws {
        defer { try? FileManager.default.removeItem(at: downloadedFile) }
        // Verify the main bundle identity and platform before signature injection.
        try StorePackageValidator.validate(at: downloadedFile, package: package)
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

        logger.info("moving finalized file: \(package.software.bundleID)")
        try FileManager.default.moveItem(at: tempFile, to: target)
    }

    func delete(request: PackageManifest) {
        logger.info("deleting download request id: \(request.id)")
        transfer.cancel(id: request.id)
        request.delete()
        manifests.removeAll(where: { $0.id == request.id })
        refreshRunningTaskCount()
    }

    func restart(request: PackageManifest) {
        logger.info("restarting download request id: \(request.id)")
        transfer.cancel(id: request.id)
        request.delete()
        request.state = .init()
        resume(request: request)
    }

    func removeAll() {
        manifests.forEach { transfer.cancel(id: $0.id); $0.delete() }
        manifests.removeAll()
        refreshRunningTaskCount()
    }
}

