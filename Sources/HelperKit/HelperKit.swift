// HelperKit.swift - wspólny protokół XPC i typy danych między aplikacją a pomocnikiem uprzywilejowanym
import Foundation

public let helperMachService = "online.equishow.vitals.helper"
public let helperPlistName = "online.equishow.vitals.helper.plist"
public let helperVersion = AppVersion.full

@objc public protocol HelperProtocol {
    /// Lista procesów (JSON [HelperProcess]) z pełnym dostępem (root)
    func processes(reply: @escaping (Data) -> Void)
    /// Moc podsystemów z IOReport (JSON HelperPower)
    func power(reply: @escaping (Data) -> Void)
    func version(reply: @escaping (String) -> Void)
    /// Sterowanie usługą launchd; akcja z ustalonej listy, wynik jako tekst (pusty = OK)
    func service(action: String, domain: String, label: String, reply: @escaping (String) -> Void)
}

/// Dozwolone operacje na usługach – pomocnik odrzuca wszystko poza tą listą
public enum ServiceAction: String, CaseIterable {
    case start, stop, restart, enable, disable, bootout

    public var title: String {
        switch self {
        case .start: return "Uruchom"
        case .stop: return "Zatrzymaj"
        case .restart: return "Uruchom ponownie"
        case .enable: return "Włącz (enable)"
        case .disable: return "Wyłącz (disable)"
        case .bootout: return "Wyładuj (bootout)"
        }
    }

    /// Argumenty launchctl dla pary domena/etykieta
    public func arguments(domain: String, label: String) -> [String] {
        let target = "\(domain)/\(label)"
        switch self {
        case .start: return ["kickstart", target]
        case .stop: return ["kill", "SIGTERM", target]
        case .restart: return ["kickstart", "-k", target]
        case .enable: return ["enable", target]
        case .disable: return ["disable", target]
        case .bootout: return ["bootout", target]
        }
    }
}

public struct HelperProcess: Codable {
    public var pid, ppid, uid: Int
    public var name, user, state, path: String
    public var cpuPercent: Double
    public var memBytes: UInt64
    public var threads: Int
    public var cpuTimeNs: UInt64
    public var startTime: Int64
    public var accessible: Bool
    /// Łączne bajty we/wy procesu (rusage); 0 gdy brak dostępu
    public var diskRead: UInt64 = 0
    public var diskWrite: UInt64 = 0
    public var contextSwitches: UInt64 = 0
    public init(pid: Int, ppid: Int, uid: Int, name: String, user: String, state: String, path: String, cpuPercent: Double, memBytes: UInt64, threads: Int, cpuTimeNs: UInt64, startTime: Int64, accessible: Bool, diskRead: UInt64 = 0, diskWrite: UInt64 = 0, contextSwitches: UInt64 = 0) {
        self.pid = pid; self.ppid = ppid; self.uid = uid; self.name = name; self.user = user; self.state = state; self.path = path
        self.cpuPercent = cpuPercent; self.memBytes = memBytes; self.threads = threads; self.cpuTimeNs = cpuTimeNs; self.startTime = startTime; self.accessible = accessible
        self.diskRead = diskRead; self.diskWrite = diskWrite; self.contextSwitches = contextSwitches
    }
}

public struct HelperProcessList: Codable {
    public var processes: [HelperProcess]
    public var totalThreads: Int
    public init(processes: [HelperProcess], totalThreads: Int) { self.processes = processes; self.totalThreads = totalThreads }
}

public struct HelperPower: Codable {
    public var sysWatts, cpuWatts, gpuWatts, aneWatts, dramWatts: Double
    public var available: Bool
    /// Z powermetrics (root): taktowania klastrów i GPU w MHz, moc łączna pakietu
    public var eFreqMHz: Double = 0
    public var pFreqMHz: Double = 0
    public var gpuFreqMHz: Double = 0
    public var combinedWatts: Double = 0
    public var source: String = ""
    public init(sysWatts: Double, cpuWatts: Double, gpuWatts: Double, aneWatts: Double, dramWatts: Double, available: Bool) {
        self.sysWatts = sysWatts; self.cpuWatts = cpuWatts; self.gpuWatts = gpuWatts; self.aneWatts = aneWatts; self.dramWatts = dramWatts; self.available = available
    }
}
