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
    let pairingURL: URL

    init() {
        let prefs = UserDefaults.standard
        country = prefs.string(forKey: "country") ?? "cn"
        host = prefs.string(forKey: "host") ?? "10.7.0.1"
        mode = PairingMode(rawValue: prefs.string(forKey: "pairingMode") ?? "") ?? .remote
        port = prefs.string(forKey: "port") ?? "49152"
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ssstore", isDirectory: true)
        storage = folder.appendingPathComponent("inventory.json")
        pairingURL = folder.appendingPathComponent("device-pairing.plist")
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
        guard hasPairing else { message = "请先在连接设置中导入配对文件。iOS 27.2 请使用 Remote Pairing 格式。"; return }
        guard let number = UInt16(port), number > 0 else { message = "端口应在 1 到 65535 之间。"; return }
        busy = true
        activity = "正在连接本机并读取应用…"
        defer { busy = false; activity = "" }
        let path = pairingURL.path
        let address = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let remote = mode == .remote
        do {
            let data: Data = try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    do { continuation.resume(returning: try DeviceScanner.scan(pairingPath: path, host: address, port: number, remotePairing: remote)) }
                    catch { continuation.resume(throwing: error) }
                }
            }
            merge(try InventoryParser.parse(data), origin: "本机读取")
        } catch { message = error.localizedDescription }
    }

    func importPairing(from url: URL) {
        guard !busy else { return }
        do {
            let data = try readSelectedFile(url)
            guard let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else {
                throw LocalError.message("配对文件必须是 plist。")
            }
            let remote = plist["private_key"] is Data && plist["public_key"] is Data && plist["identifier"] is String
            let classic = plist["HostID"] is String && plist["HostPrivateKey"] is Data
            guard remote || classic else { throw LocalError.message("未识别的配对格式。请从 idevice_pair 导出 Remote Pairing 文件。") }
            try data.write(to: pairingURL, options: [.atomic, .completeFileProtection])
            // Keep device credentials out of cloud backups and the Files browser.
            var protectedURL = pairingURL
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try protectedURL.setResourceValues(values)
            hasPairing = true
            mode = remote ? .remote : .classic
            if !remote {
                message = "已导入传统配对文件。iOS 26.4 及更新系统的回环通常需要 Remote Pairing，请重新导出相应文件。"
            }
        } catch { message = "导入配对失败：\(error.localizedDescription)" }
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

    func checkUpdates(only id: String? = nil) {
        guard !busy else { return }
        let targets = records.filter { !$0.installed.isSystem }
        // Explicit selection includes system apps; default excludes apps updated with iOS.
        let ids = id.map { [$0] } ?? targets.map(\.id)
        guard !ids.isEmpty else { message = "请先读取或导入应用清单。"; return }
        let region = country
        busy = true
        isChecking = true
        checkTask = Task {
            defer { busy = false; isChecking = false; activity = ""; checkTask = nil; persist() }
            for (offset, appID) in ids.enumerated() {
                if Task.isCancelled { break }
                guard let index = records.firstIndex(where: { $0.id == appID }) else { continue }
                activity = "查询 \(offset + 1)/\(ids.count)：\(records[index].installed.name)"
                // About 20 requests/minute, matching Apple's documented approximate limit.
                let wait = nextLookupAt.timeIntervalSinceNow
                if wait > 0 { do { try await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) } catch { break } }
                if Task.isCancelled { break }
                nextLookupAt = Date().addingTimeInterval(3.2)
                do {
                    let release = try await AppleLookup.fetch(bundleID: records[index].effectiveBundleID, country: region)
                    records[index].release = release
                    records[index].error = nil
                    records[index].checkedAt = Date()
                } catch is CancellationError { break }
                catch {
                    if Task.isCancelled { break }
                    records[index].error = error.localizedDescription
                    records[index].checkedAt = Date()
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

private enum LocalError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}
