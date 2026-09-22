// main.swift - pomocnik uprzywilejowany (LaunchDaemon): udostępnia przez XPC pełną listę procesów i liczniki energii
import Foundation
import SysCore
import HelperKit

func cStr<T>(_ tuple: T) -> String {
    withUnsafePointer(to: tuple) { $0.withMemoryRebound(to: CChar.self, capacity: MemoryLayout<T>.size) { String(cString: $0) } }
}

/// Ciągły odczyt powermetrics (dostępne tylko dla roota): moc CPU/GPU/ANE i taktowania
final class PowerMetricsReader {
    private var process: Process?
    private let readerQueue = DispatchQueue(label: "helper.powermetrics")
    private let lock = NSLock()
    private var latest: [String: Double] = [:]
    private var updated = Date.distantPast
    private var buffer = Data()

    func start() { readerQueue.async { self.startProcess() } }

    private func startProcess() {
        guard process == nil, FileManager.default.fileExists(atPath: "/usr/bin/powermetrics") else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/powermetrics")
        p.arguments = ["-i", "1000", "--samplers", "cpu_power,gpu_power,ane_power", "-f", "plist"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        pipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            if d.isEmpty { return }
            self?.readerQueue.async { self?.consume(d) }
        }
        p.terminationHandler = { [weak self] _ in
            pipe.fileHandleForReading.readabilityHandler = nil
            self?.readerQueue.async {
                guard let self else { return }
                self.process = nil
                self.buffer.removeAll()
                self.lock.lock(); self.latest = [:]; self.updated = .distantPast; self.lock.unlock()
                self.readerQueue.asyncAfter(deadline: .now() + 5) { self.startProcess() }
            }   // restart po awarii
        }
        do { try p.run(); process = p } catch {
            pipe.fileHandleForReading.readabilityHandler = nil
            readerQueue.asyncAfter(deadline: .now() + 5) { self.startProcess() }
        }
    }

    private func consume(_ d: Data) {
        buffer.append(d)
        let marker = Data("</plist>".utf8)
        while let r = buffer.range(of: marker) {
            var chunk = buffer.subdata(in: 0..<r.upperBound)
            buffer.removeSubrange(0..<r.upperBound)
            // powermetrics oddziela próbki bajtem NUL
            if let start = chunk.firstIndex(of: UInt8(ascii: "<")) { chunk = chunk.subdata(in: start..<chunk.count) }
            if let obj = try? PropertyListSerialization.propertyList(from: chunk, format: nil) as? [String: Any] { parse(obj) }
        }
        if buffer.count > 4_000_000 { buffer.removeAll() }
    }

    private func parse(_ root: [String: Any]) {
        var out: [String: Double] = [:]
        if let proc = root["processor"] as? [String: Any] {
            for (k, v) in proc { if let n = v as? NSNumber, k.hasSuffix("_power") { out[k] = n.doubleValue } }
            if let clusters = proc["clusters"] as? [[String: Any]] {
                for c in clusters {
                    let name = (c["name"] as? String ?? "").lowercased()
                    if let f = c["freq_hz"] as? NSNumber {
                        if name.hasPrefix("e") { out["e_freq"] = max(out["e_freq"] ?? 0, f.doubleValue) }
                        else if name.hasPrefix("p") { out["p_freq"] = max(out["p_freq"] ?? 0, f.doubleValue) }
                    }
                }
            }
        }
        if let gpu = root["gpu"] as? [String: Any] {
            if let f = gpu["freq_hz"] as? NSNumber { out["gpu_freq"] = f.doubleValue }
            if let pw = gpu["gpu_power"] as? NSNumber { out["gpu_power"] = pw.doubleValue }
        }
        lock.lock(); latest = out; updated = out.isEmpty ? .distantPast : Date(); lock.unlock()
    }

    /// Zwraca aktualne wartości, jeśli świeższe niż 5 s
    func snapshot() -> (values: [String: Double], date: Date)? {
        lock.lock(); defer { lock.unlock() }
        return Date().timeIntervalSince(updated) < 5 ? (latest, updated) : nil
    }
}

final class HelperService: NSObject, HelperProtocol {
    let metrics = PowerMetricsReader()
    private let sampler = sc_sampler_create()
    private let queue = DispatchQueue(label: "helper.sampler")
    private var lastList = Data()
    private var lastSample = Date.distantPast

    override init() {
        super.init()
        var n: Int32 = 0, t: Int32 = 0
        sc_free_processes(sc_sample_processes(sampler, &n, &t))
        _ = sc_power_sample()
        metrics.start()
    }

