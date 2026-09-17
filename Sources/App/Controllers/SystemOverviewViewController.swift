// SystemOverviewViewController.swift - strona „Informacje o systemie”: skrót najważniejszych faktów o maszynie
import AppKit
import IOKit
import HelperKit

final class SystemOverviewViewController: NSViewController, PageRefreshable {
    private let hw = Monitor.shared.hardware
    private let grid = TileGridView()
    private var fields: [String: FlashLabel] = [:]
    private var securityText: [String: String] = [:]
    private var securityAt = Date.distantPast

    override func loadView() {
        view = NSView()
        let title = PageTitleView(L("Informacje o systemie"))

        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true; scroll.scrollerStyle = .overlay; scroll.autohidesScrollers = true
        let doc = FlippedView()
        scroll.documentView = doc
        grid.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(grid)
        doc.translatesAutoresizingMaskIntoConstraints = false
        let height = grid.heightAnchor.constraint(equalToConstant: 600)
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: doc.topAnchor, constant: 4),
            grid.leadingAnchor.constraint(equalTo: doc.leadingAnchor),
            grid.trailingAnchor.constraint(equalTo: doc.trailingAnchor),
            grid.bottomAnchor.constraint(lessThanOrEqualTo: doc.bottomAnchor, constant: -16),
            doc.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            height,
        ])
        grid.onHeightChange = { h in height.constant = max(200, h) }
        grid.minColumnWidth = 360
        grid.items = [
            card("os", "System", "apple.logo", [
                "Nazwa systemu", "Wersja", "Kompilacja", "Jądro", "Architektura", "Czas pracy", "Uruchomiony",
            ]),
            card("machine", "Komputer", "laptopcomputer", [
                "Model", "Identyfikator", "Numer seryjny", "Procesor", "Rdzenie", "Grafika", "Neural Engine", "Pamięć",
            ]),
            card("storage", "Pamięć masowa", "internaldrive", [
                "Dysk systemowy", "Wolne miejsce", "Dyski fizyczne", "Łączna pojemność", "Stan SMART dysku systemowego",
            ]),
            card("network", "Sieć", "network", [
                "Nazwa komputera", "Nazwa hosta", "Aktywne łącze", "Adres IPv4", "Adres sprzętowy", "Router", "Serwery DNS",
            ]),
            card("user", "Użytkownik i sesja", "person.crop.circle", [
                "Zalogowany", "Katalog domowy", "Powłoka", "Uprawnienia administratora", "Zalogowanych użytkowników",
            ]),
            card("security", "Bezpieczeństwo", "lock.shield", [
                "SIP", "FileVault", "Gatekeeper", "Zapora sieciowa",
            ]),
            card("load", "Bieżący stan", "gauge.with.dots.needle.33percent", [
                "Procesy", "Wątki", "Obciążenie CPU", "Pamięć w użyciu", "Najgorętszy czujnik", "Pobór mocy",
            ]),
            card("app", "Aplikacja", "info.circle", [
                "Wersja", "Pomocnik uprzywilejowany", "Tempo pomiarów", "Zakres wykresów",
            ]),
        ]

        let root = vstack([title, scroll], spacing: 6)
        for v in [title, scroll] { v.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true }
        scroll.setContentHuggingPriority(.init(1), for: .vertical)
        root.pin(to: view, insets: NSEdgeInsets(top: 2, left: 18, bottom: 10, right: 18))

        NotificationCenter.default.addObserver(self, selector: #selector(snapshot(_:)), name: .snapshotUpdated, object: nil)
    }

    /// Karta z listą par klucz–wartość
    private func card(_ id: String, _ title: String, _ icon: String, _ keys: [String]) -> TileGridView.Item {
        let c = CardView()
        let head = hstack([symbol(icon, size: 14, weight: .regular, color: P.textDim),
                           Label.make(title, size: 12.5, weight: .semibold), spacer()], spacing: 8)
        let rows = vstack([], spacing: 4)
        for k in keys {
            let key = Label.make(L(k), size: 11.5, dim: true)
            key.size(width: 165)
            let value = FlashLabel(L("—"), size: 11.5)
            value.lineBreakMode = .byTruncatingTail
            fields[id + "." + k] = value
            let r = hstack([key, value, spacer()], spacing: 8)
            rows.addArrangedSubview(r)
            r.widthAnchor.constraint(equalTo: rows.widthAnchor).isActive = true
        }
        let v = vstack([head, rows], spacing: 8)
        head.widthAnchor.constraint(equalTo: v.widthAnchor).isActive = true
        rows.widthAnchor.constraint(equalTo: v.widthAnchor).isActive = true
        v.pin(to: c, insets: NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 14))
        return TileGridView.Item(id: id, title: L(title), view: c, span: 1, height: CGFloat(58 + keys.count * 20))
    }

    private func set(_ id: String, _ key: String, _ value: String) {
        fields[id + "." + key]?.update(value.isEmpty ? L("—") : value, flash: false)
    }

    func pageDidAppear() { if let s = Monitor.shared.latest as Snapshot? { fill(s) } }

    @objc private func snapshot(_ n: Notification) {
        guard let s = n.object as? Snapshot, view.window != nil, !view.isHiddenOrHasHiddenAncestor else { return }
        fill(s)
    }

    private var lastFill = Date.distantPast

    private func fill(_ s: Snapshot) {
        guard Date().timeIntervalSince(lastFill) > 1 else { return }
        lastFill = Date()
        refreshSecurityIfNeeded()
        let os = ProcessInfo.processInfo.operatingSystemVersion

        set("os", "Nazwa systemu", "macOS \(hw.osVersion)")
        set("os", "Wersja", "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)")
        set("os", "Kompilacja", hw.osBuild)
        set("os", "Jądro", hw.kernel)
        set("os", "Architektura", hw.arch)
        set("os", "Czas pracy", Fmt.duration(s.uptime))
        if let boot = hw.bootTime {
            let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .short
            set("os", "Uruchomiony", f.string(from: boot))
        }

        set("machine", "Model", hw.marketingName)
        set("machine", "Identyfikator", hw.model)
        set("machine", "Numer seryjny", Self.serialNumber())
        set("machine", "Procesor", hw.cpuBrand)
        set("machine", "Rdzenie", "\(hw.ncpu) logicznych · \(hw.perfCores) P + \(hw.effCores) E")
        set("machine", "Grafika", "\(hw.gpuName) · \(hw.gpuCores) " + L("rdzeni"))
        set("machine", "Neural Engine", hw.aneCores > 0 ? "\(hw.aneCores) " + L("rdzeni") + " · \(hw.aneArch)" : "—")
        set("machine", "Pamięć", Fmt.bytes(hw.memTotal, precision: 0) + " " + Monitor.shared.memoryDescription)

        if let root = Monitor.volumes().first(where: { $0.mount == "/" }) {
            set("storage", "Dysk systemowy", "\(Fmt.bytes(root.total, precision: 0)) · \(root.fs)")
            set("storage", "Wolne miejsce", "\(Fmt.bytes(root.free)) (\(Fmt.percent(100 * Double(root.free) / Double(max(1, root.total)))))")
        }
        set("storage", "Dyski fizyczne", "\(s.disks.count)")
        set("storage", "Łączna pojemność", Fmt.bytes(s.disks.reduce(UInt64(0)) { $0 + $1.size }, precision: 0))
        if let sys = s.disks.first(where: { $0.isInternal }), let d = DiskDetails.shared.detail(for: sys.bsd) {
            let extra = d.percentageUsed.map { " · " + L("zużycie") + " \($0)%" } ?? ""
            set("storage", "Stan SMART dysku systemowego", (d.smartStatus.isEmpty ? "—" : d.smartStatus) + extra)
        }

        set("network", "Nazwa komputera", Host.current().localizedName ?? hw.hostname)
        set("network", "Nazwa hosta", hw.hostname)
        if let itf = s.interfaces.first(where: { $0.up && $0.addrs.contains(".") && $0.name != "lo0" }) {
            let kind = NetInfo.kind(for: itf.name)
            set("network", "Aktywne łącze", "\(kind.display) (\(itf.name)) · \(kind.type)")
            set("network", "Adres IPv4", itf.addrs.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.first { $0.contains(".") } ?? "—")
            set("network", "Adres sprzętowy", itf.mac)
            let cfg = NetInfo.ipConfig(for: itf.name)
            set("network", "Router", cfg.router ?? "—")
            set("network", "Serwery DNS", cfg.dns.isEmpty ? "—" : cfg.dns.joined(separator: ", "))
        }

        set("user", "Zalogowany", NSUserName() + " (" + NSFullUserName() + ")")
        set("user", "Katalog domowy", NSHomeDirectory())
        set("user", "Powłoka", ProcessInfo.processInfo.environment["SHELL"] ?? "—")
        set("user", "Uprawnienia administratora", Monitor.isRoot ? "root" : (Monitor.privileged ? "przez pomocnika" : "zwykły użytkownik"))
        let users = Set(s.processes.filter { $0.uid >= 500 }.map(\.user)).sorted()
        set("user", "Zalogowanych użytkowników", users.isEmpty ? "—" : users.joined(separator: ", "))

        for (k, v) in securityText { set("security", k, v) }

        set("load", "Procesy", "\(s.processes.count)")
        set("load", "Wątki", "\(s.totalThreads)")
        set("load", "Obciążenie CPU", "\(Fmt.percent(s.cpu.total)) · " + L("obciążenie") + " \(String(format: "%.2f", s.loadAvg[0]))")
        set("load", "Pamięć w użyciu", "\(Fmt.bytes(s.mem.used)) z \(Fmt.bytes(s.mem.total, precision: 0)) · \(s.memPressureText)")
        set("load", "Najgorętszy czujnik", s.hotspot.map { Fmt.temp($0) } ?? "—")
        set("load", "Pobór mocy", s.sysWatts.map { Fmt.watts($0) } ?? "—")

        set("app", "Wersja", AppVersion.full)
        set("app", "Pomocnik uprzywilejowany", Monitor.shared.helperActive ? "aktywny" : "nieaktywny")
        set("app", "Tempo pomiarów", String(format: L("%.0f na sekundę"), 1 / max(0.01, Monitor.shared.interval)))
        set("app", "Zakres wykresów", "\(Prefs.shared.graphSpanSeconds) s")
    }

    private func refreshSecurityIfNeeded() {
        guard Date().timeIntervalSince(securityAt) > 300 else { return }
        securityAt = Date()
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let sip = Shell.run("/usr/bin/csrutil", ["status"], timeout: 6).trimmingCharacters(in: .whitespacesAndNewlines)
            let fv = Shell.run("/usr/bin/fdesetup", ["status"], timeout: 8).trimmingCharacters(in: .whitespacesAndNewlines)
            let gk = Shell.run("/usr/sbin/spctl", ["--status"], timeout: 6).trimmingCharacters(in: .whitespacesAndNewlines)
            let fwRaw = Shell.run("/usr/bin/defaults", ["read", "/Library/Preferences/com.apple.alf", "globalstate"], timeout: 6)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let fw = Int(fwRaw) ?? -1
            DispatchQueue.main.async {
                self?.securityText = [
                    "SIP": sip.isEmpty ? "—" : sip.replacingOccurrences(of: "System Integrity Protection status: ", with: ""),
                    "FileVault": fv.isEmpty ? "—" : fv,
                    "Gatekeeper": gk.isEmpty ? "—" : gk,
                    "Zapora sieciowa": fw <= 0 ? "wyłączona" : (fw == 2 ? "włączona (blokuje przychodzące)" : "włączona"),
                ]
            }
        }
    }

    /// Numer seryjny z IORegistry
    private static func serialNumber() -> String {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        defer { if service != 0 { IOObjectRelease(service) } }
        guard service != 0,
              let v = IORegistryEntryCreateCFProperty(service, "IOPlatformSerialNumber" as CFString, kCFAllocatorDefault, 0),
              let s = v.takeUnretainedValue() as? String else { return "—" }
        return s
    }
}
