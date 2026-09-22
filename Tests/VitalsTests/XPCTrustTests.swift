import XCTest
import HelperKit

@objc private protocol ProbeProtocol {
    func ping(reply: @escaping (String) -> Void)
}
private final class ProbeService: NSObject, ProbeProtocol {
    func ping(reply: @escaping (String) -> Void) { reply("unexpected") }
}
private final class ProbeDelegate: NSObject, NSXPCListenerDelegate {
    let accepted = Locked(false)
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        accepted.withValue { $0 = true }
        connection.exportedInterface = NSXPCInterface(with: ProbeProtocol.self)
        connection.exportedObject = ProbeService()
        connection.resume()
        return true
    }
}
final class XPCTrustTests: XCTestCase {
    func testUnsignedOrWrongTeamClientIsRejectedBeforeDelegate() {
        let listener = NSXPCListener.anonymous()
        let delegate = ProbeDelegate()
        listener.delegate = delegate
        listener.setConnectionCodeSigningRequirement(PeerTrust.requirement(identifier: PeerTrust.appIdentifier, team: "ABCDE12345")!)
        listener.resume()
        let connection = NSXPCConnection(listenerEndpoint: listener.endpoint)
        connection.remoteObjectInterface = NSXPCInterface(with: ProbeProtocol.self)
        connection.resume()
        defer { connection.invalidate(); listener.invalidate() }
        let rejected = expectation(description: "Untrusted client rejected")
        let proxy = connection.remoteObjectProxyWithErrorHandler { _ in rejected.fulfill() } as! ProbeProtocol
        proxy.ping { _ in XCTFail("Untrusted client reached the service") }
        wait(for: [rejected], timeout: 3)
        XCTAssertFalse(delegate.accepted.withValue { $0 })
    }
}
