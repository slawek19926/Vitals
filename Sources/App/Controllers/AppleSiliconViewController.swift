// AppleSiliconViewController.swift - klastry rdzeni P/E z wykresami, GPU, Neural Engine, silnik multimedialny
import AppKit

final class ClusterCard: CardView {
    let titleLabel: NSTextField
    let subtitle = Label.make("", size: 11, dim: true)
    let pct = FlashLabel(L("—"), size: 16, weight: .semibold)
    let graph: GraphView
    var coreGraphs: [GraphView] = []
    let tempLabel = FlashLabel("", size: 11)
    private let sub: Subsystem

    init(title: String, icon: String, accent: Subsystem, cores: [Int]) {
        titleLabel = Label.make(title, size: 14, weight: .semibold)
        graph = GraphView(series: 2, history: 120, accents: [accent, accent])
        sub = accent
        super.init(accent: accent)
        graph.colorProvider = { i, p in i == 0 ? p.cpu : p.cpuKernel }
        graph.borderAccent = accent
        graph.heightAnchor.constraint(equalToConstant: 150).isActive = true
        let icon = symbol(icon, size: 16, color: P.accent(accent))
        let head = hstack([icon, vstack([titleLabel, subtitle], spacing: 1), spacer(), pct], spacing: 8)
        let cap = hstack([Label.make(L("% wykorzystania (zielony) · jądro (czerwony)"), size: 10.5, dim: true), spacer(), tempLabel])
        let cap2 = Label.make(L("% wykorzystania na rdzeń"), size: 10.5, dim: true)
        var rows: [NSView] = []
        var row: [NSView] = []
        let perRow = cores.count > 6 ? 6 : max(2, cores.count)
        for c in cores {
            let g = GraphView(series: 2, history: 60, accents: [accent, accent])
            g.compact = true; g.title = "CPU \(c)"; g.borderAccent = accent
            g.colorProvider = { i, p in i == 0 ? p.cpu : p.cpuKernel }
            g.heightAnchor.constraint(equalToConstant: 64).isActive = true
            coreGraphs.append(g); row.append(g)
            if row.count == perRow { rows.append(hstack(row, spacing: 6, distribution: .fillEqually)); row = [] }
        }
        if !row.isEmpty { while row.count < perRow { row.append(spacer()) }; rows.append(hstack(row, spacing: 6, distribution: .fillEqually)) }
        let v = vstack([head, cap, graph, cap2] + rows, spacing: 6)
        for x in [head, cap, graph] + rows { x.widthAnchor.constraint(equalTo: v.widthAnchor).isActive = true }
        v.pin(to: self, insets: NSEdgeInsets(top: 10, left: 12, bottom: 12, right: 12))
        applyTheme()
    }
    required init?(coder: NSCoder) { fatalError() }
    override func applyTheme() { super.applyTheme(); pct.textColor = P.accent(sub); titleLabel.textColor = P.text; tempLabel.textColor = P.textDim }
}

final class AppleSiliconViewController: NSViewController, PageRefreshable {
    private let hw = Monitor.shared.hardware
    private var pCard: ClusterCard!, eCard: ClusterCard!
    private var pCores: [Int] = [], eCores: [Int] = []
    private let gpuGraph = GraphView(series: 3, history: 120, accents: [.gpu, .gpu, .gpu])
    private let gpuPct = FlashLabel(L("—"), size: 16, weight: .semibold)
    private let aneValue = FlashLabel(L("—"), size: 14, weight: .semibold)
    private let mediaNote = Label.make("", size: 10.5, dim: true)
    private var infoLabels: [String: FlashLabel] = [:]

