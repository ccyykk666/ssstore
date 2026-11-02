import Foundation
import SwiftUI
import UIKit
import UpdateCore

@MainActor
final class AppModel: ObservableObject {
    @Published var records: [AppRecord] = []
    @Published var busy = false
    @Published var activity = ""
    @Published var isChecking = false
    @Published private(set) var isRefreshingApps = false
    @Published private(set) var matchProgress: ApplicationMatchProgress?
    @Published var message: String?
    @Published var filePresentation: FilePresentation?
    @Published var scannedAt: Date?
    @Published var inventoryOrigin = "尚未读取"
    @Published var hasPairing = false
    @Published var iconRevision = 0
    @Published var scanWarning = ""
    @Published var queryWarning = ""
    @Published private(set) var ignoredApps: IgnoredApplications
    @Published var inspectionReceipts: [String: InspectionReceipt] = [:]
    @Published var country: String { didSet { UserDefaults.standard.set(country, forKey: "country") } }
    @Published var host: String { didSet { UserDefaults.standard.set(host, forKey: "host") } }
    @Published var port: String { didSet { UserDefaults.standard.set(port, forKey: "port") } }
    private var checkTask: Task<Void, Never>?
    private var revealTask: Task<Void, Never>?
    private var revealTaskID: UUID?
    private var nextLookupAt = Date.distantPast
    private let storage: URL
    let iconsDirectory: URL
    let pairingURL: URL
    private let inspectionReceiptsURL: URL
    let pairingController = OnDevicePairingController()

