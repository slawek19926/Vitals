import AppKit
import XCTest
@testable import Vitals

final class MenuBarPopoverTests: XCTestCase {
    private func withSavedPreferences(_ body: () throws -> Void) rethrows {
        _ = NSApplication.shared
        let defaults = UserDefaults.standard
        let keys = ["menuBarPopoverStyle", "menuBarSpanSeconds"]
        let previous = keys.map { ($0, defaults.object(forKey: $0)) }
        defer {
            for (key, value) in previous {
                if let value { defaults.set(value, forKey: key) }
                else { defaults.removeObject(forKey: key) }
            }
        }
        try body()
    }

    private func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }

    func testExpandedPanelsKeepValueAndGraphAndRespondToStyleChanges() throws {
        try withSavedPreferences {
            for kind in WidgetKind.allCases {
                for detailed in [false, true] {
                    Prefs.shared.menuBarPopoverStyle = .both
                    let controller = ModulePopoverController(kind: kind, detailed: detailed)
                    let views = descendants(controller.view)
                    let graph = try XCTUnwrap(views.compactMap { $0 as? GraphView }.first)
                    let value = try XCTUnwrap(views.compactMap { $0 as? NSTextField }.first { $0.font?.pointSize == 20 })
                    for style in [ModulePopoverStyle.both, .graphOnly, .valueOnly, .both] {
                        Prefs.shared.menuBarPopoverStyle = style
                        XCTAssertEqual(graph.isHiddenOrHasHiddenAncestor, style == .valueOnly)
                        XCTAssertEqual(value.isHiddenOrHasHiddenAncestor, style == .graphOnly)
                        XCTAssertEqual(controller.preferredContentSize.width, detailed ? 360 : 330, accuracy: 0.1)
                        XCTAssertGreaterThan(controller.preferredContentSize.height, 0)
                    }
                    Prefs.shared.menuBarSpanSeconds = 120
                    XCTAssertEqual(graph.timeSpan, 120)
                }
            }
        }
    }

    func testExpandedNetworkPanelShowsLiveValueAndBothGraphSeries() throws {
        try withSavedPreferences {
            Prefs.shared.menuBarPopoverStyle = .both
            let controller = ModulePopoverController(kind: .network)
            let window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: 330, height: 300),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = controller.view
            window.orderFront(nil)
            defer { window.orderOut(nil) }
            let views = descendants(controller.view)
            let graph = try XCTUnwrap(views.compactMap { $0 as? GraphView }.first)
            let value = try XCTUnwrap(views.compactMap { $0 as? NSTextField }.first { $0.font?.pointSize == 20 })
            var snapshot = Snapshot()
            snapshot.net.rxRate = 1024
            snapshot.net.txRate = 2048
            NotificationCenter.default.post(name: .snapshotUpdated, object: snapshot)
            XCTAssertEqual(value.stringValue, Fmt.rate(3072))
            XCTAssertFalse(graph.isHidden)
            XCTAssertEqual(graph.seriesCount, 2)
            XCTAssertEqual(graph.lastValue, 1024)
            Prefs.shared.menuBarPopoverStyle = .graphOnly
            snapshot.net.rxRate = 4096
            NotificationCenter.default.post(name: .snapshotUpdated, object: snapshot)
            XCTAssertTrue(value.isHidden)
            XCTAssertEqual(graph.lastValue, 4096)
        }
    }
}
