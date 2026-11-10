//
//  Installer.swift
//  AppInstaller
//
//  Created by 秋星桥 on 2024/7/10.
//

import ApplePackage
import Foundation
import Logging
import LocalInstallTLS
import UpdateCore
#if canImport(UIKit)
    import UIKit
#endif
import Vapor

@Observable
class Installer: Identifiable, @unchecked Sendable {
    enum Mode: Equatable, Sendable { case certificate, compatible }
    @ObservationIgnored let mode: Mode
    @ObservationIgnored let packageMetadata: InstallationManifest.Metadata?
    @ObservationIgnored private(set) var remoteManifestEndpoint: URL?
    var isCompatible: Bool { mode == .compatible }
    @ObservationIgnored let id: UUID
    @ObservationIgnored let app: Application
    @ObservationIgnored private let ipv6App: Application?
    @ObservationIgnored let archive: AppStore.AppPackage
    @ObservationIgnored let certificateIdentity: LocalInstallIdentity?
    @ObservationIgnored let payloadSize: Int64
    @ObservationIgnored let port = Int.random(in: 4000 ... 8000)
    @ObservationIgnored private let shutdownLock = NSLock()
    @ObservationIgnored private var shuttingDown = false

    enum Status {
        case ready
        case sendingManifest
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
        case .ready: isCompatible ? "waiting-for-system-payload" : "waiting-for-manifest"
        case .sendingManifest: "manifest-or-icon-requested"
        case .sendingPayload: "payload-requested"
        case .completed(let result): (try? result.get()) != nil ? "payload-sent" : "payload-transfer-failed"
        case .broken: "failed"
        }
    }

    init(archive: AppStore.AppPackage, path packagePath: URL, mode: Mode = .certificate) async throws {
        let id: UUID = .init()
        self.id = id
        self.archive = archive
        self.mode = mode
        let bundleID = archive.software.bundleID
        let name = archive.software.name
        packageMetadata = try await Task.detached { try Self.readMetadata(at: packagePath, bundleID: bundleID, fallbackName: name) }.value
        payloadSize = (try FileManager.default.attributesOfItem(atPath: packagePath.path)[.size] as? NSNumber)?.int64Value ?? 0
        if mode == .certificate {
            certificateIdentity = try await Task.detached { try LocalInstallIdentity.current() }.value
        } else { certificateIdentity = nil }
        app = try await Self.setupApp(port: port, identity: certificateIdentity)
        if mode == .certificate {
            ipv6App = try await Self.setupApp(port: port, identity: certificateIdentity, host: "::1")
        } else { ipv6App = nil }
        if mode == .compatible, let packageMetadata {
            remoteManifestEndpoint = try InstallationManifest.serviceURL(endpoint: InstallerManifestService.endpoint(),
                metadata: packageMetadata, payload: payloadEndpoint)
        }
        logger.info("Installer app setup completed for ID: \(id)")

        for server in [app, ipv6App].compactMap({ $0 }) {
            server.get("*") { [weak self] req in
                guard let self else { return Response(status: .badGateway) }
                logger.info("local installer request id=\(self.id) method=\(req.method) host=\(req.headers.first(name: "Host") ?? "unknown") path=\(req.url.path) userAgent=\(req.headers.first(name: "User-Agent") ?? "unknown")")

                switch req.url.path {
                case "/ping":
                    if let event = try? req.query.get(String.self, at: "event"),
                       ["page-ready", "install-click", "heartbeat"].contains(event) {
                        logger.info("Certificate install [\(self.id)]: browser event=\(event)")
                    }
                    return Response(status: .ok, headers: ["Cache-Control": "no-store"], body: .init(string: "pong"))
                case "/favicon.ico":
                    return Response(status: .noContent)
                case "/", "/index.html":
                    return Response(status: .ok, version: req.version, headers: [
                        "Content-Type": "text/html; charset=utf-8",
                    ], body: .init(string: indexHtml))
                case plistEndpoint.path where !isCompatible:
                    await MainActor.run { if case .ready = self.status { self.status = .sendingManifest } }
                    logger.info("sending manifest for installer id: \(self.id)")
                    return Response(status: .ok, version: req.version, headers: [
                        "Content-Type": "text/xml",
                    ], body: .init(data: installManifestData))
                case displayImageSmallEndpoint.path:
                    logger.info("sending small display image for installer id: \(self.id)")
                    return Response(status: .ok, version: req.version, headers: [
                        "Content-Type": "image/png",
                    ], body: .init(data: displayImageSmallData))
                case displayImageLargeEndpoint.path:
                    logger.info("sending large display image for installer id: \(self.id)")
                    return Response(status: .ok, version: req.version, headers: [
                        "Content-Type": "image/png",
                    ], body: .init(data: displayImageLargeData))
                case payloadEndpoint.path:
                    return try await self.payloadResponse(for: req, path: packagePath)
                default:
                    // 404
                    logger.warning("unknown request path: \(req.url.path) for installer id: \(self.id)")
                    return Response(status: .notFound)
                }
            }
        }

        try app.server.start()
        do { try ipv6App?.server.start() }
        catch { logger.warning("IPv6 installer listener unavailable; IPv4 listener remains active: \(error.localizedDescription)") }
        logger.info("installer init at port \(port) for loopback host \(Self.host) mode=\(isCompatible ? "compatible-http" : "certificate-https")")
    }

    init(certificateIdentity: LocalInstallIdentity) async throws {
        let id: UUID = .init()
        self.id = id
        self.certificateIdentity = certificateIdentity
        mode = .certificate
        packageMetadata = nil
        payloadSize = 0
        ipv6App = nil
        archive = .init(software: .init(
            id: .random(),
            bundleID: "",
            name: "",
            version: "",
            artistName: "",
            sellerName: "",
            description: "",
            averageUserRating: 0,
            userRatingCount: 0,
            artworkUrl: "",
            screenshotUrls: [],
            minimumOsVersion: "",
            releaseDate: "",
            formattedPrice: "",
            primaryGenreName: "",
        ))

        app = try await Self.setupApp(port: port, identity: nil)

        let profile = certificateIdentity.profile
        app.get("ssstore-loopback.mobileconfig") { _ in
            Response(status: .ok, headers: [
                "Content-Type": "application/x-apple-aspen-config",
                "Content-Disposition": "attachment; filename=ssstore-loopback.mobileconfig",
                "Cache-Control": "no-store",
            ], body: .init(data: profile))
        }
        try app.server.start()
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
        let servers = [app, ipv6App].compactMap { $0 }
        Task.detached {
            for app in servers {
                guard !app.didShutdown else { continue }
                await app.server.shutdown()
                do { try await app.asyncShutdown() }
                catch { logger.error("Installer shutdown failed: \(error.localizedDescription)") }
            }
        }
    }
}

