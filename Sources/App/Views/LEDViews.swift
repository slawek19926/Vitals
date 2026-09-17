// LEDViews.swift - segmentowe paski LED (poziome i pionowe) z tanią poświatą (bez cieni CoreGraphics)
import AppKit

/// Wspólny zegar animacji dla pasków LED (30 fps)
final class LEDTicker {
    static let shared = LEDTicker()
    private var timer: Timer?
    private var views = NSHashTable<LEDBarView>.weakObjects()
    func register(_ v: LEDBarView) {
        views.add(v)
        if timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
                guard let self else { return }
                for v in self.views.allObjects { v.tick() }
            }
            timer?.tolerance = 0.005
        }
    }
}

final class LEDBarView: ThemedView {
    /// Wartość docelowa 0..1; wyświetlana wartość dąży do niej płynnie
    var value: Double = 0 {
        didSet {
            if !Prefs.shared.smoothGraphs { shown = value; drawnState = visualState(shown); needsDisplay = true }
            else if abs(value - shown) > 0.0005 { LEDTicker.shared.register(self) }
        }
    }
    private var shown: Double = 0
    private var drawnState: Int = -1
    /// Stan widoczny na ekranie: liczba zapalonych segmentów i zgrubny ułamek ostatniego
    private func visualState(_ v: Double) -> Int { Int((max(0, min(1, v)) * 400).rounded()) }
    fileprivate func tick() {
        guard window != nil, !isHiddenOrHasHiddenAncestor else { return }
        let d = value - shown
        if abs(d) < 0.002 {
            if shown != value { shown = value }
        } else {
            shown += d * 0.18   // ~0,4 s do celu przy 30 fps
        }
        // przerysowujemy tylko wtedy, gdy zmienia się to, co naprawdę widać
        let st = visualState(shown)
        guard st != drawnState else { return }
        drawnState = st
        needsDisplay = true
    }
    var accent: Subsystem = .cpu { didSet { needsDisplay = true } }
    var gradient = false
    var vertical = false
    var segmentThickness: CGFloat = 9
    var gap: CGFloat = 3
    var fixedColor: NSColor?

    override var intrinsicContentSize: NSSize { vertical ? NSSize(width: 40, height: NSView.noIntrinsicMetric) : NSSize(width: NSView.noIntrinsicMetric, height: 12) }

    /// Nowoczesny wygląd: jednolity zaokrąglony pasek postępu zamiast siatki segmentów
    private func drawModern(_ ctx: CGContext) {
        let value = CGFloat(min(1, max(0, shown)))
        let track = bounds.insetBy(dx: 0, dy: vertical ? 0 : max(0, (bounds.height - 8) / 2))
        let radius = min(6, (vertical ? track.width : track.height) / 2)
        P.border.alpha(P.isDark ? 0.35 : 0.5).setFill()
        NSBezierPath(roundedRect: track, xRadius: radius, yRadius: radius).fill()
        guard value > 0.001 else { return }
        let filled: NSRect = vertical
            ? NSRect(x: track.minX, y: track.minY, width: track.width, height: max(3, track.height * value))
            : NSRect(x: track.minX, y: track.minY, width: max(3, track.width * value), height: track.height)
        (fixedColor ?? segColor(value)).setFill()
        NSBezierPath(roundedRect: filled, xRadius: radius, yRadius: radius).fill()
    }

    private func segColor(_ t: CGFloat) -> NSColor {
        if let c = fixedColor { return c }
        if P.isPhosphor || !gradient { return P.accent(accent) }
        if t < 0.55 { return .mix(P.good, P.warn, t / 0.55) }
        return .mix(P.warn, P.bad, (t - 0.55) / 0.45)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        if Prefs.shared.modernUI { drawModern(ctx); return }
        let length = vertical ? bounds.height : bounds.width
        let n = max(1, Int((length + gap) / (segmentThickness + gap)))
        let exact = Double(n) * min(max(shown, 0), 1)
        let lit = Int(exact.rounded(.down))
        let frac = exact - Double(lit)   // ostatni segment gaśnie/zapala się płynnie
        let bloom = ThemeManager.shared.bloomFactor
        let boost = ThemeManager.shared.edrBoost
        let dimAlpha: CGFloat = P.isDark ? 0.16 : 0.22
        for i in 0..<n {
            let t = CGFloat(i) / CGFloat(max(1, n - 1))
            let base = segColor(t)
            let rect: CGRect = vertical
                ? CGRect(x: 0, y: CGFloat(i) * (segmentThickness + gap), width: bounds.width, height: segmentThickness)
                : CGRect(x: CGFloat(i) * (segmentThickness + gap), y: 0, width: segmentThickness, height: bounds.height)
            let level: CGFloat = i < lit ? 1 : (i == lit ? CGFloat(frac) : 0)
            if level > 0.02 {
                if bloom > 0.01 {
                    let spread = 2.5 * min(2.2, bloom)
                    ctx.setFillColor(base.alpha(min(0.5, 0.22 * level * bloom)).edr(boost))
                    ctx.addPath(CGPath(roundedRect: rect.insetBy(dx: -spread, dy: -spread), cornerWidth: 3, cornerHeight: 3, transform: nil))
                    ctx.fillPath()
                }
                ctx.setFillColor(base.alpha(dimAlpha + (1 - dimAlpha) * level).edr(level > 0.9 ? boost : 1))
            } else {
                ctx.setFillColor(base.alpha(dimAlpha).cachedCG)
            }
            ctx.addPath(CGPath(roundedRect: rect, cornerWidth: 1.5, cornerHeight: 1.5, transform: nil))
            ctx.fillPath()
        }
    }
}

/// Pionowy miernik z podpisem u góry i wartością u dołu
final class MeterView: NSStackView {
    let titleLabel: NSTextField
    let bar = LEDBarView()
    let valueLabel: NSTextField
    private let accentKind: Subsystem

    /// Podpowiedź pokazywana po najechaniu na cały miernik
    var tip: String? {
        didSet {
            toolTip = tip
            bar.toolTip = tip
            titleLabel.toolTip = tip
            valueLabel.toolTip = tip
        }
    }

    init(title: String, accent: Subsystem) {
        titleLabel = Label.make(title, size: 10, weight: .semibold)
        valueLabel = Label.make(L("—"), size: 11, weight: .medium, mono: true)
        accentKind = accent
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .centerX
        spacing = 4
        bar.vertical = true
        bar.accent = accent
        bar.segmentThickness = 6
        bar.gap = 3
        bar.translatesAutoresizingMaskIntoConstraints = false
        bar.widthAnchor.constraint(equalToConstant: 40).isActive = true
        addArrangedSubview(titleLabel)
        addArrangedSubview(bar)
        addArrangedSubview(valueLabel)
        applyColors()
        NotificationCenter.default.addObserver(forName: .themeChanged, object: nil, queue: .main) { [weak self] _ in self?.applyColors() }
    }
    required init?(coder: NSCoder) { fatalError() }

    private func applyColors() {
        let c = P.accent(accentKind)
        titleLabel.textColor = c
        valueLabel.textColor = c
    }

    func set(_ fraction: Double, text: String) {
        bar.value = fraction
        valueLabel.stringValue = text
    }
}