    override func loadView() {
        view = NSView()
        let title = PageTitleView(L("Apple Silicon"))
        // Na układach Apple rdzenie energooszczędne mają pierwsze numery logiczne
        eCores = Array(0..<hw.effCores)
        pCores = Array(hw.effCores..<hw.ncpu)

        let chip = NSTextField(labelWithString: "")
        chip.attributedStringValue = NSAttributedString(string: hw.cpuBrand, attributes: [.font: Fonts.title(24), .kern: 1.0, .foregroundColor: P.text])
        let chipSub = Label.make("\(hw.perfCores) " + L("rdzeni wydajnościowych") + " · \(hw.effCores) " + L("rdzeni energooszczędnych") + " · \(hw.gpuCores) rdzeni GPU · \(hw.aneCores) rdzeni Neural Engine (\(hw.aneArch)) · \(Fmt.bytes(hw.memTotal, precision: 0)) pamięci zunifikowanej", size: 11.5, dim: true)

        pCard = ClusterCard(title: "Rdzenie wydajnościowe", icon: "hare", accent: .cpu, cores: pCores)
        pCard.subtitle.stringValue = "\(pCores.count) " + L("rdzeni") + " · L2 \(Fmt.bytes(hw.l2Cache, precision: 0)) · " + L("klaster P")
        eCard = ClusterCard(title: "Rdzenie energooszczędne", icon: "tortoise", accent: .gpu, cores: eCores)
        eCard.subtitle.stringValue = "\(eCores.count) " + L("rdzeni") + " · L2 \(Fmt.bytes(hw.l2CacheE, precision: 0)) · " + L("klaster E")
        let clusters = hstack([pCard, eCard], spacing: 12, alignment: .top, distribution: .fillEqually)

        // GPU
        let gpuCard = SectionCard(title: "GPU · \(hw.gpuName) · \(hw.gpuCores) " + L("rdzeni"), icon: "display", accent: .gpu)
        gpuCard.trailing.addArrangedSubview(gpuPct)
        gpuGraph.colorProvider = { i, p in [p.cpu, p.gpu, p.memory][i] }
        gpuGraph.borderAccent = .gpu
        gpuGraph.topLeft = L("Urządzenie (zielony) · Renderer (niebieski) · Tiler (fiolet)")
        gpuGraph.showPercentAxis = true
        gpuGraph.heightAnchor.constraint(equalToConstant: 160).isActive = true
        gpuCard.add(gpuGraph)

        // ANE + Media engine
        let aneCard = SectionCard(title: "Neural Engine", icon: "brain", accent: .npu)
        aneCard.trailing.addArrangedSubview(aneValue)
        for (k, v) in [("Rdzenie", "\(hw.aneCores)"), ("Architektura", hw.aneArch), (L("Bloki sprzętowe"), "1"), (L("Stan"), L("gotowy · power gated"))] {
            let row = KeyValueRow(k, v, keyWidth: 140); aneCard.add(row)
        }
        let mediaCard = SectionCard(title: "Silnik multimedialny (Media Engine)", icon: "film", accent: .energy)
        let dec = MediaEngine.hardwareDecoders()
        let decYes = dec.filter { $0.1 }.map { $0.0 }, decNo = dec.filter { !$0.1 }.map { $0.0 }
        mediaCard.add(KeyValueRow("Dekodowanie sprzętowe", decYes.isEmpty ? "brak" : decYes.joined(separator: ", "), keyWidth: 170))
        if !decNo.isEmpty { mediaCard.add(KeyValueRow("Bez wsparcia sprzętowego", decNo.joined(separator: ", "), keyWidth: 170)) }
        let enc = MediaEngine.hardwareEncoders()
        mediaCard.add(KeyValueRow("Kodery sprzętowe", enc.isEmpty ? "brak" : enc.joined(separator: ", "), keyWidth: 170))
        mediaCard.add(KeyValueRow("Silniki wideo", hw.cpuBrand.contains("Max") || hw.cpuBrand.contains("Ultra") ? L("wiele (Pro/Max/Ultra)") : L("1 silnik kodowania + 1 dekodowania"), keyWidth: 170))
        mediaNote.stringValue = L("Lista kodeków pochodzi z VideoToolbox. Bieżąca aktywność silnika multimedialnego nie ma publicznego API w macOS 26/27 (liczniki IOReport są zamrożone także dla roota), dlatego nie jest wyświetlana.")
        mediaNote.lineBreakMode = .byWordWrapping; mediaNote.maximumNumberOfLines = 2
        mediaCard.add(mediaNote)
        let bottom = hstack([aneCard, mediaCard], spacing: 12, alignment: .top, distribution: .fillEqually)

        let column = vstack([chip, chipSub, clusters, gpuCard, bottom], spacing: 12)
        column.setCustomSpacing(2, after: chip)
        for c in [clusters, gpuCard, bottom] { c.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true }
        let scroll = NSScrollView(); scroll.drawsBackground = false; scroll.hasVerticalScroller = true; scroll.scrollerStyle = .overlay; scroll.autohidesScrollers = true
        let doc = FlippedView(); scroll.documentView = doc
        column.pin(to: doc, insets: NSEdgeInsets(top: 4, left: 0, bottom: 20, right: 0))
        doc.translatesAutoresizingMaskIntoConstraints = false
        doc.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor).isActive = true
        let root = vstack([title, scroll], spacing: 4)
        for v in [title, scroll] { v.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true }
        scroll.setContentHuggingPriority(.init(1), for: .vertical)
        root.pin(to: view, insets: NSEdgeInsets(top: 2, left: 18, bottom: 0, right: 18))
        NotificationCenter.default.addObserver(self, selector: #selector(snapshot(_:)), name: .snapshotUpdated, object: nil)
        let brand = hw.cpuBrand
        NotificationCenter.default.addObserver(forName: .themeChanged, object: nil, queue: .main) { _ in
            chip.attributedStringValue = NSAttributedString(string: brand, attributes: [.font: Fonts.title(24), .kern: 1.0, .foregroundColor: P.text])
        }
    }

