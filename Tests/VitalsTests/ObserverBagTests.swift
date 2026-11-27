import XCTest
@testable import Vitals

final class ObserverBagTests: XCTestCase {
    func testObserverBagUnregistersOnDeinit() {
        let name = Notification.Name("ObserverBagTests.deinit.\(UUID().uuidString)")
        var count = 0
        var bag: ObserverBag? = ObserverBag()
        bag?.observe(name, queue: nil) { _ in count += 1 }

        NotificationCenter.default.post(name: name, object: nil)
        XCTAssertEqual(count, 1)

        bag = nil
        NotificationCenter.default.post(name: name, object: nil)
        XCTAssertEqual(count, 1)
    }

    func testCriticalThermalStateUsesLocalizationCatalog() {
        var snapshot = Snapshot()
        snapshot.thermalState = .critical
        XCTAssertEqual(snapshot.thermalText, L("krytyczna"))
    }
}
