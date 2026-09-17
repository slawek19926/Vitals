// Alerts.swift - progi ostrzeżeń, powiadomienia systemowe i dziennik zdarzeń
import AppKit
import UserNotifications

/// Zdarzenie zapisane w dzienniku alertów
struct AlertEvent {
    let time: Date
    let rule: String
    let title: String
    let detail: String
    let level: HealthLevel
    /// true = warunek ustąpił
    let resolved: Bool
}

final class AlertCenter {
    static let shared = AlertCenter()

    private(set) var events: [AlertEvent] = []
    private var active: [String: Date] = [:]          // reguła → od kiedy warunek trwa
    private var firedAt: [String: Date] = [:]         // reguła → kiedy ostatnio powiadomiono
    private var lastCheck = Date.distantPast
    private var authorized = false
    private let maxEvents = 300

    /// Minimalny czas trwania warunku, zanim zgłosimy alert (tłumi chwilowe skoki)
    private let sustain: TimeInterval = 5
    /// Nie powtarzamy tego samego alertu częściej niż co
    private let repeatAfter: TimeInterval = 600

    func requestAuthorizationIfNeeded() {
        guard Prefs.shared.alertsEnabled, !authorized else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { [weak self] ok, _ in
            DispatchQueue.main.async { self?.authorized = ok }
        }
    }

    /// Sprawdza progi na podstawie bieżącego pomiaru
    func evaluate(_ s: Snapshot) {
        guard Prefs.shared.alertsEnabled else { return }
        let now = Date()
        guard now.timeIntervalSince(lastCheck) > 1 else { return }
        lastCheck = now
        let p = Prefs.shared

        var conditions: [(id: String, on: Bool, title: String, detail: String, level: HealthLevel)] = []

        if let hot = s.hotspot {
            conditions.append(("temp", hot >= Double(p.alertTempC), L("Wysoka temperatura"),
                               L("Najgorętszy czujnik") + ": \(Fmt.temp(hot)) (" + L("próg") + " \(p.alertTempC) °C)",
                               hot >= Double(p.alertTempC) + 10 ? .critical : .warning))
        }
        conditions.append(("cpu", s.cpu.total >= Double(p.alertCPUPercent), L("Wysokie obciążenie procesora"),
                           "\(Fmt.percent(s.cpu.total)) " + L("przez co najmniej") + " \(Int(sustain)) s (" + L("próg") + " \(p.alertCPUPercent)%)", .warning))

        let swapGB = Double(s.mem.swapUsed) / 1_073_741_824
        conditions.append(("swap", swapGB >= Double(p.alertSwapGB), L("Duże użycie swapu"),
                           "\(Fmt.bytes(s.mem.swapUsed)) " + L("w pliku wymiany") + " (" + L("próg") + " \(p.alertSwapGB) GB)", .warning))
        conditions.append(("mempressure", s.mem.pressureLevel >= 2, "Presja pamięci",
                           L("System zgłasza presję") + ": \(s.memPressureText)", s.mem.pressureLevel >= 4 ? .critical : .warning))

        if let v = Monitor.volumes().first(where: { $0.mount == "/" }), v.total > 0 {
            let freePct = 100.0 * Double(v.free) / Double(v.total)
            conditions.append(("space", freePct <= Double(p.alertFreeSpacePercent), L("Mało miejsca na dysku systemowym"),
                               "\(Fmt.bytes(v.free)) " + L("wolnego, czyli") + " \(Fmt.percent(freePct)) (" + L("próg") + " \(p.alertFreeSpacePercent)%)",
                               freePct <= 3 ? .critical : .warning))
        }
        if let b = s.battery, b.present, !b.onAC {
            conditions.append(("battery", b.percent <= p.alertBatteryPercent, "Niski poziom baterii",
                               "\(b.percent)% " + L("naładowania") + " (" + L("próg") + " \(p.alertBatteryPercent)%)",
                               b.percent <= 10 ? .critical : .warning))
        }
        if p.alertProcessCPU > 0, let top = s.processes.filter({ $0.accessible }).max(by: { $0.cpuPercent < $1.cpuPercent }),
           top.cpuPercent >= Double(p.alertProcessCPU) {
            conditions.append(("proc-\(top.pid)", true, L("Proces obciąża procesor"),
                               "\(top.name) (PID \(top.pid)) " + L("używa") + " \(Fmt.percent(top.cpuPercent)) (" + L("próg") + " \(p.alertProcessCPU)%)", .warning))
        }

        var seen = Set<String>()
        for c in conditions {
            seen.insert(c.id)
            if c.on {
                let since = active[c.id] ?? now
                active[c.id] = since
                guard now.timeIntervalSince(since) >= sustain else { continue }
                let last = firedAt[c.id] ?? .distantPast
                guard now.timeIntervalSince(last) >= repeatAfter else { continue }
                firedAt[c.id] = now
                log(AlertEvent(time: now, rule: c.id, title: c.title, detail: c.detail, level: c.level, resolved: false))
                notify(title: c.title, body: c.detail)
            } else if active[c.id] != nil {
                active[c.id] = nil
                if firedAt[c.id] != nil {
                    log(AlertEvent(time: now, rule: c.id, title: c.title + L(" — ustąpiło"), detail: c.detail, level: .ok, resolved: true))
                }
            }
        }
        // reguły dla procesów znikają wraz z procesem
        for id in active.keys where !seen.contains(id) && id.hasPrefix("proc-") { active[id] = nil }
    }

    private func log(_ e: AlertEvent) {
        events.insert(e, at: 0)
        if events.count > maxEvents { events.removeLast(events.count - maxEvents) }
        NotificationCenter.default.post(name: .alertsChanged, object: nil)
    }

    private func notify(title: String, body: String) {
        guard Prefs.shared.alertNotifications else { return }
        requestAuthorizationIfNeeded()
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = Prefs.shared.alertSound ? .default : nil
        let req = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req, withCompletionHandler: nil)
    }

    func clear() {
        events.removeAll()
        NotificationCenter.default.post(name: .alertsChanged, object: nil)
    }
}

extension Notification.Name {
    static let alertsChanged = Notification.Name("AlertsChanged")
}
