// MenuBarPopover.swift - panel pojedynczego modułu paska menu: wykres i szczegóły tej jednej metryki
import AppKit

final class ModulePopoverController: NSViewController {
    let kind: WidgetKind
    private let value = FlashLabel("—", size: 20, weight: .semibold, mono: true)
    private let caption = Label.make("", size: 11, dim: true)
    private let graph: GraphView
    private var rows: [(key: String, label: FlashLabel)] = []
    private let listTitle = Label.make("", size: 10.5, weight: .semibold, dim: true)
    private let listRows: [(name: FlashLabel, value: FlashLabel)] = (0..<5).map { _ in
        (FlashLabel("", size: 11), FlashLabel("", size: 11, mono: true))
    }

    init(kind: WidgetKind) {
        self.kind = kind
        graph = GraphView(series: kind.series, history: 180, accents: Array(repeating: kind.accent, count: kind.series))
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Wiersze klucz–wartość zależne od metryki
    private var keys: [String] {
        switch kind {
        case .cpu: return ["Użytkownik", "System (jądro)", "Bezczynność", "Taktowanie", "Procesy", "Wątki"]
        case .memory: return ["W użyciu", "Dostępne", "Cache", "Skompresowana", "Swap użyty", "Presja"]
        case .gpu: return ["Układ", "Rdzenie", "Wykorzystanie", "Moc", "Taktowanie", "Pamięć"]
        case .temperature: return ["Najgorętszy czujnik", "Rdzenie wydajnościowe", "Rdzenie energooszczędne", "GPU", "SSD", "Presja termiczna"]
        case .network: return ["Interfejs", "Typ połączenia", "Adres IPv4", "Odbiór", "Nadawanie", "Łącznie"]
        case .disk: return ["Odczyt", "Zapis", "Łącznie odczytano", "Łącznie zapisano", "Dyski", "Dysk systemowy"]
        case .power: return ["Moc systemu", "Moc CPU", "Moc GPU", "Bateria", "Źródło zasilania", "Stan termiczny"]
        }
    }

    private var listHeader: String {
        switch kind {
        case .memory: return L("Największe procesy (pamięć)")
        case .disk: return L("Dyski fizyczne")
        case .network: return L("Interfejsy")
        default: return L("Najcięższe procesy")
        }
    }

    override func loadView() {
        let root = ThemedView()
        view = root

        value.textColor = P.accent(kind.accent)
        graph.compact = true
        graph.fillAlpha = 0.16
        if kind.isPercent { graph.maxValue = 100 } else { graph.autoScale = true }
        graph.heightAnchor.constraint(equalToConstant: 64).isActive = true
        if kind.series == 2 {
            graph.colorProvider = { [kind] i, p in
                i == 0 ? p.accent(kind.accent) : (p.accent(kind.accent).blended(withFraction: 0.45, of: .white) ?? p.accent(kind.accent))
            }
        }

        let head = hstack([Label.make(kind.title, size: 12, weight: .semibold), spacer(), value], spacing: 8)

        var kvViews: [NSView] = []
        for k in keys {
            let label = FlashLabel("—", size: 11, mono: true)
            label.alignment = .right
            rows.append((k, label))
            let key = Label.make(L(k) + ":", size: 11, dim: true)
            kvViews.append(hstack([key, spacer(), label], spacing: 8))
        }
        let kv = vstack(kvViews, spacing: 2)

        listTitle.stringValue = listHeader
        let list = vstack(listRows.map { hstack([$0.name, spacer(), $0.value], spacing: 8) }, spacing: 2)

        let open = NSButton(title: L("Pokaż Vitals"), target: NSApp.delegate, action: #selector(AppDelegate.showMainWindow(_:)))
        let settings = NSButton(title: L("Ustawienia…"), target: NSApp.delegate, action: #selector(AppDelegate.openSettings))
        let quit = NSButton(title: L("Zakończ"), target: NSApp, action: #selector(NSApplication.terminate(_:)))
        for b in [open, settings, quit] { b.bezelStyle = .rounded; b.controlSize = .small; b.font = Fonts.ui(11.5) }

        let stack = vstack([head, caption, graph, kv, listTitle, list, hstack([open, settings, spacer(), quit], spacing: 8)], spacing: 8)
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -14),
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12),
            root.widthAnchor.constraint(equalToConstant: 330),
        ])

        NotificationCenter.default.addObserver(self, selector: #selector(snapshot(_:)), name: .snapshotUpdated, object: nil)
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    @objc private func snapshot(_ n: Notification) {
        guard let s = n.object as? Snapshot, view.window?.isVisible == true else { return }
        graph.push(kind.values(s))
        value.update(kind.headline(s), flash: false)
        caption.stringValue = kind.caption(s)
        let data = details(s)
        for r in rows { r.label.update(data[r.key] ?? "—", flash: false) }
        fillList(s)
    }

    /// Wartości wierszy klucz–wartość dla bieżącej migawki
    private func details(_ s: Snapshot) -> [String: String] {
        let hw = Monitor.shared.hardware
        switch kind {
        case .cpu:
            return ["Użytkownik": Fmt.percent(s.cpu.user), "System (jądro)": Fmt.percent(s.cpu.system),
                    "Bezczynność": Fmt.percent(s.cpu.idle),
                    "Taktowanie": s.freq.map { "P \(Fmt.frequencyMHz($0.pFreqMHz)) · E \(Fmt.frequencyMHz($0.eFreqMHz))" } ?? "—",
                    "Procesy": "\(s.processes.count)", "Wątki": "\(s.totalThreads)"]
        case .memory:
            return ["W użyciu": Fmt.bytes(s.mem.used), "Dostępne": Fmt.bytes(s.mem.total - min(s.mem.total, s.mem.used)),
                    "Cache": Fmt.bytes(s.mem.cached), "Skompresowana": Fmt.bytes(s.mem.compressed),
                    "Swap użyty": Fmt.bytes(s.mem.swapUsed), "Presja": s.memPressureText]
        case .gpu:
            return ["Układ": hw.gpuName, "Rdzenie": "\(hw.gpuCores)",
                    "Wykorzystanie": s.gpuUtil.map { Fmt.percent($0) } ?? "—",
                    "Moc": s.power.available ? Fmt.watts(s.power.gpuWatts, precision: 2) : "—",
                    "Taktowanie": s.freq.map { Fmt.frequencyMHz($0.gpuFreqMHz) } ?? "—",
                    "Pamięć": Fmt.bytes(s.mem.total, precision: 0)]
        case .temperature:
            func temp(_ prefixes: [String]) -> String {
                let vals = s.temps.filter { t in prefixes.contains { t.name.hasPrefix($0) } }.map(\.value)
                return vals.isEmpty ? "—" : Fmt.temp(vals.max() ?? 0)
            }
            return ["Najgorętszy czujnik": s.hotspot.map { Fmt.temp($0) } ?? "—",
                    "Rdzenie wydajnościowe": temp(["Tp"]), "Rdzenie energooszczędne": temp(["Te"]),
                    "GPU": temp(["Tg"]), "SSD": temp(["TH"]), "Presja termiczna": s.thermalText]
        case .network:
            let itf = Monitor.interfaces().first { $0.up && !$0.addrs.isEmpty }
            let kindInfo = itf.map { NetInfo.kind(for: $0.name) }
            return ["Interfejs": kindInfo?.display ?? "—", "Typ połączenia": kindInfo?.type ?? "—",
                    "Adres IPv4": itf?.addrs ?? "—",
                    "Odbiór": Fmt.rate(s.net.rxRate), "Nadawanie": Fmt.rate(s.net.txRate),
                    "Łącznie": "↓ \(Fmt.bytes(s.net.rxBytes)) ↑ \(Fmt.bytes(s.net.txBytes))"]
        case .disk:
            return ["Odczyt": Fmt.rate(s.disk.readRate), "Zapis": Fmt.rate(s.disk.writeRate),
                    "Łącznie odczytano": Fmt.bytes(s.disk.readBytes), "Łącznie zapisano": Fmt.bytes(s.disk.writeBytes),
                    "Dyski": "\(s.disk.diskCount)",
                    "Dysk systemowy": Monitor.volumes().first { $0.mount == "/" }.map { "\(Fmt.bytes($0.free)) " + L("wolne") } ?? "—"]
        case .power:
            return ["Moc systemu": s.sysWatts.map { Fmt.watts($0) } ?? "—",
                    "Moc CPU": s.power.available ? Fmt.watts(s.power.cpuWatts, precision: 2) : "—",
                    "Moc GPU": s.power.available ? Fmt.watts(s.power.gpuWatts, precision: 2) : "—",
                    "Bateria": s.battery.map { "\($0.percent)%" } ?? L("brak"),
                    "Źródło zasilania": s.battery.map { $0.onAC ? L("Zasilanie sieciowe") : L("Bateria") } ?? "—",
                    "Stan termiczny": s.thermalText]
        }
    }

    /// Dolna lista: procesy, dyski albo interfejsy – zależnie od modułu
    private func fillList(_ s: Snapshot) {
        var items: [(String, String)] = []
        switch kind {
        case .memory:
            items = s.processes.sorted { $0.memBytes > $1.memBytes }.prefix(5).map { ($0.name, Fmt.bytes($0.memBytes)) }
        case .disk:
            items = s.disks.prefix(5).map { ($0.name.isEmpty ? $0.bsd : $0.name, "R \(Fmt.rate($0.readRate))  W \(Fmt.rate($0.writeRate))") }
        case .network:
            items = Monitor.interfaces().filter { $0.up && !$0.addrs.isEmpty }.prefix(5)
                .map { (NetInfo.kind(for: $0.name).display, "↓ \(Fmt.rate($0.rxRate))  ↑ \(Fmt.rate($0.txRate))") }
        default:
            items = s.processes.sorted { $0.cpuPercent > $1.cpuPercent }.prefix(5).map { ($0.name, Fmt.percent($0.cpuPercent)) }
        }
        for (i, row) in listRows.enumerated() {
            if i < items.count {
                row.name.update(items[i].0, flash: false)
                row.value.update(items[i].1, flash: false)
            } else {
                row.name.update("", flash: false)
                row.value.update("", flash: false)
            }
        }
    }
}
