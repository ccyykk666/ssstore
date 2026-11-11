//
//  Installer.swift
//  AppInstaller
//
//  Created by 秋星桥 on 2024/7/10.
//

import ApplePackage
import Foundation
import Logging
import UpdateCore
#if canImport(UIKit)
    import UIKit
#endif
import Vapor

@Observable
class Installer: Identifiable, @unchecked Sendable {
    static let host = "127.0.0.1"
    @ObservationIgnored let packageMetadata: InstallationManifest.Metadata
    @ObservationIgnored let manifestServiceEndpoint: URL
    @ObservationIgnored private let manifestLock = NSLock()
    @ObservationIgnored private var preparedManifestEndpoint: URL?
    var remoteManifestEndpoint: URL? {
        manifestLock.withLock { preparedManifestEndpoint }
    }
    func setPreparedManifestEndpoint(_ url: URL) {
        manifestLock.withLock { preparedManifestEndpoint = url }
    }
    @ObservationIgnored let id: UUID
    @ObservationIgnored let app: Application
    @ObservationIgnored let archive: AppStore.AppPackage
    @ObservationIgnored let payloadSize: Int64
    @ObservationIgnored let port = Int.random(in: 4000 ... 8000)
    @ObservationIgnored private let shutdownLock = NSLock()
    @ObservationIgnored private var shuttingDown = false

    enum Status {
        case ready
        case sendingPayload
        case completed(Result<Void, Error>)
        case broken(Error)
    }

    @MainActor
    var status: Status = .ready { didSet { onStatusChange?() } }

    @ObservationIgnored @MainActor var onStatusChange: (() -> Void)?
    @ObservationIgnored @MainActor private var coverage: InstallTransferCoverage?
    @MainActor var sentBytes: Int64 = 0
    @ObservationIgnored @MainActor private var transferGeneration = UUID()
    @ObservationIgnored @MainActor private var activePayloadResponses: Set<UUID> = []
    @MainActor var hasActivePayloadResponses: Bool { !activePayloadResponses.isEmpty }

    @MainActor func payloadGeneration() -> UUID { transferGeneration }

    @MainActor
    func beginPayloadResponse(_ responseID: UUID, generation: UUID) -> Bool {
        guard generation == transferGeneration else { return false }
        if case .broken = status { return false }
        activePayloadResponses.insert(responseID)
        if coverage?.isComplete != true { status = .sendingPayload }
        else { onStatusChange?() }
        return true
    }

    @MainActor
    func recordPayloadWrite(_ range: Range<Int64>, generation: UUID) {
        guard generation == transferGeneration else { return }
        if case .broken = status { return }
        var current = coverage ?? InstallTransferCoverage(totalBytes: payloadSize)
        guard current.recordWritten(range) else { return }
        coverage = current
        let changed = sentBytes != current.completedBytes
        sentBytes = current.completedBytes
        if current.isComplete {
            if case .completed = status { return }
            logger.info("Local install [\(id)]: all payload bytes written, delivered=\(sentBytes)/\(payloadSize)")
            status = .completed(.success(()))
        } else if changed { onStatusChange?() }
    }

    @MainActor
    func endPayloadResponse(_ responseID: UUID, generation: UUID) {
        guard generation == transferGeneration else { return }
        activePayloadResponses.remove(responseID)
        // Completion can precede an HTTP end/close callback. Release the short
        // flush grace only after the outstanding response bodies have drained.
        if case .completed = status { onStatusChange?() }
    }

    @MainActor
    func prepareForAttempt() {
        transferGeneration = UUID()
        activePayloadResponses = []
        coverage = nil
        sentBytes = 0
        status = .ready
    }

    @MainActor
    var diagnosticStatus: String {
        switch status {
        case .ready: "waiting-for-system-payload"
        case .sendingPayload: "payload-requested"
        case .completed(let result): (try? result.get()) != nil ? "payload-sent" : "payload-transfer-failed"
        case .broken: "failed"
        }
    }

    init(archive: AppStore.AppPackage, path packagePath: URL) async throws {
        let id: UUID = .init()
        self.id = id
        self.archive = archive
        manifestServiceEndpoint = try InstallerManifestService.endpoint()
        let bundleID = archive.software.bundleID
        let name = archive.software.name
        packageMetadata = try await Task.detached { try Self.readMetadata(at: packagePath, bundleID: bundleID, fallbackName: name) }.value
        payloadSize = (try FileManager.default.attributesOfItem(atPath: packagePath.path)[.size] as? NSNumber)?.int64Value ?? 0
        app = try await Self.setupApp(port: port)
        logger.info("Installer app setup completed for ID: \(id)")

        app.get("*") { [weak self] req in
            guard let self else { return Response(status: .badGateway) }
            logger.info("local installer request id=\(self.id) method=\(req.method) host=\(req.headers.first(name: "Host") ?? "unknown") path=\(req.url.path) userAgent=\(req.headers.first(name: "User-Agent") ?? "unknown")")

            switch req.url.path {
            case "/ping":
                if let event = try? req.query.get(String.self, at: "event"),
                   ["page-ready", "install-click", "heartbeat"].contains(event) {
                    logger.info("Compatible install [\(self.id)]: browser event=\(event)")
                }
                return Response(status: .ok, headers: ["Cache-Control": "no-store"], body: .init(string: "pong"))
            case "/favicon.ico":
                return Response(status: .noContent)
            case "/", "/index.html":
                guard let html = self.indexHtml else {
                    return Response(status: .serviceUnavailable, headers: ["Cache-Control": "no-store", "Content-Type": "text/plain; charset=utf-8"],
                        body: .init(string: "安装清单尚未准备好，请返回 App 重试。"))
                }
                return Response(status: .ok, version: req.version, headers: [
                    "Content-Type": "text/html; charset=utf-8",
                ], body: .init(string: html))
            case payloadEndpoint.path:
                return try await self.payloadResponse(for: req, path: packagePath)
            default:
                // 404
                logger.warning("unknown request path: \(req.url.path) for installer id: \(self.id)")
                return Response(status: .notFound)
            }
        }

        try app.server.start()
        logger.info("installer init at port \(port) for loopback host \(Self.host) mode=compatible-http")
    }

    deinit {
        destroy()
    }

    func destroy() {
        shutdownLock.lock()
        guard !shuttingDown else { shutdownLock.unlock(); return }
        shuttingDown = true
        shutdownLock.unlock()
        logger.info("destroying installer id: \(id)")
        let server = app
        Task.detached {
            guard !server.didShutdown else { return }
            await server.server.shutdown()
            do { try await server.asyncShutdown() }
            catch { logger.error("Installer shutdown failed: \(error.localizedDescription)") }
        }
    }
}

