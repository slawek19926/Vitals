// PerformanceViewController.swift - strona „Wydajność” odwzorowana wg TMOG: lista podsystemów, szczegóły z wykresami,
// statystykami, tabelą cech i kafelkami
import AppKit
import Metal

enum Sub: Int, CaseIterable {
    case cpu, memory, gpu, npu, disk, network, energy, thermals, battery
    var title: String { L(["CPU", "Pamięć", "GPU 0", "NPU 0", "Dyski", "Sieć", "Zasilanie", "Termika", "Bateria"][rawValue]) }
    var icon: String { ["cpu", "memorychip", "display", "brain", "internaldrive", "globe", "bolt.circle", "thermometer.medium", "battery.100percent"][rawValue] }
    var accent: Subsystem { [.cpu, .memory, .gpu, .npu, .disk, .network, .energy, .thermal, .energy][rawValue] }
}

extension Notification.Name {
    static let openSystemInfoCategory = Notification.Name("OpenSystemInfoCategory")
    static let openPage = Notification.Name("OpenPage")
}

/// Komórka listy podsystemów
final class SubsystemCell: NSTableCellView {
    let icon: NSImageView
    let title: NSTextField
    let line1 = FlashLabel("", size: 10.5)
    let line2 = FlashLabel("", size: 10.5)
    let graph: GraphView
    let sub: Sub

    init(_ s: Sub, titleText: String? = nil, iconName: String? = nil) {
        sub = s
        icon = symbol(iconName ?? s.icon, size: 16, weight: .regular, color: P.accent(s.accent))
        title = Label.make(titleText ?? s.title, size: 14)
        let series = (s == .disk || s == .network || s == .cpu) ? 2 : 1
        graph = GraphView(series: series, history: 60, accents: [s.accent, s.accent])
        super.init(frame: .zero)
        graph.compact = true
        graph.autoScale = (s == .disk || s == .network || s == .npu || s == .energy)
        graph.borderAccent = s.accent
        if s == .cpu { graph.colorProvider = { i, p in i == 0 ? p.cpu : p.cpuKernel } }
        if s == .thermals { graph.maxValue = 110 }
        let texts = vstack([title, line1, line2], spacing: 0)
        icon.size(width: 24)
        graph.size(width: 92, height: 52)
        let h = hstack([icon, texts, spacer(), graph], spacing: 8)
        h.pin(to: self, insets: NSEdgeInsets(top: 3, left: 10, bottom: 3, right: 10))
        applyTheme()
        NotificationCenter.default.addObserver(forName: .themeChanged, object: nil, queue: .main) { [weak self] _ in self?.applyTheme() }
    }
    required init?(coder: NSCoder) { fatalError() }

    func applyTheme() {
        icon.contentTintColor = P.accent(sub.accent)
        title.textColor = P.text
        line1.textColor = P.textDim; line2.textColor = P.textDim
    }
}

/// Szczegóły podsystemu: nagłówek, LED + wartość, treść, statystyki, tabela cech
final class DetailView: NSView {
    let titleLabel = NSTextField(labelWithString: "")
    let subtitle = Label.make("", size: 12, dim: true)
    let bar = LEDBarView()
    let pct = FlashLabel(L("—"), size: 18, weight: .semibold)
    /// Drugi pasek (np. zapis / wysyłanie) – tworzony tylko dla sekcji z dwoma kierunkami
    let bar2 = LEDBarView()
    let pct2 = FlashLabel(L("—"), size: 18, weight: .semibold)
    let barTag1 = Label.make("", size: 10.5, dim: true)
    let barTag2 = Label.make("", size: 10.5, dim: true)
    private(set) var hasTwoBars = false
    /// Kolory pasków (drugi kierunek dostaje odcień jak na wykresie)
    var barColors: ((Palette) -> (NSColor, NSColor))?
    let caption = Label.make("", size: 11, dim: true)
    let captionRight = NSStackView()
    let content = vstack([], spacing: 6)
    let historyCaption = Label.make(L("Historia przewijana"), size: 10.5, dim: true)
    let statsGrid: NSStackView
    let kvGrid: NSStackView
    let extra = vstack([], spacing: 6)
    let note = Label.make("", size: 10.5, dim: true)
    let sub: Sub
    /// Tytuł inny niż nazwa podsystemu (np. „Dysk 0”)
    var customTitle: String?
    private(set) var stats: [String: StatView] = [:]
    private var kv: [String: FlashLabel] = [:]

