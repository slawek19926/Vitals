// SummaryViewController.swift - strona „Podsumowanie”: mierniki, przegląd CPU, top procesy, pamięć, kafelki
import AppKit

/// Kafelek z dolnego rzędu (Sieć / Dyski / GPU / Zasilanie)
final class TileView: CardView {
    let titleLabel: NSTextField
    let valueLabel: NSTextField
    let subtitleLabel = Label.make("", size: 12, dim: true)
    let bar = LEDBarView()
    let icon: NSImageView
    private let sub: Subsystem

    init(title: String, icon: String, accent: Subsystem) {
        sub = accent
        titleLabel = Label.make(title, size: 13.5)
        valueLabel = Label.make(L("—"), size: 12.5, weight: .semibold)
        self.icon = symbol(icon, size: 13, weight: .medium, color: P.accent(accent))
        super.init(accent: accent)
        bar.accent = accent
        bar.segmentThickness = 10
        bar.gap = 3
        let header = hstack([self.icon, titleLabel, spacer(), valueLabel], spacing: 10)
        let v = vstack([header, subtitleLabel, bar], spacing: 5)
        header.widthAnchor.constraint(equalTo: v.widthAnchor).isActive = true
        bar.widthAnchor.constraint(equalTo: v.widthAnchor).isActive = true
        bar.heightAnchor.constraint(equalToConstant: 14).isActive = true
        v.translatesAutoresizingMaskIntoConstraints = false
        addSubview(v)
        NSLayoutConstraint.activate([
            v.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            v.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            v.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            v.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -12),
        ])
        applyTheme()
    }
    required init?(coder: NSCoder) { fatalError() }

    override func applyTheme() {
        super.applyTheme()
        valueLabel.textColor = P.accent(sub)
        icon.contentTintColor = P.accent(sub)
        titleLabel.textColor = P.text
        subtitleLabel.textColor = P.textDim
    }

    func set(value: String, subtitle: String, fraction: Double) {
        valueLabel.stringValue = value
        subtitleLabel.stringValue = subtitle
        bar.value = fraction
    }
}

