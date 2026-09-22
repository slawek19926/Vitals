import Foundation
import Darwin
import SysCore

struct ProcessIdentity: Equatable {
    let pid: Int
    let startTimeMicros: Int64
    static func isAllowedPID(_ pid: Int) -> Bool { pid > 1 && pid <= Int(Int32.max) }
    init?(pid: Int, startTimeMicros: Int64?) {
        guard Self.isAllowedPID(pid), let startTimeMicros, startTimeMicros > 0 else { return nil }
        self.pid = pid; self.startTimeMicros = startTimeMicros
    }
    func isCurrent(readStart: (Int32) -> Int64 = sc_process_start_time) -> Bool {
        readStart(Int32(pid)) == startTimeMicros
    }
}

extension ProcInfo {
    var actionIdentity: ProcessIdentity? { ProcessIdentity(pid: pid, startTimeMicros: startTimeMicros) }
}

enum ProcessActions {
    static func signal(_ signal: Int32, process: ProcInfo) -> String? {
        guard let identity = process.actionIdentity, identity.isCurrent() else {
            return L("Proces zakończył się, zmienił tożsamość lub jest chroniony. Odśwież listę.")
        }
        guard Darwin.kill(pid_t(identity.pid), signal) == 0 else { return String(cString: strerror(errno)) }
        return nil
    }
}
