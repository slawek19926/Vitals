import XCTest
import HelperKit
@testable import Vitals

final class UpdateTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("VitalsTest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }
    private func directory(_ name: String, contents: String) throws -> URL {
        let url = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try contents.write(to: url.appendingPathComponent("version"), atomically: true, encoding: .utf8)
        return url
    }
    private func version(_ url: URL) throws -> String { try String(contentsOf: url.appendingPathComponent("version")) }
    func testPreserveDownloadOwnsFileBeforeCallbackReturns() throws {
        let temporary = root.appendingPathComponent("URLSession-download")
        try Data("archive".utf8).write(to: temporary)
        let preserved = try UpdateTransaction.preserveDownload(temporary, temporaryDirectory: root)
        XCTAssertFalse(FileManager.default.fileExists(atPath: temporary.path))
        XCTAssertEqual(try Data(contentsOf: preserved.archive), Data("archive".utf8))
    }
    func testSwapWithShellMetacharactersKeepsBackup() throws {
        let dest = try directory("Vitals $(touch INJECTED) ' \" &.app", contents: "old")
        let staged = try directory("stage $HOME.app", contents: "new")
        let work = try directory("work", contents: "archive")
        let backup = root.appendingPathComponent("backup.app")
        let plan = UpdateTransaction(work: work, staged: staged, destination: dest, backup: backup)
        let result = CommandRunner.run("/bin/sh", plan.arguments(waitForPID: 0, launch: false), timeout: 3)
        XCTAssertTrue(result.succeeded, result.failureDescription ?? "")
        XCTAssertEqual(try version(dest), "new")
        XCTAssertEqual(try version(backup), "old")
        XCTAssertFalse(FileManager.default.fileExists(atPath: staged.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: work.path))
    }
    func testFailedSecondRenameRollsBackOldBundle() throws {
        let dest = try directory("Vitals.app", contents: "old")
        // Moving the old destination also moves this nested stage, forcing the second rename to fail.
        let stage = dest.appendingPathComponent("nested-stage.app")
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: false)
        let work = try directory("work", contents: "archive")
        let backup = root.appendingPathComponent("backup.app")
        let plan = UpdateTransaction(work: work, staged: stage, destination: dest, backup: backup)
        let result = CommandRunner.run("/bin/sh", plan.arguments(waitForPID: 0, launch: false), timeout: 3)
        XCTAssertFalse(result.succeeded)
        XCTAssertEqual(try version(dest), "old")
        XCTAssertFalse(FileManager.default.fileExists(atPath: backup.path))
    }
    func testExistingBackupIsNeverOverwritten() throws {
        let dest = try directory("Vitals.app", contents: "old")
        let stage = try directory("stage.app", contents: "new")
        let backup = try directory("backup.app", contents: "previous")
        let work = try directory("work", contents: "archive")
        let plan = UpdateTransaction(work: work, staged: stage, destination: dest, backup: backup)
        XCTAssertFalse(CommandRunner.run("/bin/sh", plan.arguments(waitForPID: 0, launch: false)).succeeded)
        XCTAssertEqual(try version(dest), "old")
        XCTAssertEqual(try version(backup), "previous")
    }
    func testMissingStageDoesNotDeleteInstalledApp() throws {
        let dest = try directory("Vitals.app", contents: "old")
        let work = try directory("work", contents: "archive")
        let plan = UpdateTransaction(work: work, staged: root.appendingPathComponent("missing"), destination: dest, backup: root.appendingPathComponent("backup"))
        XCTAssertFalse(CommandRunner.run("/bin/sh", plan.arguments(waitForPID: 0, launch: false)).succeeded)
        XCTAssertEqual(try version(dest), "old")
    }
}
