//
//  Downloads+UI.swift
//  Asspp
//
//  Created by 秋星桥 on 2024/7/13.
//

import ApplePackage
import Foundation

enum DownloadAction: Hashable {
    case suspend
    case resume
    case restart
    case delete
}

@MainActor
extension Downloads {
    func performDownloadAction(for request: PackageManifest, action: DownloadAction) {
        switch action {
        case .suspend:
            suspend(request: request)
        case .resume:
            resume(request: request)
        case .restart:
            restart(request: request)
        case .delete:
            delete(request: request)
        }
    }

    func getAvailableActions(for request: PackageManifest) -> [DownloadAction] {
        switch request.state.status {
        case .pending, .downloading:
            [.suspend, .delete]
        case .paused:
            [.resume, .delete]
        case .failed:
            [.resume, .delete]
        case .completed, .processing:
            [.delete]
        }
    }

    func getActionLabel(for action: DownloadAction) -> (title: String, systemImage: String, isDestructive: Bool) {
        switch action {
        case .suspend:
            (String(localized: "Pause"), "stop.fill", false)
        case .resume:
            (String(localized: "Resume"), "play.fill", false)
        case .restart:
            (String(localized: "Restart Download"), "arrow.clockwise", false)
        case .delete:
            (String(localized: "Delete"), "trash", true)
        }
    }
}

extension Downloads {
    @discardableResult
    func startDownload(for package: AppStore.AppPackage, accountID: String) async throws -> PackageManifest {
        if let existing = downloadRequest(forArchive: package, accountID: accountID) { return existing }
        let key = [accountID, package.id, package.externalVersionID ?? "", package.software.version,
                   (package.entityType ?? .iPhone).rawValue].joined(separator: "\u{0}")
        if let pending = preparingDownloads[key] { return try await pending.value }
        let pending = Task { try await requestDownload(for: package, accountID: accountID) }
        preparingDownloads[key] = pending
        defer { preparingDownloads.removeValue(forKey: key) }
        return try await pending.value
    }

    private func requestDownload(for package: AppStore.AppPackage, accountID: String) async throws -> PackageManifest {
        do {
            return try await prepareDownload(for: package, accountID: accountID)
        } catch ApplePackageError.licenseRequired where package.software.price == 0 {
            try await AppStore.this.withAccount(id: accountID) { account in
                try await ApplePackage.Purchase.purchase(account: &account.account, app: package.software)
            }
            return try await prepareDownload(for: package, accountID: accountID)
        }
    }

    private func prepareDownload(for package: AppStore.AppPackage, accountID: String) async throws -> PackageManifest {
        try await AppStore.this.withAccount(id: accountID) { account in
            let downloadOutput = try await StoreDownloadService.download(account: &account.account, package: package)
            let actual = downloadOutput.bundleShortVersionString
            guard StoreDownloadProtocol.matchesRequestedRelease(actual, expected: package.software.version,
                                                               allowsNewer: package.externalVersionID == nil) else {
                throw StoreDownloadError.versionMismatch(package.software.version, actual)
            }
            if let existing = self.downloadRequest(forArchive: package, accountID: accountID) { return existing }
            let request = try Downloads.this.add(request: .init(
                account: account,
                package: package,
                downloadOutput: downloadOutput,
            ))
            Downloads.this.resume(request: request)
            return request
        }
    }
}

