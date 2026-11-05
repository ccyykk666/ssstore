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
        case sessionExpired
        var errorDescription: String? {
            switch self {
            case .accountNotFound: "找不到下载账户，请先添加账户。"
            case .sessionExpired: "账户会话已过期，自动刷新未完成，请在账户页重新登录并完成验证。"
            }
        }
    }

    @MainActor
    func refreshSession(id: String, expectedToken: String) async throws {
        guard let original = accounts.first(where: { $0.id == id }) else { throw AuthenticationError.accountNotFound }
        if original.account.passwordToken != expectedToken { return }
        if let pending = sessionRefreshes[id] { return try await pending.value }
        let pending = Task { [self] in
            var refreshed = original
            do { try await ApplePackage.Authenticator.rotatePasswordToken(for: &refreshed.account) }
            catch { throw AuthenticationError.sessionExpired }
            guard let index = accounts.firstIndex(where: { $0.id == id }),
                  accounts[index].account.passwordToken == expectedToken else { return }
            accounts[index] = refreshed
        }
        sessionRefreshes[id] = pending
        defer { sessionRefreshes.removeValue(forKey: id) }
        try await pending.value
    }

    @MainActor
    func authenticate(email: String, password: String, code: String, using session: ApplePackage.Authenticator) async throws -> UserAccount {
        logger.info("starting authentication for user")
        do {
            let appleAccount = try await session.authenticate(
                email: email,
                password: password,
                code: code,
            )
            let userAccount = try save(email: email, account: appleAccount)
            logger.info("authentication successful for user")
            return userAccount
        } catch {
            logger.error("authentication failed for user: \(error.localizedDescription)")
            throw error
        }
    }

    @MainActor
    @discardableResult
    func rotate(id: UserAccount.ID) async throws -> UserAccount? {
        logger.info("starting account rotation for user id: \(id)")
        guard let account = accounts.first(where: { $0.id == id }) else {
            logger.error("account not found for rotation, id: \(id)")
            throw AuthenticationError.accountNotFound
        }
        do {
            let newAppleAccount = try await ApplePackage.Authenticator.authenticate(
                email: account.account.email,
                password: account.account.password,
                code: "",
                cookies: account.account.cookie,
            )
            let updatedAccount = try save(email: account.account.email, account: newAppleAccount)
            logger.info("account rotation successful for user id: \(id)")
            return updatedAccount
        } catch {
            logger.error("account rotation failed for user id: \(id): \(error.localizedDescription)")
            throw error
        }
    }
}

