import Foundation
import XCTest
@testable import UpdateCore

final class FileContentPreviewTests: XCTestCase {
    func testBinaryPlistSupportsKeyValuesWithoutConfusingIntegersAndBooleans() throws {
        let data = try PropertyListSerialization.data(fromPropertyList: ["count": 1, "enabled": true, "token": Data([1, 2, 3])], format: .binary, options: 0)
        let preview = FileContentPreview.make(data: data, fileExtension: "plist")
        XCTAssertEqual(preview.structured?["count"], .number(1))
        XCTAssertEqual(preview.structured?["enabled"], .bool(true))
        XCTAssertEqual(preview.structured?["token"]?["字节数"], .number(3))
        XCTAssertTrue(preview.text?.contains("<key>count</key>") == true)
    }
    func testTextBinaryAndUTF16Contents() {
        XCTAssertEqual(FileContentPreview.make(data: Data("hello\n世界".utf8)).text, "hello\n世界")
        let binary = FileContentPreview.make(data: Data([0x00, 0xff, 0x01]))
        XCTAssertNil(binary.text); XCTAssertTrue(binary.hex.contains("00 FF 01"))
        XCTAssertNil(FileContentPreview.make(data: Data([0xff])).text)
        let utf16 = Data([0xff, 0xfe]) + "你好".data(using: .utf16LittleEndian)!
        XCTAssertEqual(FileContentPreview.make(data: utf16).text, "你好")
        XCTAssertEqual(FileContentPreview.make(data: Data()).text, "")
    }
    func testLargeFilePreviewIsBoundedAndDoesNotSplitUTF8Scalars() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let data = Data(String(repeating: "你", count: FileContentPreview.maximumBytes / 3 + 20).utf8)
        try data.write(to: root)
        let result = try FileContentPreview.load(root)
        XCTAssertTrue(result.truncated)
        XCTAssertEqual(result.bytesShown, FileContentPreview.maximumBytes)
        XCTAssertFalse(result.text?.contains("\u{fffd}") ?? true)
        XCTAssertLessThanOrEqual(result.hex.split(separator: "\n").count, 1024)
    }
    func testRemotePathKeepsNamesInsideTheChosenDirectory() {
        XCTAssertEqual(RemoteFilePath.child("settings.plist", of: "/Library/Preferences"), "/Library/Preferences/settings.plist")
        XCTAssertEqual(RemoteFilePath.child("a%2Fb", of: "/"), "/a%2Fb")
        XCTAssertNil(RemoteFilePath.child("../escape", of: "/Documents"))
        XCTAssertNil(RemoteFilePath.child("..", of: "/Documents"))
        XCTAssertNil(RemoteFilePath.child("file", of: "/Documents/../Library"))
        XCTAssertNil(RemoteFilePath.child("file", of: "relative"))
        XCTAssertNil(RemoteFilePath.child("file\0name", of: "/"))
    }
    func testOldDirectoryReportsRemainDecodable() throws {
        let entry = try JSONDecoder().decode(RemoteInspectionEntry.self, from: Data(#"{"name":"file","path":"/file"}"#.utf8))
        XCTAssertNil(entry.isDirectory); XCTAssertNil(entry.size)
    }
    func testLocalPreviewDoesNotFollowSymbolicLinksOrOpenDirectories() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("target.txt"), link = root.appendingPathComponent("link")
        try Data("original".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        XCTAssertEqual(try FileContentPreview.load(target).text, "original")
        XCTAssertThrowsError(try FileContentPreview.load(link))
        XCTAssertThrowsError(try FileContentPreview.load(root))
    }
}
