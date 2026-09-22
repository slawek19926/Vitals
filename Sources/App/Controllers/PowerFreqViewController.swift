// PowerFreqViewController.swift - „Zasilanie i czujniki” (Power & Freq w TMOG): drzewo czujników z wartością, min i maks
import AppKit

/// Sposób odwzorowania wartości na skalę kolorów
enum ValueRange {
    case none
    case temperature(String)
    case fixed(Double, Double)
    case adaptive
}

final class SensorNode {
    /// true = węzeł grupujący pozycje o różnych jednostkach (nie pokazujemy dla niego wartości)
    var isHeterogeneousGroup = false
    /// false = wartość jest opisem, nie liczbą (min/maks nie mają sensu)
    var showsMinMax = true
    /// klucz czujnika temperatury (np. „Tp05”) — włącza kolorowanie wartości według progów
    var tempKey: String?
    /// zakres, według którego kolorowana jest wartość
    var range: ValueRange = .none
    /// true = im mniej, tym gorzej (np. poziom baterii)
    var inverted = false

    /// Poziom 0…1 dla bieżącej wartości albo nil, gdy wartość nie podlega kolorowaniu
    func heatLevel() -> Double? {
        guard let v = value else { return nil }
        var lvl: Double?
        switch range {
        case .none: lvl = tempKey.map { ThermalScale.level(v, key: $0) }
        case .temperature(let key): lvl = ThermalScale.level(v, key: key)
        case .fixed(let lo, let hi): lvl = (v - lo) / max(1e-9, hi - lo)
        case .adaptive:
            // skala względna: dolny koniec = najniższa zaobserwowana wartość, górny = najwyższa
            guard let mn = minV, let mx = maxV else { return nil }
            let span = mx - mn
            if span <= max(abs(mx) * 0.005, 1e-9) { return 0 }   // wartość stabilna → spokojny koniec skali
            lvl = (v - mn) / span
        }
        guard var l = lvl else { return nil }
        l = min(1, max(0, l))
        return inverted ? 1 - l : l
    }
    let title: String
    let icon: String?
    let accent: Subsystem?
    var children: [SensorNode] = []
    var value: Double?
    var minV: Double?, maxV: Double?
    var format: (Double) -> String
    var source: ((Snapshot) -> Double?)?
    lazy var cells: [FlashLabel] = (0..<4).map { i in
        let l = FlashLabel("", size: 12, weight: i == 0 && !children.isEmpty ? .semibold : .regular, mono: i > 0)
        if i > 0 { l.alignment = .right }
        return l
    }

    init(_ title: String, icon: String? = nil, accent: Subsystem? = nil, format: @escaping (Double) -> String = { Fmt.temp($0) }, source: ((Snapshot) -> Double?)? = nil) {
        self.title = L(title); self.icon = icon; self.accent = accent; self.format = format; self.source = source
    }

    func update(_ s: Snapshot) {
        if let src = source, let v = src(s) {
            value = v
            minV = min(minV ?? v, v); maxV = max(maxV ?? v, v)
        }
        for c in children { c.update(s) }
        // węzeł grupujący liście o wspólnej jednostce: wartość = maks. dzieci (jak TMOG), min/max z dzieci
        if source == nil, !children.isEmpty, !isHeterogeneousGroup {
            if children.allSatisfy({ $0.children.isEmpty && $0.source != nil }) {
                let vals = children.compactMap { $0.value }
                if let mx = vals.max() {
                    value = mx
                    minV = children.compactMap { $0.minV }.min()
                    maxV = children.compactMap { $0.maxV }.max()
                    format = children[0].format
                }
            } else {
                isHeterogeneousGroup = true
            }
        }
    }
}

final class PowerFreqViewController: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate, PageRefreshable {
    private let outline = NSOutlineView()
    private let search = NSSearchField()
    private var root: [SensorNode] = []
    /// Lista dysków, dla których zbudowano drzewo – zmiana oznacza podpięcie lub odłączenie nośnika
    private var builtDiskKeys: [String] = []
    private var built = false
    private var builtSensorKeys: [String] = []
    private let summary = Label.make("", size: 11.5, dim: true)

