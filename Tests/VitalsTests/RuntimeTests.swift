import XCTest
import Security
import HelperKit
import SysCore
@testable import Vitals

final class RuntimeTests: XCTestCase {
    func testSMCNumericDecoderPreservesSignedAndFixedPointReadings() {
        func decoded(_ type: String, _ bytes: [UInt8]) -> Double? {
            var result = 0.0
            let ok = bytes.withUnsafeBufferPointer { buffer in
                sc_smc_decode_numeric(type, Int32(bytes.count), buffer.baseAddress, &result)
            }
            return ok ? result : nil
        }
        XCTAssertEqual(decoded("sp78", [0xff, 0x00]), -1)
        XCTAssertEqual(decoded("fpe2", [0x00, 0x14]), 5)
        XCTAssertEqual(decoded("fp2e", [0x40, 0x00]), 1)
        XCTAssertEqual(decoded("si16", [0xff, 0xfe]), -2)
        XCTAssertEqual(decoded("ui32", [0x00, 0x01, 0x00, 0x00]), 65_536)
        XCTAssertNil(decoded("spg8", [0x00, 0x10]))
        XCTAssertNil(decoded("ch8*", [0x41, 0x42]))
    }

    func testElectricalReadingsRequireAConsistentPowerRail() {
        let result = SMCMeasurements.electrical(
            power: [Sensor(name: "PSTR", value: 9), Sensor(name: "PDTR", value: 10),
                    Sensor(name: "PMVC", value: 3), Sensor(name: "PABC", value: 20),
                    Sensor(name: "PHPB", value: 200)],
            voltage: [Sensor(name: "VMVC", value: 3), Sensor(name: "VABC", value: 2),
                      Sensor(name: "VBUS", value: 16_777_216)],
            current: [Sensor(name: "IMVC", value: 1), Sensor(name: "IABC", value: 1)]
        )
        XCTAssertEqual(result.power.map(\.name), ["PSTR", "PDTR", "PMVC"])
        XCTAssertEqual(result.voltage.map(\.name), ["VMVC"])
        XCTAssertEqual(result.current.map(\.name), ["IMVC"])
        XCTAssertEqual(result.rails, ["MVC"])
        let retained = SMCMeasurements.electrical(
            power: [Sensor(name: "PMVC", value: 6)],
            voltage: [Sensor(name: "VMVC", value: 3)],
            current: [Sensor(name: "IMVC", value: 1)],
            previouslyVerified: result.rails
        )
        XCTAssertEqual(retained.power.map(\.name), ["PMVC"])
    }

