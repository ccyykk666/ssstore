//
//  Installer+App.swift
//  Asspp
//
//  Created by 秋星桥 on 2024/7/11.
//

import Foundation
import LocalInstallTLS
import Vapor

extension Installer {
    private static let env: Environment = {
        var env = try! Environment.detect()
        try! LoggingSystem.bootstrap(from: &env)
        return env
    }()

    static func setupApp(port: Int, identity: LocalInstallIdentity?, host: String = LocalInstallIdentity.host) async throws -> Application {
        let app = try await Application.make()

        app.threadPool = .init(numberOfThreads: 1)

        if let identity {
            app.http.server.configuration.tlsConfiguration = try Self.setupTLS(identity: identity)
        }
        app.http.server.configuration.hostname = host
        app.http.server.configuration.tcpNoDelay = true

        app.http.server.configuration.address = .hostname(host, port: port)
        app.http.server.configuration.port = port

        app.routes.defaultMaxBodySize = "128mb"
        app.routes.caseInsensitive = false

        return app
    }
}

