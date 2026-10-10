import XCTest
import HelperKit

final class HelperAccessTests: XCTestCase {
    func testStandardUserDeniedEvenWithTrustedApp() {
        XCTAssertFalse(HelperAccess.allows(uid: 501, administratorMembership: { _ in false }))
    }
    func testAdministratorAllowedAndActualUIDUsed() {
        var checked: UInt32?
        XCTAssertTrue(HelperAccess.allows(uid: 502, administratorMembership: { checked = $0; return true }))
        XCTAssertEqual(checked, 502)
    }
    func testRootDoesNotDependOnDirectoryService() {
        XCTAssertTrue(HelperAccess.allows(uid: 0, administratorMembership: { _ in XCTFail("Unexpected lookup"); return false }))
    }
    func testSystemDaemonIsNotAnAdministrator() {
        XCTAssertFalse(HelperAccess.isAdministrator(1))
    }
    func testUnknownAccountFailsClosed() {
        XCTAssertFalse(HelperAccess.isAdministrator(UInt32.max - 1))
    }
}