    func testCommandFailurePreservesExitStatusAndStderr() {
        let result = CommandRunner.run("/bin/sh", ["-c", "printf output; printf denied >&2; exit 7"])
        XCTAssertFalse(result.succeeded)
        XCTAssertEqual(result.exitCode, 7)
        XCTAssertEqual(result.stdout, "output")
        XCTAssertEqual(result.stderr, "denied")
        XCTAssertEqual(result.failureDescription, "denied")
    }
    func testEmptySuccessfulOutputIsNotFailure() {
        let result = CommandRunner.run("/usr/bin/true", [])
        XCTAssertTrue(result.succeeded)
        XCTAssertNil(result.failureDescription)
    }
    func testMissingExecutableIsFailure() {
        let result = CommandRunner.run("/no-such-vitals-executable", [])
        XCTAssertFalse(result.succeeded)
        XCTAssertNotNil(result.launchError)
    }
    func testBothPipesAreDrainedBeyondPipeCapacity() {
        let result = CommandRunner.run("/bin/sh", ["-c", "i=0; while [ $i -lt 10000 ]; do printf 1234567890; printf abcdefghij >&2; i=$((i + 1)); done"], timeout: 5)
        XCTAssertTrue(result.succeeded, result.failureDescription ?? "")
        XCTAssertEqual(result.stdout.count, 100_000)
        XCTAssertEqual(result.stderr.count, 100_000)
    }
    func testTimeoutWhenChildClosesOutputButKeepsRunning() {
        let start = ProcessInfo.processInfo.systemUptime
        let result = CommandRunner.run("/bin/sh", ["-c", "exec 1>&- 2>&-; exec /bin/sleep 5"], timeout: 0.05)
        XCTAssertTrue(result.timedOut)
        XCTAssertFalse(result.succeeded)
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 2)
    }
    func testTimeoutEscalatesWhenSIGTERMIgnored() {
        let result = CommandRunner.run("/bin/sh", ["-c", "trap '' TERM; while :; do :; done"], timeout: 0.1)
        XCTAssertTrue(result.timedOut)
    }
    func testPeerRequirementIsValidAndRejectsMalformedIdentities() {
        let requirement = PeerTrust.requirement(identifier: PeerTrust.appIdentifier, team: "ABCDE12345")!
        var parsed: SecRequirement?
        XCTAssertEqual(SecRequirementCreateWithString(requirement as CFString, [], &parsed), errSecSuccess)
        XCTAssertNil(PeerTrust.requirement(identifier: "other.app", team: "ABCDE12345"))
        XCTAssertNil(PeerTrust.requirement(identifier: PeerTrust.appIdentifier, team: "NOTEAM"))
        XCTAssertNil(PeerTrust.requirement(identifier: PeerTrust.appIdentifier, team: "\" or true"))
    }
    func testServiceDomainsAreBoundToCaller() {
        for domain in ["system", "gui/501", "user/501"] {
            XCTAssertTrue(ServicePolicy.allows(domain: domain, label: "com.example.service", callerUID: 501))
        }
        for domain in ["gui/502", "user/0", "gui/501/other", "gui/", "system/foo", "user/0501"] {
            XCTAssertFalse(ServicePolicy.allows(domain: domain, label: "com.example.service", callerUID: 501))
        }
        for label in ["", "-x; id", "a/b", "a\nb", String(repeating: "x", count: 256)] {
            XCTAssertFalse(ServicePolicy.allows(domain: "system", label: label, callerUID: 501))
        }
    }
    func testSpecialPIDsAndUnknownIdentityAreRejected() {
        for pid in [-1, 0, 1, Int(Int32.max) + 1] {
            XCTAssertNil(ProcessIdentity(pid: pid, startTimeMicros: 100))
        }
        XCTAssertNil(ProcessIdentity(pid: 100, startTimeMicros: nil))
        XCTAssertNil(ProcessIdentity(pid: 100, startTimeMicros: 0))
    }
    func testReusedPIDIsRejectedEvenWithinSameSecond() {
        let identity = ProcessIdentity(pid: 123, startTimeMicros: 1_000_001)!
        XCTAssertTrue(identity.isCurrent(readStart: { _ in 1_000_001 }))
        XCTAssertFalse(identity.isCurrent(readStart: { _ in 1_000_002 }))
        XCTAssertFalse(identity.isCurrent(readStart: { _ in 0 }))
    }
    func testLiveProcessIdentityRoundTrip() {
        let pid = getpid()
        let start = sc_process_start_time(pid)
        XCTAssertGreaterThan(start, 0)
        XCTAssertTrue(ProcessIdentity(pid: Int(pid), startTimeMicros: start)!.isCurrent())
    }
    func testSamplerIdentityMatchesLiveKernelIdentity() throws {
        let sampler = sc_sampler_create()
        defer { sc_sampler_destroy(sampler) }
        var count: Int32 = 0, threads: Int32 = 0
        let processes = try XCTUnwrap(sc_sample_processes(sampler, &count, &threads))
        defer { sc_free_processes(processes) }
        let own = try XCTUnwrap((0..<Int(count)).map { processes[$0] }.first { $0.pid == getpid() })
        XCTAssertEqual(own.startTimeMicros, sc_process_start_time(getpid()))
        XCTAssertNotNil(ProcInfo(own).actionIdentity)
    }
    func testOlderHelperPayloadRemainsReadableButHasNoActionIdentity() throws {
        let oldProcess = HelperProcess(pid: 123, ppid: 1, uid: 501, name: "test", user: "test", state: "", path: "",
                                       cpuPercent: 0, memBytes: 0, threads: 1, cpuTimeNs: 0, startTime: 100, accessible: true)
        let data = try JSONEncoder().encode(oldProcess)
        let decoded = try JSONDecoder().decode(HelperProcess.self, from: data)
        XCTAssertEqual(decoded.pid, 123)
        XCTAssertNil(ProcInfo(decoded).actionIdentity)
        let oldPower = HelperPower(sysWatts: 10, cpuWatts: 2, gpuWatts: 1, aneWatts: 0, dramWatts: 0, available: true)
        XCTAssertNil(try JSONDecoder().decode(HelperPower.self, from: JSONEncoder().encode(oldPower)).sampledAt)
    }
    func testPowerExpiresDespiteRepeatedDisplayAndFailedRequests() {
        var cache = PowerReadings()
        let acquired = Date(timeIntervalSince1970: 1000)
        var power = HelperPower(sysWatts: 0, cpuWatts: 8, gpuWatts: 2, aneWatts: 0, dramWatts: 0, available: true)
        power.sampledAt = acquired.timeIntervalSince1970
        power.source = "powermetrics"
        cache.acceptHelper(power, receivedAt: acquired)
        for second in 0..<6 {
            cache.acceptHelper(nil, receivedAt: acquired.addingTimeInterval(Double(second)))
            XCTAssertTrue(cache.snapshot(at: acquired.addingTimeInterval(Double(second)), helperEnabled: true).power.available)
        }
        let expired = cache.snapshot(at: acquired.addingTimeInterval(6), helperEnabled: true)
        XCTAssertFalse(expired.power.available)
        XCTAssertNil(expired.frequency)
        XCTAssertTrue(expired.stale)
        // Re-delivery of the same source sample cannot renew its validity.
        cache.acceptHelper(power, receivedAt: acquired.addingTimeInterval(10))
        XCTAssertFalse(cache.snapshot(at: acquired.addingTimeInterval(10), helperEnabled: true).power.available)
    }
    func testPowerFallsBackToFreshLocalReadingAndPreservesSystemWatts() {
        var cache = PowerReadings()
        let now = Date()
        var local = SCPower(); local.sysWatts = 20; local.available = false
        cache.acceptLocal(local, at: now)
        let reading = cache.snapshot(at: now, helperEnabled: false)
        XCTAssertEqual(reading.power.sysWatts, 20)
        XCTAssertFalse(reading.power.available)
        XCTAssertNil(reading.frequency)
        XCTAssertEqual(cache.snapshot(at: now.addingTimeInterval(7), helperEnabled: false).power.sysWatts, 0)
    }
}
