// Monitor.swift - próbkowanie w tle (SysCore) i rozsyłanie migawek do widoków
import Foundation
import SysCore
import HelperKit

/// Zamiana tablicy znaków z C (krotki w Swifcie) na String
func cString<T>(_ tuple: T) -> String {
    withUnsafePointer(to: tuple) {
        $0.withMemoryRebound(to: CChar.self, capacity: MemoryLayout<T>.size) { String(cString: $0) }
    }
}

struct ProcInfo {
    let pid, ppid, uid: Int
    let name, user, state, path: String
    let cpuPercent: Double
    let memBytes: UInt64
    let threads: Int
    let cpuTimeNs: UInt64
    let startTime: Date?
    let accessible: Bool
    /// Łączne bajty we/wy procesu i tempo policzone względem poprzedniego pomiaru
    var diskRead: UInt64 = 0
    var diskWrite: UInt64 = 0
    var diskReadRate: Double = 0
    var diskWriteRate: Double = 0
    var contextSwitches: UInt64 = 0
    /// Przełączenia kontekstu na sekundę (przybliżenie wybudzeń procesu)
    var cswRate: Double = 0

    /// Przybliżony wpływ na zużycie energii: czas procesora waży najwięcej,
    /// dochodzą operacje dyskowe i częste wybudzanie rdzeni
    var energyImpact: Double {
        cpuPercent + (diskReadRate + diskWriteRate) / 1_000_000 * 0.4 + cswRate / 1000 * 0.3
    }

    init(_ h: HelperProcess) {
        pid = h.pid; ppid = h.ppid; uid = h.uid; name = h.name; user = h.user; state = h.state; path = h.path
        cpuPercent = h.cpuPercent; memBytes = h.memBytes; threads = h.threads; cpuTimeNs = h.cpuTimeNs
        startTime = h.startTime > 0 ? Date(timeIntervalSince1970: TimeInterval(h.startTime)) : nil
        accessible = h.accessible
        diskRead = h.diskRead; diskWrite = h.diskWrite; contextSwitches = h.contextSwitches
    }

    init(_ p: SCProcess) {
        pid = Int(p.pid); ppid = Int(p.ppid); uid = Int(p.uid)
        name = cString(p.name); user = cString(p.user); state = cString(p.state); path = cString(p.path)
        cpuPercent = p.cpuPercent; memBytes = p.memBytes; threads = Int(p.threads); cpuTimeNs = p.cpuTimeNs
        startTime = p.startTime > 0 ? Date(timeIntervalSince1970: TimeInterval(p.startTime)) : nil
        accessible = p.accessible
        diskRead = p.diskRead; diskWrite = p.diskWrite; contextSwitches = p.contextSwitches
    }
}

/// Tempa liczników systemowych policzone między pomiarami
struct SystemRates {
    var pageIn = 0.0, pageOut = 0.0, swapIn = 0.0, swapOut = 0.0
    var faults = 0.0, cowFaults = 0.0, compressions = 0.0, decompressions = 0.0
    var contextSwitches = 0.0
    /// Skuteczność bufora obiektów pamięci (hits / lookups)
    var cacheHitRatio: Double? = nil
}

struct CpuStats {
    var total = 0.0, user = 0.0, system = 0.0, idle = 100.0
    var perCore: [Double] = []
    var perCoreSystem: [Double] = []
    init() {}
    init(_ c: SCCpu) {
        total = c.total; user = c.user; system = c.system; idle = c.idle
        let n = Int(c.coreCount)
        perCore = withUnsafeBytes(of: c.perCore) { Array($0.bindMemory(to: Double.self).prefix(n)) }
        perCoreSystem = withUnsafeBytes(of: c.perCoreSystem) { Array($0.bindMemory(to: Double.self).prefix(n)) }
    }
}

struct Battery {
    let present: Bool, percent: Int, charging: Bool, onAC: Bool
    let timeToEmptyMin, timeToFullMin, cycleCount, designCapacity, nominalCapacity, voltage_mV, amperage_mA: Int
    let temperatureC: Double
    let health: String
    init(_ b: SCBattery) {
        present = b.present; percent = Int(b.percent); charging = b.charging; onAC = b.onAC
        timeToEmptyMin = Int(b.timeToEmptyMin); timeToFullMin = Int(b.timeToFullMin); cycleCount = Int(b.cycleCount)
        designCapacity = Int(b.designCapacity); nominalCapacity = Int(b.nominalCapacity)
        voltage_mV = Int(b.voltage_mV); amperage_mA = Int(b.amperage_mA); temperatureC = b.temperatureC
        health = cString(b.health)
    }
    var watts: Double { abs(Double(amperage_mA)) * Double(voltage_mV) / 1e6 }
}

