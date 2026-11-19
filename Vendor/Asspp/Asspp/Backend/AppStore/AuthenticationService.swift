//
//  AuthenticationService.swift
//  Asspp
//
//  Created by 秋星桥 on 2024/7/11.
//

import ApplePackage
import Foundation
import Logging

extension AppStore {
    enum AuthenticationError: LocalizedError {
        case accountNotFound
        case accountChanged
        case accountMismatch
        case sessionExpired
        case authenticationInProgress
        case serviceTemporarilyUnavailable(Int)
        var errorDescription: String? {
            switch self {
            case .accountNotFound: "找不到下载账户，请先添加账户。"
            case .accountChanged: "账户已更新，请重新打开账户详情。"
            case .accountMismatch: "验证返回的账户与当前账户不一致。"
            case .sessionExpired: "账户会话已过期，自动刷新未完成，请在账户页重新登录并完成验证。"
            case .authenticationInProgress: "此账户正在验证，请稍候。"
            case let .serviceTemporarilyUnavailable(status): "Apple 认证暂时不可用（HTTP \(status)），请稍后再试。"
            }
        }
    }

    @MainActor
    func refreshSession(id: String, expectedToken: String) async throws {
        guard let original = accounts.first(where: { $0.id == id }) else { throw AuthenticationError.accountNotFound }
        if original.account.passwordToken != expectedToken { return }
        if let pending = sessionRefreshes[id] { return try await pending.value }
        let pending = Task { [self] in
            let refreshed: ApplePackage.Account
            do {
                let session = try await makeAuthenticationSession(cookies: original.account.cookie)
                refreshed = try await authenticateAccount(email: original.id, password: original.account.password, code: "", using: session)
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as AuthenticationError {
                throw error
            } catch {
                throw AuthenticationError.sessionExpired
            }
            try Task.checkCancellation()
            guard let current = accounts.first(where: { $0.id == id }) else { throw AuthenticationError.accountNotFound }
            guard current.account.passwordToken == expectedToken else { return }
            _ = try saveRefreshedAccount(refreshed, replacing: original)
        }
        sessionRefreshes[id] = pending
        defer { sessionRefreshes.removeValue(forKey: id) }
        try await pending.value
    }

    @MainActor
    func authenticate(email: String, password: String, code: String, using session: ApplePackage.Authenticator,
                      replacing original: UserAccount? = nil) async throws -> UserAccount {
        let operation = original == nil ? "authentication" : "account rotation"
        logger.info("starting \(operation) for user")
        do {
            let appleAccount = try await authenticateAccount(email: email, password: password, code: code, using: session)
            try Task.checkCancellation()
            let userAccount: UserAccount
            if let original {
                userAccount = try saveRefreshedAccount(appleAccount, replacing: original)
            } else {
                userAccount = try save(email: email, account: appleAccount)
            }
            logger.info("\(operation) successful for user")
            return userAccount
        } catch ApplePackage.AuthenticationError.verificationCodeRequired {
            logger.info("\(operation) requires a verification code")
            throw ApplePackage.AuthenticationError.verificationCodeRequired
        } catch let error as ApplePackage.AuthenticationRedirectError {
            logger.error("\(operation) could not follow Apple redirect, HTTP=\(error.statusCode) hasLocation=\(error.hasLocation)")
            throw error
        } catch {
            logger.error("\(operation) failed for user: \(StoreDiagnostics.authenticationErrorSummary(error))")
            throw error
        }
    }

    private func authenticateAccount(email: String, password: String, code: String,
                                     using session: ApplePackage.Authenticator) async throws -> ApplePackage.Account {
        let key = email.lowercased()
        guard activeAuthenticationAccounts.insert(key).inserted else { throw AuthenticationError.authenticationInProgress }
        defer { activeAuthenticationAccounts.remove(key) }
        let clock = ContinuousClock()
        let start = clock.now
        defer { logger.debug("Apple authentication elapsed=\(clock.now - start)") }
        do {
            return try await StoreAuthenticationRetry.run(response: { error in
                guard let response = error as? ApplePackage.AuthenticationHTTPError else { return nil }
                return (response.statusCode, response.retryAfter)
            }, wait: { delay in
                logger.info("Apple authentication retry scheduled, delayMs=\(delay)")
                try await Task.sleep(for: .milliseconds(delay))
            }) {
                try await session.authenticate(email: email, password: password, code: code)
            }
        } catch let error as ApplePackage.AuthenticationHTTPError {
            logger.warning("Apple authentication temporarily unavailable, HTTP=\(error.statusCode)")
            throw AuthenticationError.serviceTemporarilyUnavailable(error.statusCode)
        }
    }

    func makeAuthenticationSession(cookies: [ApplePackage.Cookie] = []) async throws -> ApplePackage.Authenticator {
        let clock = ContinuousClock()
        let start = clock.now
        defer { logger.debug("Apple authentication setup elapsed=\(clock.now - start)") }
        return try await ApplePackage.Authenticator(cookies: cookies)
    }

    private func saveRefreshedAccount(_ account: ApplePackage.Account, replacing original: UserAccount) throws -> UserAccount {
        guard let current = accounts.first(where: { $0.id == original.id }) else { throw AuthenticationError.accountNotFound }
        guard current.account.passwordToken == original.account.passwordToken,
              current.account.password == original.account.password,
              current.account.directoryServicesIdentifier == original.account.directoryServicesIdentifier
        else { throw AuthenticationError.accountChanged }
        guard account.directoryServicesIdentifier == original.account.directoryServicesIdentifier else {
            throw AuthenticationError.accountMismatch
        }
        return try save(email: original.id, account: account)
    }

    @MainActor
    @discardableResult
    func rotate(id: UserAccount.ID) async throws -> UserAccount? {
        guard let account = accounts.first(where: { $0.id == id }) else {
            throw AuthenticationError.accountNotFound
        }
        let session = try await makeAuthenticationSession(cookies: account.account.cookie)
        return try await authenticate(email: account.account.email, password: account.account.password,
                                      code: "", using: session, replacing: account)
    }
}

