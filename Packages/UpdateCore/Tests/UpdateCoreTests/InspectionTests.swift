import XCTest
@testable import UpdateCore

final class InspectionTests: XCTestCase {
    func testDeviceResultPreservesNestedValuesAndBinaryDescription() throws {
        let data = Data(#"{"value":{"enabled":true,"bytes":1234,"Entitlements":{"application-identifier":"TEAM.app"},"binary":{"类型":"二进制","字节数":20},"absent":null},"files":[{"name":"report.ips","path":"/cache/report.ips"}],"entries":[{"name":"Documents","path":"/Documents"}],"message":null}"#.utf8)
        let result = try JSONDecoder().decode(InspectionResult.self, from: data)
        XCTAssertEqual(result.value["enabled"], .bool(true))
        XCTAssertEqual(result.value["bytes"], .number(1234))
        XCTAssertEqual(result.value["Entitlements"]?["application-identifier"]?.string, "TEAM.app")
        XCTAssertEqual(result.value["absent"], .null)
        XCTAssertEqual(result.files.first?.name, "report.ips")
        XCTAssertEqual(result.entries.first?.path, "/Documents")
        XCTAssertEqual(try JSONDecoder().decode(InspectionResult.self, from: JSONEncoder().encode(result)).value, result.value)
    }

    func testSnapshotTracksIdentifiersEvenWhenICBCBundleFieldsRemainUnchanged() {
        let old = InstalledApp(bundleID: "com.icbc.iphoneclient", name: "工行", version: "3.1.40", build: "1.2", externalVersionID: "891257769")
        var new = old; new.externalVersionID = "891999999"
        let date = Date(timeIntervalSince1970: 123)
        let events = InventoryHistory.changes(previous: [old], current: [new], at: date)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.kind, "版本标识变化")
        XCTAssertEqual(events.first?.before, "891257769")
        XCTAssertEqual(events.first?.after, "891999999")
        XCTAssertEqual(events.first?.date, date)
    }

    func testSnapshotDoesNotTreatMissingIdentifiersOrInitialScanAsAnUpdate() {
        let old = InstalledApp(bundleID: "a", name: "a", version: "1", externalVersionID: "123")
        var missing = old; missing.externalVersionID = nil; missing.version = "2"
        XCTAssertTrue(InventoryHistory.changes(previous: [old], current: [missing]).isEmpty)
        XCTAssertTrue(InventoryHistory.changes(previous: [], current: [old]).isEmpty)
        XCTAssertTrue(InventoryHistory.changes(previous: [old], current: [old]).isEmpty)
    }

    func testSnapshotAddedAndRemovedAreDiscoveryEvents() {
        let a = InstalledApp(bundleID: "a", name: "旧应用", version: "1")
        let b = InstalledApp(bundleID: "b", name: "新应用", version: "1")
        let events = InventoryHistory.changes(previous: [a], current: [b])
        XCTAssertEqual(Set(events.map(\.kind)), ["发现新增应用", "清单中已移除"])
        XCTAssertEqual(Set(events.map(\.bundleID)), ["a", "b"])
    }
}
