// TileStat.swift - kafelek statystyki z ikoną (jak w Energy / Thermals TMOG) oraz karta czujnika z mini wykresem
import AppKit

final class TileStat: CardView {
    let icon: NSImageView
    let caption: NSTextField
    let value = FlashLabel(L("—"), size: 14, weight: .semibold)
    private let iconAccent: Subsystem?

    init(_ caption: String, icon: String, accent: Subsystem? = nil) {
        self.caption = Label.make(caption, size: 10.5, dim: true)
        self.icon = symbol(icon, size: 18, weight: .regular, color: accent.map { P.accent($0) } ?? P.textDim)
        iconAccent = accent
        super.init(accent: nil)
        layer?.cornerRadius = 8
        borderAlpha = 0.0
        let texts = vstack([self.caption, value], spacing: 1)
        self.icon.size(width: 30)
        let h = hstack([self.icon, texts], spacing: 10)
        h.pin(to: self, insets: NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12))
        applyTheme()
    }
    required init?(coder: NSCoder) { fatalError() }

    override func applyTheme() {
        super.applyTheme()
        layer?.backgroundColor = P.hover.blended(withFraction: 0.5, of: P.panelBg)?.cgColor ?? P.panelBg.cgColor
        layer?.borderColor = P.border.alpha(0.5).cgColor
        icon.contentTintColor = iconAccent.map { P.accent($0) } ?? P.textDim
        caption.textColor = P.textDim
        value.textColor = P.text
    }
}

/// Karta czujnika: tytuł, wartość po prawej, mini wykres
final class SensorCard: CardView {
    let titleLabel: NSTextField
    let valueLabel = FlashLabel(L("—"), size: 11.5, weight: .semibold)
    let graph: GraphView
    /// gdy ustawione, wartość i linia wykresu przyjmują kolor według progów temperatury
    var tempKey: String?
    private let sub: Subsystem

    init(_ title: String, accent: Subsystem, maxValue: Double = 110) {
        titleLabel = Label.make(L(title), size: 12, weight: .semibold)
        graph = GraphView(series: 1, history: 90, accents: [accent])
        sub = accent
        super.init(accent: accent)
        graph.compact = true
        graph.maxValue = maxValue
        graph.borderAccent = accent
        graph.timeSpan = Double(Prefs.shared.graphSpanSeconds)   // te same próbki co na innych stronach
        graph.heightAnchor.constraint(equalToConstant: 54).isActive = true
        titleLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        valueLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        valueLabel.alignment = .right
        let head = hstack([titleLabel, spacer(), valueLabel])
        let v = vstack([head, graph], spacing: 6)
        head.widthAnchor.constraint(equalTo: v.widthAnchor).isActive = true
        graph.widthAnchor.constraint(equalTo: v.widthAnchor).isActive = true
        v.pin(to: self, insets: NSEdgeInsets(top: 8, left: 10, bottom: 10, right: 10))
        applyTheme()
    }
    required init?(coder: NSCoder) { fatalError() }

    override func applyTheme() {
        super.applyTheme()
        titleLabel.textColor = P.text
        valueLabel.textColor = P.accent(sub)
    }

    func set(_ v: Double, text: String) {
        graph.push(v)
        valueLabel.update(text, flash: false)
        if let key = tempKey {
            let c = ThermalScale.color(v, key: key)
            valueLabel.textColor = c
            graph.colorProvider = { _, _ in c }
            graph.applyTheme()
        }
    }
}

/// Wiersz z paskiem poziomym (procesy o najwyższym zapotrzebowaniu na energię)
final class BarRow: NSView {
    let name = Label.make("", size: 12)
    let value = FlashLabel("", size: 12, mono: true)
    private let track = CALayer(), fill = CALayer()
    var fraction: Double = 0 { didSet { needsLayout = true } }
    var color: NSColor = .red { didSet { fill.backgroundColor = color.cgColor } }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.addSublayer(track); layer?.addSublayer(fill)
        track.cornerRadius = 3; fill.cornerRadius = 3
        addSubview(name); addSubview(value)
        name.translatesAutoresizingMaskIntoConstraints = false
        value.translatesAutoresizingMaskIntoConstraints = false
        value.alignment = .right
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 22),
            name.leadingAnchor.constraint(equalTo: leadingAnchor), name.centerYAnchor.constraint(equalTo: centerYAnchor),
            name.widthAnchor.constraint(equalToConstant: 220),
            value.trailingAnchor.constraint(equalTo: trailingAnchor), value.centerYAnchor.constraint(equalTo: centerYAnchor),
            value.widthAnchor.constraint(equalToConstant: 60),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let x0: CGFloat = 230, x1 = bounds.width - 70
        let w = max(0, x1 - x0)
        track.frame = CGRect(x: x0, y: bounds.midY - 3, width: w, height: 6)
        track.backgroundColor = P.border.alpha(0.5).cgColor
        CATransaction.begin(); CATransaction.setAnimationDuration(0.4)
        fill.frame = CGRect(x: x0, y: bounds.midY - 3, width: w * CGFloat(min(1, max(0, fraction))), height: 6)
        CATransaction.commit()
        name.textColor = P.text
    }
}
