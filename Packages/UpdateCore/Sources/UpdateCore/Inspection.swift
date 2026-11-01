import Foundation

public enum InspectionOperation: String, CaseIterable, Identifiable, Sendable {
    case services, probe, appDetails, appCapabilities, appStorage, allStorage, profiles
    case documents, container, media, crashes, filesystemInfo, icon
    case homeWallpaper, lockWallpaper, iconMetrics, orientation, screenshot
    case deviceInfo, batteryInfo, diskInfo, diagnostics, batteryDiagnostics, nandDiagnostics, wifiDiagnostics, mobileGestalt, ioRegistry
    case coreApps, coreProcesses, coreFiles, configuration
    case dvtApps, dvtProcesses, dvtHardware, dvtNetwork, dvtKernel, dvtAttributes, dvtScreenshot
    case developerMode, mountedImages, companion
    case fileInfo, fileRead

    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .services: return "广播服务"
        case .probe: return "连接测试"
        case .appDetails: return "应用信息"
        case .appCapabilities: return "应用能力与共享声明"
        case .appStorage: return "应用存储空间"
        case .allStorage: return "全部应用存储空间"
        case .profiles: return "描述文件"
        case .documents: return "共享文档"
        case .container: return "应用容器"
        case .media: return "AFC 媒体目录"
        case .crashes: return "崩溃报告目录"
        case .filesystemInfo: return "文件系统容量"
        case .icon: return "本机应用图标"
        case .homeWallpaper: return "主屏幕墙纸"
        case .lockWallpaper: return "锁定屏幕墙纸"
        case .iconMetrics: return "图标布局参数"
        case .orientation: return "屏幕方向"
        case .screenshot: return "设备截图"
        case .deviceInfo: return "设备信息"
        case .batteryInfo: return "电池信息"
        case .diskInfo: return "存储信息"
        case .diagnostics: return "综合诊断"
        case .batteryDiagnostics: return "电池诊断"
        case .nandDiagnostics: return "存储诊断"
        case .wifiDiagnostics: return "Wi-Fi 诊断"
        case .mobileGestalt: return "硬件能力"
        case .ioRegistry: return "IORegistry 信息"
        case .coreApps: return "CoreDevice 应用列表"
        case .coreProcesses: return "CoreDevice 进程列表"
        case .coreFiles: return "CoreDevice 文件目录"
        case .configuration: return "显示与辅助功能"
        case .dvtApps: return "开发服务应用列表"
        case .dvtProcesses: return "开发服务进程列表"
        case .dvtHardware: return "开发服务硬件信息"
        case .dvtNetwork: return "开发服务网络信息"
        case .dvtKernel: return "内核名称"
        case .dvtAttributes: return "性能采样字段"
        case .dvtScreenshot: return "开发服务截图"
        case .developerMode: return "开发者模式"
        case .mountedImages: return "已挂载开发镜像"
        case .companion: return "伴侣设备"
        case .fileInfo: return "文件属性"
        case .fileRead: return "读取文件"
        }
    }
    public var group: String {
        switch self {
        case .services, .probe: return "服务发现"
        case .appDetails, .appCapabilities, .appStorage, .allStorage: return "应用与存储"
        case .profiles: return "签名与描述文件"
        case .documents, .container, .media, .crashes, .filesystemInfo, .coreFiles, .fileInfo, .fileRead: return "文件与报告"
        case .icon, .homeWallpaper, .lockWallpaper, .iconMetrics, .orientation, .screenshot: return "图标与屏幕"
        case .coreApps, .coreProcesses, .dvtApps, .dvtProcesses, .dvtHardware, .dvtNetwork, .dvtKernel, .dvtAttributes, .dvtScreenshot, .developerMode, .mountedImages: return "开发服务"
        default: return "设备与诊断"
        }
    }
    public var requiresApp: Bool {
        [.appDetails, .appCapabilities, .appStorage, .documents, .container, .icon, .coreFiles].contains(self)
    }
    public var isBrowser: Bool { [.documents, .container, .media, .crashes, .coreFiles].contains(self) }
    public var isFileHelper: Bool { self == .fileInfo || self == .fileRead }
    public var service: String {
        switch self {
        case .services, .probe: return "RSD"
        case .appDetails, .appCapabilities, .appStorage, .allStorage: return "com.apple.mobile.installation_proxy.shim.remote"
        case .profiles: return "com.apple.misagent.shim.remote"
        case .documents, .container: return "com.apple.mobile.house_arrest.shim.remote"
        case .media, .filesystemInfo, .fileInfo, .fileRead: return "com.apple.afc.shim.remote"
        case .crashes: return "com.apple.crashreportcopymobile.shim.remote"
        case .icon, .homeWallpaper, .lockWallpaper, .iconMetrics, .orientation: return "com.apple.springboardservices.shim.remote"
        case .screenshot: return "com.apple.mobile.screenshotr.shim.remote"
        case .deviceInfo, .batteryInfo, .diskInfo: return "com.apple.mobile.lockdown.remote.trusted"
        case .diagnostics, .batteryDiagnostics, .nandDiagnostics, .wifiDiagnostics, .mobileGestalt, .ioRegistry: return "com.apple.mobile.diagnostics_relay.shim.remote"
        case .coreApps, .coreProcesses: return "com.apple.coredevice.appservice"
        case .coreFiles: return "com.apple.coredevice.fileservice.control"
        case .configuration: return "com.apple.coredevice.configuration"
        case .dvtApps, .dvtProcesses, .dvtHardware, .dvtNetwork, .dvtKernel, .dvtAttributes, .dvtScreenshot: return "com.apple.instruments.dtservicehub"
        case .developerMode, .mountedImages: return "com.apple.mobile.mobile_image_mounter.shim.remote"
        case .companion: return "com.apple.companion_proxy.shim.remote"
        }
    }
    public var note: String {
        switch self {
        case .services: return "列出广播的服务及端口，不代表已获访问权限。"
        case .probe: return "测试 15 类服务的连接；具体读取权限需单独验证。"
        case .appCapabilities: return "应用声明的能力，不代表实际隐私授权。"
        case .appStorage, .allStorage: return "统计可能较慢。动态占用不等于可清理缓存。"
        case .profiles: return "解析描述文件，不验证证书信任或撤销状态。"
        case .documents, .container: return "仅浏览设备授权的目录。"
        case .coreFiles: return "仅浏览目录。导出文件请使用共享文档或应用容器。"
        case .iconMetrics: return "读取图标网格参数，不包含完整主屏幕布局。"
        case .coreApps, .coreProcesses, .configuration, .dvtApps, .dvtProcesses, .dvtHardware, .dvtNetwork, .dvtKernel, .dvtAttributes, .dvtScreenshot, .developerMode, .mountedImages: return "可能需要开发环境授权，服务以设备实际提供为准。"
        default: return ""
        }
    }
    public static var menu: [Self] { allCases.filter { !$0.isFileHelper } }
    public static var groups: [String] { menu.reduce(into: []) { if !$0.contains($1.group) { $0.append($1.group) } } }
}

