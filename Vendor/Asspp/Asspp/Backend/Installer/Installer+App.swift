//
//  Installer+App.swift
//  Asspp
//
//  Created by 秋星桥 on 2024/7/11.
//

import Foundation
import Vapor

extension Installer {
    private static let env: Environment = {
        var env = try! Environment.detect()
        try! LoggingSystem.bootstrap(from: &env)
        return env
    }()

    static func setupApp(port: Int) async throws -> Application {
        let app = try await Application.make()

        app.threadPool = .init(numberOfThreads: 1)

        app.http.server.configuration.hostname = Self.host
        app.http.server.configuration.tcpNoDelay = true

        app.http.server.configuration.address = .hostname(Self.host, port: port)
        app.http.server.configuration.port = port

        app.routes.defaultMaxBodySize = "128mb"
        app.routes.caseInsensitive = false

        return app
    }
}