struct Volume {
    let mount, device, fs: String
    let total, free, used: UInt64
    let local: Bool
    init(_ v: SCVolume) {
        mount = cString(v.mount); device = cString(v.device); fs = cString(v.fs)
        total = v.total; free = v.freeBytes; used = v.used; local = v.local
    }
}

struct NetInterface {
    let name, mac, addrs: String
    let up: Bool
    let rxBytes, txBytes, rxPackets, txPackets: UInt64
    let rxErrors, txErrors, drops, collisions: UInt64
    let mtu, linkSpeedMbps: Int
    let media, netmask, broadcast: String
    let loopback, pointToPoint, multicast: Bool
    var rxRate: Double = 0
    var txRate: Double = 0
    init(_ i: SCInterface) {
        name = cString(i.name); mac = cString(i.mac); addrs = cString(i.addrs); up = i.up
        rxBytes = i.rxBytes; txBytes = i.txBytes; rxPackets = i.rxPackets; txPackets = i.txPackets
        rxErrors = i.rxErrors; txErrors = i.txErrors; drops = i.drops; collisions = i.collisions
        mtu = Int(i.mtu); linkSpeedMbps = Int(i.linkSpeedMbps)
        media = cString(i.media); netmask = cString(i.netmask); broadcast = cString(i.broadcast)
        loopback = i.loopback; pointToPoint = i.pointToPoint; multicast = i.multicastCapable
    }
}

struct Hardware {
    let model, cpuBrand, arch, osVersion, osBuild, kernel, hostname, gpuName: String
    let ncpu, physCpu, perfCores, effCores, gpuCores: Int
    let memTotal, l2Cache, l2CacheE, l1iCache, l1dCache, pageSize: UInt64
    let hvSupport, vmPresent: Bool
    let bootTime: Date?
    var aneCores = 0
    var aneArch = ""
    init(_ h: SCHardware) {
        model = cString(h.model); cpuBrand = cString(h.cpuBrand); arch = cString(h.arch)
        osVersion = cString(h.osVersion); osBuild = cString(h.osBuild); kernel = cString(h.kernel)
        hostname = cString(h.hostname); gpuName = cString(h.gpuName)
        ncpu = Int(h.ncpu); physCpu = Int(h.physCpu); perfCores = Int(h.perfCores); effCores = Int(h.effCores)
        gpuCores = Int(h.gpuCores); memTotal = h.memTotal; l2Cache = h.l2Cache; l2CacheE = h.l2CacheE
        l1iCache = h.l1iCache; l1dCache = h.l1dCache; pageSize = h.pageSize
        hvSupport = h.hvSupport; vmPresent = h.vmPresent
        bootTime = h.bootTime > 0 ? Date(timeIntervalSince1970: TimeInterval(h.bootTime)) : nil
    }
    var marketingName: String {
        if model.hasPrefix("MacBookAir") || ["Mac16,12", "Mac16,13", "Mac15,12", "Mac15,13", "Mac14,2", "Mac14,15"].contains(model) { return "MacBook Air" }
        if model.hasPrefix("MacBookPro") || ["Mac14,5","Mac14,6","Mac14,7","Mac14,9","Mac14,10","Mac15,3","Mac15,6","Mac15,7","Mac15,8","Mac15,9","Mac15,10","Mac15,11","Mac16,1","Mac16,5","Mac16,6","Mac16,7","Mac16,8"].contains(model) { return "MacBook Pro" }
        if model.hasPrefix("Macmini") || ["Mac14,3","Mac14,12","Mac16,10","Mac16,11"].contains(model) { return "Mac mini" }
        if model.hasPrefix("iMac") || ["Mac15,4","Mac15,5","Mac16,2","Mac16,3"].contains(model) { return "iMac" }
        if model.hasPrefix("MacStudio") || ["Mac13,1","Mac13,2","Mac14,13","Mac14,14","Mac15,14","Mac16,9"].contains(model) { return "Mac Studio" }
        if model.hasPrefix("MacPro") || model == "Mac14,8" { return "Mac Pro" }
        return "Mac"
    }
}

