import Foundation
import SwiftUI
import UpdateCore

enum PairingMode: String, CaseIterable, Identifiable {
    case remote = "Remote Pairing"
    case classic = "传统 Lockdown"
    var id: String { rawValue }
    var defaultPort: String { self == .remote ? "49152" : "62078" }
}

@MainActor
final class AppModel: ObservableObject {
    @Published var records: [AppRecord] = []
    @Published var busy = false
    @Published var activity = ""
    @Published var isChecking = false
    @Published var message: String?
    @Published var scannedAt: Date?
    @Published var inventoryOrigin = "尚未读取"
    @Published var hasPairing = false
    @Published var iconRevision = 0
    @Published var iconReadSummary = ""
    @Published var checkSummary = ""
    @Published var country: String { didSet { UserDefaults.standard.set(country, forKey: "country") } }
    @Published var host: String { didSet { UserDefaults.standard.set(host, forKey: "host") } }
    @Published var port: String { didSet { UserDefaults.standard.set(port, forKey: "port") } }
    @Published var mode: PairingMode {
        didSet {
            UserDefaults.standard.set(mode.rawValue, forKey: "pairingMode")
            port = mode.defaultPort
        }
    }
    private var checkTask: Task<Void, Never>?
    private var nextLookupAt = Date.distantPast
    private let storage: URL
    let iconsDirectory: URL
    let pairingURL: URL
    let rawInventoryURL: URL
    let pairingController = OnDevicePairingController()

