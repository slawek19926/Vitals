import XCTest
import HelperKit
@testable import Vitals

final class LaunchCommandsTests: XCTestCase {
    func testHostilePathsRemainLiteralShellArguments() {
        for path in ["/tmp/$(printf INJECTED).app", "/tmp/`printf INJECTED`.app", "/tmp/a'\"&<>\\\n.app"] {
            let result = CommandRunner.run("/bin/sh", ["-c", "printf '%s' " + LaunchCommands.shellArgument(path)])
            XCTAssertTrue(result.succeeded)
            XCTAssertEqual(result.stdout, path)
        }
    }
    func testWorkflowXMLPreservesQuotedCommand() throws {
        let path = "/tmp/A'\"&<>$(printf INJECTED).app"
        let plist = try XCTUnwrap(try PropertyListSerialization.propertyList(from: Data(QuickAction.workflow(appPath: path).utf8), format: nil) as? [String: Any])
        let actions = try XCTUnwrap(plist["actions"] as? [[String: Any]])
        let action = try XCTUnwrap(actions.first?["action"] as? [String: Any])
        let parameters = try XCTUnwrap(action["ActionParameters"] as? [String: Any])
        XCTAssertEqual(parameters["COMMAND_STRING"] as? String, "/usr/bin/open -a " + LaunchCommands.shellArgument(path))
    }
    func testAdministratorScriptDecodesWithoutExecutingPrivileges() {
        let path = "/tmp/A'\"$(printf INJECTED)\\.app"
        let expression = LaunchCommands.appleScriptString(LaunchCommands.shellArgument(path))
        let decoded = CommandRunner.run("/usr/bin/osascript", ["-e", "return " + expression])
        XCTAssertTrue(decoded.succeeded)
        let result = CommandRunner.run("/bin/sh", ["-c", "printf '%s' " + decoded.stdout.trimmingCharacters(in: .newlines)])
        XCTAssertEqual(result.stdout, path)
        XCTAssertTrue(LaunchCommands.administratorRelaunch(executable: path, arguments: ["-userPrefs", path]).hasSuffix(" with administrator privileges"))
    }
}