struct Sensor { let name: String; let value: Double }

/// Lekki wpis historii: tyle danych, ile potrzeba do listy TOP procesów sprzed chwili
struct HistoryProc {
    let pid: Int
    let name: String
    let cpu: Double
    let mem: UInt64
    let accessible: Bool
}

/// Jedna próbka historii (odpowiada jednemu punktowi na wykresie)
struct HistorySample {
    let time: Date
    let generation: Int
    let cpuTotal: Double
    let cpuSystem: Double
    let memUsed: UInt64
    let processCount: Int
    let top: [HistoryProc]
    // dane do eksportu i wykresów historycznych
    var cpuUser: Double = 0
    var memSwap: UInt64 = 0
    var diskRead: Double = 0
    var diskWrite: Double = 0
    var netRx: Double = 0
    var netTx: Double = 0
    var sysWatts: Double = 0
    var cpuWatts: Double = 0
    var gpuUtil: Double = 0
    var hotspotC: Double = 0
    var batteryPercent: Int = 0
    var threads: Int = 0
}

/// Pojedynczy dysk fizyczny z bieżącym transferem
struct DiskDevice {
    let bsd: String
    let name: String
    let interconnect: String
    let medium: String
    let architecture: String
    let link: String
    let size: UInt64
    let isInternal: Bool
    let removable: Bool
    var readRate: Double = 0
    var writeRate: Double = 0
    var readBytes: UInt64 = 0
    var writeBytes: UInt64 = 0
    /// Rodzaj nośnika rozpoznany z flag IOKit
    var category: String {
        if isInternal { return L("Dysk wewnętrzny") }
        let ic = interconnect.lowercased()
        if ic.contains("secure digital") || ic.contains("card") { return L("Karta pamięci") }
        if ic.contains("virtual") { return L("Obraz dysku") }
        // pendrive: wymienny nośnik USB bez zadeklarowanego typu SSD
        if removable, medium != "SSD" { return "Pendrive" }
        return L("Dysk zewnętrzny")
    }

    /// Ikona pasująca do rodzaju nośnika
    var icon: String {
        switch category {
        case "Dysk wewnętrzny": return "internaldrive"
        case "Pendrive": return "mediastick"
        case "Karta pamięci": return "sdcard"
        default: return "externaldrive"
        }
    }

    /// Opis w stylu „Dysk wewnętrzny · SSD · NVMe · Apple Fabric”
    var kind: String {
        [category, medium.isEmpty ? nil : medium, architecture.isEmpty ? nil : architecture,
         interconnect.isEmpty ? nil : interconnect].compactMap { $0 }.joined(separator: " · ")
    }
}

struct Snapshot {
    var cpu = CpuStats()
    var power = SCPower()
    var freq: HelperPower? = nil          // taktowania i moc z powermetrics (pomocnik)
    var dcInWatts: Double? = nil
    var temps: [Sensor] = []
    var powerKeys: [Sensor] = []     // SMC P*
    var voltageKeys: [Sensor] = []   // SMC V*
    var currentKeys: [Sensor] = []   // SMC I*
    var fanKeys: [Sensor] = []       // SMC F*
    var mem = SCMem()
    var disk = SCDisk()
    var disks: [DiskDevice] = []
    var disksGeneration = 0
    var interfaces: [NetInterface] = []
    var interfacesGeneration = 0
    var rates = SystemRates()
    var net = SCNet()
    var gpu = SCGpuStats()
    var gpuUtil: Double? { gpu.device >= 0 ? gpu.device : nil }
    var battery: Battery? = nil
    var processes: [ProcInfo] = []
    var totalThreads = 0
    var loadAvg: [Double] = [0, 0, 0]
    var uptime: Double = 0
    var generation = 0
    var processGeneration = 0
    var timestamp = Date()
    var thermalState = Foundation.ProcessInfo.ThermalState.nominal
    var sysWatts: Double? { power.sysWatts > 0 ? power.sysWatts : nil }