public indirect enum InspectionValue: Codable, Equatable, Sendable {
    case object([String: InspectionValue]), array([InspectionValue]), string(String), number(Double), bool(Bool), null
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode([String: Self].self) { self = .object(v) }
        else { self = .array(try c.decode([Self].self)) }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .object(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }
    public subscript(_ key: String) -> Self? { if case .object(let v) = self { return v[key] }; return nil }
    public var text: String {
        switch self {
        case .string(let v): return v
        case .number(let v): return v.formatted(.number.grouping(.never))
        case .bool(let v): return v ? "是" : "否"
        case .null: return "未返回"
        case .array(let v): return "\(v.count) 项"
        case .object(let v): return "\(v.count) 个字段"
        }
    }
    public var string: String? { if case .string(let v) = self { return v }; return nil }
}

public struct InspectionFile: Codable, Identifiable, Sendable {
    public var path: String
    public var name: String
    public var id: String { path }
}
public struct RemoteInspectionEntry: Codable, Identifiable, Sendable {
    public var name: String
    public var path: String
    public var id: String { path }
}
public struct InspectionResult: Codable, Sendable {
    public var value: InspectionValue
    public var files: [InspectionFile]
    public var entries: [RemoteInspectionEntry]
    public var message: String?
    public var capturedAt: String?
    public var operation: String?
    public var bundleID: String?
    public var requestedPath: String?
}
public struct InspectionReceipt: Codable, Sendable {
    public var date: Date
    public var success: Bool
    public var message: String
    public var reportPath: String?
    public init(date: Date = Date(), success: Bool, message: String, reportPath: String? = nil) {
        self.date = date; self.success = success; self.message = message; self.reportPath = reportPath
    }
}

public struct InventoryEvent: Codable, Identifiable, Sendable {
    public var id: UUID
    public var date: Date
    public var bundleID: String
    public var name: String
    public var kind: String
    public var before: String?
    public var after: String?
}
public enum InventoryHistory {
    // Snapshot differences are discovery times, never claimed installation dates.
    public static func changes(previous: [InstalledApp], current: [InstalledApp], at date: Date = Date()) -> [InventoryEvent] {
        guard !previous.isEmpty else { return [] }
        let old = Dictionary(previous.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        let new = Dictionary(current.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        var events: [InventoryEvent] = []
        for app in current {
            if let prior = old[app.id] {
                if let a = prior.externalVersionID, let b = app.externalVersionID, a != b {
                    events.append(InventoryEvent(id: UUID(), date: date, bundleID: app.id, name: app.name, kind: "版本标识变化", before: a, after: b))
                }
            } else { events.append(InventoryEvent(id: UUID(), date: date, bundleID: app.id, name: app.name, kind: "发现新增应用", before: nil, after: app.externalVersionID)) }
        }
        for app in previous where new[app.id] == nil {
            events.append(InventoryEvent(id: UUID(), date: date, bundleID: app.id, name: app.name, kind: "清单中已移除", before: app.externalVersionID, after: nil))
        }
        return events
    }
}