    override func loadView() {
        view = NSView()
        let title = PageTitleView(L("Zasilanie i czujniki"))
        let expand = NSButton(title: L("Rozwiń wszystko"), target: self, action: #selector(expandAll))
        let collapse = NSButton(title: L("Zwiń"), target: self, action: #selector(collapseAll))
        let reset = NSButton(title: L("Zeruj min/maks"), target: self, action: #selector(resetMinMax))
        for b in [expand, collapse, reset] { b.bezelStyle = .rounded; b.controlSize = .small; b.font = Fonts.ui(11.5) }
        search.placeholderString = L("Filtruj czujniki"); search.font = Fonts.ui(11.5); search.size(width: 220)
        search.target = self; search.action = #selector(filterChanged); search.sendsSearchStringImmediately = true
        title.accessory = hstack([expand, collapse, reset, search], spacing: 8)

        for (id, t, w) in [("sensor", "Czujnik", 420), ("value", "Wartość", 130), ("min", "Min", 130), ("max", "Maks", 130)] {
            let c = NSTableColumn(identifier: .init(id)); c.title = L(t); c.width = CGFloat(w); c.minWidth = 80
            if id != "sensor" { c.headerCell.alignment = .right }
            outline.addTableColumn(c)
        }
        outline.outlineTableColumn = outline.tableColumns[0]
        outline.rowHeight = 24
        outline.intercellSpacing = NSSize(width: 10, height: 1)
        outline.backgroundColor = .clear
        outline.style = .plain
        outline.focusRingType = .none
        outline.indentationPerLevel = 18
        outline.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        // prawy przycisk na nagłówku: wybór widocznych kolumn
        ColumnMenu.attach(to: outline, key: "sensors", locked: ["sensor"])
        outline.dataSource = self; outline.delegate = self
        let scroll = NSScrollView()
        scroll.documentView = outline; scroll.drawsBackground = false; scroll.hasVerticalScroller = true; scroll.scrollerStyle = .overlay; scroll.autohidesScrollers = true
        scroll.setContentHuggingPriority(.init(1), for: .vertical)
        let root = vstack([title, summary, scroll], spacing: 6)
        summary.lineBreakMode = .byWordWrapping
        summary.maximumNumberOfLines = 0
        for v in [title, summary, scroll] { v.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true }
        root.pin(to: view, insets: NSEdgeInsets(top: 2, left: 18, bottom: 10, right: 18))
        NotificationCenter.default.addObserver(self, selector: #selector(snapshot(_:)), name: .snapshotUpdated, object: nil)
        NotificationCenter.default.addObserver(forName: .themeChanged, object: nil, queue: .main) { [weak self] _ in
            self?.outline.reloadData()
            self?.update(Monitor.shared.latest)
        }
    }

    func pageDidAppear() { update(Monitor.shared.latest) }

    private static func sensorKeys(_ s: Snapshot) -> [String] {
        s.temps.map { "T:" + $0.name } + s.powerKeys.map { "P:" + $0.name } +
        s.voltageKeys.map { "V:" + $0.name } + s.currentKeys.map { "I:" + $0.name } +
        s.fanKeys.map { "F:" + $0.name }
    }

    private func build(_ s: Snapshot) {
        let hw = Monitor.shared.hardware
        func tempGroup(_ title: String, prefixes: [String], accent: Subsystem, excluding: [String] = []) -> SensorNode {
            let g = SensorNode(title, icon: "thermometer.medium", accent: accent)
            g.tempKey = prefixes.first
            g.range = .temperature(prefixes.first ?? "T")
            for t in s.temps.sorted(by: { $0.name < $1.name })
                where prefixes.contains(where: { t.name.hasPrefix($0) }) && !excluding.contains(where: { t.name.hasPrefix($0) }) {
                let name = t.name
                let node = SensorNode(Self.describe(name), accent: accent, source: { $0.temps.first { $0.name == name }?.value })
                node.tempKey = name
                node.range = .temperature(name)
                g.children.append(node)
            }
            return g
        }
        func keyGroup(_ title: String, icon: String, keys: [Sensor], path: KeyPath<Snapshot, [Sensor]>, unit: String, accent: Subsystem, filter: ((Sensor) -> Bool)? = nil) -> SensorNode {
            let g = SensorNode(title, icon: icon, accent: accent)
            for k in keys.sorted(by: { $0.name < $1.name }) where filter?(k) ?? true {
                let name = k.name
                let fmt: (Double) -> String = unit == "obr/min" ? { String(format: "%.0f obr/min", $0) } : { String(format: "%.3f \(unit)", $0) }
                let node = SensorNode(Self.describe(name), accent: accent, format: fmt, source: { $0[keyPath: path].first { $0.name == name }?.value })
                node.range = .adaptive
                g.children.append(node)
            }
            return g
        }
        let pct: (Double) -> String = { Fmt.percent($0) }
        let watt: (Double) -> String = { Fmt.watts($0, precision: 2) }

        let cpu = SensorNode(hw.cpuBrand + " (CPU)", icon: "cpu", accent: .cpu)
        cpu.children.append(tempGroup("Temperatury CPU (Tp*)", prefixes: ["Tp"], accent: .thermal))
        cpu.children.append(tempGroup("Temperatury CPU (Te*)", prefixes: ["Te"], accent: .thermal))
        let util = SensorNode("Wykorzystanie", icon: "gauge.with.dots.needle.33percent", accent: .cpu)
        util.children = [
            SensorNode("Łącznie", accent: .cpu, format: pct, source: { $0.cpu.total }),
            SensorNode("Użytkownik", accent: .cpu, format: pct, source: { $0.cpu.user }),
            SensorNode("System (jądro)", accent: .cpu, format: pct, source: { $0.cpu.system }),
        ] + (0..<hw.ncpu).map { i in SensorNode("CPU \(i)" + (i < hw.effCores ? " (E)" : " (P)"), accent: .cpu, format: pct, source: { i < $0.cpu.perCore.count ? $0.cpu.perCore[i] : nil }) }
        for c in util.children { c.range = .fixed(0, 100) }
        util.range = .fixed(0, 100)
        cpu.children.append(util)
        let cpuPower = SensorNode("Moc CPU", icon: "bolt", accent: .energy, format: watt, source: { $0.power.available ? $0.power.cpuWatts : nil })
        cpuPower.range = .fixed(0, 18)
        cpu.children.append(cpuPower)
        let mhz: (Double) -> String = { Fmt.frequencyMHz($0) }
        let clocks = SensorNode("Taktowanie", icon: "clock", accent: .cpu)
        let pClock = SensorNode("Klaster wydajnościowy (P)", accent: .cpu, format: mhz, source: { ($0.freq?.pFreqMHz ?? 0) > 0 ? $0.freq?.pFreqMHz : nil })
        pClock.range = .fixed(600, 4400)
        let eClock = SensorNode("Klaster energooszczędny (E)", accent: .cpu, format: mhz, source: { ($0.freq?.eFreqMHz ?? 0) > 0 ? $0.freq?.eFreqMHz : nil })
        eClock.range = .fixed(600, 2900)
        clocks.children = [pClock, eClock]
        clocks.range = .fixed(600, 4400)
        cpu.children.append(clocks)

        let gpu = SensorNode(hw.gpuName + " (GPU)", icon: "display", accent: .gpu)
        gpu.children.append(tempGroup("Temperatury GPU", prefixes: ["Tg"], accent: .thermal))
        let gu = SensorNode("Wykorzystanie", icon: "gauge.with.dots.needle.33percent", accent: .gpu)
        gu.children = [
            SensorNode("Urządzenie", accent: .gpu, format: pct, source: { $0.gpuUtil }),
            SensorNode("Renderer", accent: .gpu, format: pct, source: { $0.gpu.renderer >= 0 ? $0.gpu.renderer : nil }),
            SensorNode("Tiler", accent: .gpu, format: pct, source: { $0.gpu.tiler >= 0 ? $0.gpu.tiler : nil }),
        ]
        for c in gu.children { c.range = .fixed(0, 100) }
        gu.range = .fixed(0, 100)
        gpu.children.append(gu)
        let gpuMem = SensorNode("Pamięć GPU w użyciu", icon: "memorychip", accent: .gpu, format: { Fmt.bytes($0) }, source: { Double($0.gpu.memUsed) })
        gpuMem.range = .adaptive
        gpu.children.append(gpuMem)
        let gpuPower = SensorNode("Moc GPU", icon: "bolt", accent: .energy, format: watt, source: { $0.power.available ? $0.power.gpuWatts : nil })
        gpuPower.range = .fixed(0, 12)
        gpu.children.append(gpuPower)
        let gpuClock = SensorNode("Taktowanie GPU", icon: "clock", accent: .gpu, format: { Fmt.frequencyMHz($0) }, source: { ($0.freq?.gpuFreqMHz ?? 0) > 0 ? $0.freq?.gpuFreqMHz : nil })
        gpuClock.range = .fixed(300, 1600)
        gpu.children.append(gpuClock)

        let ane = SensorNode("Apple Neural Engine (ANE)", icon: "brain", accent: .npu)
        let anePower = SensorNode("Moc ANE", accent: .energy, format: watt, source: { $0.power.available ? $0.power.aneWatts : nil })
        anePower.range = .fixed(0, 5)
        ane.children.append(anePower)
        let aneState = SensorNode("Stan", accent: .npu, format: { $0 > 0.005 ? "aktywny" : "bezczynny (power gated)" }, source: { $0.power.available ? $0.power.aneWatts : nil })
        aneState.showsMinMax = false
        ane.children.append(aneState)

        let power = SensorNode("Zasilanie", icon: "bolt.circle", accent: .energy)
        let sysPower = SensorNode("Moc systemu (PSTR)", accent: .energy, format: watt, source: { $0.sysWatts }); sysPower.range = .fixed(0, 45)
        let dcPower = SensorNode("Wejście zasilacza (PDTR)", accent: .energy, format: watt, source: { $0.dcInWatts }); dcPower.range = .fixed(0, 45)
        let batFlow = SensorNode("Przepływ baterii", accent: .energy, format: watt, source: { $0.battery?.watts }); batFlow.range = .fixed(0, 40)
        power.children.append(contentsOf: [sysPower, dcPower, batFlow])
        let pkgPower = SensorNode("Moc pakietu SoC", accent: .energy, format: watt, source: { ($0.freq?.combinedWatts ?? 0) > 0 ? $0.freq?.combinedWatts : nil }); pkgPower.range = .fixed(0, 30)
        let dramPower = SensorNode("DRAM", accent: .energy, format: watt, source: { $0.power.available ? $0.power.dramWatts : nil }); dramPower.range = .fixed(0, 8)
        power.children.append(contentsOf: [pkgPower, dramPower])
        power.children.append(keyGroup("Pomiary mocy SMC", icon: "bolt", keys: s.powerKeys, path: \.powerKeys, unit: "W", accent: .energy))
        power.children.append(keyGroup("Napięcia szyn zasilania SMC", icon: "waveform", keys: s.voltageKeys, path: \.voltageKeys, unit: "V", accent: .energy))
        power.children.append(keyGroup("Prądy szyn zasilania SMC", icon: "waveform.path", keys: s.currentKeys, path: \.currentKeys, unit: "A", accent: .energy))

        let bat = SensorNode("Bateria", icon: "battery.100percent", accent: .energy)
        let batLevel = SensorNode("Poziom", accent: .energy, format: { String(format: "%.0f%%", $0) }, source: { $0.battery.map { Double($0.percent) } })
        batLevel.range = .fixed(0, 100); batLevel.inverted = true   // im mniej, tym gorzej
        let batVolt = SensorNode("Napięcie", accent: .energy, format: { String(format: "%.3f V", $0) }, source: { $0.battery.map { Double($0.voltage_mV) / 1000 } })
        batVolt.range = .adaptive
        let batAmp = SensorNode("Prąd", accent: .energy, format: { String(format: "%.0f mA", $0) }, source: { $0.battery.map { Double($0.amperage_mA) } })
        batAmp.range = .adaptive
        bat.children = [batLevel, batVolt, batAmp, tempGroup("Temperatury baterii", prefixes: ["TB"], accent: .thermal)]

        let mem = SensorNode("Pamięć", icon: "memorychip", accent: .memory)
        let total = Double(max(1, Monitor.shared.latest.mem.total))
        let memUsed = SensorNode("W użyciu", accent: .memory, format: { Fmt.bytes($0) }, source: { Double($0.mem.used) }); memUsed.range = .fixed(0, total)
        let memComp = SensorNode("Skompresowana", accent: .memory, format: { Fmt.bytes($0) }, source: { Double($0.mem.compressed) }); memComp.range = .fixed(0, total / 2)
        let memSwap = SensorNode("Swap", accent: .memory, format: { Fmt.bytes($0) }, source: { Double($0.mem.swapUsed) }); memSwap.range = .fixed(0, max(1, Double(Monitor.shared.latest.mem.swapTotal)))
        let memPress = SensorNode("Obciążenie presji", accent: .memory, format: pct, source: { Double(100 - $0.mem.freePercent) }); memPress.range = .fixed(0, 100)
        mem.children = [memUsed, memComp, memSwap, memPress, tempGroup("Temperatury pamięci", prefixes: ["Tm", "TM"], accent: .thermal)]

        let ssd = SensorNode("Pamięć masowa", icon: "internaldrive", accent: .disk)
        ssd.isHeterogeneousGroup = true
        let ssdRead = SensorNode("Odczyt (wszystkie dyski)", accent: .disk, format: { Fmt.rate($0) }, source: { $0.disk.readRate }); ssdRead.range = .adaptive
        let ssdWrite = SensorNode("Zapis (wszystkie dyski)", accent: .disk, format: { Fmt.rate($0) }, source: { $0.disk.writeRate }); ssdWrite.range = .adaptive
        let ssdBusy = SensorNode("Zajętość kolejek", accent: .disk, format: pct, source: { $0.disk.activeFraction * 100 }); ssdBusy.range = .fixed(0, 100)
        ssd.children = [tempGroup("Temperatury SSD", prefixes: ["TH"], accent: .thermal), ssdRead, ssdWrite, ssdBusy]

        // każdy fizyczny dysk osobno: transfer, temperatura i dane SMART
        builtDiskKeys = s.disks.map(\.bsd)
        for d in s.disks {
            let bsd = d.bsd
            let node = SensorNode("\(d.name.isEmpty ? bsd : d.name) (\(bsd))", icon: d.icon, accent: .disk)
            node.isHeterogeneousGroup = true
            let r = SensorNode("Odczyt", accent: .disk, format: { Fmt.rate($0) }, source: { $0.disks.first { $0.bsd == bsd }?.readRate }); r.range = .adaptive
            let w = SensorNode("Zapis", accent: .disk, format: { Fmt.rate($0) }, source: { $0.disks.first { $0.bsd == bsd }?.writeRate }); w.range = .adaptive
            let kind = SensorNode("Rodzaj", accent: .disk, format: { _ in d.kind }, source: { _ in 0 }); kind.showsMinMax = false
            let cap = SensorNode("Pojemność", accent: .disk, format: { Fmt.bytes(UInt64($0), precision: 0) }, source: { _ in Double(d.size) }); cap.showsMinMax = false
            node.children = [r, w, kind, cap]
            // dane SMART są czytane w tle; gdy ich nie ma (zwykle USB), węzły po prostu pokazują „—”
            let temp = SensorNode("Temperatura", accent: .thermal, format: { Fmt.temp($0) },
                                  source: { _ in DiskDetails.shared.detail(for: bsd)?.temperatureC })
            temp.range = .temperature("TH")
            let wear = SensorNode("Zużycie komórek", accent: .disk, format: { String(format: "%.0f%%", $0) },
                                  source: { _ in DiskDetails.shared.detail(for: bsd)?.percentageUsed.map(Double.init) })
            wear.range = .fixed(0, 100)
            let spare = SensorNode("Zapas bloków", accent: .disk, format: { String(format: "%.0f%%", $0) },
                                   source: { _ in DiskDetails.shared.detail(for: bsd)?.availableSpare.map(Double.init) })
            spare.range = .fixed(0, 100); spare.inverted = true
            let hours = SensorNode("Czas pracy", accent: .disk, format: { String(format: "%.0f h", $0) },
                                   source: { _ in DiskDetails.shared.detail(for: bsd)?.powerOnHours.map(Double.init) })
            hours.showsMinMax = false
            let cycles = SensorNode("Cykle zasilania", accent: .disk, format: { String(format: "%.0f", $0) },
                                    source: { _ in DiskDetails.shared.detail(for: bsd)?.powerCycles.map(Double.init) })
            cycles.showsMinMax = false
            let errors = SensorNode("Błędy nośnika", accent: .disk, format: { String(format: "%.0f", $0) },
                                    source: { _ in DiskDetails.shared.detail(for: bsd)?.mediaErrors.map(Double.init) })
            errors.range = .fixed(0, 1)
            node.children.append(contentsOf: [temp, wear, spare, hours, cycles, errors])
            ssd.children.append(node)
        }

        let other = tempGroup("Pozostałe odczyty temperatury", prefixes: ["T"], accent: .thermal,
                              excluding: ["Tp", "Te", "Tg", "TB", "Tm", "TM", "TH"])
        let fans = keyGroup(L("Wentylatory (F*)"), icon: "fan", keys: s.fanKeys, path: \.fanKeys, unit: "obr/min", accent: .cpu)

        let machine = SensorNode("\(hw.marketingName) (\(hw.model))", icon: "laptopcomputer", accent: nil)
        machine.children = [cpu, gpu, ane, mem, ssd, bat, power, other] + (fans.children.isEmpty ? [] : [fans])
        root = [machine]
        builtSensorKeys = Self.sensorKeys(s)
        built = true
        outline.reloadData()
        outline.expandItem(machine)
        for c in machine.children { outline.expandItem(c) }
    }

    /// Opis klucza SMC (best effort) — TMOG pokazuje nazwy przyjazne, my dodajemy klucz w nawiasie
    static func describe(_ key: String) -> String {
        let map: [String: String] = [
            "PSTR": "Moc systemu", "PDTR": "Wejście DC", "PPBR": "Bateria", "PMVC": "Rdzeń pamięci", "TB0T": "Bateria 1", "TB1T": "Bateria 2", "TB2T": "Bateria 3",
            "TH0T": "SSD", "TH0x": "SSD (maks.)", "TW0P": "Moduł bezprzewodowy", "TCMz": "SoC (maks.)", "TCMb": "SoC (baza)", "TCHP": "Hub", "TIOP": "I/O", "TAOL": "Otoczenie",
        ]
        if let d = map[key] { return "\(L(d)) (\(key))" }
        if key.hasPrefix("Tp") { return "CPU Tp \(key.dropFirst(2)) (\(key))" }
        if key.hasPrefix("Te") { return "CPU Te \(key.dropFirst(2)) (\(key))" }
        if key.hasPrefix("Tg") { return "GPU \(key.dropFirst(2)) (\(key))" }
        if key.hasPrefix("TPD") { return "PMU \(key.dropFirst(3)) (\(key))" }
        if key.hasPrefix("TRD") { return L("Regulator") + " \(key.dropFirst(3)) (\(key))" }
        if key.hasPrefix("TV") { return "VRM \(key.dropFirst(2)) (\(key))" }
        return key
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        guard !sensorsRetained else { return }
        sensorsRetained = true
        Monitor.shared.retainSensors()
    }

    override func viewDidDisappear() {
        super.viewDidDisappear()
        guard sensorsRetained else { return }
        sensorsRetained = false
        Monitor.shared.releaseSensors()
    }

    private var sensorsRetained = false

    @objc private func snapshot(_ n: Notification) {
        guard let s = n.object as? Snapshot, view.window != nil, !view.isHiddenOrHasHiddenAncestor else { return }
        update(s)
    }

    private func update(_ s: Snapshot) {
        let keys = Self.sensorKeys(s)
        if !built { build(s) }
        // Zmiana czujników lub dysków wymaga przebudowy drzewa.
        if built, keys != builtSensorKeys || s.disks.map(\.bsd) != builtDiskKeys { build(s) }
        guard built else { return }
        for r in root { r.update(s) }
        let filter = search.stringValue.lowercased()
        func refresh(_ n: SensorNode) {
            let match = filter.isEmpty || n.title.lowercased().contains(filter)
            n.cells[0].update(n.title, flash: false)
            n.cells[0].textColor = match ? P.text : P.textDim
            let placeholder = n.isHeterogeneousGroup ? "" : "Niedostępne"
            n.cells[1].update(n.value.map(n.format) ?? placeholder, flash: false)
            if let lvl = n.heatLevel() {
                n.cells[1].textColor = HeatScale.color(lvl)
            } else if n.value == nil {
                n.cells[1].textColor = P.textDim
            } else {
                // wiersze zbiorcze bez wspólnego zakresu (np. wszystkie klucze mocy SMC) dostają kolor swojej kategorii
                n.cells[1].textColor = n.accent.map { P.accent($0) } ?? P.valueColor
            }
            let dash = (n.isHeterogeneousGroup || !n.showsMinMax) ? "" : "—"
            n.cells[2].update(n.showsMinMax ? (n.minV.map(n.format) ?? dash) : dash, flash: false); n.cells[2].textColor = P.textDim
            n.cells[3].update(n.showsMinMax ? (n.maxV.map(n.format) ?? dash) : dash, flash: false)
            if let mx = n.maxV, n.showsMinMax, case .temperature(let key) = n.range {
                n.cells[3].textColor = ThermalScale.color(mx, key: key).alpha(0.85)
            } else { n.cells[3].textColor = P.textDim }
            for c in n.children { refresh(c) }
        }
        for r in root { refresh(r) }
        let src = s.powerStale ? L("Dane nieaktualne") : (s.powerSource.isEmpty ? L("Brak danych") : s.powerSource)
        var counts = [
            "\(s.temps.count) " + L("odczytów temperatury"),
            "\(s.voltageKeys.count) " + L("napięć"),
            "\(s.powerKeys.count) " + L("mocy"),
            "\(s.currentKeys.count) " + L("prądów"),
        ]
        if !s.fanKeys.isEmpty { counts.append("\(s.fanKeys.count) " + L("wentylatorów")) }
        counts.append(L("moc i taktowania") + ": " + src)
        summary.stringValue = counts.joined(separator: " · ")
    }

    @objc private func filterChanged() {
        let f = search.stringValue.lowercased()
        if !f.isEmpty { expandAll() }
        update(Monitor.shared.latest)
    }
    @objc private func expandAll() {
        for r in root { outline.expandItem(r, expandChildren: true) }
        update(Monitor.shared.latest)
    }
    @objc private func collapseAll() { for r in root { for c in r.children { outline.collapseItem(c, collapseChildren: true) } } }
    @objc private func resetMinMax() {
        func reset(_ n: SensorNode) { n.minV = nil; n.maxV = nil; for c in n.children { reset(c) } }
        for r in root { reset(r) }
        update(Monitor.shared.latest)
    }

    // MARK: outline
    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int { item == nil ? root.count : ((item as? SensorNode)?.children.count ?? 0) }
    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any { item == nil ? root[index] : (item as! SensorNode).children[index] }
    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool { !((item as? SensorNode)?.children.isEmpty ?? true) }
    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? { let r = ThemedRowView(); r.inset = 0; r.zebra = outlineView.row(forItem: item) % 2 == 1; return r }
    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let n = item as? SensorNode, let col = tableColumn else { return nil }
        let idx = ["sensor": 0, "value": 1, "min": 2, "max": 3][col.identifier.rawValue] ?? 0
        let cell = NSTableCellView()
        let label = n.cells[idx]
        label.removeFromSuperview()
        if idx == 0, let ic = n.icon {
            let iv = symbol(ic, size: 12, color: n.accent.map { P.accent($0) } ?? P.textDim)
            iv.size(width: 18)
            hstack([iv, label], spacing: 6).pinCentered(to: cell, leading: 2, trailing: 2)
        } else {
            label.pinCentered(to: cell, leading: 2, trailing: 4)
        }
        return cell
    }
}