    func tempMax(_ prefixes: [String]) -> Double? {
        let v = temps.filter { t in prefixes.contains { t.name.hasPrefix($0) } }.map(\.value)
        return v.isEmpty ? nil : v.max()
    }
    func tempAvg(_ prefixes: [String]) -> Double? {
        let v = temps.filter { t in prefixes.contains { t.name.hasPrefix($0) } }.map(\.value)
        return v.isEmpty ? nil : v.reduce(0, +) / Double(v.count)
    }
    var cpuTemp: Double? { tempMax(["Tp", "Te"]) }
    var pCoreTemp: Double? { tempMax(["Tp"]) }
    var eCoreTemp: Double? { tempMax(["Te"]) }
    var gpuTemp: Double? { tempMax(["Tg"]) }
    var batteryTemp: Double? { tempAvg(["TB"]) }
    var ssdTemp: Double? { tempMax(["TH"]) }
    var wifiTemp: Double? { tempMax(["TW"]) }
    /// Najgorętszy czujnik SoC (jak „hotspot” w TMOG)
    var hotspot: Double? { tempMax(["Tp", "Te", "Tg", "TC", "TV"]) }

    var thermalText: String {
        switch thermalState {
        case .nominal: return L("nominalna")
        case .fair: return L("podwyższona")
        case .serious: return L("poważna")
        case .critical: return "krytyczna"
        @unknown default: return L("nieznana")
        }
    }
    var memPressureText: String {
        switch mem.pressureLevel { case 4: return L("krytyczna"); case 2: return L("ostrzeżenie"); default: return L("normalna") }
    }
}

final class Monitor {
    static let shared = Monitor()

    let hardware: Hardware
    private(set) var latest = Snapshot()
    /// Historia ostatnich pomiarów – pozwala cofnąć się na wykresie do wybranej chwili
    private(set) var history: [HistorySample] = []
    /// Ile próbek trzymamy (z zapasem na najdłuższy wykres)
    /// Ile widocznych stron potrzebuje pełnych odczytów czujników
    private(set) var sensorsInUse = 0
    func retainSensors() { sensorsInUse += 1 }
    func releaseSensors() { sensorsInUse = max(0, sensorsInUse - 1) }

    /// Poprzednie liczniki we/wy procesów, żeby pokazać tempo zamiast sumy od startu
    private var prevProcIO: [Int: (r: UInt64, w: UInt64, csw: UInt64)] = [:]

    private func applyDiskRates(_ dt: Double) {
        var next: [Int: (r: UInt64, w: UInt64, csw: UInt64)] = [:]
        next.reserveCapacity(lastProcesses.count)
        for i in lastProcesses.indices {
            let p = lastProcesses[i]
            next[p.pid] = (p.diskRead, p.diskWrite, p.contextSwitches)
            guard let old = prevProcIO[p.pid] else { continue }
            lastProcesses[i].diskReadRate = p.diskRead >= old.r ? Double(p.diskRead - old.r) / dt : 0
            lastProcesses[i].diskWriteRate = p.diskWrite >= old.w ? Double(p.diskWrite - old.w) / dt : 0
            lastProcesses[i].cswRate = p.contextSwitches >= old.csw ? Double(p.contextSwitches - old.csw) / dt : 0
        }
        prevProcIO = next
    }

    private var lastDisks: [DiskDevice] = []
    private var lastDisksAt = Date.distantPast
    private var disksGeneration = 0
    private var prevMem: SCMem? = nil
    private var prevMemAt = Date.distantPast
    private var prevCsw: UInt64 = 0
    private var prevCswAt = Date.distantPast
    private var lastRates = SystemRates()

    /// Liczy tempa stronicowania, kompresji i przełączeń kontekstu
    private func computeRates(_ mem: SCMem, _ now: Date) -> SystemRates {
        var r = lastRates
        if let p = prevMem {
            let dt = max(0.05, now.timeIntervalSince(prevMemAt))
            func rate(_ a: UInt64, _ b: UInt64) -> Double { a >= b ? Double(a - b) / dt : 0 }
            r.pageIn = rate(mem.pageIns, p.pageIns)
            r.pageOut = rate(mem.pageOuts, p.pageOuts)
            r.swapIn = rate(mem.swapIns, p.swapIns)
            r.swapOut = rate(mem.swapOuts, p.swapOuts)
            r.faults = rate(mem.faults, p.faults)
            r.cowFaults = rate(mem.cowFaults, p.cowFaults)
            r.compressions = rate(mem.compressions, p.compressions)
            r.decompressions = rate(mem.decompressions, p.decompressions)
        }
        if mem.lookups > 0 { r.cacheHitRatio = Double(mem.hits) / Double(mem.lookups) }
        prevMem = mem
        prevMemAt = now
        lastRates = r
        return r
    }

