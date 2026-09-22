import Foundation
import Security
import Darwin

/// Shared state must be accessed inside the lock's scope.
public final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    public init(_ value: Value) { self.value = value }
    public func withValue<T>(_ body: (inout Value) throws -> T) rethrows -> T {
        lock.lock(); defer { lock.unlock() }
        return try body(&value)
    }
}

public struct CommandResult {
    public let stdout: String
    public let stderr: String
    public let exitCode: Int32
    public let timedOut: Bool
    public let launchError: String?
    public let outputTruncated: Bool
    public var succeeded: Bool { launchError == nil && !timedOut && !outputTruncated && exitCode == 0 }
    public var failureDescription: String? {
        if succeeded { return nil }
        if let launchError { return launchError }
        if timedOut { return "Przekroczono czas oczekiwania / Command timed out" }
        if outputTruncated { return "Przekroczono limit wyjścia / Output limit exceeded" }
        let message = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        return message.isEmpty ? "Exit code: \(exitCode)" : message
    }
}

public enum CommandRunner {
    /// Drain both pipes while the child runs. Bound waits even if a descendant retains a pipe.
    public static func run(_ path: String, _ arguments: [String], timeout: TimeInterval = 60) -> CommandResult {
        let process = Process(), output = Pipe(), errors = Pipe()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardOutput = output; process.standardError = errors
        defer {
            try? output.fileHandleForReading.close(); try? errors.fileHandleForReading.close()
            try? output.fileHandleForWriting.close(); try? errors.fileHandleForWriting.close()
        }
        do { try process.run() } catch {
            return CommandResult(stdout: "", stderr: "", exitCode: -1, timedOut: false,
                                 launchError: error.localizedDescription, outputTruncated: false)
        }
        try? output.fileHandleForWriting.close(); try? errors.fileHandleForWriting.close()
        let outFD = output.fileHandleForReading.fileDescriptor, errFD = errors.fileHandleForReading.fileDescriptor
        _ = fcntl(outFD, F_SETFL, O_NONBLOCK); _ = fcntl(errFD, F_SETFL, O_NONBLOCK)
        var out = Data(), err = Data(), outEOF = false, errEOF = false, truncated = false
        let deadline = ProcessInfo.processInfo.systemUptime + max(0, timeout)
        let limit = 32 * 1024 * 1024
        func drain(_ fd: Int32, _ data: inout Data, _ eof: inout Bool) {
            var bytes = [UInt8](repeating: 0, count: 16_384)
            for _ in 0..<64 {
                let count = Darwin.read(fd, &bytes, bytes.count)
                if count == 0 { eof = true; return }
                if count < 0 {
                    if errno == EINTR { continue }
                    if errno != EAGAIN && errno != EWOULDBLOCK { eof = true }
                    return
                }
                let keep = min(count, max(0, limit - data.count))
                data.append(contentsOf: bytes.prefix(keep))
                if keep < count { truncated = true }
            }
        }
        var timedOut = false
        while true {
            drain(outFD, &out, &outEOF); drain(errFD, &err, &errEOF)
            if !process.isRunning && outEOF && errEOF { break }
            if ProcessInfo.processInfo.systemUptime >= deadline {
                timedOut = true
                if process.isRunning {
                    process.terminate()
                    let grace = ProcessInfo.processInfo.systemUptime + 0.2
                    while process.isRunning && ProcessInfo.processInfo.systemUptime < grace { usleep(5_000) }
                    if process.isRunning { _ = Darwin.kill(process.processIdentifier, SIGKILL) }
                }
                break
            }
            usleep(5_000)
        }
        return CommandResult(stdout: String(decoding: out, as: UTF8.self), stderr: String(decoding: err, as: UTF8.self),
                             exitCode: process.isRunning ? -1 : process.terminationStatus, timedOut: timedOut,
                             launchError: nil, outputTruncated: truncated)
    }
}

public enum PeerTrust {
    public static let appIdentifier = "online.equishow.vitals"
    /// Derive trust from our executable's signature, never from a caller-supplied team or PID.
    public static func requirement(identifier: String) -> String? {
        var code: SecCode?
        var info: CFDictionary?
        var staticCode: SecStaticCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let values = info as? [String: Any], let team = values[kSecCodeInfoTeamIdentifier as String] as? String
        else { return nil }
        return requirement(identifier: identifier, team: team)
    }
    public static func requirement(identifier: String, team: String) -> String? {
        guard [appIdentifier, helperMachService].contains(identifier), team.count == 10,
              team.utf8.allSatisfy({ (65...90).contains($0) || (48...57).contains($0) }) else { return nil }
        return "anchor apple generic and identifier \"\(identifier)\" and certificate leaf[subject.OU] = \"\(team)\""
    }
}

public enum ServicePolicy {
    public static func allows(domain: String, label: String, callerUID: uid_t) -> Bool {
        let validDomain = domain == "system" || domain == "user/\(callerUID)" || domain == "gui/\(callerUID)"
        return validDomain && !label.isEmpty && label.utf8.count < 256 && label.utf8.allSatisfy {
            (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || [45, 46, 95].contains($0)
        }
    }
}

public enum AuthorizationRequest {
    public static func copyRight(_ name: String, auth: AuthorizationRef, flags: AuthorizationFlags) -> OSStatus {
        name.withCString { namePointer in
            var item = AuthorizationItem(name: namePointer, valueLength: 0, value: nil, flags: 0)
            return withUnsafeMutablePointer(to: &item) { itemPointer in
                var rights = AuthorizationRights(count: 1, items: itemPointer)
                return AuthorizationCopyRights(auth, &rights, nil, flags, nil)
            }
        }
    }
}