    func processes(reply: @escaping (Data) -> Void) {
        queue.async {
            // nie próbkuj częściej niż co 0,5 s (różnice CPU potrzebują odstępu)
            if Date().timeIntervalSince(self.lastSample) < 0.5, !self.lastList.isEmpty { reply(self.lastList); return }
            var count: Int32 = 0, threads: Int32 = 0
            var list: [HelperProcess] = []
            if let arr = sc_sample_processes(self.sampler, &count, &threads) {
                list.reserveCapacity(Int(count))
                for i in 0..<Int(count) {
                    let p = arr[i]
                    list.append(HelperProcess(pid: Int(p.pid), ppid: Int(p.ppid), uid: Int(p.uid), name: cStr(p.name), user: cStr(p.user), state: cStr(p.state), path: cStr(p.path),
                                              cpuPercent: p.cpuPercent, memBytes: p.memBytes, threads: Int(p.threads), cpuTimeNs: p.cpuTimeNs, startTime: p.startTime, accessible: p.accessible,
                                              diskRead: p.diskRead, diskWrite: p.diskWrite, contextSwitches: p.contextSwitches, startTimeMicros: p.startTimeMicros))
                }
                sc_free_processes(arr)
            }
            let data = (try? JSONEncoder().encode(HelperProcessList(processes: list, totalThreads: Int(threads)))) ?? Data()
            self.lastList = data; self.lastSample = Date()
            reply(data)
        }
    }

    func power(reply: @escaping (Data) -> Void) {
        queue.async {
            let p = sc_power_sample()
            var hp = HelperPower(sysWatts: p.sysWatts, cpuWatts: p.cpuWatts, gpuWatts: p.gpuWatts, aneWatts: p.aneWatts, dramWatts: p.dramWatts, available: p.available)
            hp.sampledAt = Date().timeIntervalSince1970
            if let sample = self.metrics.snapshot() {
                let m = sample.values
                hp.sampledAt = sample.date.timeIntervalSince1970
                // powermetrics podaje mW
                hp.cpuWatts = (m["cpu_power"] ?? 0) / 1000
                hp.gpuWatts = (m["gpu_power"] ?? 0) / 1000
                hp.aneWatts = (m["ane_power"] ?? 0) / 1000
                hp.dramWatts = (m["dram_power"] ?? 0) / 1000
                hp.combinedWatts = (m["combined_power"] ?? 0) / 1000
                hp.eFreqMHz = (m["e_freq"] ?? 0) / 1e6
                hp.pFreqMHz = (m["p_freq"] ?? 0) / 1e6
                hp.gpuFreqMHz = (m["gpu_freq"] ?? 0) / 1e6
                hp.available = true
                hp.source = "powermetrics"
            }
            reply((try? JSONEncoder().encode(hp)) ?? Data())
        }
    }

    func version(reply: @escaping (String) -> Void) { reply(helperVersion) }

    func priority(pid: Int32, startTimeMicros: Int64, value: Int32, reply: @escaping (String) -> Void) {
        guard pid > 1, startTimeMicros > 0, (-20...20).contains(value),
              sc_process_start_time(pid) == startTimeMicros else { reply("Proces zakończył się lub jest chroniony."); return }
        reply(setpriority(PRIO_PROCESS, id_t(pid), value) == 0 ? "" : String(cString: strerror(errno)))
    }

    /// Sterowanie usługami launchd. Akcja musi być z listy, a etykieta i domena są sprawdzane,
    /// żeby przez pomocnika nie dało się uruchomić dowolnego polecenia.
    func service(action: String, domain: String, label: String, reply: @escaping (String) -> Void) {
        guard let act = ServiceAction(rawValue: action) else { reply("Nieznana operacja"); return }
        guard let caller = NSXPCConnection.current(),
              ServicePolicy.allows(domain: domain, label: label, callerUID: caller.effectiveUserIdentifier)
        else { reply("Niedozwolona domena lub etykieta"); return }
        DispatchQueue.global(qos: .userInitiated).async {
            let result = CommandRunner.run("/bin/launchctl", act.arguments(domain: domain, label: label), timeout: 6)
            reply(result.failureDescription ?? "")
        }
    }
}

final class ListenerDelegate: NSObject, NSXPCListenerDelegate {
    let service = HelperService()
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        newConnection.exportedInterface = NSXPCInterface(with: HelperProtocol.self)
        newConnection.exportedObject = service
        newConnection.resume()
        return true
    }
}

guard let requirement = PeerTrust.requirement(identifier: PeerTrust.appIdentifier) else {
    NSLog("VitalsHelper: refusing to start without a trusted signing team")
    exit(EXIT_FAILURE)
}
let delegate = ListenerDelegate()
let listener = NSXPCListener(machServiceName: helperMachService)
listener.setConnectionCodeSigningRequirement(requirement)
listener.delegate = delegate
listener.resume()
RunLoop.main.run()