    private var lastIfaces: [NetInterface] = []
    private var lastIfacesAt = Date.distantPast
    private var ifacesGeneration = 0

    /// Interfejsy sieciowe z policzonym tempem transferu (getifaddrs jest tani, ale nie ma po co wołać go 4x/s)
    private func sampleInterfaces(_ now: Date) -> [NetInterface] {
        guard now.timeIntervalSince(lastIfacesAt) >= 0.05 || lastIfaces.isEmpty else { return lastIfaces }
        let dt = max(0.1, now.timeIntervalSince(lastIfacesAt))
        let first = lastIfaces.isEmpty
        lastIfacesAt = now
        ifacesGeneration += 1
        let prev = Dictionary(uniqueKeysWithValues: lastIfaces.map { ($0.name, $0) })
        var out = Self.interfaces()
        if !first {
            for i in out.indices {
                guard let p = prev[out[i].name] else { continue }
                let rx = out[i].rxBytes >= p.rxBytes ? Double(out[i].rxBytes - p.rxBytes) / dt : 0
                let tx = out[i].txBytes >= p.txBytes ? Double(out[i].txBytes - p.txBytes) / dt : 0
                out[i].rxRate = p.rxRate * 0.55 + rx * 0.45
                out[i].txRate = p.txRate * 0.55 + tx * 0.45
            }
        }
        lastIfaces = out
        return out
    }

    /// Lista dysków fizycznych z policzonym transferem (IOKit jest kosztowny, więc co ~2 s)
    private func sampleDisks(_ now: Date) -> [DiskDevice] {
        guard now.timeIntervalSince(lastDisksAt) >= 0.05 || lastDisks.isEmpty else { return lastDisks }
        disksGeneration += 1
        let dt = max(0.1, now.timeIntervalSince(lastDisksAt))
        let first = lastDisks.isEmpty
        lastDisksAt = now
        var raw = [SCDiskDevice](repeating: SCDiskDevice(), count: 32)
        let n = Int(sc_disk_devices(&raw, 32))
        let prev = Dictionary(uniqueKeysWithValues: lastDisks.map { ($0.bsd + $0.name, $0) })
        var out: [DiskDevice] = []
        out.reserveCapacity(n)
        for i in 0..<n {
            let r = raw[i]
            var d = DiskDevice(bsd: cString(r.bsd), name: cString(r.name), interconnect: cString(r.interconnect),
                               medium: cString(r.medium), architecture: cString(r.architecture), link: cString(r.link),
                               size: r.size, isInternal: r.internalDisk != 0, removable: r.removable != 0)
            d.readBytes = r.readBytes
            d.writeBytes = r.writeBytes
            if !first, let p = prev[d.bsd + d.name] {
                // przy krótkim odstępie liczniki są ziarniste, więc tempo lekko wygładzamy
                let r = d.readBytes >= p.readBytes ? Double(d.readBytes - p.readBytes) / dt : 0
                let w = d.writeBytes >= p.writeBytes ? Double(d.writeBytes - p.writeBytes) / dt : 0
                d.readRate = p.readRate * 0.55 + r * 0.45
                d.writeRate = p.writeRate * 0.55 + w * 0.45
            }
            out.append(d)
        }
        lastDisks = out
        return out
    }

