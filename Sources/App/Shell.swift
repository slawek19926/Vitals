import Foundation
import HelperKit

enum Shell {
    static func execute(_ path: String, _ args: [String], timeout: TimeInterval = 60) -> CommandResult {
        CommandRunner.run(path, args, timeout: timeout)
    }
    /// Read-only callers may consume stdout; mutations must check execute().succeeded.
    static func run(_ path: String, _ args: [String], timeout: TimeInterval = 60) -> String {
        execute(path, args, timeout: timeout).stdout
    }
    static func status(_ path: String, _ args: [String], timeout: TimeInterval = 60) -> Int32 {
        let result = execute(path, args, timeout: timeout)
        return result.succeeded ? 0 : (result.exitCode == 0 ? -1 : result.exitCode)
    }
    static func runCombined(_ path: String, _ args: [String], timeout: TimeInterval = 60) -> String {
        let result = execute(path, args, timeout: timeout)
        return result.stdout + result.stderr
    }
    static func async(_ path: String, _ args: [String], timeout: TimeInterval = 60, _ done: @escaping (String) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let text = run(path, args, timeout: timeout)
            DispatchQueue.main.async { done(text) }
        }
    }
}
