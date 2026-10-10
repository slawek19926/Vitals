import XCTest
@testable import Vitals

final class RelatedAppFilesTests: XCTestCase {
    func testRejectsMissingAndTraversingMetadata() {
        for bad in ["", " ", ".", "..", "../Documents", "a/b", "a\\b"] {
            XCTAssertTrue(RelatedAppFiles.candidates(home: "/tmp/home", name: "App", bundleID: bad).isEmpty)
            XCTAssertTrue(RelatedAppFiles.candidates(home: "/tmp/home", name: bad, bundleID: "org.test.app").isEmpty)
        }
    }
    func testNormalPathsAndEscapingSymlink() throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let caches = home.appendingPathComponent("Library/Caches")
        try fm.createDirectory(at: caches, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: home) }
        let link = caches.appendingPathComponent("org.test.app")
        XCTAssertTrue(RelatedAppFiles.candidates(home: home.path, name: "App", bundleID: "org.test.app").contains(link.path))
        try fm.createSymbolicLink(at: link, withDestinationURL: home)
        XCTAssertFalse(RelatedAppFiles.candidates(home: home.path, name: "App", bundleID: "org.test.app").contains(link.path))
    }
}
