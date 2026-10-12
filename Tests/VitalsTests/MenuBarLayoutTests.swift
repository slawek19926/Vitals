import AppKit
import XCTest
@testable import Vitals

final class MenuBarLayoutTests: XCTestCase {
    private func withSavedPreferences(_ body: (UserDefaults) throws -> Void) rethrows {
        let defaults = UserDefaults.standard
        let keys = ["menuBarStyle", "menuBarPopoverStyle", "menuBarNetworkLayout", "menuBarDetailed", "language", "fahrenheit"]
        let previous = keys.map { ($0, defaults.object(forKey: $0)) }
        defer {
            for (key, value) in previous {
                if let value { defaults.set(value, forKey: key) }
                else { defaults.removeObject(forKey: key) }
            }
        }
        try body(defaults)
    }

    func testCollapsedModulesAlwaysShowValuesEvenWithLegacyGraphPreferences() throws {
        _ = NSApplication.shared
        try withSavedPreferences { defaults in
            defaults.set(0, forKey: "menuBarNetworkLayout")
            defaults.set(WidgetKind.allCases.map(\.rawValue), forKey: "menuBarDetailed")
            for kind in WidgetKind.allCases {
                let target = NSObject()
                let module = MenuBarModule(kind: kind, target: target, action: #selector(NSObject.description))
                defer { module.remove() }
                let button = try XCTUnwrap(module.item.button)
                for style in ModulePopoverStyle.allCases {
                    defaults.set(style.rawValue, forKey: "menuBarStyle")
                    defaults.set(style.rawValue, forKey: "menuBarPopoverStyle")
                    module.applyLength()
                    module.update(Snapshot())
                    let image = try XCTUnwrap(button.image)
                    XCTAssertTrue(image.isTemplate, kind.rawValue)
                    XCTAssertEqual(image.accessibilityDescription, kind.title)
                    XCTAssertEqual(button.attributedTitle.string, kind.menuBarText(Snapshot()))
                    XCTAssertEqual(button.imagePosition, .imageLeading)
                    XCTAssertLessThanOrEqual(try XCTUnwrap(button.cell).cellSize.width, module.item.length)
                }
            }
        }
    }

    func testNetworkLayoutSwitchingKeepsBothRatesAndFixedWidth() throws {
        _ = NSApplication.shared
        try withSavedPreferences { defaults in
            let target = NSObject()
            let module = MenuBarModule(kind: .network, target: target, action: #selector(NSObject.description))
            defer { module.remove() }
            let button = try XCTUnwrap(module.item.button)
            for layout in [NetworkMenuBarLayout.twoRows, .singleRow, .twoRows] {
                defaults.set(layout.rawValue, forKey: "menuBarNetworkLayout")
                module.applyLength()
                let width = module.item.length
                for style in ModulePopoverStyle.allCases {
                    defaults.set(style.rawValue, forKey: "menuBarPopoverStyle")
                    for rate in [0.0, 999, 1000, 1024, 999_999, 1_048_576, 1_073_741_824, 1_099_511_627_776] {
                        var snapshot = Snapshot()
                        snapshot.net.rxRate = rate
                        snapshot.net.txRate = 2048
                        module.applyLength()
                        module.update(snapshot)
                        let image = try XCTUnwrap(button.image)
                        XCTAssertTrue(image.isTemplate)
                        XCTAssertEqual(module.item.length, width)
                        XCTAssertTrue(button.toolTip?.contains(Fmt.rate(rate)) == true)
                        XCTAssertTrue(button.toolTip?.contains(Fmt.rate(2048)) == true)
                        if layout == .twoRows {
                            XCTAssertEqual(button.imagePosition, .imageOnly)
                            XCTAssertEqual(button.attributedTitle.string, "")
                            XCTAssertEqual(image.size, NetworkMenuBarDisplay.size)
                            XCTAssertTrue(image.accessibilityDescription?.contains(Fmt.rate(rate)) == true)
                            XCTAssertTrue(image.accessibilityDescription?.contains(Fmt.rate(2048)) == true)
                            XCTAssertLessThanOrEqual(try XCTUnwrap(button.cell).cellSize.width, width)
                            XCTAssertLessThan(width, image.size.width + 12)
                        } else {
                            XCTAssertEqual(button.imagePosition, .imageLeading)
                            XCTAssertEqual(button.attributedTitle.string, WidgetKind.network.menuBarText(snapshot))
                        }
                    }
                }
            }
        }
    }

    func testTwoRowsFitNativeMenuBarAndRenderAcrossUnits() throws {
        let size = NetworkMenuBarDisplay.size
        XCTAssertLessThanOrEqual(size.height, 22)
        XCTAssertLessThan(size.width, 100)
        for rate in [0.0, 999, 1000, 1024, 999_999, 1_048_576, 1_073_741_824, 1_099_511_627_776] {
            let rows = NetworkMenuBarDisplay.rows(download: rate, upload: 2048)
            XCTAssertEqual(rows, ["↓ " + Fmt.rate(rate), "↑ " + Fmt.rate(2048)])
            for row in rows {
                let measured = NSAttributedString(string: row, attributes: [.font: NetworkMenuBarDisplay.font]).size()
                XCTAssertLessThanOrEqual(measured.width, size.width)
                XCTAssertLessThanOrEqual(measured.height, NetworkMenuBarDisplay.rowHeight)
            }
            let image = NetworkMenuBarDisplay.image(download: rate, upload: 2048)
            XCTAssertEqual(image.size, size)
            XCTAssertTrue(image.isTemplate)
            let representation = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation)))
            XCTAssertGreaterThan(representation.pixelsWide, 0)
            XCTAssertGreaterThan(representation.pixelsHigh, 0)
        }
    }

    func testDefaultsPreserveSingleRowAndBothInExpandedPanel() {
        withSavedPreferences { defaults in
            defaults.removeObject(forKey: "menuBarNetworkLayout")
            defaults.removeObject(forKey: "menuBarPopoverStyle")
            XCTAssertEqual(Prefs.shared.menuBarNetworkLayout, .singleRow)
            for oldStyle in 0...2 {
                defaults.set(oldStyle, forKey: "menuBarStyle")
                XCTAssertEqual(Prefs.shared.menuBarPopoverStyle, .both)
            }
            defaults.set(999, forKey: "menuBarNetworkLayout")
            defaults.set(999, forKey: "menuBarPopoverStyle")
            XCTAssertEqual(Prefs.shared.menuBarNetworkLayout, .singleRow)
            XCTAssertEqual(Prefs.shared.menuBarPopoverStyle, .both)
        }
    }

    func testNetworkLayoutChoicesAreLocalized() {
        withSavedPreferences { defaults in
            for (language, expected) in [(AppLanguage.polish, ["Jeden wiersz", "Dwa wiersze"]),
                                         (.english, ["One row", "Two rows"]),
                                         (.simplifiedChinese, ["单行", "双行"])] {
                defaults.set(language.rawValue, forKey: "language")
                XCTAssertEqual(NetworkMenuBarLayout.allCases.map(\.title), expected)
                for key in ["settings.network_layout.label", "settings.network_layout.hint", "settings.menu_bar.panel_content"] {
                    XCTAssertNotEqual(L(key), key)
                }
            }
        }
    }

    func testCompactWidthsFitLongReadingsAndReduceOverallSpace() throws {
        _ = NSApplication.shared
        try withSavedPreferences { defaults in
            defaults.set(0, forKey: "menuBarNetworkLayout")
            var compactWidth: CGFloat = 0
            var oldWidth: CGFloat = 0
            var snapshot = Snapshot()
            snapshot.cpu.total = 100
            snapshot.mem.total = 100
            snapshot.mem.used = 100
            snapshot.gpu.device = 100
            snapshot.temps = [Sensor(name: "Tp00", value: 160)]
            snapshot.net.rxRate = 1_073_741_824
            snapshot.net.txRate = 1_099_511_627_776
            snapshot.disk.readRate = 1_073_741_824
            snapshot.power.sysWatts = 999.9
            for kind in WidgetKind.allCases {
                let target = NSObject()
                let module = MenuBarModule(kind: kind, target: target, action: #selector(NSObject.description))
                defer { module.remove() }
                let button = try XCTUnwrap(module.item.button)
                let width = module.item.length
                compactWidth += width
                oldWidth += kind == .network ? kind.menuBarWidth + 29 : (kind == .disk || kind == .power ? 84 : 62)
                for fahrenheit in [false, true] {
                    defaults.set(fahrenheit, forKey: "fahrenheit")
                    module.update(snapshot)
                    let required = try XCTUnwrap(button.cell).cellSize.width
                    XCTAssertLessThanOrEqual(required, width, "\(kind.rawValue): \(required) > \(width)")
                    XCTAssertEqual(module.item.length, width)
                }
            }
            XCTAssertLessThan(compactWidth, oldWidth)
        }
    }

    func testNetworkWidthAndUploadPositionStayStableAcrossUnits() {
        let values: [Double] = [0, 9, 99, 999, 1000, 1024, 10_240, 102_400, 1_023_990, 1_048_576, 1_073_741_824]
        let kind = WidgetKind.network
        var widths: [CGFloat] = []
        var arrowOffsets: [CGFloat] = []
        for value in values {
            var snapshot = Snapshot()
            snapshot.net.rxRate = value
            snapshot.net.txRate = 123
            let text = kind.menuBarText(snapshot)
            let attributes: [NSAttributedString.Key: Any] = [.font: kind.menuBarFont]
            let width = NSAttributedString(string: text, attributes: attributes).size().width
            widths.append(width)
            let prefix = String(text.prefix(while: { $0 != "↑" }))
            arrowOffsets.append(NSAttributedString(string: prefix, attributes: attributes).size().width)
            XCTAssertLessThanOrEqual(width, kind.menuBarWidth)
        }
        XCTAssertLessThan((widths.max() ?? 0) - (widths.min() ?? 0), 0.01)
        XCTAssertLessThan((arrowOffsets.max() ?? 0) - (arrowOffsets.min() ?? 0), 0.01)
    }
}
