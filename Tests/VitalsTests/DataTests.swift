import XCTest
@testable import Vitals

final class DataTests: XCTestCase {
    func testCSVSeparatesUnavailableMetricsFromRealZero() {
        var sample = HistorySample(time: Date(timeIntervalSince1970: 0), generation: 1, cpuTotal: 0, cpuSystem: 0, memUsed: 10, processCount: 0, top: [])
        sample.gpuUtil = 0
        let format = HistoryExport.Format(separator: ",", decimalComma: false, header: "")
        let cells = HistoryExport.line(sample, format).split(separator: ",", omittingEmptySubsequences: false)
        XCTAssertEqual(cells[10], "") // unavailable system power
        XCTAssertEqual(cells[11], "") // unavailable CPU power
        XCTAssertEqual(cells[12], "0.0") // measured idle GPU
        XCTAssertEqual(cells[13], "") // unavailable temperature
        XCTAssertEqual(cells[14], "") // no battery
    }
    func testCSVPreservesQuotesSeparatorsAndNewlines() {
        XCTAssertEqual(HistoryExport.escapeCell("a,b\"c\nd", separator: ","), "\"a,b\"\"c\nd\"")
        XCTAssertEqual(HistoryExport.escapeCell("a;b", separator: ";"), "\"a;b\"")
    }
    func testScannerCountsFilesAndSkipsSymbolicLinks() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: root.appendingPathComponent("child"), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        try Data(repeating: 1, count: 8192).write(to: root.appendingPathComponent("one"))
        try Data(repeating: 2, count: 8192).write(to: root.appendingPathComponent("child/two"))
        try fm.createSymbolicLink(at: root.appendingPathComponent("loop"), withDestinationURL: root)
        let result = FastScanner.scan(root.path, shouldCancel: { false }, progress: { _, _ in })
        XCTAssertEqual(result.files, 2)
        XCTAssertGreaterThan(result.root.size, 0)
        XCTAssertEqual(result.deniedDirs, 0)
    }
    func testDiskBenchmarkReportsInvalidDestinationAsError() {
        XCTAssertThrowsError(try Bench.disk(dir: "/no-such-vitals-directory", totalMB: 1))
    }
    func testDiskBenchmarkCleansUpOnCancellation() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: root) }
        XCTAssertThrowsError(try Bench.disk(dir: root.path, totalMB: 1, shouldCancel: { true }))
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: root.path), [])
    }
    func testDiskBenchmarkWritesRequestedNonChunkMultiple() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: root) }
        let result = try Bench.disk(dir: root.path, totalMB: 1)
        XCTAssertGreaterThan(result.write, 0)
        XCTAssertGreaterThan(result.read, 0)
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: root.path), [])
    }
}
