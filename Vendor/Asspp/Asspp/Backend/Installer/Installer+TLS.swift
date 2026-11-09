//
//  Installer+TLS.swift
//  Asspp
//
//  Created by 秋星桥 on 2024/7/11.
//

import Foundation
import LocalInstallTLS
import NIOSSL
import NIOTLS
import Vapor
#if canImport(UIKit)
import UIKit
#endif

extension Installer {
    static let host = LocalInstallIdentity.host

    @MainActor private static var certificateServer: Task<Installer, Error>?

    @MainActor
    static func prepareCertificateServer() async throws -> URL {
        if let certificateServer { return try await certificateServer.value.certificateProfileEndpoint }
        let task = Task {
            let identity = try await Task.detached { try LocalInstallIdentity.current() }.value
            return try await Installer(certificateIdentity: identity)
        }
        certificateServer = task
        do { return try await task.value.certificateProfileEndpoint }
        catch { certificateServer = nil; throw error }
    }

    #if canImport(UIKit)
    @MainActor private static var certificateBackgroundTask: UIBackgroundTaskIdentifier = .invalid

    @MainActor
    static func openCertificateProfile() async throws {
        let url = try await prepareCertificateServer()
        if certificateBackgroundTask == .invalid {
            certificateBackgroundTask = UIApplication.shared.beginBackgroundTask(withName: "LocalInstallCertificate") {
                Task { @MainActor in endCertificateBackgroundTask() }
            }
        }
        guard await UIApplication.shared.open(url, options: [:]) else {
            endCertificateBackgroundTask()
            throw NSError(domain: "ssstore.install", code: 3, userInfo: [NSLocalizedDescriptionKey: "无法打开证书描述文件。"])
        }
    }

    @MainActor private static func endCertificateBackgroundTask() {
        guard certificateBackgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(certificateBackgroundTask)
        certificateBackgroundTask = .invalid
    }
    #endif

    static func setupTLS(identity: LocalInstallIdentity) throws -> TLSConfiguration {
        return try TLSConfiguration.makeServerConfiguration(
            certificateChain: NIOSSLCertificate
                .fromPEMBytes(Array(identity.certificateChainPEM.utf8))
                .map { NIOSSLCertificateSource.certificate($0) },
            privateKey: NIOSSLPrivateKeySource.privateKey(NIOSSLPrivateKey(bytes: Array(identity.privateKeyPEM.utf8), format: .pem)),
        )
    }
}

