//
//  AppPackageArchive.swift
//  Asspp
//
//  Created by luca on 15.09.2025.
//

import ApplePackage
import Foundation
import OrderedCollections

@MainActor
@Observable
class AppPackageArchive {
    @ObservationIgnored
    let accountIdentifier: String?
    @ObservationIgnored
    let region: String

    var package: AppStore.AppPackage

    typealias VersionIdentifier = String
    @ObservationIgnored
    private var _versionIdentifiers: Persist<[VersionIdentifier]>

    var versionIdentifiers: [VersionIdentifier] {
        get {
            access(keyPath: \.versionIdentifiers)
            return _versionIdentifiers.wrappedValue
        }
        set {
            withMutation(keyPath: \.versionIdentifiers) {
                _versionIdentifiers.wrappedValue = newValue
            }
        }
    }

    @ObservationIgnored
    private var _versionItems: Persist<OrderedDictionary<VersionIdentifier, VersionMetadata>>

    var versionItems: OrderedDictionary<VersionIdentifier, VersionMetadata> {
        get {
            access(keyPath: \.versionItems)
            return _versionItems.wrappedValue
        }
        set {
            withMutation(keyPath: \.versionItems) {
                _versionItems.wrappedValue = newValue
            }
        }
    }

    var isVersionItemsFullyLoaded: Bool {
        versionIdentifiers.allSatisfy { versionItems[$0] != nil }
    }

    var error: String?
    var loading = false
    var licenseRequired = false
    var canAcquireLicense: Bool { StoreHistoryProtocol.canAcquireLicense(price: package.software.price) }

    private func historyRequest<T>(_ request: (inout Account) async throws -> T) async throws -> T {
        guard let accountIdentifier else { throw AppStore.AuthenticationError.accountNotFound }
        return try await StoreHistoryProtocol.withSessionRecovery {
            try await AppStore.this.withAccount(id: accountIdentifier) { user in
                try await request(&user.account)
            }
        } refresh: {
            // Persist the refreshed session before retrying, even if the history request fails.
            try await AppStore.this.withAccount(id: accountIdentifier) { user in
                try await ApplePackage.Authenticator.rotatePasswordToken(for: &user.account)
            }
        }
    }

    private func handleHistoryError(_ failure: Error) {
        if case .licenseRequired = failure as? ApplePackageError {
            licenseRequired = true
            error = nil
        } else {
            error = failure.localizedDescription
        }
    }

    func acquireHistoryLicense() {
        guard !loading, canAcquireLicense else { return }
        let requestedPackage = package
        loading = true; error = nil
        Task {
            do {
                try await historyRequest { account in
                    try await StoreDownloadService.acquireFreeLicense(account: &account, package: requestedPackage)
                }
                licenseRequired = false
                loading = false
                populateVersionIdentifiers { await MainActor.run { self.populateNextVersionItems() } }
            } catch {
                handleHistoryError(error)
                loading = false
            }
        }
    }

    init(accountID: String?, region: String, package: AppStore.AppPackage) {
        accountIdentifier = accountID
        self.region = region
        self.package = package

        let packageIdentifier = [package.id, package.software.bundleID.lowercased(), region, (package.entityType ?? .iPhone).rawValue]
            .joined()
            .lowercased()
        _versionItems = Persist(key: "\(packageIdentifier).versions", defaultValue: [:])
        _versionIdentifiers = Persist(key: "\(packageIdentifier).versionNumbers", defaultValue: [])
    }

    func package(for externalVersion: String) -> AppStore.AppPackage? {
        if let metadata = versionItems[externalVersion] {
            var pkg = package
            pkg.software.version = metadata.displayVersion
            pkg.externalVersionID = externalVersion
            return pkg
        } else {
            return nil
        }
    }

    func clearVersionItems() {
        assert(!loading)
        error = nil
        licenseRequired = false
        versionIdentifiers = []
        versionItems = [:]
    }

    func populateVersionIdentifiers(_ completion: (() async -> Void)? = nil) {
        guard accountIdentifier != nil, !loading else { return }
        let requestedPackage = package
        loading = true
        error = nil

        Task {
            do {
                let versions = try await historyRequest { account in
                    try await StoreDownloadService.versions(account: &account, package: requestedPackage)
                }
                self.versionIdentifiers = versions.reversed()
                let valid = Set(versions)
                for key in Array(self.versionItems.keys) where !valid.contains(key) {
                    self.versionItems.removeValue(forKey: key)
                }
                self.licenseRequired = false
                self.loading = false
                await completion?()
            } catch {
                self.handleHistoryError(error)
                self.loading = false
            }
        }
    }

    func populateNextVersionItems(count: Int = 3) {
        guard accountIdentifier != nil, !loading, !licenseRequired, !isVersionItemsFullyLoaded else { return }
        loading = true
        error = nil

        Task {
            do {
                for version in self.versionIdentifiers.filter({ self.versionItems[$0] == nil }).prefix(max(0, count)) {
                    let requestedPackage = self.package

                    let metadata = try await historyRequest { account in
                        try await StoreDownloadService.versionMetadata(account: &account, package: requestedPackage, versionID: version)
                    }
                    self.versionItems[version] = metadata
                }
            } catch {
                self.handleHistoryError(error)
            }
            self.loading = false
        }
    }

    func populateVersionItem(for versionID: String) {
        guard accountIdentifier != nil, !loading, !licenseRequired, versionIdentifiers.contains(versionID), versionItems[versionID] == nil else { return }
        loading = true
        error = nil

        Task {
            do {
                let requestedPackage = self.package
                let metadata = try await historyRequest { account in
                    try await StoreDownloadService.versionMetadata(account: &account, package: requestedPackage, versionID: versionID)
                }
                self.versionItems[versionID] = metadata
            } catch {
                self.handleHistoryError(error)
            }
            self.loading = false
        }
    }
}

extension AppPackageArchive {
    var version: String {
        package.software.version
    }

    var releaseDate: Date? {
        package.releaseDate
    }

    var releaseNotes: String? {
        package.software.releaseNotes
    }

    var formattedPrice: String? {
        package.software.formattedPrice
    }

    var price: Double? {
        package.software.price
    }

    var downloadOutput: DownloadOutput? {
        get { package.downloadOutput }
        set { package.downloadOutput = newValue }
    }
}


