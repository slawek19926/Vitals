import AppKit
import XCTest
@testable import Vitals

final class MenuBarLayoutTests: XCTestCase {
    func testNetworkKeepsGraphInBothModeAndRespectsOtherStyles() throws {
        // Exercise the real status item rather than only its formatting helpers.
        _ = NSApplication.shared
        let defaults = UserDefaults.standard
        let originalStyle = defaults.object(forKey: "menuBarStyle")
        defer {
            if let originalStyle { defaults.set(originalStyle, forKey: "menuBarStyle") }
            else { defaults.removeObject(forKey: "menuBarStyle") }
        }
        let target = NSObject()
        let module = MenuBarModule(kind: .network, target: target, action: #selector(NSObject.description))
        defer { module.remove() }
        let button = try XCTUnwrap(module.item.button)
        var snapshot = Snapshot()
        snapshot.net.rxRate = 1024
        snapshot.net.txRate = 2048
        for style in [MenuBarStyle.both, .graphOnly, .valueOnly, .both] {
            defaults.set(style.rawValue, forKey: "menuBarStyle")
            module.applyLength()
            module.update(snapshot)
            let image = try XCTUnwrap(button.image)
            if style == .valueOnly {
                XCTAssertTrue(image.isTemplate)
            } else {
                XCTAssertEqual(image.size, NSSize(width: 34, height: 16))
                XCTAssertFalse(image.isTemplate)
            }
            if style == .graphOnly {
                XCTAssertEqual(button.attributedTitle.string, "")
            } else {
                XCTAssertTrue(button.attributedTitle.string.contains("↓"))
                XCTAssertTrue(button.attributedTitle.string.contains("↑"))
                XCTAssertLessThanOrEqual(button.attributedTitle.size().width + image.size.width, module.item.length)
            }
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
            let text = " " + kind.menuBarText(snapshot)
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
