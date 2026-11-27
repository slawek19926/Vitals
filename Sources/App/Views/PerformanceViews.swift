// PerformanceViews.swift - współdzielone komponenty widoku „Wydajność” (Sub, SubsystemCell, DetailView)
import AppKit

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
    private let observers = ObserverBag()

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
        observers.observe(.themeChanged) { [weak self] _ in self?.applyTheme() }
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
    private let observers = ObserverBag()

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
        note.lineBreakMode = .byWordWrapping; note.maximumNumberOfLines = 0
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
            observers.observe(n) { [weak self] _ in self?.applyTheme() }
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
