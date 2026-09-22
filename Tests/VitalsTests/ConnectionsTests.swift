import XCTest
@testable import Vitals

final class ConnectionsTests: XCTestCase {
    private func socket(_ id: String, pid: Int = 42, name: String = "Browser", proto: String = "TCP4",
                        local: String = "192.168.1.2", localPort: String = "50000",
                        remote: String = "8.8.8.8", remotePort: String = "443", state: String = "ESTABLISHED") -> Connection {
        Connection(proto: proto, local: local, localPort: localPort, remote: remote, remotePort: remotePort,
                   state: state, pid: pid, processName: name, socketID: id)
    }

    func testScopeFiltersRemoteListeningAndLocalPeers() {
        let remote = socket("remote")
        let local = socket("local", remote: "192.168.1.1")
        let ipv6Local = socket("ipv6", remote: "fe80::1234")
        let listener = socket("listen", remote: "*", remotePort: "*", state: "LISTEN")
        let udp = socket("udp", proto: "UDP4", remote: "*", remotePort: "*", state: "")
        let all = [remote, local, ipv6Local, listener, udp]
        func ids(scope: Int, proto: Int = 0) -> [String] {
            all.filter { ConnectionPresentation.matches($0, scope: scope, proto: proto, query: "") }.map(\.socketID)
        }
        XCTAssertEqual(ids(scope: 0), ["remote"])
        XCTAssertEqual(ids(scope: 1), ["listen"])
        XCTAssertEqual(ids(scope: 2), ["local", "ipv6"])
        XCTAssertEqual(ids(scope: 3), ["remote", "local", "ipv6", "listen", "udp"])
        XCTAssertEqual(ids(scope: 3, proto: 2), ["udp"])
        XCTAssertTrue(ConnectionPresentation.matches(remote, scope: 3, proto: 0, query: "browser"))
        XCTAssertTrue(ConnectionPresentation.matches(remote, scope: 3, proto: 0, query: "443"))
        XCTAssertFalse(ConnectionPresentation.matches(remote, scope: 3, proto: 0, query: "Safari"))
    }

    func testGroupingCountsSocketsPerDestinationAndSortsDescending() {
        let sockets = [socket("a", remotePort: "80"), socket("b", localPort: "50001", remotePort: "80"),
                       socket("c", remotePort: "443"), socket("d", pid: 5, name: "Mail", remotePort: "993")]
        let groups = ConnectionPresentation.grouped(sockets, sortKey: "rport", ascending: false)
        XCTAssertEqual(groups.map(\.name), ["Browser", "Mail"])
        XCTAssertEqual(groups[0].socketCount, 3)
        XCTAssertEqual(groups[0].destinations.map { $0.first.remotePort }, ["443", "80"])
        XCTAssertEqual(groups[0].destinations.map { $0.sockets.count }, [1, 2])
        XCTAssertEqual(groups[0].destinations[1].localPorts, ["50000", "50001"])
        XCTAssertEqual(groups[0].destinations[1].localPort, ConnectionPresentation.quantity(2, one: "port", few: "porty", many: "portów"))
    }

    func testLsofParserCollapsesDuplicateFileDescriptorsForOneSocket() {
        let output = """
        COMMAND PID USER FD TYPE DEVICE SIZE/OFF NODE NAME
        browser 42 user 10u IPv4 0x123 0t0 TCP 192.168.1.2:50000->8.8.8.8:443 (ESTABLISHED)
        browser 42 user 11u IPv4 0x123 0t0 TCP 192.168.1.2:50000->8.8.8.8:443 (ESTABLISHED)
        browser 42 user 12u IPv6 0x456 0t0 UDP *:5353
        """
        let sockets = ConnectionsViewController.parseLsof(output, procs: [42: "Browser App"])
        XCTAssertEqual(sockets.count, 2)
        XCTAssertEqual(sockets[0].processName, "Browser App")
        XCTAssertEqual(sockets[0].remote, "8.8.8.8")
        XCTAssertEqual(sockets[0].remotePort, "443")
        XCTAssertEqual(sockets[0].state, "ESTABLISHED")
        XCTAssertEqual(sockets[1].proto, "UDP6")
        XCTAssertEqual(sockets[1].remote, "*")
    }
}
