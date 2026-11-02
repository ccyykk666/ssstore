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
    @ObservationIgnored let accountIdentifier: String?
    @ObservationIgnored let region: String
    var package: AppStore.AppPackage
    typealias VersionIdentifier = String

    @ObservationIgnored private var _versionIdentifiers: Persist<[VersionIdentifier]>
    @ObservationIgnored private var _versionItems: Persist<OrderedDictionary<VersionIdentifier, VersionMetadata>>
    @ObservationIgnored private var indexFetchedAt: Persist<TimeInterval>

    var versionIdentifiers: [VersionIdentifier] {
        get { access(keyPath: \.versionIdentifiers); return _versionIdentifiers.wrappedValue }
        set { withMutation(keyPath: \.versionIdentifiers) { _versionIdentifiers.wrappedValue = newValue } }
    }
    var versionItems: OrderedDictionary<VersionIdentifier, VersionMetadata> {
        get { access(keyPath: \.versionItems); return _versionItems.wrappedValue }
        set { withMutation(keyPath: \.versionItems) { _versionItems.wrappedValue = newValue } }
    }

    var isVersionItemsFullyLoaded: Bool {
        StoreHistorySupport.missingIdentifiers(versionIdentifiers, loaded: Set(versionItems.keys)).isEmpty
    }
    var error: String?
    var shouldDismiss = false
    var isLoadingIndex = false
    var loadingIDs: Set<String> = []
    var metadataErrors: [String: String] = [:]
    var loading: Bool { isLoadingIndex || !loadingIDs.isEmpty }

    @ObservationIgnored private var indexTask: Task<Void, Never>?
    @ObservationIgnored private var metadataTasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var queued: [String] = []
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var started = false
    @ObservationIgnored private var requestsPaused = false

    init(accountID: String?, region: String, package: AppStore.AppPackage) {
        accountIdentifier = accountID
        self.region = region
        self.package = package
        let key = [package.id, package.software.bundleID.lowercased(), region, (package.entityType ?? .iPhone).rawValue]
            .joined().lowercased()
        _versionItems = Persist(key: "\(key).versions", defaultValue: [:])
        _versionIdentifiers = Persist(key: "\(key).versionNumbers", defaultValue: [])
        indexFetchedAt = Persist(key: "\(key).versionIndexFetchedAt", defaultValue: 0)
    }

    func package(for externalVersion: String) -> AppStore.AppPackage? {
        guard let metadata = versionItems[externalVersion] else { return nil }
        var pkg = package
        pkg.software.version = metadata.displayVersion
        pkg.externalVersionID = externalVersion
        return pkg
    }

    func loadHistory(force: Bool = false) {
        guard accountIdentifier != nil, !isLoadingIndex else { return }
        started = true
        if !force, !versionIdentifiers.isEmpty,
           (0..<900).contains(Date().timeIntervalSince1970 - indexFetchedAt.wrappedValue) {
            populateNextVersionItems()
            return
        }
        cancelHistoryLoading()
        started = true
        requestsPaused = false
        error = nil
        shouldDismiss = false
        isLoadingIndex = true
        let session = generation
        let requestedPackage = package
        guard let accountIdentifier else { return }
        indexTask = Task {
            defer {
                if generation == session {
                    isLoadingIndex = false
                    indexTask = nil
                    startPendingMetadata()
                }
            }
            do {
                let index = try await AppStore.this.withAccount(id: accountIdentifier) { account in
                    try await StoreDownloadService.versionIndex(account: &account.account, package: requestedPackage)
                }
                try Task.checkCancellation()
                guard generation == session else { return }
                let identifiers = StoreHistorySupport.uniqueIdentifiers(Array(index.identifiers.reversed()))
                let valid = Set(identifiers)
                var retained = versionItems
                for key in Array(retained.keys) where !valid.contains(key) { retained.removeValue(forKey: key) }
                for (key, value) in index.metadata where valid.contains(key) { retained[key] = value }
                queued.removeAll { !valid.contains($0) }
                versionItems = retained
                versionIdentifiers = identifiers
                indexFetchedAt.wrappedValue = Date().timeIntervalSince1970
                metadataErrors = [:]
                populateNextVersionItems()
            } catch is CancellationError {
                // Keep cached rows and all completed metadata.
            } catch {
                guard generation == session, !Task.isCancelled else { return }
                requestsPaused = true
                queued = []
                if case ApplePackageError.licenseRequired = error { shouldDismiss = true }
                self.error = error.localizedDescription
            }
        }
    }

    func populateNextVersionItems(count: Int = 8) {
        guard started, !requestsPaused else { return }
        let missing = StoreHistorySupport.missingIdentifiers(versionIdentifiers, loaded: Set(versionItems.keys))
            .filter { metadataErrors[$0] == nil && !loadingIDs.contains($0) && !queued.contains($0) }
        enqueue(Array(missing.prefix(count)))
    }

    func populateVersionItem(for versionID: String, retry: Bool = false) {
        guard started, versionIdentifiers.contains(versionID), versionItems[versionID] == nil else { return }
        if retry {
            metadataErrors.removeValue(forKey: versionID)
            requestsPaused = false
        }
        guard metadataErrors[versionID] == nil, !requestsPaused else { return }
        enqueue([versionID], priority: retry)
    }

    private func enqueue(_ identifiers: [String], priority: Bool = false) {
        let added = identifiers.filter { versionItems[$0] == nil && !loadingIDs.contains($0) && !queued.contains($0) }
        if priority { queued.insert(contentsOf: added, at: 0) } else { queued.append(contentsOf: added) }
        startPendingMetadata()
    }

    private func startPendingMetadata() {
        guard let accountIdentifier, !requestsPaused, !isLoadingIndex else { return }
        while metadataTasks.count < 2, !queued.isEmpty {
            let version = queued.removeFirst()
            guard versionItems[version] == nil else { continue }
            let requestedPackage = package
            let session = generation
            loadingIDs.insert(version)
            metadataTasks[version] = Task {
                defer {
                    if generation == session {
                        metadataTasks.removeValue(forKey: version)
                        loadingIDs.remove(version)
                        startPendingMetadata()
                    }
                }
                do {
                    let metadata = try await AppStore.this.historyMetadata(accountID: accountIdentifier,
                        package: requestedPackage, versionID: version)
                    try Task.checkCancellation()
                    guard generation == session else { return }
                    versionItems[version] = metadata
                    metadataErrors.removeValue(forKey: version)
                } catch is CancellationError {
                } catch {
                    guard generation == session, !Task.isCancelled else { return }
                    metadataErrors[version] = error.localizedDescription
                    if Self.shouldPause(error) {
                        requestsPaused = true
                        queued = []
                        self.error = error.localizedDescription
                    }
                }
            }
        }
    }

    private static func shouldPause(_ error: Error) -> Bool {
        if case ApplePackageError.licenseRequired = error { return true }
        guard let error = error as? StoreDownloadError else { return false }
        switch error {
        case let .response(status), let .emptyResponse(status), let .serviceResponse(status, _):
            return [401, 403, 429].contains(status)
        case .rejected, .actionRequired: return true
        default: return false
        }
    }

    func cancelHistoryLoading() {
        generation = UUID()
        started = false
        indexTask?.cancel()
        indexTask = nil
        for task in metadataTasks.values { task.cancel() }
        metadataTasks = [:]
        loadingIDs = []
        queued = []
        isLoadingIndex = false
    }
}

extension AppPackageArchive {
    var version: String { package.software.version }
    var releaseDate: Date? { package.releaseDate }
    var releaseNotes: String? { package.software.releaseNotes }
    var formattedPrice: String? { package.software.formattedPrice }
    var price: Double? { package.software.price }
    var downloadOutput: DownloadOutput? {
        get { package.downloadOutput }
        set { package.downloadOutput = newValue }
    }
}