    private let historyLimit = 1500
    /// Ile procesów zapamiętujemy w każdej próbce
    private let historyTopCount = 30
    private(set) var memoryDescription = ""   // np. "LPDDR5 · Hynix" (system_profiler)
    private let queue = DispatchQueue(label: "online.equishow.vitals.sampler", qos: .userInitiated)
    /// Kosztowne odczyty (SMC ~90 ms, XPC do pomocnika) idą osobno, żeby nie rozjeżdżać rytmu próbkowania
    private let auxQueue = DispatchQueue(label: "online.equishow.vitals.aux", qos: .utility)
    private var auxTimer: DispatchSourceTimer?
    private var auxBusy = false
    private var timer: DispatchSourceTimer?
    private let sampler: OpaquePointer
    private var generation = 0
    private var procGeneration = 0
    private var lastProcesses: [ProcInfo] = []
    private var lastThreads = 0
    private var lastTemps: [Sensor] = []
    private var lastPower: [Sensor] = [], lastVolt: [Sensor] = [], lastCurr: [Sensor] = [], lastFan: [Sensor] = []
    private var tick = 0
    // każdy rodzaj danych ma własną częstotliwość – tanie metryki idą z pełną prędkością
    private var lastProcAt = Date.distantPast
    private var lastTempAt = Date.distantPast
    private var lastKeysAt = Date.distantPast
    private var lastPowerAt = Date.distantPast
    private(set) var helperActive = false
    private var lastHelperPower: SCPower?
    private var lastGoodPower: SCPower?
    private var lastGoodPowerAt = Date.distantPast
    private var lastSMCPower = SCPower()
    private var lastDCWatts: Double?
    private var lastHelperFreq: HelperPower?

    var interval: TimeInterval = UserDefaults.standard.double(forKey: "refresh") > 0 ? UserDefaults.standard.double(forKey: "refresh") : 0.1 {
        didSet {
            UserDefaults.standard.set(interval, forKey: "refresh")
            start()
        }
    }

    private init() {
        var hwi = Hardware(sc_read_hardware())
        var cores: Int32 = 0
        var arch = [CChar](repeating: 0, count: 32)
        if sc_ane_info(&cores, &arch, 32) { hwi.aneCores = Int(cores); hwi.aneArch = String(cString: arch) }
        hardware = hwi
        sampler = sc_sampler_create()
        _ = sc_sample_cpu(sampler); _ = sc_sample_net(sampler); _ = sc_sample_disk(sampler)
        var n: Int32 = 0, t: Int32 = 0
        sc_free_processes(sc_sample_processes(sampler, &n, &t))
        Shell.async("/usr/sbin/system_profiler", ["-json", "SPMemoryDataType"], timeout: 30) { [weak self] out in
            guard let data = out.data(using: .utf8), let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let arr = json["SPMemoryDataType"] as? [[String: Any]], let first = arr.first else { return }
            var parts: [String] = []
            if let t = first["dimm_type"] as? String { parts.append(t) }
            if let m = first["dimm_manufacturer"] as? String { parts.append(m) }
            self?.memoryDescription = parts.joined(separator: " · ")
        }
    }

