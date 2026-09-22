import XCTest
@testable import Vitals

final class BluetoothTests: XCTestCase {
    func testUnavailableRSSIIsNotShownAsStrongSignal() {
        XCTAssertNil(BluetoothReading.rssi(127))
        XCTAssertNil(BluetoothReading.rssi(1))
        XCTAssertEqual(BluetoothReading.rssi(-62), -62)
    }

    func testBatteryParserRejectsAmbiguousAndOutOfRangeProducts() throws {
        let entries: [[String: Any]] = [
            ["Product": "Headphones", "BatteryPercent": 62],
            ["Product": "Keyboard", "BatteryPercent": 48],
            ["Product": "Keyboard", "BatteryPercent": 52],
            ["Product": "Broken", "BatteryPercent": 127]
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: entries, format: .xml, options: 0)
        XCTAssertEqual(BluetoothReading.batteries(from: data), ["Headphones": 62])
    }
}
