import AppKit
import XCTest
@testable import Vitals

final class MenuBarLayoutTests: XCTestCase {
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
