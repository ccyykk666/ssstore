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
    @ObservationIgnored let id: UUID
    @ObservationIgnored let app: Application
    @ObservationIgnored private let ipv6App: Application?
    @ObservationIgnored let archive: AppStore.AppPackage
    @ObservationIgnored let certificateIdentity: LocalInstallIdentity
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

    @MainActor
    func prepareForAttempt() {
        coverage = nil
        sentBytes = 0
        status = .ready
    }

    @MainActor
    var diagnosticStatus: String {
        switch status {
        case .ready: "waiting-for-manifest"
        case .sendingManifest: "manifest-or-icon-requested"
        case .sendingPayload: "payload-requested"
        case .completed(let result): (try? result.get()) != nil ? "payload-sent" : "payload-transfer-failed"
        case .broken: "failed"
        }
    }

    init(archive: AppStore.AppPackage, path packagePath: URL) async throws {
        let id: UUID = .init()
        self.id = id
        self.archive = archive
        payloadSize = (try FileManager.default.attributesOfItem(atPath: packagePath.path)[.size] as? NSNumber)?.int64Value ?? 0
        certificateIdentity = try await Task.detached { try LocalInstallIdentity.current() }.value
        app = try await Self.setupApp(port: port, identity: certificateIdentity)
        ipv6App = try await Self.setupApp(port: port, identity: certificateIdentity, host: "::1")
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
                case plistEndpoint.path:
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
                    await MainActor.run { self.status = .sendingPayload }
                    logger.info("starting payload transfer for installer id: \(self.id)")

                    let receipt = InstallerPayloadReceipt()
                    let response = try await req.fileio.asyncStreamFile(
                        at: packagePath.path,
                        chunkSize: 64 * 1024,
                    ) { result in
                        await MainActor.run {
                            switch result {
                            case .success:
                                guard let receipt = receipt.snapshot else { return }
                                var coverage = self.coverage ?? InstallTransferCoverage(totalBytes: self.payloadSize)
                                coverage.record(method: req.method.rawValue, status: receipt.status,
                                    contentLength: receipt.length, contentRange: receipt.range)
                                self.coverage = coverage
                                self.sentBytes = coverage.completedBytes
                                // A successful range probe is not a completed IPA transfer.
                                self.status = coverage.isComplete ? .completed(.success(())) : .sendingPayload
                                logger.info("Certificate install [\(self.id)]: payload response sent status=\(receipt.status) range=\(receipt.range ?? "full") delivered=\(self.sentBytes)/\(self.payloadSize)")
                            case .failure(let error):
                                // Clients can cancel a probe and retry with a different range.
                                // Keep the server alive until the user leaves or iOS stops it.
                                logger.error("Certificate install [\(self.id)]: payload stream interrupted: \(DiagnosticLog.errorDetails(error))")
                            }
                        }
                    }
                    receipt.configure(response)
                    return response
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
        logger.info("installer init at port \(port) for loopback host \(Self.host)")
    }

    init(certificateIdentity: LocalInstallIdentity) async throws {
        let id: UUID = .init()
        self.id = id
        self.certificateIdentity = certificateIdentity
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

/// FileIO constructs the response before its asynchronous body is consumed.
/// Snapshot its actual headers rather than interpreting the client's Range twice.
private final class InstallerPayloadReceipt: @unchecked Sendable {
    struct Snapshot { let status: Int; let length: Int64; let range: String? }
    private let lock = NSLock()
    private var value: Snapshot?
    var snapshot: Snapshot? { lock.lock(); defer { lock.unlock() }; return value }
    func configure(_ response: Response) {
        lock.lock(); defer { lock.unlock() }
        value = Snapshot(status: Int(response.status.code),
            length: Int64(response.headers.first(name: "Content-Length") ?? "") ?? -1,
            range: response.headers.first(name: "Content-Range"))
    }
}

