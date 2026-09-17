// SystemHealth.swift - reguły oceny stanu maszyny: miejsce, SMART, bateria, termika, pamięć, bezpieczeństwo
import Foundation

enum HealthLevel: Int, Comparable {
    case ok = 0, info = 1, warning = 2, critical = 3
    static func < (a: HealthLevel, b: HealthLevel) -> Bool { a.rawValue < b.rawValue }
    var title: String { L(["W porządku", "Informacja", "Ostrzeżenie", "Uwaga"][rawValue]) }
}

/// Pojedynczy wynik kontroli
struct HealthItem {
    let id: String
    let category: String
    let title: String
    let detail: String
    let level: HealthLevel
    /// Strona aplikacji, do której warto przejść (indeks w pasku bocznym), albo nil
    var page: Int? = nil
}

/// Liczy listę kontroli na podstawie bieżącego pomiaru i danych czytanych w tle
final class HealthChecker {
    static let shared = HealthChecker()

    private var security: [String: String] = [:]
    private var securityAt = Date.distantPast
    private var securityPending = false

    /// Stan zabezpieczeń (SIP, FileVault, zapora, Gatekeeper) – wolne wywołania, więc w tle i z cache
    private func refreshSecurityIfNeeded() {
        guard !securityPending, Date().timeIntervalSince(securityAt) > 300 else { return }
        securityPending = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var out: [String: String] = [:]
            out["sip"] = Shell.run("/usr/bin/csrutil", ["status"], timeout: 6).trimmingCharacters(in: .whitespacesAndNewlines)
            out["filevault"] = Shell.run("/usr/bin/fdesetup", ["status"], timeout: 8).trimmingCharacters(in: .whitespacesAndNewlines)
            out["gatekeeper"] = Shell.run("/usr/sbin/spctl", ["--status"], timeout: 6).trimmingCharacters(in: .whitespacesAndNewlines)
            out["firewall"] = Shell.run("/usr/bin/defaults", ["read", "/Library/Preferences/com.apple.alf", "globalstate"], timeout: 6)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            DispatchQueue.main.async {
                self?.security = out
                self?.securityAt = Date()
                self?.securityPending = false
            }
        }
    }

    func check(_ s: Snapshot) -> [HealthItem] {
        refreshSecurityIfNeeded()
        var items: [HealthItem] = []

        // --- miejsce na dyskach
        for v in Monitor.volumes() where v.local && v.total > 0 {
            let freePct = 100.0 * Double(v.free) / Double(v.total)
            let level: HealthLevel = freePct < 5 ? .critical : (freePct < 10 ? .warning : (freePct < 20 ? .info : .ok))
            items.append(HealthItem(id: "space-" + v.mount, category: L("Miejsce na dysku"),
                                    title: v.mount == "/" ? L("Dysk systemowy") : v.mount,
                                    detail: "\(Fmt.bytes(v.free)) " + L("wolnego z") + " \(Fmt.bytes(v.total, precision: 0)) · \(Fmt.percent(freePct)) " + L("wolne"),
                                    level: level, page: 12))
        }

        // --- SMART dysków fizycznych
        for d in s.disks {
            guard let x = DiskDetails.shared.detail(for: d.bsd) else { continue }
            if x.hasSMART {
                var level = HealthLevel.ok
                var notes: [String] = []
                if let used = x.percentageUsed {
                    notes.append(L("zużycie komórek") + " \(used)%")
                    if used >= 90 { level = max(level, .critical) } else if used >= 75 { level = max(level, .warning) }
                }
                if let spare = x.availableSpare, spare < 100 {
                    notes.append(L("zapas bloków") + " \(spare)%")
                    if spare < 20 { level = max(level, .critical) } else if spare < 50 { level = max(level, .warning) }
                }
                if let err = x.mediaErrors, err > 0 { notes.append(L("błędy nośnika") + ": \(err)"); level = max(level, .warning) }
                if let t = x.temperatureC { notes.append(Fmt.temp(t)); if t > 70 { level = max(level, .warning) } }
                if x.smartStatus != "Verified", !x.smartStatus.isEmpty, x.smartStatus != "Not Supported" {
                    notes.append(L("status SMART") + ": \(x.smartStatus)"); level = max(level, .critical)
                }
                items.append(HealthItem(id: "smart-" + d.bsd, category: L("Nośniki"),
                                        title: "\(d.name.isEmpty ? d.bsd : d.name) (\(d.bsd))",
                                        detail: notes.isEmpty ? L("SMART bez zastrzeżeń") : notes.joined(separator: " · "),
                                        level: level, page: 1))
            }
        }

        // --- bateria
        if let b = s.battery, b.present {
            var level = HealthLevel.ok
            var notes: [String] = ["\(b.cycleCount) " + L("cykli")]
            if !b.health.isEmpty, b.health != "—" { notes.append(b.health) }
            if b.designCapacity > 0, b.nominalCapacity > 0 {
                let wear = 100.0 * Double(b.nominalCapacity) / Double(b.designCapacity)
                notes.insert(String(format: L("pojemność %.0f%% fabrycznej"), wear), at: 0)
                if wear < 70 { level = .critical } else if wear < 80 { level = .warning } else if wear < 90 { level = .info }
            }
            if b.health.lowercased().contains("service") || b.health.lowercased().contains("replace") { level = .critical }
            if b.temperatureC > 40 { level = max(level, .warning); notes.append(Fmt.temp(b.temperatureC)) }
            items.append(HealthItem(id: "battery", category: L("Zasilanie"), title: L("Kondycja baterii"),
                                    detail: notes.joined(separator: " · "), level: level, page: 1))
        }

        // --- termika
        if let hot = s.hotspot {
            let level: HealthLevel = hot > 100 ? .critical : (hot > 90 ? .warning : (hot > 80 ? .info : .ok))
            items.append(HealthItem(id: "thermal", category: L("Termika"), title: L("Najgorętszy czujnik"),
                                    detail: "\(Fmt.temp(hot)) · " + L("presja termiczna") + " \(s.thermalText)", level: level, page: 6))
        }
        if s.thermalState != .nominal {
            items.append(HealthItem(id: "thermal-state", category: L("Termika"), title: L("Presja termiczna systemu"),
                                    detail: L("macOS zgłasza stan") + ": \(s.thermalText). " + L("Przy wysokiej presji system obniża taktowanie."),
                                    level: s.thermalState == .critical ? .critical : .warning, page: 6))
        }

        // --- pamięć
        let swapGB = Double(s.mem.swapUsed) / 1_073_741_824
        var memLevel: HealthLevel = s.mem.pressureLevel >= 4 ? .critical : (s.mem.pressureLevel >= 2 ? .warning : .ok)
        if swapGB > 8 { memLevel = max(memLevel, .warning) } else if swapGB > 2 { memLevel = max(memLevel, .info) }
        items.append(HealthItem(id: "memory", category: L("Pamięć"), title: L("Presja pamięci"),
                                detail: "\(s.memPressureText) · swap \(Fmt.bytes(s.mem.swapUsed)) · " + L("skompresowane") + " \(Fmt.bytes(s.mem.compressed))",
                                level: memLevel, page: 1))

        // --- obciążenie
        let cores = Double(max(1, Monitor.shared.hardware.ncpu))
        let load = s.loadAvg[0]
        let loadLevel: HealthLevel = load > cores * 2 ? .warning : (load > cores ? .info : .ok)
        items.append(HealthItem(id: "load", category: L("Procesor"), title: L("Obciążenie systemu"),
                                detail: String(format: L("%.2f / %.2f / %.2f przy %d procesorach logicznych"), s.loadAvg[0], s.loadAvg[1], s.loadAvg[2], Monitor.shared.hardware.ncpu),
                                level: loadLevel, page: 2))

        // --- procesy zombie
        let zombies = s.processes.filter { $0.state == "Zombie" }
        if !zombies.isEmpty {
            items.append(HealthItem(id: "zombies", category: L("Procesy"), title: L("Procesy zombie"),
                                    detail: "\(zombies.count): " + zombies.prefix(5).map(\.name).joined(separator: ", "),
                                    level: .warning, page: 2))
        }

        // --- czas pracy
        let days = s.uptime / 86400
        if days >= 14 {
            items.append(HealthItem(id: "uptime", category: L("System"), title: L("Długi czas pracy"),
                                    detail: String(format: L("%.0f dni bez restartu · warto zrestartować po aktualizacjach"), days),
                                    level: days >= 30 ? .warning : .info, page: 3))
        }

        // --- pomocnik
        if !Monitor.privileged {
            items.append(HealthItem(id: "helper", category: L("Aplikacja"), title: L("Pomocnik nieaktywny"),
                                    detail: L("Bez pomocnika brakuje pełnych danych o procesach innych użytkowników i mocy podsystemów."),
                                    level: .info, page: 14))
        }

        // --- zabezpieczenia
        if !security.isEmpty {
            let sip = security["sip"] ?? ""
            items.append(HealthItem(id: "sip", category: L("Bezpieczeństwo"), title: L("Ochrona integralności systemu (SIP)"),
                                    detail: sip.isEmpty ? L("nieznany") : sip,
                                    level: sip.lowercased().contains("enabled") ? .ok : .warning))
            let fv = security["filevault"] ?? ""
            items.append(HealthItem(id: "filevault", category: L("Bezpieczeństwo"), title: "FileVault",
                                    detail: fv.isEmpty ? L("nieznany") : fv,
                                    level: fv.lowercased().contains("on") ? .ok : .warning))
            let gk = security["gatekeeper"] ?? ""
            items.append(HealthItem(id: "gatekeeper", category: L("Bezpieczeństwo"), title: "Gatekeeper",
                                    detail: gk.isEmpty ? L("nieznany") : gk,
                                    level: gk.lowercased().contains("enabled") ? .ok : .warning))
            let fw = Int(security["firewall"] ?? "") ?? -1
            items.append(HealthItem(id: "firewall", category: L("Bezpieczeństwo"), title: L("Zapora sieciowa"),
                                    detail: fw <= 0 ? L("wyłączona") : (fw == 2 ? L("włączona, blokuje połączenia przychodzące") : L("włączona")),
                                    level: fw <= 0 ? .warning : .ok))
        }

        return items.sorted { a, b in
            a.level != b.level ? a.level > b.level : a.category < b.category
        }
    }
}