    init() {
        let prefs = UserDefaults.standard
        let initialCountry = StoreQueryPolicy.initialScope(saved: prefs.string(forKey: "country"),
                                                           migrated: prefs.bool(forKey: "chinaUSFallbackMigration"))
        country = initialCountry
        prefs.set(initialCountry, forKey: "country")
        prefs.set(true, forKey: "chinaUSFallbackMigration")
        host = prefs.string(forKey: "host") ?? "10.7.0.1"
        // Migrate the removed classic transport without retaining its default port.
        let initialPort = prefs.string(forKey: "pairingMode") == "传统 Lockdown" ? "49152" : (prefs.string(forKey: "port") ?? "49152")
        port = initialPort
        prefs.set("Remote Pairing", forKey: "pairingMode")
        prefs.set(initialPort, forKey: "port")
        ignoredApps = prefs.data(forKey: "ignoredApplications")
            .flatMap { try? JSONDecoder().decode(IgnoredApplications.self, from: $0) } ?? IgnoredApplications()
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ssstore", isDirectory: true)
        storage = folder.appendingPathComponent("inventory.json")
        iconsDirectory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ssstore-icons", isDirectory: true)
        pairingURL = folder.appendingPathComponent("device-pairing.plist")
        inspectionReceiptsURL = folder.appendingPathComponent("inspection-receipts.json")
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: storage.path) {
                let saved = try JSONDecoder().decode(SavedInventory.self, from: Data(contentsOf: storage))
                ignoredApps.captureMetadata(from: saved.records.map(\.installed))
                records = ignoredApps.visible(saved.records)
                scannedAt = saved.scannedAt
                inventoryOrigin = saved.origin
            }
            hasPairing = FileManager.default.fileExists(atPath: pairingURL.path)
            if hasPairing {
                do { _ = try PairingRecord.kind(of: Data(contentsOf: pairingURL)) }
                catch { hasPairing = false; message = error.localizedDescription }
            }
            if let data = try? Data(contentsOf: inspectionReceiptsURL) { inspectionReceipts = (try? JSONDecoder().decode([String: InspectionReceipt].self, from: data)) ?? [:] }
        } catch { message = "读取本地记录失败：\(error.localizedDescription)" }
        if ignoredApps.names.keys.contains(where: { ignoredApps.applications?[$0] == nil }),
           let data = try? Data(contentsOf: folder.appendingPathComponent("device-inventory.json")),
           let apps = try? InventoryParser.parse(data) {
            ignoredApps.captureMetadata(from: apps)
        }
        saveIgnoredApps()
    }

    @discardableResult
    func scan() async -> Bool {
        guard !busy else { return false }
        guard hasPairing else { message = "请先创建或导入 Remote Pairing 配对文件。"; return false }
        guard let number = UInt16(port), number > 0 else { message = "端口应在 1 到 65535 之间。"; return false }
        busy = true
        activity = "正在读取应用…"
        defer { busy = false; activity = "" }
        let path = pairingURL.path
        let address = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let iconsPath = iconsDirectory.path
        let ignoredBundleIDs = Array(ignoredApps.bundleIDs)
        scanWarning = ""
        do {
            let data: Data = try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        let data = try DeviceScanner.scan(pairingPath: path, host: address, port: number,
                            iconsDirectory: iconsPath, ignoredBundleIDs: ignoredBundleIDs, inventory: { data in
                                DispatchQueue.main.async {
                                    do {
                                        let apps = try InventoryParser.parse(data)
                                        self.merge(apps, origin: "本机读取")
                                    }
                                    catch { self.message = error.localizedDescription }
                                }
                            }, progress: { text in
                                DispatchQueue.main.async {
                                    self.activity = text
                                    self.iconRevision += 1
                                }
                            }, warning: { text in
                                DispatchQueue.main.async {
                                    self.scanWarning += (self.scanWarning.isEmpty ? "" : "\n") + text
                                }
                            })
                        DispatchQueue.main.async { continuation.resume(returning: data) }
                    }
                    catch { DispatchQueue.main.async { continuation.resume(throwing: error) } }
                }
            }
            // The final inventory includes InstallationProxy's version metadata.
            // Merge it before starting version queries, even if a UI callback is queued.
            merge(try InventoryParser.parse(data), origin: "本机读取")
        } catch { message = error.localizedDescription; return false }
        return true
    }

    /// One action owns the full read-then-lookup lifecycle. A failed device read
    /// never starts a query against an old inventory.
    func refreshApps() async {
        guard !busy, !isRefreshingApps else { return }
        isRefreshingApps = true
        stopRevealingMatches()
        matchProgress = ApplicationMatchProgress(scope: country)
        defer { isRefreshingApps = false }
        guard await scan() else { return }
        // System apps are read with the inventory and have no store lookup.
        recordMatches(records.filter { $0.installed.isSystem }, scope: country)
        checkUpdates(force: true)
        await checkTask?.value
    }

    func inspect(_ operation: InspectionOperation, bundleID: String = "", path: String = "/",
                 source: String? = nil, domain: Int = 1, groupID: String = "") async throws -> (InspectionResult, URL) {
        func failure(_ text: String) -> NSError { NSError(domain: "ssstore.Inspection", code: 1, userInfo: [NSLocalizedDescriptionKey: text]) }
        guard !busy else { throw failure("请等待当前操作完成。") }
        guard hasPairing else { throw failure("请先创建或导入配对文件。") }
        guard let number = UInt16(port), number > 0 else { throw failure("端口应在 1 到 65535 之间。") }
        let needsApp = operation.requiresApp && !(operation == .coreFiles && domain != 1)
        guard !needsApp || !bundleID.isEmpty else { throw failure("请先选择应用。") }
        guard operation != .coreFiles || domain != 2 || !groupID.isEmpty else { throw failure("请输入 App Group 标识。") }
        busy = true; activity = "正在读取：\(operation.title)…"
        defer { busy = false; activity = "" }
        let pairingPath = pairingURL.path
        let address = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let folder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ssstore-inspection", isDirectory: true).appendingPathComponent(UUID().uuidString, isDirectory: true)
        let key = operation.rawValue + "|" + bundleID
        do {
            let data: Data = try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        let options: [String: Any] = ["bundleID": bundleID, "path": path, "source": source ?? operation.rawValue,
                                                      "domain": domain, "groupID": groupID]
                        continuation.resume(returning: try DeviceInspector.run(pairingPath: pairingPath, host: address, port: number,
                            operation: operation.rawValue, options: options, outputDirectory: folder.path))
                    } catch { continuation.resume(throwing: error) }
                }
            }
            var result = try JSONDecoder().decode(InspectionResult.self, from: data)
            result.capturedAt = ISO8601DateFormatter().string(from: Date())
            result.operation = operation.rawValue
            result.bundleID = bundleID.isEmpty ? nil : bundleID
            result.requestedPath = operation.isBrowser || operation.isFileHelper ? path : nil
            if result.value == .null && result.files.isEmpty && result.entries.isEmpty && result.message == nil {
                result.message = "设备未返回数据。"
            }
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let reportURL = folder.appendingPathComponent("\(operation.rawValue)-report.json")
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(result).write(to: reportURL, options: [.atomic, .completeFileProtection])
            inspectionReceipts[key] = InspectionReceipt(success: true, message: "调用成功", reportPath: reportURL.path)
            saveInspectionReceipts()
            return (result, reportURL)
        } catch {
            inspectionReceipts[key] = InspectionReceipt(success: false, message: error.localizedDescription)
            saveInspectionReceipts()
            throw error
        }
    }

    private func saveInspectionReceipts() {
        do { try JSONEncoder().encode(inspectionReceipts).write(to: inspectionReceiptsURL, options: [.atomic, .completeFileProtection]) }
        catch { message = "保存接口调用记录失败：\(error.localizedDescription)" }
    }

    func localIconURL(for app: InstalledApp) -> URL? {
        guard let key = app.localIconKey, key.count == 64,
              key.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { return nil }
        return iconsDirectory.appendingPathComponent(key).appendingPathExtension("png")
    }

    func installPackage(at url: URL, bundleID: String,
                        progress: @escaping @MainActor (String, Double) -> Void) async throws {
        func failure(_ text: String) -> NSError {
            NSError(domain: "ssstore.Installation", code: 1, userInfo: [NSLocalizedDescriptionKey: text])
        }
        guard !busy else { throw failure("请等待当前操作完成。") }
        guard hasPairing else { throw failure("请先在设置中完成配对。") }
        guard let number = UInt16(port), number > 0 else { throw failure("端口应在 1 到 65535 之间。") }
        busy = true
        activity = "正在连接设备…"
        let idleTimerWasDisabled = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        defer {
            UIApplication.shared.isIdleTimerDisabled = idleTimerWasDisabled
            busy = false; activity = ""
        }
        let pairingPath = pairingURL.path
        let address = host.trimmingCharacters(in: .whitespacesAndNewlines)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try DeviceInstaller.install(pairingPath: pairingPath, host: address, port: number,
                        packagePath: url.path, bundleID: bundleID) { stage, fraction in
                            DispatchQueue.main.async {
                                self.activity = stage
                                progress(stage, fraction)
                            }
                        }
                    continuation.resume(returning: ())
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    func importPairing(from url: URL) {
        guard !busy else { return }
        do {
            let data = try readSelectedFile(url)
            _ = try savePairing(data)
        } catch { message = "导入配对失败：\(error.localizedDescription)" }
    }

    func createPairingOnDevice() {
        guard !busy else { return }
        guard #available(iOS 27.0, *) else {
            message = "创建配对需要 iOS 27 或更高版本，请导入配对文件。"
            return
        }
        busy = true
        activity = "正在配对，请在配对页面完成操作…"
        pairingController.start { [weak self] result in
            guard let self else { return }
            defer { busy = false; activity = "" }
            if case .success(let data) = result {
                do {
                    _ = try savePairing(data)
                    pairingController.reportSaveResult(nil)
                } catch { pairingController.reportSaveResult(error) }
            }
        }
    }

    private func savePairing(_ data: Data) throws -> PairingRecordKind {
        let kind = try PairingRecord.kind(of: data)
        try data.write(to: pairingURL, options: [.atomic, .completeFileProtection])
        var protectedURL = pairingURL
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try protectedURL.setResourceValues(values)
        hasPairing = true
        return kind
    }

    func pairingDataForExport() throws -> Data {
        let data = try Data(contentsOf: pairingURL)
        _ = try PairingRecord.kind(of: data)
        return data
    }

    func removePairing() {
        guard !busy else { return }
        do {
            if FileManager.default.fileExists(atPath: pairingURL.path) { try FileManager.default.removeItem(at: pairingURL) }
            hasPairing = false
        } catch { message = error.localizedDescription }
    }

    private func readSelectedFile(_ url: URL) throws -> Data {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        return try Data(contentsOf: url)
    }

    private func merge(_ apps: [InstalledApp], origin: String) {
        let previous = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) })
        records = ignoredApps.visible(apps.map { app in
            var record = previous[app.id] ?? AppRecord(installed: app)
            record.installed = app
            return record
        })
        scannedAt = Date()
        inventoryOrigin = origin
        persist()
    }

    func ignoreApp(_ id: String) {
        guard !busy, let record = records.first(where: { $0.id == id }) else { return }
        ignoredApps.ignore(record.installed, iconURL: record.release?.iconURL)
        saveIgnoredApps()
        records = ignoredApps.visible(records)
        queryWarning = ""
        persist()
    }

    func restoreApp(_ id: String) {
        guard !busy else { return }
        ignoredApps.restore(id)
        saveIgnoredApps()
    }

    private func saveIgnoredApps() {
        do { UserDefaults.standard.set(try JSONEncoder().encode(ignoredApps), forKey: "ignoredApplications") }
        catch { message = "保存忽略名单失败：\(error.localizedDescription)" }
    }

    func checkUpdates(only id: String? = nil, force: Bool = false) {
        guard !busy else { return }
        let targets = records.filter { !$0.installed.isSystem }
        // Explicit selection includes system apps; default excludes apps updated with iOS.
        let ids = id.map { [$0] } ?? targets.map(\.id)
        guard !ids.isEmpty else {
            if records.isEmpty { message = "请先读取应用。" }
            return
        }
        let region = country
        let refresh = force || id != nil
        let selected = records.filter { ids.contains($0.id) }
        let cached = selected.filter { !refresh && $0.error == nil && AppleLookup.isFresh($0.release, country: region) }
        let cachedIDs = Set(cached.map(\.id))
        let pending = selected.filter { !cachedIDs.contains($0.id) }
        let batches = AppleLookup.batches(bundleIDs: pending.map(\.effectiveBundleID))
        var knownStoreIDs: [String: String] = [:]
        for record in pending {
            if let storeID = record.release?.storeID ?? (record.lookupBundleID == nil ? record.installed.storeID : nil) {
                knownStoreIDs[record.effectiveBundleID] = storeID
            }
        }
        busy = true
        isChecking = true
        recordMatches(cached, scope: region)
        queryWarning = ""
        checkTask = Task {
            var failures = 0
            var warning: String?
            defer {
                var warnings: [String] = []
                if failures > 0 { warnings.append("有 \(failures) 个应用未取得商店版本。") }
                if let warning { warnings.append(warning) }
                queryWarning = warnings.joined(separator: "\n")
                busy = false; isChecking = false; activity = ""; checkTask = nil; persist()
            }
            for bundles in batches {
                if Task.isCancelled { break }
                // Throttle batches rather than sleeping once per app.
                let wait = nextLookupAt.timeIntervalSinceNow
                if wait > 0 { do { try await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) } catch { break } }
                if Task.isCancelled { break }
                nextLookupAt = Date().addingTimeInterval(3.2)
                do {
                    let batch = try await AppleLookup.fetchForScope(bundleIDs: bundles, scope: region, knownStoreIDs: knownStoreIDs)
                    if Task.isCancelled { break }
                    warning = batch.catalogWarning ?? warning
                    for index in records.indices where ids.contains(records[index].id) && bundles.contains(records[index].effectiveBundleID) {
                        let release = batch.releases[records[index].effectiveBundleID]
                        // Preserve a previous success on a failed lookup, clearly marked.
                        if let release { records[index].release = release }
                        records[index].error = release == nil ? (batch.errors[records[index].effectiveBundleID] ?? StoreQueryPolicy.notFoundMessage(scope: region)) : nil
                        records[index].checkedAt = Date()
                        recordMatches([records[index]], scope: region)
                        if release == nil { failures += 1 }
                    }
                    persist()
                    if batch.stopAfterBatch {
                        message = "美国商店请求受限，已停止查询并保留中国大陆结果。请稍后重试。"
                        break
                    }
                } catch is CancellationError { break }
                catch {
                    if Task.isCancelled { break }
                    for index in records.indices where ids.contains(records[index].id) && bundles.contains(records[index].effectiveBundleID) {
                        records[index].error = error.localizedDescription
                        records[index].checkedAt = Date()
                        recordMatches([records[index]], scope: region)
                        failures += 1
                    }
                    // A rate-limit response should end the batch instead of hammering the service.
                    if case LookupError.http(429) = error {
                        message = "Apple 请求受限，已停止查询并保留结果。请稍后重试。"
                        break
                    }
                }
            }
        }
    }

    private func recordMatches(_ records: [AppRecord], scope: String) {
        guard var progress = matchProgress, progress.scope == scope else { return }
        for record in records { progress.complete(record) }
        matchProgress = progress
        revealMatches()
    }

    private func stopRevealingMatches() {
        revealTask?.cancel()
        revealTask = nil
        revealTaskID = nil
    }

    private func revealMatches() {
        guard revealTask == nil, let progress = matchProgress, progress.hasUnrevealed else { return }
        let session = progress.id
        let taskID = UUID()
        revealTaskID = taskID
        revealTask = Task {
            defer {
                if revealTaskID == taskID { revealTask = nil; revealTaskID = nil }
            }
            while !Task.isCancelled {
                guard let progress = matchProgress, progress.id == session, progress.hasUnrevealed else { return }
                do { try await Task.sleep(for: .milliseconds(24)) } catch { return }
                guard !Task.isCancelled, revealTaskID == taskID,
                      var next = matchProgress, next.id == session else { return }
                next.revealNext(hidingSystemApps: !UserDefaults.standard.bool(forKey: "includeSystemApps"))
                // One transaction publishes one prefix: application count, update
                // count, pending count, failures, and row badges change together.
                withAnimation(.linear(duration: 0.024)) { matchProgress = next }
            }
        }
    }

    func cancelCheck() {
        checkTask?.cancel()
        stopRevealingMatches()
    }


    private func persist() {
        do {
            let saved = SavedInventory(records: records, scannedAt: scannedAt, origin: inventoryOrigin)
            try JSONEncoder().encode(saved).write(to: storage, options: [.atomic, .completeFileProtection])
        } catch { message = "保存记录失败：\(error.localizedDescription)" }
    }
}

private struct SavedInventory: Codable {
    var records: [AppRecord]
    var scannedAt: Date?
    var origin: String
}