    func pageDidAppear() {}

    override func viewDidAppear() {
        super.viewDidAppear()
        GraphStyle.applyTimeSpan(view)
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
        func avg(_ idx: [Int], _ arr: [Double]) -> Double { let v = idx.compactMap { $0 < arr.count ? arr[$0] : nil }; return v.isEmpty ? 0 : v.reduce(0, +) / Double(v.count) }
        let pU = avg(pCores, s.cpu.perCore), pS = avg(pCores, s.cpu.perCoreSystem)
        let eU = avg(eCores, s.cpu.perCore), eS = avg(eCores, s.cpu.perCoreSystem)
        pCard.graph.push([pU, pS]); eCard.graph.push([eU, eS])
        for (i, c) in pCores.enumerated() { pCard.coreGraphs[i].push([c < s.cpu.perCore.count ? s.cpu.perCore[c] : 0, c < s.cpu.perCoreSystem.count ? s.cpu.perCoreSystem[c] : 0]) }
        for (i, c) in eCores.enumerated() { eCard.coreGraphs[i].push([c < s.cpu.perCore.count ? s.cpu.perCore[c] : 0, c < s.cpu.perCoreSystem.count ? s.cpu.perCoreSystem[c] : 0]) }
        gpuGraph.push([s.gpuUtil ?? 0, max(0, s.gpu.renderer), max(0, s.gpu.tiler)])
        guard view.window != nil else { return }
        pCard.pct.update(Fmt.percent(pU), flash: false); eCard.pct.update(Fmt.percent(eU), flash: false)
        // taktowania z powermetrics (jeśli pomocnik działa)
        let pClock = (s.freq?.pFreqMHz ?? 0) > 0 ? " · " + Fmt.frequencyMHz(s.freq!.pFreqMHz) : ""
        let eClock = (s.freq?.eFreqMHz ?? 0) > 0 ? " · " + Fmt.frequencyMHz(s.freq!.eFreqMHz) : ""
        pCard.tempLabel.update((s.pCoreTemp.map { L("maks.") + " " + Fmt.temp($0) } ?? "") + pClock, flash: false)
        eCard.tempLabel.update((s.eCoreTemp.map { L("maks.") + " " + Fmt.temp($0) } ?? "") + eClock, flash: false)
        gpuPct.update(s.gpuUtil.map { Fmt.percent($0) } ?? L("—")); gpuPct.textColor = P.gpu
        aneValue.update(s.power.available ? Fmt.watts(s.power.aneWatts, precision: 2) : L("0,0% zasilanych bloków")); aneValue.textColor = P.npu
    }
}
