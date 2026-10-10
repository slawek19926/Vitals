import Foundation

/// Encode each boundary separately: shell arguments, AppleScript strings, XML text.
enum LaunchCommands {
    static func shellArgument(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }
    static func appleScriptString(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\n", with: "\\n") + "\""
    }
    static func administratorRelaunch(executable: String, arguments: [String]) -> String {
        let command = ([executable] + arguments).map(shellArgument).joined(separator: " ") + " >/dev/null 2>&1 &"
        return "do shell script " + appleScriptString(command) + " with administrator privileges"
    }
    static func xmlText(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }
}
