// MenuBarPopover.swift - panel pojedynczego modułu paska menu: wykres i szczegóły tej jednej metryki
import AppKit

final class ModulePopoverController: NSViewController {
    let kind: WidgetKind
    /// true = pełne listy odczytów (jak panel Czujników w Stats), false = skrót
    let detailed: Bool
    private let detailStack = vstack([], spacing: 2)
    private var detailRows: [String: FlashLabel] = [:]
    private var detailOrder: [String] = []
    private let value = FlashLabel("—", size: 20, weight: .semibold, mono: true)
    private let caption = Label.make("", size: 11, dim: true)
    private let graph: GraphView
    private var rows: [(key: String, label: FlashLabel)] = []
    private let listTitle = Label.make("", size: 10.5, weight: .semibold, dim: true)
    private let listRows: [(name: FlashLabel, value: FlashLabel)] = (0..<5).map { _ in
        (FlashLabel("", size: 11), FlashLabel("", size: 11, mono: true))
    }

    init(kind: WidgetKind, detailed: Bool = false) {
        self.kind = kind
        self.detailed = detailed
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

        var content: [NSView] = [head, caption, graph]
        var scrollView: NSScrollView?
        if detailed {
            let scroll = NSScrollView()
            scroll.drawsBackground = false
            scroll.hasVerticalScroller = true
            scroll.scrollerStyle = .overlay
            scroll.autohidesScrollers = true
            let doc = FlippedView()
            scroll.documentView = doc
            detailStack.pin(to: doc, insets: NSEdgeInsets(top: 0, left: 0, bottom: 8, right: 0))
            doc.translatesAutoresizingMaskIntoConstraints = false
            doc.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor).isActive = true
            scroll.heightAnchor.constraint(equalToConstant: 420).isActive = true
            scrollView = scroll
            content.append(scroll)
        } else {
            content += [kv, listTitle, list]
        }
        content.append(hstack([open, settings, spacer(), quit], spacing: 8))
        let stack = vstack(content, spacing: 8)
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -14),
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12),
            root.widthAnchor.constraint(equalToConstant: detailed ? 360 : 330),
        ])
        // widok przewijany musi dostać szerokość ze stosu, inaczej zwija się do zera
        if let scrollView { scrollView.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }

        NotificationCenter.default.addObserver(self, selector: #selector(snapshot(_:)), name: .snapshotUpdated, object: nil)
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    @objc private func snapshot(_ n: Notification) {
        guard let s = n.object as? Snapshot, view.window?.isVisible == true else { return }
        graph.push(kind.values(s))
        value.update(kind.headline(s), flash: false)
        caption.stringValue = kind.caption(s)
        if detailed {
            fillDetailed(s)
        } else {
            let data = details(s)
            for r in rows { r.label.update(data[r.key] ?? "—", flash: false) }
            fillList(s)
        }
    }

    /// Grupy odczytów w trybie rozbudowanym: nazwa sekcji i pary nazwa–wartość
    private func groups(_ s: Snapshot) -> [(String, [(String, String)])] {
        let hw = Monitor.shared.hardware
        switch kind {
        case .cpu:
            var cores: [(String, String)] = []
            for (i, v) in s.cpu.perCore.enumerated() {
                let sys = i < s.cpu.perCoreSystem.count ? s.cpu.perCoreSystem[i] : 0
                let label = i < hw.perfCores ? L("Rdzeń P") : L("Rdzeń E")
                cores.append(("\(label) \(i)", "\(Fmt.percent(v)) · \(L("jądro")) \(Fmt.percent(sys))"))
            }
            let load = (0..<3).map { String(format: "%.2f", s.loadAvg[$0]) }.joined(separator: " / ")
            return [(L("Rdzenie"), cores),
                    (L("Ogólnie"), [(L("Wykorzystanie"), Fmt.percent(s.cpu.total)),
                                    (L("Użytkownik"), Fmt.percent(s.cpu.user)),
                                    (L("System (jądro)"), Fmt.percent(s.cpu.system)),
                                    (L("Obciążenie 1 / 5 / 15 min"), load),
                                    (L("Procesy"), "\(s.processes.count)"),
                                    (L("Wątki"), "\(s.totalThreads)"),
                                    (L("Przełączenia kontekstu/s"), Fmt.number(UInt64(max(0, s.rates.contextSwitches))))]),
                    (L("Najcięższe procesy"), s.processes.sorted { $0.cpuPercent > $1.cpuPercent }.prefix(8).map { ($0.name, Fmt.percent($0.cpuPercent)) })]
        case .memory:
            return [(L("Pamięć"), [(L("W użyciu"), Fmt.bytes(s.mem.used)), (L("Aplikacje"), Fmt.bytes(s.mem.app)),
                                   (L("Pamięć zablokowana"), Fmt.bytes(s.mem.wired)), (L("Skompresowana"), Fmt.bytes(s.mem.compressed)),
                                   (L("Cache"), Fmt.bytes(s.mem.cached)), (L("Dostępne"), Fmt.bytes(s.mem.total - min(s.mem.total, s.mem.used))),
                                   (L("Razem"), Fmt.bytes(s.mem.total, precision: 0)), (L("Presja"), s.memPressureText)]),
                    (L("Plik wymiany"), [(L("Swap użyty"), Fmt.bytes(s.mem.swapUsed)), (L("Swap dostępny"), Fmt.bytes(s.mem.swapFree)),
                                         (L("Page in"), Fmt.number(s.mem.pageIns)), (L("Page out"), Fmt.number(s.mem.pageOuts))]),
                    (L("Największe procesy (pamięć)"), s.processes.sorted { $0.memBytes > $1.memBytes }.prefix(8).map { ($0.name, Fmt.bytes($0.memBytes)) })]
        case .gpu:
            var rows: [(String, String)] = [(L("Układ"), hw.gpuName), (L("Rdzenie"), "\(hw.gpuCores)"),
                                            (L("Wykorzystanie"), s.gpuUtil.map { Fmt.percent($0) } ?? "—")]
            if let f = s.freq, f.gpuFreqMHz > 0 { rows.append((L("Taktowanie"), Fmt.frequencyMHz(f.gpuFreqMHz))) }
            if s.power.available { rows.append((L("Moc"), Fmt.watts(s.power.gpuWatts, precision: 3))) }
            let temps = s.temps.filter { $0.name.hasPrefix("Tg") }.map { (PowerFreqViewController.describe($0.name), Fmt.temp($0.value)) }
            return [(L("GPU"), rows), (L("Temperatury GPU"), temps)]
        case .temperature:
            let temps = s.temps.sorted { $0.value > $1.value }.map { (PowerFreqViewController.describe($0.name), Fmt.temp($0.value)) }
            let fans = s.fanKeys.map { ($0.name, String(format: "%.0f " + L("obr/min"), $0.value)) }
            return [(L("Temperatura"), temps), (L("Wentylatory (F*)"), fans)]
        case .network:
            var groups: [(String, [(String, String)])] = []
            for itf in Monitor.interfaces().filter({ $0.up && !$0.addrs.isEmpty }).prefix(6) {
                let k = NetInfo.kind(for: itf.name)
                groups.append(("\(k.display) (\(itf.name))",
                               [(L("Typ połączenia"), k.type), (L("Adres IPv4"), itf.addrs),
                                (L("Odbiór"), Fmt.rate(itf.rxRate)), (L("Nadawanie"), Fmt.rate(itf.txRate)),
                                (L("Łącznie odebrano"), Fmt.bytes(itf.rxBytes)), (L("Łącznie wysłano"), Fmt.bytes(itf.txBytes))]))
            }
            return groups
        case .disk:
            var groups: [(String, [(String, String)])] = []
            for d in s.disks.prefix(6) {
                groups.append((d.name.isEmpty ? d.bsd : d.name,
                               [(L("Rodzaj"), d.category), (L("Pojemność"), Fmt.bytes(d.size, precision: 0)),
                                (L("Odczyt"), Fmt.rate(d.readRate)), (L("Zapis"), Fmt.rate(d.writeRate))]))
            }
            let vols = Monitor.volumes().filter(\.local).prefix(4).map {
                ($0.mount, "\(Fmt.bytes($0.free)) " + L("wolne") + " / \(Fmt.bytes($0.total, precision: 0))")
            }
            groups.append((L("Woluminy"), Array(vols)))
            return groups
        case .power:
            var rows: [(String, String)] = [(L("Moc systemu"), s.sysWatts.map { Fmt.watts($0) } ?? "—")]
            if s.power.available {
                rows += [(L("Moc CPU"), Fmt.watts(s.power.cpuWatts, precision: 3)),
                         (L("Moc GPU"), Fmt.watts(s.power.gpuWatts, precision: 3)),
                         (L("Moc ANE"), Fmt.watts(s.power.aneWatts, precision: 3)),
                         ("DRAM", Fmt.watts(s.power.dramWatts, precision: 3))]
            }
            if let b = s.battery, b.present {
                rows += [(L("Bateria"), "\(b.percent)%"), (L("Stan"), b.charging ? L("ładowanie") : (b.onAC ? L("zasilanie sieciowe") : L("rozładowanie"))),
                         (L("Cykle ładowania"), "\(b.cycleCount)"), (L("Kondycja"), b.health)]
            }
            let smcPower = s.powerKeys.map { (PowerFreqViewController.describe($0.name), String(format: "%.2f W", $0.value)) }
            let volts = s.voltageKeys.map { (PowerFreqViewController.describe($0.name), String(format: "%.3f V", $0.value)) }
            let amps = s.currentKeys.map { (PowerFreqViewController.describe($0.name), String(format: "%.3f A", $0.value)) }
            return [(L("Moc"), rows), (L("Klucze mocy (P*)"), smcPower), (L("Napięcie"), volts), (L("Prąd"), amps)]
        }
    }

    /// Buduje albo odświeża listę odczytów; przy zmianie zestawu wierszy przestawia widoki
    private func fillDetailed(_ s: Snapshot) {
        let data = groups(s)
        let order = data.flatMap { g in g.1.map { g.0 + "|" + $0.0 } }
        if order != detailOrder {
            detailOrder = order
            detailRows.removeAll()
            for v in detailStack.arrangedSubviews { detailStack.removeArrangedSubview(v); v.removeFromSuperview() }
            for (title, entries) in data where !entries.isEmpty {
                let header = Label.make(title.uppercased(), size: 9.5, weight: .semibold, dim: true)
                detailStack.addArrangedSubview(header)
                detailStack.setCustomSpacing(4, after: header)
                for (name, _) in entries {
                    let value = FlashLabel("—", size: 11, mono: true)
                    value.alignment = .right
                    detailRows[title + "|" + name] = value
                    let row = hstack([Label.make(name, size: 11), spacer(), value], spacing: 8)
                    detailStack.addArrangedSubview(row)
                    row.widthAnchor.constraint(equalTo: detailStack.widthAnchor).isActive = true
                }
                detailStack.setCustomSpacing(10, after: detailStack.arrangedSubviews.last!)
            }
        }
        for (title, entries) in data {
            for (name, value) in entries { detailRows[title + "|" + name]?.update(value, flash: false) }
        }
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