final class SummaryViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    private let hw = Monitor.shared.hardware

    // mierniki
    private let sysHeader = DisplayHeader("SYS")
    private let meterCPU = MeterView(title: "CPU", accent: .cpu)
    private let meterGPU = MeterView(title: "GPU", accent: .gpu)
    private let meterRAM = MeterView(title: "RAM", accent: .memory)
    private let meterTemp = MeterView(title: "TEMP CPU", accent: .thermal)

    // przegląd CPU
    private let cpuHeader = DisplayHeader(L("Obciążenie CPU"), accent: .cpu)
    private let cpuGraph = GraphView(series: 2, history: 120, accents: [.cpu, .cpu])
    private let legendUtil = Label.make(L("Wykorzystanie"), size: 11)
    private let legendKernel = Label.make(L("Jądro (system)"), size: 11)
    private let cpuFootL = Label.make("", size: 12, dim: true)
    private let cpuFootR = Label.make("", size: 12, dim: true)

    // top procesy
    private let topHeader = DisplayHeader(L("TOP 15 PROCESÓW CPU"), accent: .cpu)
    private let topTable = NSTableView()
    private var topRows: [HistoryProc] = []
    private let liveButton = NSButton(title: L("Na żywo"), target: nil, action: nil)
    /// Zakres generacji pomiarów wybrany na wykresie (nil = dane bieżące)
    private var scrubGenerations: ClosedRange<Int>?
    private var scrubPinned = false
    /// Docelowe i aktualnie wyświetlane wartości procesów – różnica jest animowana klatka po klatce
    private var targetCPU: [Int: Double] = [:]
    private var dispCPU: [Int: Double] = [:]
    private var targetMem: [Int: Double] = [:]
    private var dispMem: [Int: Double] = [:]
    private var lastProcMeta: [Int: String] = [:]
    private var topOrder: [Int] = []
    private var lastTopOrderAt = Date.distantPast

    private var lastProcGen = -1
    private var lastSnapshot: Snapshot?

    // pamięć
    private let memBar = LEDBarView()
    private let memPct = Label.make(L("—"), size: 11, weight: .medium, mono: true)
    private let memTitle = Label.make(L("Wykorzystanie pamięci"), size: 17, weight: .light)
    private let memRight = Label.make("", size: 12.5, weight: .semibold)
    private let memGraph = GraphView(series: 1, history: 120, accents: [.memory])
    private let memFootL = Label.make("", size: 12, dim: true)
    private let memFootC = Label.make("", size: 12, dim: true)
    private let memFootR = Label.make("", size: 12, dim: true)

    // kafelki
    private let tileNet = TileView(title: "Sieć", icon: "globe", accent: .network)
    private let tileDisk = TileView(title: L("Dyski"), icon: "internaldrive", accent: .disk)
    private let tileGPU = TileView(title: "GPU", icon: "display", accent: .gpu)
    private let tileEnergy = TileView(title: "Zasilanie", icon: "bolt.circle", accent: .energy)
    private var netHistory: [Double] = [], diskHistory: [Double] = []

    override func loadView() {
        view = NSView()
        let title = PageTitleView(L("Podsumowanie"))

        // --- karta mierników
        let metersCard = CardView()
        let meters = hstack([meterCPU, meterGPU, meterTemp, meterRAM], spacing: 6, alignment: .top, distribution: .fillEqually)
        for m in [meterCPU, meterGPU, meterTemp, meterRAM] { m.bar.setContentHuggingPriority(.init(1), for: .vertical) }
        meters.setContentHuggingPriority(.init(1), for: .vertical)
        let mv = vstack([sysHeader, meters], spacing: 10)
        sysHeader.widthAnchor.constraint(equalTo: mv.widthAnchor).isActive = true
        meters.widthAnchor.constraint(equalTo: mv.widthAnchor).isActive = true
        meters.heightAnchor.constraint(equalTo: mv.heightAnchor, constant: -40).isActive = true
        mv.pin(to: metersCard, insets: NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12))
        metersCard.size(width: 250)


        // --- karta przeglądu CPU
        let cpuCard = CardView(accent: nil)
        cpuGraph.colorProvider = { i, p in i == 0 ? p.cpu : p.cpuKernel }
        cpuGraph.showPercentAxis = true
        cpuGraph.borderAccent = .cpu
        // klik na wykresie cofa listę TOP do wybranej chwili, przeciągnięcie zaznacza przedział
        cpuGraph.timeSpan = Double(Prefs.shared.graphSpanSeconds)
        memGraph.timeSpan = Double(Prefs.shared.graphSpanSeconds)
        cpuGraph.scrubbable = true
        memGraph.scrubbable = true
        cpuGraph.onScrub = { [weak self] r, pinned in self?.applyScrub(r, pinned: pinned, source: self?.cpuGraph) }
        memGraph.onScrub = { [weak self] r, pinned in self?.applyScrub(r, pinned: pinned, source: self?.memGraph) }
        liveButton.bezelStyle = .inline
        liveButton.controlSize = .mini
        liveButton.font = Fonts.ui(10, .semibold)
        liveButton.target = self
        liveButton.action = #selector(returnToLive)
        liveButton.isHidden = true
        cpuGraph.setContentHuggingPriority(.init(1), for: .vertical)
        let legend = hstack([legendDot(.cpu), legendUtil, legendDot(nil), legendKernel, spacer()], spacing: 6)
        let foot = hstack([cpuFootL, spacer(), cpuFootR])
        let cv = vstack([cpuHeader, legend, cpuGraph, foot], spacing: 8)
        for v in [cpuHeader, legend, cpuGraph, foot] { v.widthAnchor.constraint(equalTo: cv.widthAnchor).isActive = true }
        cv.pin(to: cpuCard, insets: NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 14))

        // --- karta top procesów
        let topCard = CardView()
        setupTopTable()
        let scroll = NSScrollView()
        scroll.documentView = topTable
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = false
        scroll.setContentHuggingPriority(.init(1), for: .vertical)
        topHeader.addTrailing(liveButton)
        let tv = vstack([topHeader, scroll], spacing: 8)
        topHeader.widthAnchor.constraint(equalTo: tv.widthAnchor).isActive = true
        scroll.widthAnchor.constraint(equalTo: tv.widthAnchor).isActive = true
        tv.pin(to: topCard, insets: NSEdgeInsets(top: 12, left: 12, bottom: 10, right: 12))
        topCard.size(width: 380)

        let row1 = hstack([metersCard, cpuCard, topCard], spacing: 14, alignment: .top, distribution: .fill)
        cpuCard.setContentHuggingPriority(.init(1), for: .horizontal)
        for c in [metersCard, cpuCard, topCard] { c.heightAnchor.constraint(equalTo: row1.heightAnchor).isActive = true }



        // --- karta pamięci
        let memCard = CardView(accent: nil)
        memBar.vertical = true; memBar.accent = .memory; memBar.segmentThickness = 5; memBar.gap = 2
        memBar.setContentHuggingPriority(.init(1), for: .vertical)
        let meter = vstack([memBar, memPct], spacing: 6, alignment: .centerX)
        memBar.widthAnchor.constraint(equalToConstant: 46).isActive = true
        meter.size(width: 60)
        memGraph.borderAccent = .memory
        memGraph.setContentHuggingPriority(.init(1), for: .vertical)
        let mh = hstack([memTitle, spacer(), memRight])
        let mf = hstack([memFootL, spacer(), memFootC, spacer(), memFootR])
        let mvs = vstack([mh, memGraph, mf], spacing: 6)
        for v in [mh, memGraph, mf] { v.widthAnchor.constraint(equalTo: mvs.widthAnchor).isActive = true }
        let mrow = hstack([meter, mvs], spacing: 10, alignment: .top)
        meter.heightAnchor.constraint(equalTo: mrow.heightAnchor).isActive = true
        mvs.heightAnchor.constraint(equalTo: mrow.heightAnchor).isActive = true
        mrow.pin(to: memCard, insets: NSEdgeInsets(top: 10, left: 12, bottom: 12, right: 14))

        // --- kafelki w stałym rzędzie
        let tiles = hstack([tileNet, tileDisk, tileGPU, tileEnergy], spacing: 14, alignment: .top, distribution: .fillEqually)
        memCard.setContentHuggingPriority(.init(1), for: .vertical)
        for t in [tileNet, tileDisk, tileGPU, tileEnergy] { t.heightAnchor.constraint(equalTo: tiles.heightAnchor).isActive = true }

        let root = vstack([title, row1, memCard, tiles], spacing: 10)
        for v in [title, row1, memCard, tiles] { v.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true }
        root.pin(to: view, insets: NSEdgeInsets(top: 2, left: 18, bottom: 12, right: 18))
        NSLayoutConstraint.activate([
            row1.heightAnchor.constraint(equalTo: root.heightAnchor, multiplier: 0.42),
            tiles.heightAnchor.constraint(equalToConstant: 98),
        ])

        NotificationCenter.default.addObserver(forName: .prefsChanged, object: nil, queue: .main) { [weak self] _ in
            let span = Double(Prefs.shared.graphSpanSeconds)
            self?.cpuGraph.timeSpan = span
            self?.memGraph.timeSpan = span
        }
        NotificationCenter.default.addObserver(self, selector: #selector(snapshot(_:)), name: .snapshotUpdated, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(themeChanged), name: .themeChanged, object: nil)
        themeChanged()
    }

    private func legendDot(_ s: Subsystem?) -> NSView {
        let d = ThemedView(); d.layer?.cornerRadius = 3; d.size(width: 10, height: 10)
        let apply = { d.layer?.backgroundColor = (s.map { P.accent($0) } ?? P.cpuKernel).cgColor }
        apply()
        NotificationCenter.default.addObserver(forName: .themeChanged, object: nil, queue: .main) { _ in apply() }
        return d
    }

    private func setupTopTable() {
        for (id, title, w) in [("pid", "PID", 56), ("name", "Nazwa", 150), ("cpu", "CPU", 60), ("mem", "Pamięć", 76)] {
            let c = NSTableColumn(identifier: .init(id)); c.title = L(title); c.width = CGFloat(w)
            if id == "name" { c.minWidth = 80; c.resizingMask = .autoresizingMask } else { c.resizingMask = [] }
            topTable.addTableColumn(c)
        }
        topTable.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        topTable.rowHeight = 21
        topTable.intercellSpacing = NSSize(width: 6, height: 2)
        topTable.backgroundColor = .clear
        topTable.selectionHighlightStyle = .none
        topTable.style = .plain
        topTable.headerView?.frame.size.height = 20
        topTable.dataSource = self
        topTable.delegate = self
        topTable.focusRingType = .none
        topTable.allowsColumnReordering = false
    }

    @objc private func themeChanged() {
        legendUtil.textColor = P.text; legendKernel.textColor = P.text
        for l in [cpuFootL, cpuFootR, memFootL, memFootC, memFootR] { l.textColor = P.textDim }
        memTitle.textColor = P.text; memRight.textColor = P.text; memPct.textColor = P.memory
        topTable.reloadData()
    }

    @objc private func snapshot(_ n: Notification) {
        guard let s = n.object as? Snapshot else { return }
        lastSnapshot = s
        // gdy strona jest schowana, zbieramy tylko dane do wykresów – reszta i tak nie jest widoczna
        if view.window == nil || view.isHiddenOrHasHiddenAncestor {
            cpuGraph.push([s.cpu.total, s.cpu.system])
            memGraph.push(Double(s.mem.used))
            return
        }
        // mierniki
        meterCPU.set(s.cpu.total / 100, text: Fmt.percent(s.cpu.total))
        if let g = s.gpuUtil { meterGPU.set(g / 100, text: Fmt.percent(g)) } else { meterGPU.set(0, text: "—") }
        let memFrac = s.mem.total > 0 ? Double(s.mem.used) / Double(s.mem.total) : 0
        meterRAM.set(memFrac, text: Fmt.percent(memFrac * 100))
        if let t = s.cpuTemp { meterTemp.set(t / 100, text: String(format: "%.1f °C", t)) } else { meterTemp.set(0, text: "—") }
        updateMeterTips(s)
        if let w = s.sysWatts { sysHeader.right.stringValue = String(format: "%.1fW", w) }
        else { sysHeader.right.stringValue = Fmt.percent(s.cpu.total, precision: 0) }

        // CPU
        cpuGraph.push([s.cpu.total, s.cpu.system])
        cpuHeader.right.stringValue = Fmt.percent(s.cpu.total, precision: 0)
        var foot = "\(hw.ncpu) " + L("procesorów logicznych") + " · \(Fmt.percent(s.cpu.total)) · " + L("użytkownik") + " \(Fmt.percent(s.cpu.user)) · " + L("system") + " \(Fmt.percent(s.cpu.system))"
        if let w = s.sysWatts { foot += String(format: " · %.1f W", w) }
        if scrubGenerations == nil { cpuFootL.stringValue = foot }
        cpuFootR.stringValue = String(format: L("Obciążenie %.2f"), s.loadAvg[0])

        // top procesy – bieżące albo z wybranej chwili na wykresie
        if scrubGenerations != nil {
            refreshTopFromHistory()
        } else {
            updateSmoothedTop(s)
        }

        // pamięć
        memBar.value = memFrac
        memPct.stringValue = Fmt.percent(memFrac * 100)
        memRight.stringValue = "\(Fmt.bytes(s.mem.used)) / \(Fmt.bytes(s.mem.total, precision: 0))"
        memGraph.maxValue = Double(max(1, s.mem.total))
        memGraph.autoRange = true; memGraph.formatter = { Fmt.bytes($0) }
        memGraph.push(Double(s.mem.used))
        memFootL.stringValue = L("Dostępne") + " \(Fmt.bytes(s.mem.total - min(s.mem.total, s.mem.used)))"
        memFootC.stringValue = L("Pliki w cache") + " \(Fmt.bytes(s.mem.cached))"
        memFootR.stringValue = "Swap \(Fmt.bytes(s.mem.swapUsed))"

        // kafelki
        let netTotal = s.net.rxRate + s.net.txRate
        netHistory.append(netTotal); if netHistory.count > 60 { netHistory.removeFirst() }
        let netScale = niceMax(netHistory.max() ?? 0)
        tileNet.set(value: Fmt.rate(netTotal), subtitle: "↓ \(Fmt.rate(s.net.rxRate)) · ↑ \(Fmt.rate(s.net.txRate))   skala \(Fmt.rate(netScale))", fraction: netTotal / netScale)
        let diskTotal = s.disk.readRate + s.disk.writeRate
        diskHistory.append(diskTotal); if diskHistory.count > 60 { diskHistory.removeFirst() }
        let diskScale = niceMax(diskHistory.max() ?? 0)
        tileDisk.set(value: Fmt.rate(diskTotal), subtitle: "R \(Fmt.rate(s.disk.readRate)) · W \(Fmt.rate(s.disk.writeRate))   skala \(Fmt.rate(diskScale))", fraction: diskTotal / diskScale)
        let gpuSub = hw.gpuCores > 0 ? "\(hw.gpuName) · \(hw.gpuCores) " + L("rdzeni") : hw.gpuName
        if let g = s.gpuUtil { tileGPU.set(value: Fmt.percent(g), subtitle: gpuSub, fraction: g / 100) }
        else { tileGPU.set(value: "—", subtitle: gpuSub, fraction: 0) }
        let sysW = s.sysWatts.map { String(format: "%.1f W", $0) } ?? "—"
        if let b = s.battery {
            let state = b.charging ? L("ładowanie") : (b.onAC ? L("zasilanie sieciowe") : L("bateria"))
            tileEnergy.set(value: sysW, subtitle: L("Bateria") + " \(b.percent)% · \(state) · " + L("termika") + ": \(s.thermalText)", fraction: min(1, (s.sysWatts ?? 0) / 60))
        } else {
            tileEnergy.set(value: sysW, subtitle: L("Zasilanie sieciowe") + " · " + L("termika") + ": \(s.thermalText)", fraction: min(1, (s.sysWatts ?? 0) / 100))
        }
    }

    /// Aktualizuje listę TOP z wygładzaniem: wartości dochodzą do nowego pomiaru stopniowo,
    /// dzięki czemu liczby „płyną” zamiast skakać przy co drugim odświeżeniu procesów
    private func updateSmoothedTop(_ s: Snapshot) {
        var seen = Set<Int>()
        for p in s.processes where p.accessible {
            seen.insert(p.pid)
            targetCPU[p.pid] = p.cpuPercent
            targetMem[p.pid] = Double(p.memBytes)
            lastProcMeta[p.pid] = p.name
            dispCPU[p.pid] = p.cpuPercent
            dispMem[p.pid] = Double(p.memBytes)
        }
        // procesy, których już nie ma: zjeżdżają do zera i znikają
        for pid in targetCPU.keys where !seen.contains(pid) {
            targetCPU[pid] = 0
            if (dispCPU[pid] ?? 0) < 0.05 {
                targetCPU[pid] = nil; dispCPU[pid] = nil
                targetMem[pid] = nil; dispMem[pid] = nil; lastProcMeta[pid] = nil
            }
        }
        // Przestawianie wierszy wymaga pełnego reloadu tabeli, więc kolejność ustalamy co ~1,5 s,
        // a pomiędzy tym odświeżamy same wartości w istniejących komórkach.
        let order = targetCPU.sorted { $0.value > $1.value }.prefix(15).map(\.key)
        let due = Date().timeIntervalSince(lastTopOrderAt) >= 1.5
        if order != topOrder, due || topOrder.isEmpty || Set(order) != Set(topOrder) && topOrder.count < 15 {
            lastTopOrderAt = Date()
            topOrder = order
            rebuildTopRows()
            if view.window != nil { topTable.reloadData() }
        } else {
            rebuildTopRows()
            applyAnimatedCells()
        }
        topHeader.left.stringValue = "TOP \(topOrder.count) " + L("PROCESÓW CPU")
        topHeader.right.stringValue = "\(s.processes.count)"
    }

    /// Składa wiersze z aktualnie animowanych wartości
    private func rebuildTopRows() {
        topRows = topOrder.compactMap { pid in
            guard let name = lastProcMeta[pid] else { return nil }
            return HistoryProc(pid: pid, name: name, cpu: dispCPU[pid] ?? 0,
                               mem: UInt64(max(0, dispMem[pid] ?? 0)), accessible: true)
        }
    }

    /// Podmienia tekst tylko w widocznych komórkach – bez reloadData, z przenikaniem starej i nowej wartości
    private func applyAnimatedCells() {
        let rows = topTable.rows(in: topTable.visibleRect)
        guard rows.length > 0 else { return }
        let cpuCol = topTable.column(withIdentifier: NSUserInterfaceItemIdentifier("cpu"))
        let memCol = topTable.column(withIdentifier: NSUserInterfaceItemIdentifier("mem"))
        for row in rows.location..<(rows.location + rows.length) where row < topRows.count {
            let p = topRows[row]
            if cpuCol >= 0, let c = topTable.view(atColumn: cpuCol, row: row, makeIfNecessary: false) as? ProcCell {
                c.flash.update(Fmt.percent(p.cpu), flash: false)
            }
            if memCol >= 0, let c = topTable.view(atColumn: memCol, row: row, makeIfNecessary: false) as? ProcCell {
                c.flash.update(Fmt.bytes(p.mem), flash: false)
            }
        }
    }

    /// Podpowiedzi wyjaśniające, co dokładnie pokazuje każdy miernik
    private func updateMeterTips(_ s: Snapshot) {
        meterCPU.tip = L("Łączne wykorzystanie procesora ze wszystkich rdzeni: użytkownik plus jądro.")
            + String(format: " %@ %@ · %@ %@", L("użytkownik"), Fmt.percent(s.cpu.user), L("jądro"), Fmt.percent(s.cpu.system))
        meterGPU.tip = L("Wykorzystanie układu graficznego") + ": \(hw.gpuName) · \(hw.gpuCores) " + L("rdzeni")
        // temperatura: najwyższy odczyt z czujników rdzeni procesora
        let hottest = s.temps.filter { $0.name.hasPrefix("Tp") || $0.name.hasPrefix("Te") }.max { $0.value < $1.value }
        var tempTip = L("Najwyższa temperatura rdzeni procesora: czujniki Tp (rdzenie wydajnościowe) i Te (energooszczędne).")
        if let h = hottest { tempTip += "\n" + L("Najgorętszy czujnik") + ": \(h.name) \(Fmt.temp(h.value))" }
        if let g = s.gpuTemp { tempTip += "\n" + L("GPU") + ": \(Fmt.temp(g))" }
        if let d = s.ssdTemp { tempTip += "\n" + L("Dysk systemowy") + ": \(Fmt.temp(d))" }
        tempTip += "\n" + L("Pełna lista czujników jest na stronie Zasilanie i czujniki.")
        meterTemp.tip = tempTip
        meterRAM.tip = L("Udział zajętej pamięci: aplikacje, pamięć zablokowana i skompresowana.")
            + " \(Fmt.bytes(s.mem.used)) / \(Fmt.bytes(s.mem.total, precision: 0))"
    }

    /// Reaguje na kursor czasu: przelicza indeksy wykresu na generacje pomiarów i odświeża listę TOP
    private func applyScrub(_ range: ClosedRange<Int>?, pinned: Bool, source: GraphView?) {
        let hist = Monitor.shared.history
        guard let range, !hist.isEmpty else { returnToLive(); return }
        scrubPinned = pinned
        let n = hist.count
        let oldest = max(0, n - 1 - range.upperBound)
        let newest = min(n - 1, n - 1 - range.lowerBound)
        guard oldest <= newest else { return }
        scrubGenerations = hist[oldest].generation...hist[newest].generation
        // ten sam kursor na drugim wykresie
        let other = source === cpuGraph ? memGraph : cpuGraph
        other.setScrub(from: range.upperBound, to: range.lowerBound, pinned: pinned)
        liveButton.isHidden = !pinned
        refreshTopFromHistory()
    }

    @objc private func returnToLive() {
        scrubGenerations = nil
        scrubPinned = false
        liveButton.isHidden = true
        cpuGraph.clearScrub(notify: false)
        memGraph.clearScrub(notify: false)
        lastProcGen = -1
        if let s = lastSnapshot { snapshot(Notification(name: .snapshotUpdated, object: s)) }
    }

    /// Buduje listę TOP z zapamiętanych pomiarów (przy zakresie uśrednia CPU)
    private func refreshTopFromHistory() {
        guard let gens = scrubGenerations else { return }
        let hist = Monitor.shared.history
        let samples = hist.filter { gens.contains($0.generation) }
        guard let first = samples.first, let last = samples.last else { returnToLive(); return }
        // przy pojedynczym punkcie uśredniamy z najbliższymi sąsiadami – inaczej wartości skaczą
        var window = samples
        if samples.count == 1, let i = hist.firstIndex(where: { $0.generation == last.generation }) {
            window = Array(hist[max(0, i - 1)...min(hist.count - 1, i + 1)])
        }
        var acc: [Int: (name: String, cpu: Double, mem: UInt64)] = [:]
        for s in window {
            for p in s.top {
                var e = acc[p.pid] ?? (p.name, 0, 0)
                e.name = p.name
                e.cpu += p.cpu
                e.mem = max(e.mem, p.mem)
                acc[p.pid] = e
            }
        }
        let divisor = Double(max(1, window.count))
        // wartości z historii też animujemy – kursor przesuwany myszą zmienia liczby płynnie
        for (pid, e) in acc {
            targetCPU[pid] = e.cpu / divisor
            targetMem[pid] = Double(e.mem)
            lastProcMeta[pid] = e.name
            dispCPU[pid] = e.cpu / Double(max(1, window.count))
            dispMem[pid] = Double(e.mem)
        }
        for pid in targetCPU.keys where acc[pid] == nil { targetCPU[pid] = 0 }
        let order = acc.map { ($0.key, $0.value.cpu) }.sorted { $0.1 > $1.1 }.prefix(15).map(\.0)
        let sameOrder = order == topOrder
        topOrder = order
        rebuildTopRows()
        if sameOrder { applyAnimatedCells() }
        let t = Fmt.time.string(from: last.time)
        let divisorAll = Double(samples.count)
        if samples.count > 1 {
            topHeader.left.stringValue = "TOP \(topRows.count) · \(Fmt.time.string(from: first.time))–\(t)"
            topHeader.right.stringValue = "\(samples.count) " + L("PRÓBEK")
            cpuFootL.stringValue = "Przedział \(Fmt.time.string(from: first.time))–\(t) · średnio \(Fmt.percent(samples.reduce(0) { $0 + $1.cpuTotal } / divisorAll)) · \(samples.count) pomiarów"
        } else {
            topHeader.left.stringValue = "TOP \(topRows.count) · \(t)"
            topHeader.right.stringValue = "\(last.processCount)"
            cpuFootL.stringValue = L("Pomiar z") + " \(t) · \(Fmt.percent(last.cpuTotal)) · " + L("jądro") + " \(Fmt.percent(last.cpuSystem)) · \(last.processCount) " + L("procesów")
        }
        if !sameOrder { topTable.reloadData() }
    }

    private func niceMax(_ m: Double) -> Double {
        guard m > 0 else { return 1024 }
        let p = pow(10.0, floor(log10(m))); let n = m / p
        return (n <= 1 ? 1 : n <= 2 ? 2 : n <= 5 ? 5 : 10) * p
    }

    // MARK: tabela top
    func numberOfRows(in tableView: NSTableView) -> Int { topRows.count }
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let r = ThemedRowView(); r.inset = 0; r.zebra = row % 2 == 1; return r
    }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let col = tableColumn, row < topRows.count else { return nil }
        let p = topRows[row]
        let id = col.identifier
        let cell: ProcCell
        if let c = topTable.makeView(withIdentifier: id, owner: nil) as? ProcCell { cell = c } else {
            cell = ProcCell(); cell.identifier = id
            cell.flash.pinCentered(to: cell, leading: 2, trailing: 2)
        }
        let label = cell.flash
        label.crossfade = true
        label.font = Fonts.mono(11); label.alignment = .right; label.textColor = P.text
        switch id.rawValue {
        case "pid": cell.setText("\(p.pid)", pid: p.pid); label.textColor = P.textDim
        case "cpu": cell.setText(Fmt.percent(p.cpu), pid: p.pid); label.textColor = P.cpu
        case "mem": cell.setText(Fmt.bytes(p.mem), pid: p.pid)
        default: cell.setText(p.name, pid: p.pid); label.font = Fonts.ui(11); label.alignment = .left
        }
        return cell
    }
}
