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
    @ObservationIgnored private var _versionItems: Persist<OrderedDictionary<VersionIdentifier, StoreHistorySupport.Metadata>>
    @ObservationIgnored private var indexFetchedAt: Persist<TimeInterval>
    @ObservationIgnored private var catalogFetchedAt: Persist<TimeInterval>

    var versionIdentifiers: [VersionIdentifier] {
        get { access(keyPath: \.versionIdentifiers); return _versionIdentifiers.wrappedValue }
        set { withMutation(keyPath: \.versionIdentifiers) { _versionIdentifiers.wrappedValue = newValue } }
    }
    var versionItems: OrderedDictionary<VersionIdentifier, StoreHistorySupport.Metadata> {
        get { access(keyPath: \.versionItems); return _versionItems.wrappedValue }
        set { withMutation(keyPath: \.versionItems) { _versionItems.wrappedValue = newValue } }
    }

    var isVersionItemsFullyLoaded: Bool {
        StoreHistorySupport.missingIdentifiers(versionIdentifiers, loaded: Set(versionItems.keys)).isEmpty
    }
    var error: String?
    var shouldDismiss = false
    var isLoadingIndex = false
    var isLoadingEarlierVersions = false
    var canLoadEarlierVersions = true
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
        catalogFetchedAt = Persist(key: "\(key).catalogHistoryFetchedAt", defaultValue: 0)
    }

    func package(for externalVersion: String) -> AppStore.AppPackage? {
        guard let metadata = versionItems[externalVersion] else { return nil }
        var pkg = package
        pkg.software.version = metadata.displayVersion
        pkg.externalVersionID = externalVersion
        return pkg
    }

    private var fullIndexIsFresh: Bool {
        indexFetchedAt.wrappedValue > 0 &&
        (0..<900).contains(Date().timeIntervalSince1970 - indexFetchedAt.wrappedValue)
    }

    func loadHistory(force: Bool = false) {
        guard !isLoadingIndex else { return }
        started = true
        canLoadEarlierVersions = !fullIndexIsFresh
        if !force, !versionIdentifiers.isEmpty,
           (0..<900).contains(Date().timeIntervalSince1970 - catalogFetchedAt.wrappedValue) {
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
        let requestedRegion = region
        let platform = package.entityType == .appleTV ? "appletv" : (package.entityType == .iPad ? "ipad" : "iphone")
        indexTask = Task {
            defer { finishIndex(session: session) }
            do {
                let index = try await StoreCatalogHistoryService.history(appID: requestedPackage.software.id,
                    bundleID: requestedPackage.software.bundleID, region: requestedRegion, platform: platform) {
                        logger.info("\($0)")
                    }
                try Task.checkCancellation()
                guard generation == session else { return }
                var retained = versionItems
                for (key, value) in index.metadata { retained[key] = value; metadataErrors.removeValue(forKey: key) }
                versionItems = retained
                // Apple's public endpoint returns newest-first, with exact
                // external IDs. Preserve older cached IDs after these rows.
                versionIdentifiers = StoreHistorySupport.uniqueIdentifiers(index.identifiers + versionIdentifiers)
                queued.removeAll { retained[$0] != nil }
                catalogFetchedAt.wrappedValue = Date().timeIntervalSince1970
                canLoadEarlierVersions = !fullIndexIsFresh
                // Do not start authenticated requests just to display recent
                // versions. Older versions are requested only on demand.
            } catch {
                guard generation == session, !Task.isCancelled else { return }
                logger.info("Store history catalog unavailable; using account history")
                do { try await fetchFullIndex(session: session) }
                catch { handleIndexError(error, session: session) }
            }
        }
    }

    func loadEarlierVersions() {
        guard !isLoadingIndex else { return }
        if fullIndexIsFresh { canLoadEarlierVersions = false; populateNextVersionItems(); return }
        cancelHistoryLoading()
        started = true
        requestsPaused = false
        error = nil
        shouldDismiss = false
        isLoadingIndex = true
        isLoadingEarlierVersions = true
        let session = generation
        indexTask = Task {
            defer { finishIndex(session: session) }
            do { try await fetchFullIndex(session: session) }
            catch { handleIndexError(error, session: session) }
        }
    }

    private func finishIndex(session: UUID) {
        guard generation == session else { return }
        isLoadingIndex = false
        isLoadingEarlierVersions = false
        indexTask = nil
        startPendingMetadata()
    }

    private func handleIndexError(_ error: Error, session: UUID) {
        guard generation == session, !Task.isCancelled, !(error is CancellationError) else { return }
        requestsPaused = true
        queued = []
        if case ApplePackageError.licenseRequired = error { shouldDismiss = true }
        self.error = error.localizedDescription
    }

    private func fetchFullIndex(session: UUID) async throws {
        guard let accountIdentifier else { throw AuthenticationError.accountNotFound }
        isLoadingEarlierVersions = true
        let requestedPackage = package
        let index = try await AppStore.this.withAccount(id: accountIdentifier) { account in
            try await StoreDownloadService.versionIndex(account: &account.account, package: requestedPackage)
        }
        try Task.checkCancellation()
        guard generation == session else { return }
        let complete = StoreHistorySupport.uniqueIdentifiers(Array(index.identifiers.reversed()))
        let valid = Set(complete)
        var retained = versionItems
        for key in Array(retained.keys) where !valid.contains(key) { retained.removeValue(forKey: key) }
        for (key, value) in index.metadata where valid.contains(key) && retained[key] == nil { retained[key] = value }
        let recent = versionIdentifiers.filter { valid.contains($0) && retained[$0]?.releaseDate != nil }
        versionItems = retained
        versionIdentifiers = StoreHistorySupport.uniqueIdentifiers(recent + complete)
        queued.removeAll { !valid.contains($0) }
        indexFetchedAt.wrappedValue = Date().timeIntervalSince1970
        canLoadEarlierVersions = false
        metadataErrors = [:]
        populateNextVersionItems()
    }

    func populateNextVersionItems(count: Int = 8) {
        guard started, !requestsPaused else { return }
        let allMissing = StoreHistorySupport.missingIdentifiers(versionIdentifiers, loaded: Set(versionItems.keys))
        if allMissing.isEmpty, canLoadEarlierVersions, !isLoadingIndex { loadEarlierVersions(); return }
        let missing = allMissing.filter { metadataErrors[$0] == nil && !loadingIDs.contains($0) && !queued.contains($0) }
        enqueue(Array(missing.prefix(count)))
    }

    func populateVersionItem(for versionID: String, retry: Bool = false) {
        guard started, versionIdentifiers.contains(versionID), versionItems[versionID] == nil else { return }
        if retry {
            metadataErrors.removeValue(forKey: versionID)
            queued.removeAll { $0 == versionID }
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
        isLoadingEarlierVersions = false
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