    init() {
        let prefs = UserDefaults.standard
        country = prefs.string(forKey: "country") ?? "cn"
        host = prefs.string(forKey: "host") ?? "10.7.0.1"
        mode = PairingMode(rawValue: prefs.string(forKey: "pairingMode") ?? "") ?? .remote
        port = prefs.string(forKey: "port") ?? "49152"
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ssstore", isDirectory: true)
        storage = folder.appendingPathComponent("inventory.json")
        iconsDirectory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ssstore-icons", isDirectory: true)
        pairingURL = folder.appendingPathComponent("device-pairing.plist")
        rawInventoryURL = folder.appendingPathComponent("device-inventory.json")
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: storage.path) {
                let saved = try JSONDecoder().decode(SavedInventory.self, from: Data(contentsOf: storage))
                records = saved.records
                scannedAt = saved.scannedAt
                inventoryOrigin = saved.origin
            }
            hasPairing = FileManager.default.fileExists(atPath: pairingURL.path)
        } catch { message = "读取本地记录失败：\(error.localizedDescription)" }
    }

    func scan() async {
        guard !busy else { return }
        guard hasPairing else { message = "请先在连接设置中创建或导入 Remote Pairing 文件。"; return }
        guard let number = UInt16(port), number > 0 else { message = "端口应在 1 到 65535 之间。"; return }
        busy = true
        activity = "正在连接本机并读取应用…"
        defer { busy = false; activity = "" }
        let path = pairingURL.path
        let address = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let remote = mode == .remote
        let iconsPath = iconsDirectory.path
        do {
            let _: Data = try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        let data = try DeviceScanner.scan(pairingPath: path, host: address, port: number, remotePairing: remote,
                            iconsDirectory: iconsPath, inventory: { data in
                                DispatchQueue.main.async {
                                    do {
                                        let apps = try InventoryParser.parse(data)
                                        try data.write(to: self.rawInventoryURL, options: [.atomic, .completeFileProtection])
                                        self.merge(apps, origin: "本机读取")
                                    }
                                    catch { self.message = error.localizedDescription }
                                }
                            }, progress: { text in
                                DispatchQueue.main.async {
                                    self.activity = text
                                    self.iconReadSummary = text
                                    self.iconRevision += 1
                                }
                            })
                        continuation.resume(returning: data)
                    }
                    catch { continuation.resume(throwing: error) }
                }
            }
        } catch { message = error.localizedDescription }
    }

    func localIconURL(for app: InstalledApp) -> URL? {
        guard let key = app.localIconKey, key.count == 64,
              key.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { return nil }
        return iconsDirectory.appendingPathComponent(key).appendingPathExtension("png")
    }

    func importPairing(from url: URL) {
        guard !busy else { return }
        do {
            let data = try readSelectedFile(url)
            let kind = try savePairing(data)
            if kind == .lockdown {
                message = "已导入传统配对文件。iOS 26.4 及更新系统的回环通常需要 Remote Pairing，请重新导出相应文件。"
            }
        } catch { message = "导入配对失败：\(error.localizedDescription)" }
    }

    func createPairingOnDevice() {
        guard !busy else { return }
        guard #available(iOS 27.0, *) else {
            message = "手机端创建配对需要 iOS 27 或更新版本。当前系统请使用导入功能。"
            return
        }
        busy = true
        activity = "正在创建手机配对，请在连接设置中完成确认…"
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
        mode = kind == .remote ? .remote : .classic
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

    func importInventory(from url: URL) {
        guard !busy else { return }
        do { merge(try InventoryParser.parse(readSelectedFile(url)), origin: "文件快照（记录为导入时间）") }
        catch { message = "导入清单失败：\(error.localizedDescription)" }
    }

    private func readSelectedFile(_ url: URL) throws -> Data {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        return try Data(contentsOf: url)
    }

    private func merge(_ apps: [InstalledApp], origin: String) {
        let previous = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) })
        records = apps.map { app in
            var record = previous[app.id] ?? AppRecord(installed: app)
            record.installed = app
            return record
        }
        scannedAt = Date()
        inventoryOrigin = origin
        persist()
    }

    func setMapping(id: String, bundleID: String) {
        guard !busy, let index = records.firstIndex(where: { $0.id == id }) else { return }
        let value = bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        records[index].lookupBundleID = value.isEmpty ? nil : value
        records[index].release = nil
        records[index].checkedAt = nil
        records[index].error = nil
        persist()
    }

    func checkUpdates(only id: String? = nil, force: Bool = false) {
        guard !busy else { return }
        let targets = records.filter { !$0.installed.isSystem }
        // Explicit selection includes system apps; default excludes apps updated with iOS.
        let ids = id.map { [$0] } ?? targets.map(\.id)
        guard !ids.isEmpty else { message = "请先读取或导入应用清单。"; return }
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
        checkSummary = ""
        checkTask = Task {
            let started = Date()
            var completed = cached.count
            var failures = 0
            var warning: String?
            defer {
                checkSummary = "\(Task.isCancelled ? "已停止" : "本轮检查")：\(completed)/\(ids.count) · 缓存 \(cached.count) · 未取得 \(failures) · \(String(format: "%.1f", Date().timeIntervalSince(started))) 秒"
                if let warning { checkSummary += "\n" + warning }
                busy = false; isChecking = false; activity = ""; checkTask = nil; persist()
            }
            for (offset, bundles) in batches.enumerated() {
                if Task.isCancelled { break }
                activity = "批量查询 \(offset + 1)/\(batches.count) · 已完成 \(completed)/\(ids.count)"
                // Throttle batches rather than sleeping once per app.
                let wait = nextLookupAt.timeIntervalSinceNow
                if wait > 0 { do { try await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) } catch { break } }
                if Task.isCancelled { break }
                nextLookupAt = Date().addingTimeInterval(3.2)
                do {
                    let batch = try await AppleLookup.fetchBatch(bundleIDs: bundles, country: region, knownStoreIDs: knownStoreIDs)
                    warning = batch.catalogWarning ?? warning
                    for index in records.indices where ids.contains(records[index].id) && bundles.contains(records[index].effectiveBundleID) {
                        let release = batch.releases[records[index].effectiveBundleID]
                        // Preserve a previous success on a failed lookup, clearly marked.
                        if let release { records[index].release = release }
                        records[index].error = release == nil ? LookupError.notFound.localizedDescription : nil
                        records[index].checkedAt = Date()
                        completed += 1
                        if release == nil { failures += 1 }
                    }
                    persist()
                } catch is CancellationError { break }
                catch {
                    if Task.isCancelled { break }
                    for index in records.indices where ids.contains(records[index].id) && bundles.contains(records[index].effectiveBundleID) {
                        records[index].error = error.localizedDescription
                        records[index].checkedAt = Date()
                        completed += 1
                        failures += 1
                    }
                    // A rate-limit response should end the batch instead of hammering the service.
                    if case LookupError.http(429) = error {
                        message = "苹果接口限流，本轮查询已停止，已获得的结果会保留。请稍后重试。"
                        break
                    }
                }
            }
        }
    }

    func cancelCheck() { checkTask?.cancel() }

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
