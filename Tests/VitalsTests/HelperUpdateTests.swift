import XCTest
@testable import Vitals

final class HelperUpdateTests: XCTestCase {
    private let target = "1.1.1.143"

    func testVersionComparisonDoesNotDowngradeOrAcceptMalformedReplies() {
        for version in ["1.1.0.999", "1.1.1.9", "1.1.1.142", "1.1.1"] {
            XCTAssertTrue(HelperUpdater.needsUpdate(installed: version, target: target))
        }
        for version in [target, "1.1.1.144", "1.2.0.1", "", "broken", "1..0", "1.1.1.beta", "1.1.1.-1"] {
            XCTAssertFalse(HelperUpdater.needsUpdate(installed: version, target: target))
        }
    }

    func testDisabledCurrentAndNewerHelpersDoNotStartInstallation() {
        var installs = 0
        let updater = HelperUpdater(target: target, install: { _ in installs += 1 }, readVersion: { _ in XCTFail() })
        updater.consider(installed: "1.1.0.1", enabled: false)
        updater.consider(installed: target, enabled: true)
        updater.consider(installed: "1.2.0.1", enabled: true)
        XCTAssertEqual(installs, 0)
    }

    func testOldHelperAutomaticallyUpdatesAndWaitsForMatchingRunningVersion() {
        var installs = 0
        var installDone: ((Result<Bool, Error>) -> Void)?
        var replies: [String?] = ["1.1.1.142", nil, target]
        var pending: [() -> Void] = []
        let updater = HelperUpdater(target: target, install: { installs += 1; installDone = $0 },
            readVersion: { $0(replies.removeFirst()) }, schedule: { _, work in pending.append(work) })
        updater.consider(installed: "1.1.1.142", enabled: true)
        XCTAssertEqual(updater.phase, .installing)
        updater.consider(installed: "1.1.1.142", enabled: true)
        updater.update()
        XCTAssertEqual(installs, 1)
        installDone?(.success(false))
        XCTAssertEqual(updater.phase, .verifying)
        XCTAssertTrue(updater.isBusy)
        pending.removeFirst()()
        XCTAssertEqual(updater.phase, .verifying)
        pending.removeFirst()()
        XCTAssertEqual(updater.phase, .current)
        XCTAssertFalse(updater.isBusy)
    }

    func testCancellationDoesNotRepeatAutomaticallyButManualRetryWorks() {
        var installs = 0
        let cancelled = NSError(domain: "Helper", code: -60006)
        let updater = HelperUpdater(target: target, install: { installs += 1; $0(.failure(cancelled)) },
                                    readVersion: { _ in XCTFail() })
        updater.consider(installed: "1.1.1.142", enabled: true)
        for _ in 0..<20 { updater.consider(installed: "1.1.1.142", enabled: true) }
        XCTAssertEqual(installs, 1)
        XCTAssertFalse(updater.isBusy)
        updater.update()
        XCTAssertEqual(installs, 2)
    }

    func testSuccessfulInstallWithoutNewVersionFailsAfterBoundedRetries() {
        var reads = 0
        var failures = 0
        let updater = HelperUpdater(target: target, install: { $0(.success(false)) },
            readVersion: { reads += 1; $0("1.1.1.142") }, schedule: { _, work in work() })
        updater.onFailure = { _ in failures += 1 }
        updater.consider(installed: "1.1.1.142", enabled: true)
        XCTAssertEqual(reads, 10)
        XCTAssertEqual(failures, 1)
        guard case .failed = updater.phase else { return XCTFail("Old running helper must not count as updated") }
        updater.consider(installed: "1.1.1.142", enabled: true)
        XCTAssertEqual(reads, 10)
    }

    func testApprovalIsNotReportedAsSuccessAndDoesNotReinstall() {
        var installs = 0
        let updater = HelperUpdater(target: target, install: { installs += 1; $0(.success(true)) },
                                    readVersion: { _ in XCTFail() })
        updater.consider(installed: "1.1.1.142", enabled: true)
        XCTAssertEqual(updater.phase, .requiresApproval)
        updater.consider(installed: "1.1.1.142", enabled: true)
        XCTAssertEqual(installs, 1)
        updater.consider(installed: target, enabled: true)
        XCTAssertEqual(updater.phase, .current)
    }

    func testLegacyUpdateUsesBlessOnly() {
        var calls: [String] = []
        HelperInstallation.run(backend: .legacy, bless: { calls.append("bless") },
            unregister: { _ in XCTFail() }, register: { XCTFail() }, installNew: { XCTFail() }) { error in
                XCTAssertNil(error); calls.append("done")
            }
        XCTAssertEqual(calls, ["bless", "done"])
    }

    func testBundledUpdateWaitsUntilOldDaemonHasStopped() {
        var stopped: ((Error?) -> Void)?
        var calls: [String] = []
        HelperInstallation.run(backend: .bundled, bless: { XCTFail() },
            unregister: { calls.append("unregister"); stopped = $0 },
            register: { calls.append("register") }, installNew: { XCTFail() }) { error in
                XCTAssertNil(error); calls.append("done")
            }
        XCTAssertEqual(calls, ["unregister"])
        stopped?(nil)
        XCTAssertEqual(calls, ["unregister", "register", "done"])
    }

    func testUnregisterFailureDoesNotRegisterOrFallBackToBless() {
        let denied = NSError(domain: "test", code: 99)
        var failure: NSError?
        HelperInstallation.run(backend: .bundled, bless: { XCTFail() },
            unregister: { $0(denied) }, register: { XCTFail() }, installNew: { XCTFail() }) {
                failure = $0 as NSError?
            }
        XCTAssertEqual(failure, denied)
    }

    func testRegistrationFailureDoesNotFallBackToAnotherBackend() {
        let denied = NSError(domain: "test", code: 99)
        var failure: NSError?
        HelperInstallation.run(backend: .bundled, bless: { XCTFail() },
            unregister: { $0(nil) }, register: { throw denied }, installNew: { XCTFail() }) {
                failure = $0 as NSError?
            }
        XCTAssertEqual(failure, denied)
    }
}
