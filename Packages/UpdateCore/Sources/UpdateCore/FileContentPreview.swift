import Foundation
import CoreFoundation

public enum RemoteFilePath {
    public static func child(_ name: String, of path: String) -> String? {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\0"),
              path.hasPrefix("/"), !path.contains("\0"), !path.split(separator: "/").contains("..") else { return nil }
        let root = path == "/" ? "" : path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return root.isEmpty ? "/" + name : "/" + root + "/" + name
    }
}

public struct FileContentPreview: Sendable {
    public static let maximumBytes = 1024 * 1024
    public let text: String?
    public let hex: String
    public let structured: InspectionValue?
    public let bytesShown: Int
    public let totalBytes: Int64
    public let truncated: Bool

    public static func load(_ file: URL) throws -> Self {
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        guard (attributes[.type] as? FileAttributeType) == .typeRegular else {
            throw NSError(domain: "ssstore.FilePreview", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "仅支持普通文件的内容预览。"])
        }
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        let data = try handle.read(upToCount: maximumBytes) ?? Data()
        return make(data: data, totalBytes: size, fileExtension: file.pathExtension)
    }
    public static func make(data: Data, totalBytes: Int64? = nil, fileExtension: String = "") -> Self {
        let prefix = Data(data.prefix(maximumBytes))
        let total = totalBytes ?? Int64(data.count)
        var structure: InspectionValue?
        var text: String?
        var clipped = total > prefix.count
        if total <= maximumBytes,
           prefix.starts(with: Data("bplist".utf8)) || ["plist", "strings", "entitlements"].contains(fileExtension.lowercased()),
           let value = try? PropertyListSerialization.propertyList(from: prefix, format: nil) {
            var budget = 2000
            structure = convert(value, depth: 0, budget: &budget)
            clipped = clipped || budget <= 0
            if let xml = try? PropertyListSerialization.data(fromPropertyList: value, format: .xml, options: 0) {
                text = String(decoding: xml.prefix(maximumBytes), as: UTF8.self)
                clipped = clipped || xml.count > maximumBytes
            }
        }
        if text == nil {
            if prefix.starts(with: [0xff, 0xfe]) { text = String(data: prefix, encoding: .utf16LittleEndian) }
            else if prefix.starts(with: [0xfe, 0xff]) { text = String(data: prefix, encoding: .utf16BigEndian) }
            else {
                // A prefix may end in the middle of a UTF-8 scalar.
                for trim in 0...(total > prefix.count ? min(3, prefix.count) : 0) {
                    if let candidate = String(data: prefix.dropLast(trim), encoding: .utf8) { text = candidate; break }
                }
            }
            if let value = text, value.unicodeScalars.contains(where: { $0.value < 0x20 && ![9, 10, 13].contains($0.value) }) { text = nil }
            if text?.first == "\u{feff}" { text?.removeFirst() }
        }
        let bytes = Array(prefix.prefix(16 * 1024))
        var lines: [String] = []
        for offset in stride(from: 0, to: bytes.count, by: 16) {
            let chunk = bytes[offset..<min(offset + 16, bytes.count)]
            let hex = chunk.map { String(format: "%02X", $0) }.joined(separator: " ")
            let ascii = chunk.map { (32...126).contains($0) ? String(UnicodeScalar(Int($0))!) : "." }.joined()
            lines.append(String(format: "%08X", offset) + "  " + hex.padding(toLength: 47, withPad: " ", startingAt: 0) + "  " + ascii)
        }
        return Self(text: text, hex: lines.joined(separator: "\n"), structured: structure,
            bytesShown: prefix.count, totalBytes: total, truncated: clipped)
    }
    private static func convert(_ object: Any, depth: Int, budget: inout Int) -> InspectionValue {
        guard depth < 24, budget > 0 else { return .string("更多内容请查看文本或导出文件") }
        budget -= 1
        if let dictionary = object as? [String: Any] {
            var result: [String: InspectionValue] = [:]
            for key in dictionary.keys.sorted() where budget > 0 { result[key] = convert(dictionary[key]!, depth: depth + 1, budget: &budget) }
            return .object(result)
        }
        if let array = object as? [Any] {
            var result: [InspectionValue] = []
            for value in array where budget > 0 { result.append(convert(value, depth: depth + 1, budget: &budget)) }
            return .array(result)
        }
        if let number = object as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return .bool(number.boolValue) }
            return number.doubleValue.isFinite ? .number(number.doubleValue) : .null
        }
        if let string = object as? String { return .string(String(string.prefix(maximumBytes))) }
        if let date = object as? Date { return .string(ISO8601DateFormatter().string(from: date)) }
        if let data = object as? Data { return .object(["类型": .string("二进制"), "字节数": .number(Double(data.count))]) }
        return .null
    }
}