    func start() {
        timer?.cancel()
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 0.2, repeating: interval, leeway: .milliseconds(20))
        t.setEventHandler { [weak self] in self?.sample() }
        t.resume()
        timer = t
    }

    func sampleNow() { queue.async { [weak self] in self?.sample() } }

    /// Zleca w tle kosztowne odczyty, których wyniki trafiają do pól używanych przez `sample()`
    private func scheduleAux(_ now: Date) {
        guard !auxBusy else { return }
        let sensorsHot = sensorsInUse > 0 || Prefs.shared.menuBarItem >= 3
        let needPower = now.timeIntervalSince(lastPowerAt) >= 0.9 || lastSMCPower.sysWatts == 0
        let needTemps = now.timeIntervalSince(lastTempAt) >= (sensorsHot ? 2.4 : 8.0) || lastTemps.isEmpty
        let needKeys = now.timeIntervalSince(lastKeysAt) >= (sensorsHot ? 2.8 : 12.0) || lastPower.isEmpty
        guard needPower || needTemps || needKeys else { return }
        auxBusy = true
        if needPower { lastPowerAt = now }
        if needTemps { lastTempAt = now }
        if needKeys { lastKeysAt = now }
        let helper = helperActive
        auxQueue.async { [weak self] in
            guard let self else { return }
            var power: SCPower? = nil
            var helperPower: HelperPower? = nil
            var temps: [Sensor]? = nil
            var keys: (p: [Sensor], v: [Sensor], i: [Sensor], f: [Sensor])? = nil
            var dc: Double? = nil
            if needPower {
                power = sc_power_sample()
                let raw = sc_smc_read_float("PDTR")
                dc = raw.isFinite && raw > 0 ? raw : nil
                if helper { helperPower = HelperClient.shared.fetchPower() }
            }
            if needTemps {
                var sensors = [SCSensor](repeating: SCSensor(), count: 200)
                let nt = Int(sc_smc_read_temps(&sensors, 200))
                temps = (0..<nt).map { Sensor(name: cString(sensors[$0].name), value: sensors[$0].value) }
            }
            if needKeys {
                keys = (self.readKeys("P"), self.readKeys("V"), self.readKeys("I"), self.readKeys("F"))
            }
            self.queue.async {
                if let power { self.lastSMCPower = power }
                self.lastDCWatts = needPower ? dc : self.lastDCWatts
                if let hp = helperPower {
                    var pw = SCPower()
                    pw.sysWatts = self.lastSMCPower.sysWatts
                    pw.cpuWatts = hp.cpuWatts; pw.gpuWatts = hp.gpuWatts; pw.aneWatts = hp.aneWatts; pw.dramWatts = hp.dramWatts
                    pw.available = hp.available
                    self.lastHelperPower = pw
                    var hf = hp
                    if hf.gpuFreqMHz > 0, hf.gpuFreqMHz < 1 { hf.gpuFreqMHz *= 1e6 }
                    self.lastHelperFreq = hf
                }
                if let temps { self.lastTemps = temps }
                if let keys { self.lastPower = keys.p; self.lastVolt = keys.v; self.lastCurr = keys.i; self.lastFan = keys.f }
                self.auxBusy = false
            }
        }
    }

    private func readKeys(_ prefix: Character) -> [Sensor] {
        var arr = [SCSensor](repeating: SCSensor(), count: 200)
        let n = Int(sc_smc_read_keys(CChar(prefix.asciiValue!), &arr, 200))
        return (0..<n).map { Sensor(name: cString(arr[$0].name), value: arr[$0].value) }
    }

    private func sample() {
        var s = Snapshot()
        tick += 1
        s.cpu = CpuStats(sc_sample_cpu(sampler))
        s.mem = sc_read_mem()
        s.disk = sc_sample_disk(sampler)
        s.net = sc_sample_net(sampler)
        s.gpu = sc_gpu_stats()
        let b = Battery(sc_read_battery())
        s.battery = b.present ? b : nil
        // lista procesów co ~2 s
        let now = Date()
        if now.timeIntervalSince(lastProcAt) >= 0.5 || lastProcesses.isEmpty {
            let procDt = max(0.05, now.timeIntervalSince(lastProcAt))
            defer { applyDiskRates(procDt) }
            lastProcAt = now
            if !Self.isRoot, let hl = HelperClient.shared.fetchProcesses() {
                // pełne dane z pomocnika uprzywilejowanego
                lastProcesses = hl.processes.map { ProcInfo($0) }
                lastThreads = hl.totalThreads
                helperActive = true
            } else {
                var count: Int32 = 0, threads: Int32 = 0
                if let arr = sc_sample_processes(sampler, &count, &threads) {
                    lastProcesses = (0..<Int(count)).map { ProcInfo(arr[$0]) }
                    sc_free_processes(arr)
                }
                lastThreads = Int(threads)
                helperActive = false
            }
            // suma przełączeń kontekstu wszystkich procesów → tempo na sekundę
            let csw = lastProcesses.reduce(UInt64(0)) { $0 &+ $1.contextSwitches }
            if prevCsw > 0, csw >= prevCsw {
                let dt = max(0.05, now.timeIntervalSince(prevCswAt))
                lastRates.contextSwitches = Double(csw - prevCsw) / dt
            }
            prevCsw = csw
            prevCswAt = now
            procGeneration += 1
        }
        s.processes = lastProcesses
        s.totalThreads = lastThreads
        s.processGeneration = procGeneration
        var la = [Double](repeating: 0, count: 3)
        sc_load_average(&la)
        s.loadAvg = la
        s.uptime = sc_uptime_seconds()
        s.thermalState = Foundation.ProcessInfo.processInfo.thermalState
        s.power = lastSMCPower
        if helperActive, let pw = lastHelperPower {
            // pomocnik podaje CPU/GPU/ANE/DRAM z powermetrics, ale silnik wideo i ISP mamy tylko z IOReport
            let io = s.power
            s.power = pw
            s.power.sysWatts = io.sysWatts
            s.power.encoderWatts = io.encoderWatts
            s.power.decoderWatts = io.decoderWatts
            s.power.ispWatts = io.ispWatts
            s.power.displayWatts = io.displayWatts
            s.freq = lastHelperFreq
        }
        // powermetrics bywa chwilowo bez próbki; zamiast migać kreską trzymamy ostatni dobry odczyt
        if s.power.available {
            lastGoodPower = s.power
            lastGoodPowerAt = now
        } else if let g = lastGoodPower, now.timeIntervalSince(lastGoodPowerAt) < 6 {
            let sys = s.power.sysWatts
            s.power = g
            if sys > 0 { s.power.sysWatts = sys }
        }
        s.dcInWatts = lastDCWatts
        scheduleAux(now)
        s.rates = computeRates(s.mem, now)
        s.disks = sampleDisks(now)
        s.disksGeneration = disksGeneration
        s.interfaces = sampleInterfaces(now)
        s.interfacesGeneration = ifacesGeneration
        s.temps = lastTemps
        s.powerKeys = lastPower; s.voltageKeys = lastVolt; s.currentKeys = lastCurr; s.fanKeys = lastFan
        generation += 1
        s.generation = generation
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.latest = s
            self.appendHistory(s)
            AlertCenter.shared.evaluate(s)
            NotificationCenter.default.post(name: .snapshotUpdated, object: s)
        }
    }

    /// Wygładzone (EMA) użycie CPU per proces – surowy pomiar z jednego ticku jest kwantowany
    /// tykami jądra i skacze 0/1 %, co widać było w historii pod kursorem wykresu
    private var procCPUAvg: [Int: Double] = [:]

    private func appendHistory(_ s: Snapshot) {
        var live = Set<Int>()
        for p in s.processes where p.accessible {
            live.insert(p.pid)
            let prev = procCPUAvg[p.pid] ?? p.cpuPercent
            procCPUAvg[p.pid] = prev + (p.cpuPercent - prev) * 0.35
        }
        for pid in procCPUAvg.keys where !live.contains(pid) { procCPUAvg[pid] = nil }
        let top = s.processes.filter { $0.accessible }
            .map { (p: $0, cpu: procCPUAvg[$0.pid] ?? $0.cpuPercent) }
            .sorted { $0.cpu > $1.cpu }
            .prefix(historyTopCount)
            .map { HistoryProc(pid: $0.p.pid, name: $0.p.name, cpu: $0.cpu, mem: $0.p.memBytes, accessible: true) }
        var sample = HistorySample(time: s.timestamp, generation: s.generation, cpuTotal: s.cpu.total,
                                   cpuSystem: s.cpu.system, memUsed: s.mem.total > 0 ? s.mem.used : 0,
                                   processCount: s.processes.count, top: Array(top))
        sample.cpuUser = s.cpu.user
        sample.memSwap = s.mem.swapUsed
        sample.diskRead = s.disk.readRate
        sample.diskWrite = s.disk.writeRate
        sample.netRx = s.net.rxRate
        sample.netTx = s.net.txRate
        sample.sysWatts = s.sysWatts ?? 0
        sample.cpuWatts = s.power.available ? s.power.cpuWatts : 0
        sample.gpuUtil = s.gpuUtil ?? 0
        sample.hotspotC = s.hotspot ?? 0
        sample.batteryPercent = s.battery?.percent ?? 0
        sample.threads = s.totalThreads
        history.append(sample)
        HistoryExport.shared.record(sample)
        if history.count > historyLimit { history.removeFirst(history.count - historyLimit) }
    }

    static func volumes() -> [Volume] {
        var n: Int32 = 0
        guard let arr = sc_read_volumes(&n) else { return [] }
        defer { sc_free_volumes(arr) }
        return (0..<Int(n)).map { Volume(arr[$0]) }
    }

    static func interfaces() -> [NetInterface] {
        var n: Int32 = 0
        guard let arr = sc_read_interfaces(&n) else { return [] }
        defer { sc_free_interfaces(arr) }
        return (0..<Int(n)).map { NetInterface(arr[$0]) }
    }

    static var isRoot: Bool { sc_is_root() }
    /// Pełny dostęp do danych: root albo działający pomocnik uprzywilejowany
    static var privileged: Bool { isRoot || shared.helperActive }
}