    init(_ s: Sub, statCaptions: [String], kvKeys: [String] = [], subtitleAboveBar: Bool = false, titleText: String? = nil, twoBars: Bool = false) {
        sub = s
        customTitle = titleText
        // statystyki: wiersze po 4 równe kolumny (elastyczne)
        statsGrid = vstack([], spacing: 8)
        var row: [NSView] = []
        for c in statCaptions {
            let sv = StatView(L(c), valueSize: 13)
            stats[c] = sv
            row.append(sv)
            if row.count == 4 { let r = hstack(row, spacing: 16, alignment: .top, distribution: .fillEqually); statsGrid.addArrangedSubview(r); r.widthAnchor.constraint(equalTo: statsGrid.widthAnchor).isActive = true; row = [] }
        }
        if !row.isEmpty { while row.count < 4 { row.append(spacer()) }; let r = hstack(row, spacing: 16, alignment: .top, distribution: .fillEqually); statsGrid.addArrangedSubview(r); r.widthAnchor.constraint(equalTo: statsGrid.widthAnchor).isActive = true }
        for sv in stats.values { sv.setContentCompressionResistancePriority(.defaultLow, for: .horizontal) }

        // tabela cech: dwie pary klucz/wartość w wierszu
        kvGrid = vstack([], spacing: 3)
        var kvLabels: [String: FlashLabel] = [:]
        var pairs: [NSView] = []
        for k in kvKeys {
            let key = Label.make(L(k) + ":", size: 11.5, dim: true); key.size(width: 150)
            let val = FlashLabel(L("—"), size: 11.5)
            kvLabels[k] = val
            pairs.append(hstack([key, val], spacing: 8))
            if pairs.count == 2 { let r = hstack(pairs, spacing: 20, distribution: .fillEqually); kvGrid.addArrangedSubview(r); r.widthAnchor.constraint(equalTo: kvGrid.widthAnchor).isActive = true; pairs = [] }
        }
        if !pairs.isEmpty { pairs.append(spacer()); let r = hstack(pairs, spacing: 20, distribution: .fillEqually); kvGrid.addArrangedSubview(r); r.widthAnchor.constraint(equalTo: kvGrid.widthAnchor).isActive = true }
        kv = kvLabels
        kvGrid.isHidden = kvKeys.isEmpty

        super.init(frame: .zero)
        bar.accent = s.accent
        bar.gradient = (s == .cpu || s == .thermals)
        bar.segmentThickness = 10
        bar.gap = 3
        bar.heightAnchor.constraint(equalToConstant: 14).isActive = true
        pct.alignment = .right
        pct.size(width: 110)
        hasTwoBars = twoBars
        let barRow: NSView
        if twoBars {
            // dwa paski jeden nad drugim: osobno każdy kierunek transferu
            bar2.accent = s.accent
            bar2.segmentThickness = 10
            bar2.gap = 3
            bar2.heightAnchor.constraint(equalToConstant: 14).isActive = true
            pct2.alignment = .right
            pct2.size(width: 110)
            for t in [barTag1, barTag2] { t.size(width: 62) }
            let r1 = hstack([barTag1, bar, pct], spacing: 8)
            let r2 = hstack([barTag2, bar2, pct2], spacing: 8)
            let stack = vstack([r1, r2], spacing: 5)
            for r in [r1, r2] { r.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
            barRow = stack
        } else {
            barRow = hstack([bar, pct], spacing: 14)
        }
        captionRight.orientation = .horizontal; captionRight.spacing = 8
        let captionRow = hstack([caption, spacer(), captionRight])
        note.lineBreakMode = .byWordWrapping; note.maximumNumberOfLines = 3

        var order: [NSView] = [titleLabel]
        if subtitleAboveBar { order += [subtitle, barRow] } else { order += [barRow, subtitle] }
        order += [captionRow, content, historyCaption, statsGrid, kvGrid, extra, note]
        let v = vstack(order, spacing: 6)
        for x in [barRow, captionRow, content, statsGrid, kvGrid, extra, note] { x.widthAnchor.constraint(equalTo: v.widthAnchor).isActive = true }
        v.setCustomSpacing(2, after: titleLabel)
        v.setCustomSpacing(10, after: subtitleAboveBar ? barRow : subtitle)
        v.setCustomSpacing(3, after: captionRow)
        v.setCustomSpacing(10, after: content)
        v.setCustomSpacing(4, after: historyCaption)
        v.setCustomSpacing(12, after: statsGrid)
        v.pin(to: self, insets: NSEdgeInsets(top: 2, left: 18, bottom: 14, right: 18))
        applyTheme()
        DispatchQueue.main.async { [weak self] in self?.applyTheme() }   // kolory pasków są ustawiane po inicjalizacji
        for n in [Notification.Name.themeChanged, .prefsChanged] {
            NotificationCenter.default.addObserver(forName: n, object: nil, queue: .main) { [weak self] _ in self?.applyTheme() }
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    func applyTheme() {
        titleLabel.attributedStringValue = NSAttributedString(string: customTitle ?? sub.title, attributes: [.font: Fonts.title(26), .kern: 1.0, .foregroundColor: P.text])
        pct.textColor = P.valueColor
        pct2.textColor = P.valueColor
        if let c = barColors {
            let (a, b) = c(P)
            bar.fixedColor = a; bar2.fixedColor = b
            bar.needsDisplay = true; bar2.needsDisplay = true
        }
        barTag1.textColor = P.textDim; barTag2.textColor = P.textDim
        subtitle.textColor = P.textDim; caption.textColor = P.textDim
        historyCaption.textColor = P.textDim; note.textColor = P.textDim
        for v in kv.values { v.textColor = P.text }
    }

    func addContent(_ v: NSView) { content.addArrangedSubview(v); v.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true }
    func set(_ caption: String, _ value: String) { stats[caption]?.value = L(value) }
    func setKV(_ key: String, _ value: String) { kv[key]?.update(L(value), flash: false) }
}

final class PerformanceViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, PageRefreshable {
    private let hw = Monitor.shared.hardware
    private let table = NSTableView()
    private var cells: [SubsystemCell] = []
    private var details: [DetailView] = []
    /// Kolejność pozycji na liście (pozwala wstawić dyski zaraz za pozycją „Dyski”)
    private var order: [Int] = Array(0..<4) + Array(6..<Sub.allCases.count)   // bez zbiorczych „Dyski” i „Sieć”
    /// Pozycje pojedynczych dysków: klucz → indeks w `cells`/`details` oraz wykres szczegółów
    private var diskPages: [String: (index: Int, graph: GraphView)] = [:]
    /// To samo dla interfejsów sieciowych
    private var ifacePages: [String: (index: Int, graph: GraphView)] = [:]
    private var ifaceKeys: [String] = []
    private var diskKeysOrder: [String] = []
    private var lastIfacesGeneration = -1
    private let container = NSView()
    private var lastSnapshot: Snapshot?

    // CPU
    private var coreGraphs: [GraphView] = []
    private let cpuOverall = GraphView(series: 2, history: 120, accents: [.cpu, .cpu])
    private let cpuMode = NSPopUpButton(frame: .zero, pullsDown: false)
    private var coreGridView: NSView!
    // Pamięć
    private let memGraph = GraphView(series: 1, history: 120, accents: [.memory])
    // GPU
    private let gpuGraph = GraphView(series: 2, history: 120, accents: [.gpu, .gpu])
    private let gpuMemGraph = GraphView(series: 1, history: 120, accents: [.gpu])
    private let gpuMemLabel = FlashLabel("", size: 11)
    private let gpuMode = NSSegmentedControl(labels: ["Ogólnie", "Silniki"], trackingMode: .selectOne, target: nil, action: nil)
    private let videoEnc = GraphView(series: 1, history: 120, accents: [.gpu]), videoDec = GraphView(series: 1, history: 120, accents: [.gpu])
    // NPU
    private let npuGraph = GraphView(series: 1, history: 120, accents: [.npu])
    // Dyski
    private let diskActive = GraphView(series: 1, history: 120, accents: [.disk])
    private let diskRate = GraphView(series: 2, history: 120, accents: [.disk, .disk])
    // Sieć
    private let netGraph = GraphView(series: 2, history: 120, accents: [.network, .network])
    private var netPeak: Double = 1024
    // Zasilanie
    private let energyGraph = GraphView(series: 1, history: 120, accents: [.energy])
    private var energyTiles: [String: TileStat] = [:]
    private let energyProcs = vstack([], spacing: 4)
    private var barRows: [BarRow] = []
    private var powerMode = "—"
    private var lastPmset = Date.distantPast
    // Termika
    private let thermGraph = GraphView(series: 1, history: 120, accents: [.thermal])
    private var thermTiles: [String: TileStat] = [:]
    private var sensorCards: [String: SensorCard] = [:]
    private let sensorsGrid = vstack([], spacing: 8)

    override func loadView() {
        view = NSView()
        let title = PageTitleView(L("Wydajność"))

        cells = Sub.allCases.map { SubsystemCell($0) }
        let col = NSTableColumn(identifier: .init("c"))
        table.addTableColumn(col)
        table.headerView = nil
        table.rowHeight = 60
        table.intercellSpacing = NSSize(width: 0, height: 2)
        table.backgroundColor = .clear
        table.style = .plain
        table.focusRingType = .none
        table.dataSource = self
        table.delegate = self
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true; scroll.scrollerStyle = .overlay; scroll.autohidesScrollers = true
        scroll.size(width: 330)

        let divider = ThemedView()
        divider.size(width: 1)
        divider.layer?.backgroundColor = P.border.alpha(0.6).cgColor
        NotificationCenter.default.addObserver(forName: .themeChanged, object: nil, queue: .main) { _ in divider.layer?.backgroundColor = P.border.alpha(0.6).cgColor }

        let detailScroll = NSScrollView()
        detailScroll.drawsBackground = false
        detailScroll.hasVerticalScroller = true; detailScroll.scrollerStyle = .overlay; detailScroll.autohidesScrollers = true
        let doc = FlippedView()
        detailScroll.documentView = doc
        container.pin(to: doc)
        doc.translatesAutoresizingMaskIntoConstraints = false
        doc.widthAnchor.constraint(equalTo: detailScroll.contentView.widthAnchor).isActive = true

        let body = hstack([scroll, divider, detailScroll], spacing: 0, alignment: .top)
        for v in [scroll, divider, detailScroll] { v.heightAnchor.constraint(equalTo: body.heightAnchor).isActive = true }
        let root = vstack([title, body], spacing: 2)
        body.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
        body.setContentHuggingPriority(.init(1), for: .vertical)
        root.pin(to: view, insets: NSEdgeInsets(top: 2, left: 0, bottom: 0, right: 0))
        root.alignment = .leading
        NSLayoutConstraint.activate([title.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 18),
                                     title.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -18)])

        buildDetails()
        applyTimeSpan()
        NotificationCenter.default.addObserver(forName: .prefsChanged, object: nil, queue: .main) { [weak self] _ in self?.applyTimeSpan() }
        let saved = min(max(UserDefaults.standard.integer(forKey: "perfSub"), 0), Sub.allCases.count - 1)
        let initialRow = order.firstIndex(of: saved) ?? 0
        table.selectRowIndexes(IndexSet(integer: initialRow), byExtendingSelection: false)
        show(order[initialRow])
        NotificationCenter.default.addObserver(self, selector: #selector(snapshot(_:)), name: .snapshotUpdated, object: nil)
    }

    func pageDidAppear() { if let s = lastSnapshot { updateDetails(s) } }
    func select(_ i: Int) { table.selectRowIndexes(IndexSet(integer: i), byExtendingSelection: false) }

    private func linkButton(_ title: String, _ action: Selector) -> NSButton {
        let b = NSButton(title: title, image: NSImage(systemSymbolName: "info.circle", accessibilityDescription: nil)!, target: self, action: action)
        b.imagePosition = .imageLeading; b.bezelStyle = .rounded; b.controlSize = .small; b.font = Fonts.ui(11.5)
        return b
    }

    private func buildDetails() {
        // ---------------- CPU
        let cpu = DetailView(.cpu, statCaptions: ["Wykorzystanie", "Użytkownik", "System (jądro)", "Bezczynność",
                                                  "Taktowanie", "Procesy", "Wątki", "Czas pracy",
                                                  "Przełączenia kontekstu/s", "Błędy stron/s", "Rdzenie P", "Rdzenie E"],
                             kvKeys: ["Taktowanie bazowe", "Gniazda", "Rdzenie fizyczne", "Procesory logiczne", "Wirtualizacja", "Maszyna wirtualna",
                                      "Pamięć L1 (I/D)", "Pamięć L2 (P/E)", "Pamięć L3", "Sterownik częstotliwości", "Regulator częstotliwości", "Preferencja zasilania",
                                      "Obciążenie 1 / 5 / 15 min", "Presja termiczna", "Moc CPU", "Temperatura rdzeni", "Architektura", "Jądro"])
        cpu.subtitle.stringValue = "\(hw.ncpu) " + L("procesorów logicznych") + " · \(hw.cpuBrand)"
        cpu.caption.stringValue = L("% wykorzystania na procesor logiczny")
        cpuMode.addItems(withTitles: ["Rdzenie rozwinięte", "Wykres łączny"].map { L($0) })
        cpuMode.font = Fonts.ui(11.5); cpuMode.controlSize = .small
        cpuMode.target = self; cpuMode.action = #selector(cpuModeChanged)
        cpu.captionRight.addArrangedSubview(cpuMode)
        cpuOverall.colorProvider = { i, p in i == 0 ? p.cpu : p.cpuKernel }
        cpuOverall.borderAccent = .cpu; cpuOverall.showPercentAxis = true
        cpuOverall.topLeft = "Łącznie (zielony) · jądro (czerwony)"
        cpuOverall.heightAnchor.constraint(equalToConstant: 300).isActive = true
        let cols = hw.ncpu >= 12 ? 6 : 5
        var rows: [NSStackView] = []
        var row: [NSView] = []
        for i in 0..<hw.ncpu {
            let g = GraphView(series: 2, history: 60, accents: [.cpu, .cpu])
            g.compact = true
            g.title = "CPU \(i)"
            g.colorProvider = { i, p in i == 0 ? p.cpu : p.cpuKernel }
            g.borderAccent = i < hw.perfCores ? .gpu : .cpu     // TMOG: niebieska ramka = P, zielona = E
            g.heightAnchor.constraint(equalToConstant: 118).isActive = true
            coreGraphs.append(g)
            row.append(g)
            if row.count == cols { rows.append(hstack(row, spacing: 6, distribution: .fillEqually)); row = [] }
        }
        if !row.isEmpty { while row.count < cols { row.append(spacer()) }; rows.append(hstack(row, spacing: 6, distribution: .fillEqually)) }
        coreGridView = vstack(rows, spacing: 6)
        for r in rows { r.widthAnchor.constraint(equalTo: coreGridView.widthAnchor).isActive = true }
        cpu.addContent(coreGridView)
        cpu.addContent(cpuOverall)
        cpuOverall.isHidden = true
        cpu.set("Taktowanie", "Zarządzane przez Apple")
        cpu.setKV("Taktowanie bazowe", "Niedostępne"); cpu.setKV("Gniazda", "1")
        cpu.setKV("Rdzenie fizyczne", "\(hw.physCpu) (\(hw.perfCores) P + \(hw.effCores) E)"); cpu.setKV("Procesory logiczne", "\(hw.ncpu)")
        cpu.setKV("Wirtualizacja", hw.hvSupport ? "Apple Hypervisor wspierany" : "Niedostępna"); cpu.setKV("Maszyna wirtualna", hw.vmPresent ? "Tak" : "Nie")
        cpu.setKV("Pamięć L1 (I/D)", hw.l1iCache > 0 ? "\(Fmt.bytes(hw.l1iCache, precision: 0)) / \(Fmt.bytes(hw.l1dCache, precision: 0))" : "Niedostępna")
        cpu.setKV("Pamięć L2 (P/E)", hw.l2Cache > 0 ? "\(Fmt.bytes(hw.l2Cache, precision: 0)) / \(Fmt.bytes(hw.l2CacheE, precision: 0))" : "Niedostępna")
        cpu.setKV("Pamięć L3", "Niedostępna"); cpu.setKV("Sterownik częstotliwości", "Apple silicon power management")
        cpu.setKV("Regulator częstotliwości", "Niedostępny"); cpu.setKV("Preferencja zasilania", "Automatyczna (macOS)")

        // ---------------- Pamięć
        let mem = DetailView(.memory, statCaptions: ["W użyciu", "Dostępne", "Zadeklarowane", "Cache", "Swap użyty", "Swap dostępny", "Prędkość", "Sloty",
                                                     "Format", "Typ", "Skompresowane", "Zablokowane (wired)", "Pamięć aplikacji", "Swap łącznie", "Presja", "Obciążenie presji", "Page ins", "Page outs",
                                                     "Aktywna", "Nieaktywna", "Spekulatywna", "Usuwalna (purgeable)", "Pliki w pamięci", "Wolna",
                                                     "Page in/s", "Page out/s", "Swap in/s", "Swap out/s", "Kompresje/s", "Dekompresje/s",
                                                     "Błędy stron/s", "Kopiuj przy zapisie/s", "Trafienia cache", "Rozmiar strony"])
        mem.caption.stringValue = L("Wykorzystanie pamięci")
        memPagingGraph.borderAccent = .memory
        memPagingGraph.autoScale = true
        memPagingGraph.formatter = { Fmt.number(UInt64(max(0, $0))) + "/s" }
        memPagingGraph.colorProvider = { i, p in i == 0 ? p.memory : p.disk }
        memPagingGraph.topLeft = "Page in · page out (na sekundę)"
        memPagingGraph.heightAnchor.constraint(equalToConstant: 120).isActive = true
        memGraph.borderAccent = .memory
        memGraph.autoRange = true
        memGraph.formatter = { Fmt.bytes($0) }
        memGraph.heightAnchor.constraint(equalToConstant: 320).isActive = true
        mem.addContent(memGraph)
        mem.addContent(Label.make(L("Stronicowanie"), size: 11, dim: true))
        mem.addContent(memPagingGraph)
        mem.set("Prędkość", "Niedostępna"); mem.set("Sloty", "Zintegrowane"); mem.set("Format", "On-package"); mem.set("Typ", "Pamięć zunifikowana")

        // ---------------- GPU
        let gpu = DetailView(.gpu, statCaptions: ["Wykorzystanie", "Pamięć", "Temperatura", "Renderer / Tiler", "Taktowanie", "Moc", "Rdzenie", "Zaalokowana",
                                                  "Enkoder wideo", "Dekoder wideo", "Procesor obrazu (ISP)", "Wyświetlacz"],
                             kvKeys: ["Układ", "Pamięć wspólna", "Zalecany limit pamięci", "Maksymalny bufor", "Rodzina Metal",
                                      "Ray tracing", "Bufory argumentów", "Obniżanie precyzji", "Wyświetlacze"])
        gpu.subtitle.stringValue = "\(hw.gpuName) · \(hw.gpuCores) " + L("rdzeni")
        gpu.caption.stringValue = L("% wykorzystania")
        gpuMode.selectedSegment = 0; gpuMode.controlSize = .small; gpuMode.font = Fonts.ui(11.5)
        gpuMode.target = self; gpuMode.action = #selector(gpuModeChanged)
        gpu.captionRight.addArrangedSubview(gpuMode)
        gpuGraph.colorProvider = { i, p in i == 0 ? p.cpu : p.gpu }
        gpuGraph.borderAccent = .gpu
        gpuGraph.heightAnchor.constraint(equalToConstant: 250).isActive = true
        gpu.addContent(gpuGraph)
        let gm = hstack([Label.make(L("Pamięć GPU w użyciu"), size: 11, dim: true), spacer(), gpuMemLabel])
        gpu.addContent(gm)
        gpuMemGraph.borderAccent = .gpu; gpuMemGraph.autoScale = true; gpuMemGraph.formatter = { Fmt.bytes($0) }
        gpuMemGraph.heightAnchor.constraint(equalToConstant: 70).isActive = true
        gpu.addContent(gpuMemGraph)
        gpu.addContent(Label.make(L("Aktywność silników wideo (media engine)"), size: 11, dim: true))
        let encNames = MediaEngine.hardwareEncoders()
        let decNames = MediaEngine.hardwareDecoders().filter { $0.1 }.map { $0.0 }
        let encHead = hstack([Label.make(L("Kodowanie wideo"), size: 11.5, weight: .semibold), spacer(), Label.make(encNames.isEmpty ? L("brak koderów sprzętowych") : encNames.joined(separator: ", "), size: 11, dim: true)])
        let decHead = hstack([Label.make(L("Dekodowanie wideo"), size: 11.5, weight: .semibold), spacer(), Label.make(decNames.isEmpty ? "brak" : "sprzętowo: " + decNames.joined(separator: ", "), size: 11, dim: true)])
        for g in [videoEnc, videoDec] {
            g.borderAccent = .gpu
            g.autoScale = true
            g.formatter = { Fmt.watts($0, precision: 2) }
            g.heightAnchor.constraint(equalToConstant: 70).isActive = true
        }
        let encCol = vstack([encHead, videoEnc], spacing: 3), decCol = vstack([decHead, videoDec], spacing: 3)
        for (h, g, c) in [(encHead, videoEnc, encCol), (decHead, videoDec, decCol)] { h.widthAnchor.constraint(equalTo: c.widthAnchor).isActive = true; g.widthAnchor.constraint(equalTo: c.widthAnchor).isActive = true }
        gpu.addContent(hstack([encCol, decCol], spacing: 10, alignment: .top, distribution: .fillEqually))
        gpu.note.stringValue = "Aktywność silników wideo pokazujemy jako pobór mocy bloków AVE (kodowanie) i VDEC (dekodowanie) z IOReport. Procentowe wykorzystanie tych bloków nie jest udostępniane przez system."

        // ---------------- NPU
        let npu = DetailView(.npu, statCaptions: ["Zasilane bloki", "Pobór mocy", "Energia w oknie", "Stan"])
        npu.subtitle.stringValue = hw.aneCores > 0 ? "Apple Neural Engine · " + L("1 blok sprzętowy") + " · \(hw.aneCores) " + L("rdzeni") + " · \(hw.aneArch)" : "Apple Neural Engine"
        npu.caption.stringValue = L("Zasilane bloki Neural Engine")
        npuGraph.borderAccent = .npu; npuGraph.autoScale = true; npuGraph.formatter = { Fmt.watts($0, precision: 2) }
        npuGraph.heightAnchor.constraint(equalToConstant: 320).isActive = true
        npu.addContent(npuGraph)
        npu.extra.addArrangedSubview(Label.make("ANE 0 · \(hw.aneCores) " + L("rdzeni") + " · \(hw.aneArch) · " + L("gotowy · power gated"), size: 10.5, dim: true))
        npu.note.stringValue = "„Zasilane bloki” to udział bloków ANE niewyłączonych zasilaniem, nie wykorzystanie obliczeniowe. Na macOS 26/27 liczniki energii ANE/CPU/GPU (IOReport) są zamrożone dla wszystkich programów poza narzędziami Apple (powermetrics), także dla procesów administratora; TMOG pokazuje tu również 0,0 W."

        // ---------------- Dyski
        let disk = DetailView(.disk, statCaptions: ["Odczyt", "Zapis", "Łącznie odczytano", "Łącznie zapisano", "Zajętość kolejek", "Śr. czas odpowiedzi", "Pojemność", "Formatowanie", "Dysk systemowy", "Typ", "Temperatura SSD"], subtitleAboveBar: true, twoBars: true)
        disk.caption.stringValue = L("Łączny transfer wszystkich dysków")
        disk.barTag1.stringValue = L("Odczyt"); disk.barTag2.stringValue = L("Zapis")
        disk.barColors = { p in (p.disk, .mix(p.disk, p.network, 0.6)) }
        diskActive.borderAccent = .disk; diskActive.maxValue = 100
        diskActive.heightAnchor.constraint(equalToConstant: 220).isActive = true
        disk.addContent(Label.make(L("Zajętość kolejek we/wy (%) — suma równoległych operacji, przy NVMe często dochodzi do 100%"), size: 11, dim: true))
        disk.addContent(diskActive)
        disk.addContent(Label.make(L("Transfer dysków"), size: 11, dim: true))
        diskRate.borderAccent = .disk; diskRate.autoScale = true; diskRate.formatter = { Fmt.rate($0) }
        diskRate.colorProvider = { i, p in i == 0 ? p.disk : .mix(p.disk, p.network, 0.6) }
        diskRate.topLeft = "Odczyt (zielony) · zapis (turkusowy)"
        diskRate.heightAnchor.constraint(equalToConstant: 110).isActive = true
        disk.addContent(diskRate)
        disk.set("Formatowanie", "Niedostępne"); disk.set("Dysk systemowy", "Tak")
        disk.extra.addArrangedSubview(linkButton(L("Szczegóły pamięci masowej…"), #selector(openStorage)))

        // ---------------- Sieć
        let net = DetailView(.network, statCaptions: ["Odbiór", "Nadawanie", "Łącznie odebrano", "Łącznie wysłano", "Interfejs", "Typ połączenia", "Adres sprzętowy", "Adres IPv4", "Adres IPv6", "Pakiety / s", "Sieć Wi-Fi", "Sygnał", "Szybkość łącza", "Zabezpieczenia", "Pasmo / kanał"], subtitleAboveBar: true, twoBars: true)
        net.barTag1.stringValue = L("↓ Odbiór"); net.barTag2.stringValue = L("↑ Nadawanie")
        net.barColors = { p in (p.cpu, p.energy) }
        net.caption.stringValue = L("Przepustowość")
        netGraph.borderAccent = .network; netGraph.autoScale = true; netGraph.formatter = { Fmt.rate($0) }
        netGraph.colorProvider = { i, p in i == 0 ? p.cpu : p.energy }
        netGraph.topLeft = "Odbiór (zielony) · nadawanie (żółty)"
        netGraph.heightAnchor.constraint(equalToConstant: 340).isActive = true
        net.addContent(netGraph)
        net.set("Interfejs", "Wszystkie interfejsy"); net.set("Typ połączenia", "Łączone"); net.set("Adres sprzętowy", "—")
        net.set("Adres IPv4", "Wiele"); net.set("Adres IPv6", "Wiele")
        net.addContent(Label.make(L("Interfejsy"), size: 11, dim: true))
        ifaceList.orientation = .vertical
        ifaceList.alignment = .leading
        ifaceList.spacing = 3
        net.addContent(ifaceList)
        net.extra.addArrangedSubview(linkButton(L("Szczegóły połączeń…"), #selector(openConnections)))
        locationButton.title = L("Pokaż nazwę sieci Wi-Fi…")
        locationButton.bezelStyle = .rounded
        locationButton.controlSize = .small
        locationButton.font = Fonts.ui(11.5)
        locationButton.target = self
        locationButton.action = #selector(askLocation)
        locationButton.toolTip = L("macOS udostępnia nazwę sieci (SSID) tylko aplikacjom ze zgodą na dostęp do lokalizacji")
        net.extra.addArrangedSubview(locationButton)
        LocationAccess.shared.onChange = { [weak self] in
            guard let self, let s = self.lastSnapshot else { return }
            self.updateDetails(s)
        }

        // ---------------- Zasilanie
        let en = DetailView(.energy, statCaptions: [], subtitleAboveBar: true)
        en.caption.stringValue = L("Pobór mocy")
        energyGraph.borderAccent = .energy; energyGraph.autoScale = true; energyGraph.formatter = { Fmt.watts($0) }
        energyGraph.heightAnchor.constraint(equalToConstant: 200).isActive = true
        en.addContent(energyGraph)
        en.statsGrid.isHidden = true
        let tileDefs: [(String, String, Subsystem?)] = [
            ("CPU", "cpu", .cpu), ("GPU", "display", .gpu), ("ANE", "brain", .npu),
            ("DRAM", "memorychip", .memory), ("Moc pakietu SoC", "cpu.fill", .npu), ("Stan termiczny", "thermometer.medium", .thermal),
            ("Tryb zasilania", "gauge.with.dots.needle.33percent", .cpu), ("Źródło zasilania", "powerplug", .energy), ("Bateria", "battery.100percent", .disk),
            ("Cykle ładowania", "arrow.triangle.2.circlepath", nil), ("Kondycja baterii", "heart.text.square", .energy), ("Zasilacz (DC)", "bolt", .energy),
        ]
        var tileRows: [NSView] = []
        var tr: [NSView] = []
        for (t, ic, a) in tileDefs {
            let tile = TileStat(t, icon: ic, accent: a)
            energyTiles[t] = tile
            tr.append(tile)
            if tr.count == 3 { tileRows.append(hstack(tr, spacing: 10, distribution: .fillEqually)); tr = [] }
        }
        if !tr.isEmpty { while tr.count < 3 { tr.append(spacer()) }; tileRows.append(hstack(tr, spacing: 10, distribution: .fillEqually)) }
        let tilesStack = vstack(tileRows, spacing: 10)
        for r in tileRows { r.widthAnchor.constraint(equalTo: tilesStack.widthAnchor).isActive = true }
        en.extra.addArrangedSubview(tilesStack)
        tilesStack.widthAnchor.constraint(equalTo: en.extra.widthAnchor).isActive = true
        let epTitle = NSTextField(labelWithString: "")
        epTitle.attributedStringValue = NSAttributedString(string: "Procesy o najwyższym szacowanym zapotrzebowaniu na energię", attributes: [.font: Fonts.title(17), .kern: 0.5, .foregroundColor: P.text])
        en.extra.addArrangedSubview(epTitle)
        for _ in 0..<8 { let r = BarRow(); barRows.append(r); energyProcs.addArrangedSubview(r); r.widthAnchor.constraint(equalTo: energyProcs.widthAnchor).isActive = true }
        en.extra.addArrangedSubview(energyProcs)
        energyProcs.widthAnchor.constraint(equalTo: en.extra.widthAnchor).isActive = true
        en.note.stringValue = "Moc systemu i zasilacza pochodzi z SMC. Moc CPU / GPU / ANE / DRAM wymaga liczników energii IOReport, które macOS 26/27 udostępnia wyłącznie narzędziom Apple (powermetrics); dlatego pola pokazują „—”."

        // ---------------- Termika
        let th = DetailView(.thermals, statCaptions: [], subtitleAboveBar: true)
        th.caption.stringValue = "Hotspot CPU / SoC"
        let maxLabel = Label.make(L("110,0 °C"), size: 10.5, dim: true)
        th.captionRight.addArrangedSubview(maxLabel)
        thermGraph.borderAccent = .thermal; thermGraph.maxValue = 110
        thermGraph.heightAnchor.constraint(equalToConstant: 240).isActive = true
        th.addContent(thermGraph)
        th.statsGrid.isHidden = true
        let tp = TileStat("Presja termiczna", icon: "thermometer.medium", accent: .thermal)
        let hs = TileStat("Hotspot", icon: "thermometer.high", accent: .thermal)
        thermTiles["Presja"] = tp; thermTiles["Hotspot"] = hs
        let ttRow = hstack([tp, hs], spacing: 10, distribution: .fillEqually)
        th.extra.addArrangedSubview(ttRow)
        ttRow.widthAnchor.constraint(equalTo: th.extra.widthAnchor).isActive = true
        let stTitle = NSTextField(labelWithString: "")
        stTitle.attributedStringValue = NSAttributedString(string: "Czujniki temperatury", attributes: [.font: Fonts.title(17), .kern: 0.5, .foregroundColor: P.text])
        th.extra.addArrangedSubview(stTitle)
        th.extra.addArrangedSubview(sensorsGrid)
        sensorsGrid.widthAnchor.constraint(equalTo: th.extra.widthAnchor).isActive = true

        // ---------------- Bateria
        let bat = DetailView(.battery, statCaptions: ["Naładowanie", "Stan", "Czas pozostały", "Moc", "Napięcie", "Prąd",
                                                      "Cykle ładowania", "Kondycja", "Temperatura", "Pojemność bieżąca",
                                                      "Pojemność fabryczna", "Zużycie pojemności"],
                             kvKeys: ["Źródło zasilania", "Ładowanie", "Zasilacz", "Wejście zasilacza", "Pobór systemu", "Presja termiczna"],
                             subtitleAboveBar: true, twoBars: true)
        bat.barTag1.stringValue = L("Poziom"); bat.barTag2.stringValue = L("Przepływ")
        bat.barColors = { p in (p.good, p.energy) }
        bat.caption.stringValue = L("Naładowanie baterii")
        batteryGraph.borderAccent = .energy
        batteryGraph.maxValue = 100
        batteryGraph.formatter = { String(format: "%.0f%%", $0) }
        batteryGraph.heightAnchor.constraint(equalToConstant: 220).isActive = true
        bat.addContent(batteryGraph)
        bat.addContent(Label.make(L("Przepływ mocy (ładowanie dodatnie, rozładowanie ujemne)"), size: 11, dim: true))
        batteryFlowGraph.borderAccent = .energy
        batteryFlowGraph.autoScale = true
        batteryFlowGraph.formatter = { Fmt.watts($0, precision: 1) }
        batteryFlowGraph.heightAnchor.constraint(equalToConstant: 110).isActive = true
        bat.addContent(batteryFlowGraph)

        details = [cpu, mem, gpu, npu, disk, net, en, th, bat]
    }

    private static let sensorGroups: [(String, String)] = [
        ("Tp", "Rdzenie wydajnościowe"), ("Te", "Rdzenie energooszczędne"), ("Tg", "GPU"), ("TB", "Bateria"), ("TH", "SSD"),
        ("TW", "Moduł bezprzewodowy"), ("TC", "SoC"), ("TPD", "Zasilanie (PMU)"), ("TR", "Regulatory napięcia"), ("TV", "VRM"), ("Tm", "Pamięć"), ("TA", "Otoczenie"),
    ]

    private func groupName(_ key: String) -> String {
        for (prefix, name) in Self.sensorGroups where key.hasPrefix(prefix) { return name }
        return "Pozostałe"
    }

    @objc private func cpuModeChanged() {
        let expanded = cpuMode.indexOfSelectedItem == 0
        coreGridView.isHidden = !expanded
        cpuOverall.isHidden = expanded
    }
    @objc private func gpuModeChanged() { gpuGraph.seriesCount == 2 ? () : () }
    @objc private func openStorage() { NotificationCenter.default.post(name: .openSystemInfoCategory, object: "SPStorageDataType") }
    @objc private func askLocation() { LocationAccess.shared.request() }

    /// Przy pierwszym pokazaniu strony Wi-Fi system sam pyta o zgodę (tylko gdy nie było jeszcze decyzji)
    private func askLocationIfNeeded() {
        guard !askedLocation, LocationAccess.shared.status == .notDetermined else { return }
        askedLocation = true
        LocationAccess.shared.request()
    }
    @objc private func openConnections() { NotificationCenter.default.post(name: .openPage, object: 8) }

    /// Tworzy/usuwa pozycje listy dla fizycznych dysków i odświeża ich dane
    private let locationButton = NSButton()
    private var wifiLocationButtons: [NSButton] = []
    private var askedLocation = false
    private var gpuInfoApplied = false
    private let memPagingGraph = GraphView(series: 2, history: 120, accents: [.memory, .disk])
    private let batteryGraph = GraphView(series: 1, history: 120, accents: [.energy])
    private let batteryFlowGraph = GraphView(series: 1, history: 120, accents: [.energy])
    private var batteryPeakWatts: Double = 5
    private var mediaPeak: Double = 0.05
    private let ifaceList = NSStackView()
    private var ifaceRows: [String: (title: NSTextField, info: NSTextField)] = [:]
    private var ifacePeak: [String: Double] = [:]
    private var diskScaleHistory: [Double] = []
    /// Największy zaobserwowany transfer dla każdego dysku – pasek LED skaluje się do niego
    private var diskPeak: [String: Double] = [:]
    private var lastDisksGeneration = -1

    private func syncDisks(_ disks: [DiskDevice], generation: Int) {
        // wykresy karmimy tylko nowymi pomiarami – inaczej powstają płaskie „schodki”
        let fresh = generation != lastDisksGeneration
        lastDisksGeneration = generation
        let keys = disks.map { $0.bsd + "|" + $0.name }
        if Set(keys) != Set(diskPages.keys) {
            // przebudowa: pozycje dysków trzymamy na końcu tablic, a kolejność wyświetlania ustala `order`
            let fixed = Sub.allCases.count
            cells.removeSubrange(fixed...)
            details.removeSubrange(fixed...)
            diskPages.removeAll()
            for (i, d) in disks.enumerated() {
                let label = L("Dysk") + " \(i)"
                let cell = SubsystemCell(.disk, titleText: label, iconName: d.icon)
                let detail = DetailView(.disk,
                                        statCaptions: ["Odczyt", "Zapis", "Łącznie odczytano", "Łącznie zapisano", "Pojemność"],
                                        kvKeys: ["Model", "Rodzaj", "Architektura", "Łącze", "Nazwa BSD", "Nośnik", "Interfejs", "Położenie", "Wymienny",
                                                 "Wysuwalny", "Rozmiar bloku", "Schemat", "Wolumin",
                                                 "Stan SMART", "Temperatura", "Czas pracy", "Cykle zasilania",
                                                 "Zużycie komórek", "Zapas bloków", "Nagłe wyłączenia", "Błędy nośnika",
                                                 "Odczytano (SMART)", "Zapisano (SMART)"],
                                        subtitleAboveBar: true, titleText: label, twoBars: true)
                detail.barTag1.stringValue = L("Odczyt"); detail.barTag2.stringValue = L("Zapis")
                detail.barColors = { p in (p.disk, .mix(p.disk, p.network, 0.6)) }
                detail.caption.stringValue = L("Transfer")
                let g = GraphView(series: 2, history: 120, accents: [.disk, .disk])
                g.borderAccent = .disk
                g.autoScale = true
                g.formatter = { Fmt.rate($0) }
                g.colorProvider = { i, p in i == 0 ? p.disk : .mix(p.disk, p.network, 0.6) }
                g.topLeft = "Odczyt (jaśniejszy) · zapis"
                g.heightAnchor.constraint(equalToConstant: 220).isActive = true
                detail.addContent(g)
                let span = Double(Prefs.shared.graphSpanSeconds)
                g.timeSpan = span
                cell.graph.timeSpan = span
                diskPages[keys[i]] = (cells.count, g)
                cells.append(cell)
                details.append(detail)
            }
            diskKeysOrder = keys
            rebuildOrder()
        }
        for (i, d) in disks.enumerated() {
            guard let page = diskPages[keys[i]] else { continue }
            let cell = cells[page.index], detail = details[page.index]
            if fresh { cell.graph.push([d.readRate, d.writeRate]) }
            cell.line1.update((d.name.isEmpty ? d.bsd : d.name) + " · " + d.category, flash: false)
            cell.line2.update("R \(Fmt.rate(d.readRate))  W \(Fmt.rate(d.writeRate))", flash: false)
            if fresh { page.graph.push([d.readRate, d.writeRate]) }
            guard detail.superview != nil else { continue }
            detail.subtitle.stringValue = "\(d.bsd) · \(d.kind) · \(Fmt.bytes(d.size, precision: 0))"
            // pasek pokazuje bieżący transfer w skali do największego, jaki ten dysk osiągnął w tej sesji
            let peak = max(1_000_000, max(diskPeak[keys[i]] ?? 0, d.readRate, d.writeRate))
            diskPeak[keys[i]] = peak
            detail.bar.value = min(1, d.readRate / peak)
            detail.pct.update(flash: false, Fmt.rate(d.readRate))
            detail.bar2.value = min(1, d.writeRate / peak)
            detail.pct2.update(flash: false, Fmt.rate(d.writeRate))
            detail.caption.stringValue = L("Transfer") + " · " + L("skala do") + " \(Fmt.rate(peak))"
            detail.set("Odczyt", Fmt.rate(d.readRate)); detail.set("Zapis", Fmt.rate(d.writeRate))
            detail.set("Łącznie odczytano", Fmt.bytes(d.readBytes)); detail.set("Łącznie zapisano", Fmt.bytes(d.writeBytes))
            detail.set("Pojemność", Fmt.bytes(d.size, precision: 0))
            detail.setKV("Model", d.name.isEmpty ? "—" : d.name)
            detail.setKV("Rodzaj", d.category)
            detail.setKV("Architektura", d.architecture.isEmpty ? "—" : d.architecture)
            detail.setKV("Łącze", d.link.isEmpty ? (d.interconnect.isEmpty ? "—" : d.interconnect) : d.link)
            detail.setKV("Nazwa BSD", d.bsd.isEmpty ? "—" : d.bsd)
            detail.setKV("Nośnik", d.medium.isEmpty ? "—" : d.medium)
            detail.setKV("Interfejs", d.interconnect.isEmpty ? "—" : d.interconnect)
            detail.setKV("Położenie", d.isInternal ? "Wewnętrzny" : "Zewnętrzny")
            detail.setKV("Wymienny", d.removable ? "Tak" : "Nie")
            applySMART(detail, bsd: d.bsd)
        }
    }

    /// Układa listę: stałe podsystemy, a zaraz za „Dyski” i „Sieć” ich pojedyncze urządzenia
    private func rebuildOrder() {
        let fixed = Sub.allCases.count
        // bez zbiorczych pozycji „Dyski” i „Sieć” – lista pokazuje wyłącznie konkretne urządzenia
        var o = Array(0..<4)                                  // CPU, pamięć, GPU, NPU
        o += diskKeysOrder.compactMap { diskPages[$0]?.index }
        o += ifaceKeys.compactMap { ifacePages[$0]?.index }
        o += Array(6..<fixed)                                 // Zasilanie, Termika, Bateria
        guard o != order else { return }
        let selectedDetail = table.selectedRow >= 0 && table.selectedRow < order.count ? order[table.selectedRow] : 0
        order = o
        table.reloadData()
        if let row = order.firstIndex(of: selectedDetail) {
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
    }

    /// Tworzy i odświeża pozycje pojedynczych interfejsów sieciowych
    private func syncInterfaces(_ all: [NetInterface], generation: Int) {
        let fresh = generation != lastIfacesGeneration
        lastIfacesGeneration = generation
        // Pokazujemy tylko interfejsy z adresem albo z bieżącym ruchem. Liczniki od startu systemu
        // nie wystarczą: adapter USB bywa podłączony i „uruchomiony”, choć nie ma sieci ani adresu.
        let shown = all.filter { !$0.addrs.isEmpty || $0.rxRate + $0.txRate > 1024 }
        let keys = shown.map(\.name)
        if keys != ifaceKeys {
            let fixed = Sub.allCases.count
            // pozycje interfejsów trzymamy na końcu tablic, tuż za dyskami
            for k in ifacePages.keys.sorted(by: { (ifacePages[$0]?.index ?? 0) > (ifacePages[$1]?.index ?? 0) }) {
                if let idx = ifacePages[k]?.index, idx >= fixed, idx < cells.count {
                    cells.remove(at: idx); details.remove(at: idx)
                }
            }
            ifacePages.removeAll()
            // indeksy dysków mogły się przesunąć, więc odbudowujemy je od nowa
            for (n, k) in diskKeysOrder.enumerated() { if let g = diskPages[k]?.graph { diskPages[k] = (fixed + n, g) } }
            for name in keys {
                let kind = NetInfo.kind(for: name)
                let cell = SubsystemCell(.network, titleText: "\(kind.display) (\(name))", iconName: kind.icon)
                let detail = DetailView(.network,
                                        statCaptions: ["Odbiór", "Nadawanie", "Łącznie odebrano", "Łącznie wysłano",
                                                       "Pakiety odebrane", "Pakiety wysłane", "Błędy", "Odrzucone"],
                                        kvKeys: ["Rodzaj", "Urządzenie", "Sprzęt", "Usługa sieciowa", "Stan", "Adres sprzętowy",
                                                 "Adres IPv4", "Maska podsieci", "Rozgłoszeniowy", "Adres IPv6",
                                                 "Router", "Serwery DNS", "Domeny wyszukiwania", "Serwer DHCP", "Dzierżawa DHCP",
                                                 "Interfejs podstawowy", "MTU", "Medium", "Prędkość łącza", "Multicast",
                                                 "Sieć Wi-Fi", "Sygnał", "Szybkość Wi-Fi", "Zabezpieczenia", "Pasmo / kanał", "BSSID",
                                                 "Profil VPN", "Typ VPN", "Kolizje"],
                                        subtitleAboveBar: true, titleText: "\(kind.display) (\(name))", twoBars: true)
                detail.barTag1.stringValue = L("↓ Odbiór"); detail.barTag2.stringValue = L("↑ Nadawanie")
                detail.barColors = { p in (p.cpu, p.energy) }
                detail.caption.stringValue = L("Przepustowość")
                let g = GraphView(series: 2, history: 120, accents: [.network, .network])
                g.borderAccent = .network
                g.autoScale = true
                g.formatter = { Fmt.rate($0) }
                g.colorProvider = { i, p in i == 0 ? p.cpu : p.energy }
                g.topLeft = "Odbiór · nadawanie"
                g.heightAnchor.constraint(equalToConstant: 220).isActive = true
                detail.addContent(g)
                if kind.type == "Wi-Fi" {
                    let b = NSButton(title: L("Pokaż nazwę sieci Wi-Fi…"), target: self, action: #selector(askLocation))
                    b.bezelStyle = .rounded; b.controlSize = .small; b.font = Fonts.ui(11.5)
                    b.toolTip = L("macOS udostępnia nazwę sieci (SSID) tylko aplikacjom ze zgodą na dostęp do lokalizacji")
                    b.isHidden = LocationAccess.shared.granted
                    detail.extra.addArrangedSubview(b)
                    wifiLocationButtons.append(b)
                }
                let span = Double(Prefs.shared.graphSpanSeconds)
                g.timeSpan = span
                cell.graph.timeSpan = span
                ifacePages[name] = (cells.count, g)
                cells.append(cell)
                details.append(detail)
            }
            ifaceKeys = keys
            rebuildOrder()
        }
        let wifi = NetInfo.wifi()
        if wifi?.powerOn == true { askLocationIfNeeded() }
        for itf in shown {
            guard let page = ifacePages[itf.name] else { continue }
            let cell = cells[page.index], detail = details[page.index]
            let kind = NetInfo.kind(for: itf.name)
            if fresh { cell.graph.push([itf.rxRate, itf.txRate]) }
            if fresh { page.graph.push([itf.rxRate, itf.txRate]) }
            cell.line1.update("\(itf.name) · \(kind.type)", flash: false)
            cell.line2.update("↓ \(Fmt.rate(itf.rxRate))  ↑ \(Fmt.rate(itf.txRate))", flash: false)
            guard detail.superview != nil else { continue }
            let peak = max(125_000.0, itf.rxRate, itf.txRate, ifacePeak[itf.name] ?? 0)
            ifacePeak[itf.name] = peak
            detail.subtitle.stringValue = "\(itf.name) · \(kind.type)" + " · " + (itf.up ? L("aktywny") : L("nieaktywny"))
            detail.bar.value = min(1, itf.rxRate / peak); detail.pct.update(flash: false, Fmt.rate(itf.rxRate))
            detail.bar2.value = min(1, itf.txRate / peak); detail.pct2.update(flash: false, Fmt.rate(itf.txRate))
            detail.set("Odbiór", Fmt.rate(itf.rxRate)); detail.set("Nadawanie", Fmt.rate(itf.txRate))
            detail.set("Łącznie odebrano", Fmt.bytes(itf.rxBytes)); detail.set("Łącznie wysłano", Fmt.bytes(itf.txBytes))
            detail.set("Pakiety odebrane", "\(itf.rxPackets)")
            detail.set("Pakiety wysłane", "\(itf.txPackets)")
            detail.set("Błędy", "↓ \(itf.rxErrors)  ↑ \(itf.txErrors)")
            detail.set("Odrzucone", "\(itf.drops)")
            detail.setKV("Rodzaj", kind.type)
            detail.setKV("Urządzenie", "\(kind.display) · \(itf.name)")
            detail.setKV("Sprzęt", NetInfo.hardwareModel(for: itf.name) ?? "—")
            detail.setKV("Usługa sieciowa", NetInfo.serviceName(for: itf.name) ?? "brak (interfejs bez usługi)")
            detail.setKV("Adres sprzętowy", itf.mac.isEmpty ? "—" : itf.mac)
            let parts = itf.addrs.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            detail.setKV("Adres IPv4", parts.first { $0.contains(".") } ?? "—")
            detail.setKV("Adres IPv6", parts.first { $0.contains(":") } ?? "—")
            detail.setKV("Stan", itf.up ? "Aktywny" : "Nieaktywny")
            detail.setKV("Maska podsieci", itf.netmask.isEmpty ? "—" : itf.netmask)
            detail.setKV("Rozgłoszeniowy", itf.broadcast.isEmpty ? "—" : itf.broadcast)
            detail.setKV("MTU", itf.mtu > 0 ? "\(itf.mtu) B" : "—")
            detail.setKV("Medium", itf.media.isEmpty ? "—" : itf.media)
            detail.setKV("Prędkość łącza", itf.linkSpeedMbps > 0 ? "\(itf.linkSpeedMbps) Mb/s" : "—")
            detail.setKV("Multicast", itf.multicast ? "Tak" : "Nie")
            detail.setKV("Kolizje", "\(itf.collisions)")
            let cfg = NetInfo.ipConfig(for: itf.name)
            detail.setKV("Router", cfg.router ?? "—")
            detail.setKV("Serwery DNS", cfg.dns.isEmpty ? "—" : cfg.dns.joined(separator: ", "))
            detail.setKV("Domeny wyszukiwania", cfg.searchDomains.isEmpty ? "—" : cfg.searchDomains.joined(separator: ", "))
            detail.setKV("Serwer DHCP", cfg.dhcpServer ?? "—")
            detail.setKV("Dzierżawa DHCP", cfg.leaseHours.map { String(format: "%.1f h", $0) } ?? "—")
            detail.setKV("Interfejs podstawowy", cfg.isPrimary ? "Tak" : "Nie")
            if let w = wifi, w.interface == itf.name, w.powerOn {
                detail.setKV("Sieć Wi-Fi", w.ssid ?? "brak zgody na lokalizację")
                detail.setKV("Sygnał", "\(w.rssi) dBm (szum \(w.noise) dBm)")
                detail.setKV("Szybkość Wi-Fi", w.txRateMbps > 0 ? String(format: "%.0f Mb/s", w.txRateMbps) : "—")
                detail.setKV("Zabezpieczenia", w.security)
                detail.setKV("Pasmo / kanał", w.channel > 0 ? "\(w.band) · " + L("kanał") + " \(w.channel)" : "—")
                detail.setKV("BSSID", w.bssid ?? "—")
            } else {
                for k in ["Sieć Wi-Fi", "Sygnał", "Szybkość Wi-Fi", "Zabezpieczenia", "Pasmo / kanał", "BSSID"] { detail.setKV(k, "—") }
            }
            if kind.type == "VPN", let v = NetInfo.vpn(for: itf.name) {
                detail.setKV("Profil VPN", v.name)
                detail.setKV("Typ VPN", v.kind)
                detail.subtitle.stringValue = "\(itf.name) · VPN „\(v.name)” · \(v.kind)"
                cell.title.stringValue = v.name
                cell.line1.update("\(itf.name) · VPN · \(v.kind)", flash: false)
            } else {
                detail.setKV("Profil VPN", kind.type == "VPN" ? "nierozpoznany" : "nie dotyczy")
                detail.setKV("Typ VPN", kind.type == "VPN" ? "tunel systemowy" : "nie dotyczy")
            }
        }
        for b in wifiLocationButtons { b.isHidden = LocationAccess.shared.granted }
    }

    /// Strona baterii: naładowanie, przepływ mocy, kondycja i parametry ogniwa
    private func updateBattery(_ s: Snapshot) {
        let bat = details[8]
        guard let b = s.battery, b.present else {
            bat.subtitle.stringValue = L("Brak baterii (zasilanie sieciowe)")
            bat.pct.update(flash: false, L("—"))
            return
        }
        let flow = b.watts
        batteryPeakWatts = max(5, max(batteryPeakWatts * 0.999, flow))
        batteryGraph.push(Double(b.percent))
        batteryFlowGraph.push(flow)
        let state = b.charging ? L("ładowanie") : (b.onAC ? L("zasilanie sieciowe") : L("rozładowanie"))
        bat.subtitle.stringValue = "\(b.percent)% · \(state) · \(b.cycleCount) " + L("cykli") + " · \(b.health)"
        bat.bar.value = Double(b.percent) / 100
        bat.pct.update(flash: false, "\(b.percent)%")
        bat.bar2.value = min(1, flow / batteryPeakWatts)
        bat.pct2.update(flash: false, Fmt.watts(flow, precision: 1))
        bat.set("Naładowanie", "\(b.percent)%")
        bat.set("Stan", state)
        let mins = b.charging ? b.timeToFullMin : b.timeToEmptyMin
        bat.set("Czas pozostały", mins > 0 ? "\(mins / 60) h \(mins % 60) min" : "obliczanie…")
        bat.set("Moc", Fmt.watts(flow, precision: 2))
        bat.set("Napięcie", String(format: "%.3f V", Double(b.voltage_mV) / 1000))
        bat.set("Prąd", String(format: "%d mA", b.amperage_mA))
        bat.set("Cykle ładowania", "\(b.cycleCount)")
        bat.set("Kondycja", b.health)
        bat.set("Temperatura", b.temperatureC > 0 ? Fmt.temp(b.temperatureC) : "—")
        bat.set("Pojemność bieżąca", b.nominalCapacity > 0 ? "\(b.nominalCapacity) mAh" : "—")
        bat.set("Pojemność fabryczna", b.designCapacity > 0 ? "\(b.designCapacity) mAh" : "—")
        if b.designCapacity > 0, b.nominalCapacity > 0 {
            let wear = 100.0 * Double(b.nominalCapacity) / Double(b.designCapacity)
            bat.set("Zużycie pojemności", String(format: L("%.0f%% pojemności fabrycznej"), wear))
            bat.stats["Zużycie pojemności"]?.valueLabel.textColor = wear > 90 ? P.good : (wear > 80 ? P.warn : P.bad)
        } else {
            bat.set("Zużycie pojemności", "—")
        }
        if b.temperatureC > 0 { bat.stats["Temperatura"]?.valueLabel.textColor = ThermalScale.color(b.temperatureC, key: "TB") }
        bat.setKV("Źródło zasilania", b.onAC ? "Zasilacz sieciowy" : "Bateria")
        bat.setKV("Ładowanie", b.charging ? "Tak" : "Nie")
        bat.setKV("Zasilacz", s.dcInWatts != nil ? "Podłączony" : (b.onAC ? "Podłączony" : "Odłączony"))
        bat.setKV("Wejście zasilacza", s.dcInWatts.map { Fmt.watts($0, precision: 1) } ?? "—")
        bat.setKV("Pobór systemu", s.sysWatts.map { Fmt.watts($0, precision: 1) } ?? "—")
        bat.setKV("Presja termiczna", s.thermalText)
    }

    /// Gęsta historia (jak na stronie Podsumowanie): mała odległość między próbkami daje płynny ruch
    private func applyTimeSpan() {
        for c in cells { GraphStyle.applyTimeSpan(c) }
        for d in details { GraphStyle.applyTimeSpan(d) }
    }

    /// Statyczne dane GPU z Metal i lista wyświetlaczy (ustawiane raz)
    private func applyGPUInfo(_ gpu: DetailView) {
        guard !gpuInfoApplied else {
            gpu.setKV("Wyświetlacze", Self.displaysDescription())
            return
        }
        gpuInfoApplied = true
        if let d = MTLCreateSystemDefaultDevice() {
            gpu.setKV("Układ", d.name)
            gpu.setKV("Pamięć wspólna", d.hasUnifiedMemory ? "Tak (unified memory)" : "Nie")
            gpu.setKV("Zalecany limit pamięci", Fmt.bytes(UInt64(d.recommendedMaxWorkingSetSize)))
            gpu.setKV("Maksymalny bufor", Fmt.bytes(UInt64(d.maxBufferLength)))
            let families: [(MTLGPUFamily, String)] = [(.apple9, "Apple 9"), (.apple8, "Apple 8"), (.apple7, "Apple 7"),
                                                      (.apple6, "Apple 6"), (.metal3, "Metal 3")]
            gpu.setKV("Rodzina Metal", families.first { d.supportsFamily($0.0) }?.1 ?? "—")
            gpu.setKV("Ray tracing", d.supportsRaytracing ? "Tak" : "Nie")
            gpu.setKV("Bufory argumentów", "Tier \(d.argumentBuffersSupport == .tier2 ? 2 : 1)")
            gpu.setKV("Obniżanie precyzji", d.supports32BitFloatFiltering ? L("Filtrowanie 32-bit float") : "—")
        }
        gpu.setKV("Wyświetlacze", Self.displaysDescription())
    }

    /// Opis podłączonych ekranów: rozdzielczość, odświeżanie, skala i HDR
    private static func displaysDescription() -> String {
        NSScreen.screens.enumerated().map { i, sc in
            let size = sc.frame.size
            let hz = sc.maximumFramesPerSecond
            let hdr = sc.maximumPotentialExtendedDynamicRangeColorComponentValue > 1.0
            return "\(i + 1): \(Int(size.width))×\(Int(size.height)) @\(hz) Hz ·  \(Int(sc.backingScaleFactor))x" + (hdr ? " · HDR" : "")
        }.joined(separator: "   |   ")
    }

    /// Rozpoznaje aktywne połączenie (Wi-Fi, Ethernet, hotspot, Bluetooth PAN…) i listuje interfejsy
    private func updateNetworkKind(_ net: DetailView) {
        let all = Monitor.interfaces()
        // aktywne łącze: interfejs z adresem IPv4 innym niż pętla zwrotna
        let active = all.first { $0.up && $0.addrs.contains(".") && $0.name != "lo0" }
        let wifi = NetInfo.wifi()
        let activeKind = active.map { NetInfo.kind(for: $0.name) }

        if let w = wifi, w.powerOn, active?.name == w.interface || activeKind?.type == "Wi-Fi" {
            net.set("Typ połączenia", w.isHotspot ? "Wi-Fi — udostępnianie (hotspot)" : "Wi-Fi \(w.phyMode)")
            net.set("Sieć Wi-Fi", w.ssid ?? "ukryta lub brak zgody na lokalizację")
            net.set("Sygnał", "\(w.rssi) dBm (szum \(w.noise) dBm)")
            net.set("Szybkość łącza", w.txRateMbps > 0 ? String(format: "%.0f Mb/s", w.txRateMbps) : "—")
            net.set("Zabezpieczenia", w.security)
            net.set("Pasmo / kanał", w.channel > 0 ? "\(w.band) · " + L("kanał") + " \(w.channel)" : "—")
            net.subtitle.stringValue = "Wi-Fi \(w.ssid ?? "") · \(w.band) · \(w.phyMode)"
        } else {
            net.set("Typ połączenia", activeKind?.type ?? "—")
            for k in ["Sieć Wi-Fi", "Sygnał", "Szybkość łącza", "Zabezpieczenia", "Pasmo / kanał"] { net.set(k, "—") }
            if let a = active, let k = activeKind { net.subtitle.stringValue = "\(k.display) (\(a.name)) · \(k.type)" }
        }
        if let a = active, let k = activeKind {
            net.set("Interfejs", "\(k.display) (\(a.name))")
            net.set("Adres sprzętowy", a.mac.isEmpty ? "—" : a.mac)
            let v4 = a.addrs.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.first { $0.contains(".") }
            let v6 = a.addrs.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.first { $0.contains(":") }
            net.set("Adres IPv4", v4 ?? "—")
            net.set("Adres IPv6", v6 ?? "—")
        }

        // lista wszystkich interfejsów: z adresem, z ruchem albo podłączonych fizycznie
        let shown = all.filter { !$0.addrs.isEmpty || $0.rxRate + $0.txRate > 1024 || $0.up }
        let keys = shown.map(\.name)
        if Set(keys) != Set(ifaceRows.keys) {
            ifaceRows.removeAll()
            for v in ifaceList.arrangedSubviews { ifaceList.removeArrangedSubview(v); v.removeFromSuperview() }
            for name in keys {
                let t = Label.make(name, size: 11.5, weight: .medium)
                t.size(width: 90)
                let i = Label.make("", size: 11, dim: true)
                let row = hstack([t, i, spacer()], spacing: 8)
                ifaceList.addArrangedSubview(row)
                row.widthAnchor.constraint(equalTo: ifaceList.widthAnchor).isActive = true
                ifaceRows[name] = (t, i)
            }
        }
        for itf in shown {
            guard let r = ifaceRows[itf.name] else { continue }
            let k = NetInfo.kind(for: itf.name)
            r.title.stringValue = "\(itf.name) · \(k.type)"
            let addr = itf.addrs.isEmpty ? "bez adresu" : itf.addrs
            r.info.stringValue = "\(k.display) · \(itf.up ? L("aktywny") : L("nieaktywny")) · \(addr)"
            r.info.textColor = itf.up ? P.text : P.textDim
        }
    }

    /// Uzupełnia stronę dysku o szczegóły i SMART z diskutil (ładowane w tle)
    private func applySMART(_ detail: DetailView, bsd: String) {
        guard let x = DiskDetails.shared.detail(for: bsd) else {
            detail.setKV("Stan SMART", "odczytywanie…")
            return
        }
        detail.setKV("Wysuwalny", x.ejectable ? "Tak" : "Nie")
        detail.setKV("Rozmiar bloku", x.blockSize > 0 ? "\(x.blockSize) B" : "—")
        detail.setKV("Schemat", x.content.isEmpty ? "—" : x.content)
        detail.setKV("Wolumin", x.volumeName.isEmpty ? "—" : x.volumeName)
        switch x.smartStatus {
        case "Verified": detail.setKV("Stan SMART", "Sprawny (Verified)")
        case "": detail.setKV("Stan SMART", "—")
        case "Not Supported": detail.setKV("Stan SMART", "Nieobsługiwany (typowe dla USB)")
        default: detail.setKV("Stan SMART", x.smartStatus)
        }
        detail.setKV("Temperatura", x.temperatureC.map { Fmt.temp($0) } ?? "—")
        detail.setKV("Czas pracy", x.powerOnHours.map { h in h > 48 ? "\(h) h (\(h / 24) " + L("dni") + ")" : "\(h) h" } ?? "—")
        detail.setKV("Cykle zasilania", x.powerCycles.map { "\($0)" } ?? "—")
        detail.setKV("Zużycie komórek", x.percentageUsed.map { "\($0)%" } ?? "—")
        detail.setKV("Zapas bloków", x.availableSpare.map { "\($0)%" } ?? "—")
        detail.setKV("Nagłe wyłączenia", x.unsafeShutdowns.map { "\($0)" } ?? "—")
        detail.setKV("Błędy nośnika", x.mediaErrors.map { "\($0)" } ?? "—")
        detail.setKV("Odczytano (SMART)", x.dataRead.map { Fmt.bytes($0) } ?? "—")
        detail.setKV("Zapisano (SMART)", x.dataWritten.map { Fmt.bytes($0) } ?? "—")
    }

    private func show(_ i: Int) {
        container.subviews.forEach { $0.removeFromSuperview() }
        details[i].pin(to: container)
    }

    private func w(_ v: Double, _ available: Bool = true) -> String { available ? Fmt.watts(v) : "—" }

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
        // niewidoczna strona nie odrysowuje się – to był główny koszt CPU
        guard let s = n.object as? Snapshot, view.window != nil, !view.isHiddenOrHasHiddenAncestor else { return }
        lastSnapshot = s
        let pw = s.power
        cells[0].graph.push([s.cpu.total, s.cpu.system])
        cells[0].line1.update(Fmt.percent(s.cpu.total), flash: false)
        cells[0].line2.update("\(hw.ncpu) " + L("procesorów logicznych"), flash: false)
        cells[1].graph.maxValue = Double(max(1, s.mem.total)); cells[1].graph.push(Double(s.mem.used))
        cells[1].line1.update("\(Fmt.bytes(s.mem.used)) / \(Fmt.bytes(s.mem.total, precision: 0))", flash: false)
        cells[1].line2.update(Fmt.percent(s.mem.total > 0 ? 100 * Double(s.mem.used) / Double(s.mem.total) : 0), flash: false)
        cells[2].graph.push(s.gpuUtil ?? 0)
        cells[2].line1.update("\(hw.gpuName) · \(hw.gpuCores) " + L("rdzeni"), flash: false); cells[2].line2.update(s.gpuUtil.map { Fmt.percent($0) } ?? L("—"), flash: false)
        cells[3].graph.push(pw.available ? pw.aneWatts : 0)
        cells[3].line1.update(hw.aneCores > 0 ? "Apple Neural Engine · \(hw.aneCores) " + L("rdzeni") : "Apple Neural Engine", flash: false)
        cells[3].line2.update(pw.available ? Fmt.watts(pw.aneWatts, precision: 2) : L("0,0% zasilanych bloków"), flash: false)
        memPagingGraph.push([s.rates.pageIn, s.rates.pageOut])
        syncDisks(s.disks, generation: s.disksGeneration)
        cells[4].graph.push([s.disk.readRate, s.disk.writeRate])
        cells[4].line1.update("\(s.disk.diskCount) " + L("dysków fizycznych") + " · R \(Fmt.rate(s.disk.readRate))  W \(Fmt.rate(s.disk.writeRate))", flash: false)
        cells[4].line2.update(L("Śr. czas odpowiedzi") + " " + String(format: "%.1f ms", s.disk.avgResponseMs), flash: false)
        syncInterfaces(s.interfaces, generation: s.interfacesGeneration)
        cells[5].graph.push([s.net.rxRate, s.net.txRate])
        cells[5].line1.update(L("Podsumowanie wszystkich interfejsów"), flash: false); cells[5].line2.update("N: \(Fmt.rate(s.net.txRate))  O: \(Fmt.rate(s.net.rxRate))", flash: false)
        cells[6].graph.push(s.sysWatts ?? 0)
        cells[6].line1.update(L("Termika") + " \(s.thermalText) · " + ((s.battery?.onAC ?? true) ? L("zasilanie sieciowe") : L("bateria")), flash: false)
        cells[6].line2.update(s.sysWatts.map { Fmt.watts($0) } ?? L("—"), flash: false)
        if let b = s.battery, b.present {
            cells[8].graph.push(Double(b.percent))
            cells[8].line1.update("\(b.percent)% · " + (b.charging ? L("ładowanie") : (b.onAC ? L("zasilanie sieciowe") : L("na baterii"))), flash: false)
            let mins = b.charging ? b.timeToFullMin : b.timeToEmptyMin
            cells[8].line2.update(mins > 0 ? "\(mins / 60) h \(mins % 60) min" : Fmt.watts(b.watts, precision: 1), flash: false)
        } else {
            cells[8].line1.update(L("brak baterii"), flash: false)
        }
        cells[7].graph.push(s.hotspot ?? 0)
        cells[7].line1.update(L("Presja termiczna") + " \(s.thermalText)", flash: false); cells[7].line2.update(s.hotspot.map { Fmt.temp($0) } ?? L("—"), flash: false)

        // historia dużych wykresów
        cpuOverall.push([s.cpu.total, s.cpu.system])
        for (i, g) in coreGraphs.enumerated() { g.push([i < s.cpu.perCore.count ? s.cpu.perCore[i] : 0, i < s.cpu.perCoreSystem.count ? s.cpu.perCoreSystem[i] : 0]) }
        memGraph.push(Double(s.mem.used))
        if gpuMode.selectedSegment == 0 { gpuGraph.push([s.gpuUtil ?? 0, 0]) } else { gpuGraph.push([max(0, s.gpu.renderer), max(0, s.gpu.tiler)]) }
        gpuMemGraph.push(Double(s.gpu.memUsed))
        npuGraph.push(pw.available ? pw.aneWatts : 0)
        diskActive.push(s.disk.activeFraction * 100)
        diskRate.push([s.disk.readRate, s.disk.writeRate])
        netGraph.push([s.net.rxRate, s.net.txRate])
        energyGraph.push(s.sysWatts ?? 0)
        thermGraph.push(s.hotspot ?? 0)
        if view.window != nil { updateDetails(s) }
    }

    private func updateDetails(_ s: Snapshot) {
        let pw = s.power
        let cpu = details[0]
        cpu.bar.value = s.cpu.total / 100
        cpu.pct.update(flash: false, Fmt.percent(s.cpu.total))
        cpu.set("Wykorzystanie", Fmt.percent(s.cpu.total)); cpu.set("Procesy", "\(s.processes.count)"); cpu.set("Wątki", "\(s.totalThreads)")
        if let f = s.freq, f.pFreqMHz > 0 || f.eFreqMHz > 0 {
            cpu.set("Taktowanie", "P " + Fmt.frequencyMHz(f.pFreqMHz) + " · E " + Fmt.frequencyMHz(f.eFreqMHz))
            cpu.setKV("Regulator częstotliwości", "powermetrics (pomocnik)")
        } else { cpu.set("Taktowanie", "Zarządzane przez Apple") }
        cpu.set("Czas pracy", Fmt.duration(s.uptime))
        cpu.set("Użytkownik", Fmt.percent(s.cpu.user)); cpu.set("System (jądro)", Fmt.percent(s.cpu.system))
        cpu.set("Bezczynność", Fmt.percent(s.cpu.idle))
        cpu.set("Przełączenia kontekstu/s", Fmt.number(UInt64(max(0, s.rates.contextSwitches))))
        cpu.set("Błędy stron/s", Fmt.number(UInt64(max(0, s.rates.faults))))
        // średnie obciążenie klastrów wydajnościowego i energooszczędnego
        let eCount = max(0, hw.effCores), pStart = eCount
        let eAvg = eCount > 0 ? s.cpu.perCore.prefix(eCount).reduce(0, +) / Double(eCount) : 0
        let pCount = max(0, s.cpu.perCore.count - pStart)
        let pAvg = pCount > 0 ? s.cpu.perCore.dropFirst(pStart).reduce(0, +) / Double(pCount) : 0
        cpu.set("Rdzenie P", pCount > 0 ? "\(Fmt.percent(pAvg)) · \(pCount) rdz." : "—")
        cpu.set("Rdzenie E", eCount > 0 ? "\(Fmt.percent(eAvg)) · \(eCount) rdz." : "—")
        cpu.setKV("Obciążenie 1 / 5 / 15 min", String(format: "%.2f / %.2f / %.2f", s.loadAvg[0], s.loadAvg[1], s.loadAvg[2]))
        cpu.setKV("Presja termiczna", s.thermalText)
        cpu.setKV("Moc CPU", pw.available ? Fmt.watts(pw.cpuWatts, precision: 2) : "—")
        cpu.setKV("Temperatura rdzeni", s.cpuTemp.map { Fmt.temp($0) } ?? "—")
        cpu.setKV("Architektura", hw.arch)
        cpu.setKV("Jądro", hw.kernel)

        let mem = details[1]
        let frac = s.mem.total > 0 ? Double(s.mem.used) / Double(s.mem.total) : 0
        mem.bar.value = frac
        mem.pct.update(flash: false, Fmt.percent(frac * 100))
        let md = Monitor.shared.memoryDescription
        mem.subtitle.stringValue = Fmt.bytes(s.mem.total, precision: 0) + (md.isEmpty ? "" : " " + md)
        mem.set("W użyciu", Fmt.bytes(s.mem.used)); mem.set("Dostępne", Fmt.bytes(s.mem.total - min(s.mem.total, s.mem.used)))
        mem.set("Zadeklarowane", Fmt.bytes(s.mem.used + s.mem.swapUsed)); mem.set("Cache", Fmt.bytes(s.mem.cached))
        mem.set("Swap użyty", Fmt.bytes(s.mem.swapUsed)); mem.set("Swap dostępny", Fmt.bytes(s.mem.swapTotal - min(s.mem.swapTotal, s.mem.swapUsed)))
        mem.set("Skompresowane", Fmt.bytes(s.mem.compressed)); mem.set("Zablokowane (wired)", Fmt.bytes(s.mem.wired))
        mem.set("Pamięć aplikacji", Fmt.bytes(s.mem.app)); mem.set("Swap łącznie", Fmt.bytes(s.mem.swapTotal))
        mem.set("Presja", s.memPressureText.prefix(1).uppercased() + s.memPressureText.dropFirst()); mem.set("Obciążenie presji", Fmt.percent(Double(100 - s.mem.freePercent), precision: 1))
        mem.set("Page ins", Fmt.number(s.mem.pageIns)); mem.set("Page outs", Fmt.number(s.mem.pageOuts))
        mem.set("Aktywna", Fmt.bytes(s.mem.active)); mem.set("Nieaktywna", Fmt.bytes(s.mem.inactive))
        mem.set("Spekulatywna", Fmt.bytes(s.mem.speculative)); mem.set("Usuwalna (purgeable)", Fmt.bytes(s.mem.purgeable))
        mem.set("Pliki w pamięci", Fmt.bytes(s.mem.external)); mem.set("Wolna", Fmt.bytes(s.mem.freeCount))
        mem.set("Page in/s", Fmt.number(UInt64(max(0, s.rates.pageIn)))); mem.set("Page out/s", Fmt.number(UInt64(max(0, s.rates.pageOut))))
        mem.set("Swap in/s", Fmt.number(UInt64(max(0, s.rates.swapIn)))); mem.set("Swap out/s", Fmt.number(UInt64(max(0, s.rates.swapOut))))
        mem.set("Kompresje/s", Fmt.number(UInt64(max(0, s.rates.compressions)))); mem.set("Dekompresje/s", Fmt.number(UInt64(max(0, s.rates.decompressions))))
        mem.set("Błędy stron/s", Fmt.number(UInt64(max(0, s.rates.faults)))); mem.set("Kopiuj przy zapisie/s", Fmt.number(UInt64(max(0, s.rates.cowFaults))))
        mem.set("Trafienia cache", s.rates.cacheHitRatio.map { Fmt.percent($0 * 100) } ?? "—")
        mem.set("Rozmiar strony", Fmt.bytes(s.mem.pageSize, precision: 0))
        // presja pamięci kolorowana jak czujniki
        mem.stats["Presja"]?.valueLabel.textColor = s.mem.pressureLevel >= 4 ? P.bad : (s.mem.pressureLevel >= 2 ? P.warn : P.good)

        let gpu = details[2]
        gpu.bar.value = (s.gpuUtil ?? 0) / 100
        gpu.pct.update(flash: false, s.gpuUtil.map { Fmt.percent($0) } ?? L("—"))
        gpu.set("Wykorzystanie", s.gpuUtil.map { Fmt.percent($0) } ?? "niedostępne")
        gpu.set("Pamięć", "\(Fmt.bytes(s.gpu.memUsed)) / \(Fmt.bytes(s.mem.total, precision: 0))")
        gpu.set("Temperatura", s.gpuTemp.map { Fmt.temp($0) } ?? "—")
        if let t = s.gpuTemp { gpu.stats["Temperatura"]?.valueLabel.textColor = ThermalScale.color(t, key: "Tg") }
        if let f = s.freq, f.gpuFreqMHz > 0 { gpu.subtitle.stringValue = "\(hw.gpuName) · \(hw.gpuCores) " + L("rdzeni") + " · \(Fmt.frequencyMHz(f.gpuFreqMHz)) · \(Fmt.watts(pw.gpuWatts, precision: 2))" }
        gpu.set("Renderer / Tiler", s.gpu.renderer >= 0 ? "\(Fmt.percent(s.gpu.renderer, precision: 0)) / \(Fmt.percent(s.gpu.tiler, precision: 0))" : "—")
        gpu.set("Taktowanie", (s.freq?.gpuFreqMHz ?? 0) > 0 ? Fmt.frequencyMHz(s.freq!.gpuFreqMHz) : "—")
        gpu.set("Moc", pw.available ? Fmt.watts(pw.gpuWatts, precision: 2) : "—")
        gpu.set("Rdzenie", "\(hw.gpuCores)")
        gpu.set("Zaalokowana", Fmt.bytes(s.gpu.memAlloc))
        // silnik wideo: IOReport podaje pobór mocy bloków AVE (enkoder) i VDEC (dekoder)
        let enc = s.power.encoderWatts, dec = s.power.decoderWatts
        mediaPeak = max(mediaPeak * 0.999, enc, dec, 0.05)
        gpu.set("Enkoder wideo", enc > 0.002 ? "\(Fmt.watts(enc, precision: 3)) · " + L("aktywny") : L("bezczynny"))
        gpu.set("Dekoder wideo", dec > 0.002 ? "\(Fmt.watts(dec, precision: 3)) · " + L("aktywny") : L("bezczynny"))
        gpu.stats["Enkoder wideo"]?.valueLabel.textColor = enc > 0.002 ? P.good : P.textDim
        gpu.stats["Dekoder wideo"]?.valueLabel.textColor = dec > 0.002 ? P.good : P.textDim
        gpu.set("Procesor obrazu (ISP)", s.power.ispWatts > 0.002 ? Fmt.watts(s.power.ispWatts, precision: 3) : L("bezczynny"))
        gpu.set("Wyświetlacz", s.power.displayWatts > 0.002 ? Fmt.watts(s.power.displayWatts, precision: 3) : "—")
        videoEnc.push(enc)
        videoDec.push(dec)
        applyGPUInfo(gpu)
        gpuMemLabel.update(flash: false, "\(Fmt.bytes(s.gpu.memUsed)) / \(Fmt.bytes(s.mem.total, precision: 0))")
        gpuMemLabel.textColor = P.textDim

        let npu = details[3]
        npu.bar.value = pw.available ? min(1, pw.aneWatts / 4) : 0
        npu.pct.update(flash: false, pw.available ? Fmt.watts(pw.aneWatts, precision: 2) : "0,0%")
        npu.set("Zasilane bloki", pw.available ? (pw.aneWatts > 0.01 ? L("aktywne") : "0,0%") : "0,0%")
        npu.set("Pobór mocy", pw.available ? Fmt.watts(pw.aneWatts, precision: 2) : "0,0 W")
        npu.set("Energia w oknie", pw.available ? String(format: "%.1f mJ", pw.aneWatts * Monitor.shared.interval * 1000) : "0,0 µJ")
        npu.set("Stan", pw.available ? "pomiar aktywny" : "niedostępny (brak uprawnień)")

        let disk = details[4]
        disk.subtitle.stringValue = L("Podsumowanie wszystkich dysków fizycznych") + " (\(s.disk.diskCount)) · " + L("pojedyncze dyski są niżej na liście")
        // pasek pokazuje transfer, bo „czas aktywności” z IOKit sumuje równoległe operacje i przy NVMe stale bije w 100%
        let diskTotal = s.disk.readRate + s.disk.writeRate
        diskScaleHistory.append(diskTotal); if diskScaleHistory.count > 120 { diskScaleHistory.removeFirst() }
        let diskScale = max(1_000_000, diskScaleHistory.max() ?? 1)
        disk.bar.value = min(1, s.disk.readRate / diskScale)
        disk.pct.update(flash: false, Fmt.rate(s.disk.readRate))
        disk.bar2.value = min(1, s.disk.writeRate / diskScale)
        disk.pct2.update(flash: false, Fmt.rate(s.disk.writeRate))
        disk.set("Odczyt", Fmt.rate(s.disk.readRate)); disk.set("Zapis", Fmt.rate(s.disk.writeRate))
        disk.set("Łącznie odczytano", Fmt.bytes(s.disk.readBytes)); disk.set("Łącznie zapisano", Fmt.bytes(s.disk.writeBytes))
        disk.set("Zajętość kolejek", Fmt.percent(s.disk.activeFraction * 100)); disk.set("Śr. czas odpowiedzi", String(format: "%.1f ms", s.disk.avgResponseMs))
        disk.set("Pojemność", Fmt.bytes(s.disk.capacityBytes)); disk.set("Typ", s.disk.diskCount > 1 ? "Mieszany" : "SSD")
        disk.set("Temperatura SSD", s.ssdTemp.map { Fmt.temp($0) } ?? "—")
        if let t = s.ssdTemp { disk.stats["Temperatura SSD"]?.valueLabel.textColor = ThermalScale.color(t, key: "TH") }

        let net = details[5]
        let total = s.net.rxRate + s.net.txRate
        netPeak = max(netPeak * 0.995, total, 1024)
        net.subtitle.stringValue = "\(Monitor.interfaces().count) " + L("interfejsów łącznie")
        net.bar.value = min(1, s.net.rxRate / netPeak)
        net.pct.update(flash: false, Fmt.rate(s.net.rxRate))
        net.bar2.value = min(1, s.net.txRate / netPeak)
        net.pct2.update(flash: false, Fmt.rate(s.net.txRate))
        net.set("Odbiór", Fmt.rate(s.net.rxRate)); net.set("Nadawanie", Fmt.rate(s.net.txRate))
        net.set("Łącznie odebrano", Fmt.bytes(s.net.rxBytes)); net.set("Łącznie wysłano", Fmt.bytes(s.net.txBytes))
        net.set("Pakiety / s", String(format: "↓ %.0f  ↑ %.0f", s.net.rxPacketRate, s.net.txPacketRate))
        updateNetworkKind(net)
        locationButton.isHidden = LocationAccess.shared.granted

        let en = details[6]
        en.subtitle.stringValue = L("Termika") + " \(s.thermalText) · " + (s.battery.map { $0.charging ? L("ładowanie") : ($0.onAC ? L("zasilanie sieciowe") : L("bateria")) } ?? L("zasilanie sieciowe"))
        en.bar.value = min(1, (s.sysWatts ?? 0) / 60)
        en.pct.update(flash: false, s.sysWatts.map { Fmt.watts($0) } ?? L("—"))
        energyTiles["CPU"]?.value.update(flash: false, w(pw.cpuWatts, pw.available)); energyTiles["GPU"]?.value.update(flash: false, w(pw.gpuWatts, pw.available))
        energyTiles["ANE"]?.value.update(flash: false, w(pw.aneWatts, pw.available)); energyTiles["DRAM"]?.value.update(flash: false, w(pw.dramWatts, pw.available))
        energyTiles["Moc pakietu SoC"]?.value.update(flash: false, s.sysWatts.map { Fmt.watts($0) } ?? L("—"))
        energyTiles["Stan termiczny"]?.value.update(flash: false, L("Termika") + " " + s.thermalText)
        if Date().timeIntervalSince(lastPmset) > 30 {
            lastPmset = Date()
            Shell.async("/usr/bin/pmset", ["-g"], timeout: 5) { [weak self] out in
                let low = out.split(separator: "\n").first { $0.contains("lowpowermode") }.map { $0.contains(" 1") } ?? false
                self?.powerMode = low ? "Niski pobór energii" : "Normalny"
                self?.energyTiles["Tryb zasilania"]?.value.update(flash: false, self?.powerMode ?? L("—"))
            }
        }
        energyTiles["Źródło zasilania"]?.value.update(flash: false, s.battery.map { $0.onAC ? L("Zasilanie sieciowe") : L("Bateria") } ?? L("Zasilanie sieciowe"))
        energyTiles["Bateria"]?.value.update(flash: false, s.battery.map { "\($0.percent)%" } ?? L("brak"))
        energyTiles["Cykle ładowania"]?.value.update(flash: false, s.battery.map { $0.cycleCount >= 0 ? "\($0.cycleCount)" : L("—") } ?? L("—"))
        if let b = s.battery, b.designCapacity > 0, b.nominalCapacity > 0 {
            energyTiles["Kondycja baterii"]?.value.update(flash: false, String(format: "%.0f%% (%@)", 100.0 * Double(b.nominalCapacity) / Double(b.designCapacity), b.health.isEmpty ? L("—") : b.health))
        } else { energyTiles["Kondycja baterii"]?.value.update(flash: false, L("—")) }
        energyTiles["Zasilacz (DC)"]?.value.update(flash: false, s.dcInWatts.map { Fmt.watts($0) } ?? L("—"))
        let top = s.processes.filter { $0.accessible }.sorted { $0.cpuPercent > $1.cpuPercent }.prefix(barRows.count)
        let maxCpu = top.first?.cpuPercent ?? 1
        for (i, r) in barRows.enumerated() {
            if i < top.count {
                let p = top[i]
                r.isHidden = false
                r.name.stringValue = p.name
                r.fraction = maxCpu > 0 ? p.cpuPercent / maxCpu : 0
                r.value.update(String(format: "%.0f", 100 * (maxCpu > 0 ? p.cpuPercent / maxCpu : 0)), flash: false)
                r.color = i == 0 ? P.bad : (i < 3 ? P.warn : P.energy)
            } else { r.isHidden = true }
        }

        updateBattery(s)
        let th = details[7]
        th.subtitle.stringValue = L("Presja termiczna") + ": \(s.thermalText)"
        th.bar.value = ThermalScale.level(s.hotspot ?? 0, key: "Tp")
        th.pct.update(flash: false, s.hotspot.map { Fmt.temp($0) } ?? L("—"))
        if let hs = s.hotspot { th.pct.textColor = ThermalScale.color(hs, key: "Tp") }
        thermTiles["Presja"]?.value.update(flash: false, s.thermalText.prefix(1).uppercased() + s.thermalText.dropFirst())
        thermTiles["Hotspot"]?.value.update(flash: false, s.hotspot.map { Fmt.temp($0) } ?? L("—"))
        if let hs = s.hotspot { thermTiles["Hotspot"]?.value.textColor = ThermalScale.color(hs, key: "Tp") }
        // karty grup czujników
        var groups: [String: [Double]] = [:]
        for t in s.temps { groups[groupName(t.name), default: []].append(t.value) }
        let order = Self.sensorGroups.map { $0.1 } + ["Pozostałe"]
        var changed = false
        for g in order where groups[g] != nil && sensorCards[g] == nil {
            let card = SensorCard(g, accent: .thermal)
            card.tempKey = Self.sensorGroups.first { $0.1 == g }?.0
            sensorCards[g] = card
            changed = true
        }
        if changed {
            sensorsGrid.arrangedSubviews.forEach { $0.removeFromSuperview() }
            let cards = order.compactMap { sensorCards[$0] }
            for chunk in stride(from: 0, to: cards.count, by: 2) {
                var rowViews: [NSView] = Array(cards[chunk..<min(chunk + 2, cards.count)])
                if rowViews.count < 2 { rowViews.append(spacer()) }
                let r = hstack(rowViews, spacing: 10, distribution: .fillEqually)
                sensorsGrid.addArrangedSubview(r)
                r.widthAnchor.constraint(equalTo: sensorsGrid.widthAnchor).isActive = true
            }
        }
        for (g, vals) in groups {
            guard let card = sensorCards[g], let mx = vals.max() else { continue }
            card.set(mx, text: Fmt.temp(mx) + " · \(vals.count) czujn.")
        }
    }

    // MARK: tabela
    func numberOfRows(in tableView: NSTableView) -> Int { order.count }
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { let r = ThemedRowView(); r.inset = 8; return r }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < order.count else { return nil }
        return cells[order[row]]
    }
    func tableViewSelectionDidChange(_ notification: Notification) {
        guard table.selectedRow >= 0, table.selectedRow < order.count else { return }
        show(order[table.selectedRow])
        if let s = lastSnapshot { updateDetails(s) }
    }
}

final class FlippedView: NSView { override var isFlipped: Bool { true } }
