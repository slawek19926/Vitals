// Shell.swift - uruchamianie narzędzi systemowych (system_profiler, launchctl, dscl, who) w tle
import Foundation

enum Shell {
    /// Uruchamia program i zwraca stdout (synchronicznie; wołać z wątku w tle)
    static func run(_ path: String, _ args: [String], timeout: TimeInterval = 60) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return "" }
        var data = Data()
        let reader = DispatchQueue(label: "shell.read")
        let sem = DispatchSemaphore(value: 0)
        reader.async { data = out.fileHandleForReading.readDataToEndOfFile(); sem.signal() }
        if sem.wait(timeout: .now() + timeout) == .timedOut { p.terminate(); return String(data: data, encoding: .utf8) ?? "" }
        p.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// Kod wyjścia programu; wyjście pomijane (ditto, codesign --verify)
    static func status(_ path: String, _ args: [String], timeout: TimeInterval = 60) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return -1 }
        let deadline = Date().addingTimeInterval(timeout)
        while p.isRunning, Date() < deadline { usleep(20_000) }
        if p.isRunning { p.terminate(); return -1 }
        return p.terminationStatus
    }

    /// stdout razem ze stderr – część narzędzi (codesign -dv) pisze wynik na stderr
    static func runCombined(_ path: String, _ args: [String], timeout: TimeInterval = 60) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        do { try p.run() } catch { return "" }
        var data = Data()
        let reader = DispatchQueue(label: "shell.read2")
        let sem = DispatchSemaphore(value: 0)
        reader.async { data = out.fileHandleForReading.readDataToEndOfFile(); sem.signal() }
        if sem.wait(timeout: .now() + timeout) == .timedOut { p.terminate(); return String(data: data, encoding: .utf8) ?? "" }
        p.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }

    static func async(_ path: String, _ args: [String], timeout: TimeInterval = 60, _ done: @escaping (String) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let s = run(path, args, timeout: timeout)
            DispatchQueue.main.async { done(s) }
        }
    }
}
