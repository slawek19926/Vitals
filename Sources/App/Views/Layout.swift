// Layout.swift - drobne pomocniki Auto Layout
import AppKit

extension NSView {
    @discardableResult
    func pin(to parent: NSView, insets: NSEdgeInsets = NSEdgeInsets()) -> Self {
        translatesAutoresizingMaskIntoConstraints = false
        if superview == nil { parent.addSubview(self) }
        NSLayoutConstraint.activate([
            leadingAnchor.constraint(equalTo: parent.leadingAnchor, constant: insets.left),
            trailingAnchor.constraint(equalTo: parent.trailingAnchor, constant: -insets.right),
            topAnchor.constraint(equalTo: parent.topAnchor, constant: insets.top),
            bottomAnchor.constraint(equalTo: parent.bottomAnchor, constant: -insets.bottom),
        ])
        return self
    }
    /// Układa zawartość komórki tabeli: pełna szerokość, a w pionie na środku,
    /// bo NSTextField rysuje tekst przy górnej krawędzi, gdy dostanie za wysoką ramkę
    @discardableResult
    func pinCentered(to parent: NSView, leading: CGFloat = 0, trailing: CGFloat = 0) -> Self {
        translatesAutoresizingMaskIntoConstraints = false
        if superview == nil { parent.addSubview(self) }
        NSLayoutConstraint.activate([
            leadingAnchor.constraint(equalTo: parent.leadingAnchor, constant: leading),
            trailingAnchor.constraint(equalTo: parent.trailingAnchor, constant: -trailing),
            centerYAnchor.constraint(equalTo: parent.centerYAnchor),
        ])
        return self
    }

    @discardableResult
    func size(width: CGFloat? = nil, height: CGFloat? = nil) -> Self {
        translatesAutoresizingMaskIntoConstraints = false
        if let w = width { widthAnchor.constraint(equalToConstant: w).isActive = true }
        if let h = height { heightAnchor.constraint(equalToConstant: h).isActive = true }
        return self
    }
}

func hstack(_ views: [NSView], spacing: CGFloat = 8, alignment: NSLayoutConstraint.Attribute = .centerY, distribution: NSStackView.Distribution = .fill) -> NSStackView {
    let s = NSStackView(views: views)
    s.orientation = .horizontal; s.spacing = spacing; s.alignment = alignment; s.distribution = distribution
    return s
}
func vstack(_ views: [NSView], spacing: CGFloat = 8, alignment: NSLayoutConstraint.Attribute = .leading, distribution: NSStackView.Distribution = .fill) -> NSStackView {
    let s = NSStackView(views: views)
    s.orientation = .vertical; s.spacing = spacing; s.alignment = alignment; s.distribution = distribution
    return s
}
func spacer() -> NSView { let v = NSView(); v.setContentHuggingPriority(.init(1), for: .horizontal); v.setContentHuggingPriority(.init(1), for: .vertical); return v }

/// Karta z nagłówkiem, w której układamy treść pionowo
final class SectionCard: CardView {
    let stack: NSStackView
    let titleLabel: NSTextField
    let iconView: NSImageView
    let trailing = NSStackView()

    init(title: String, icon: String, accent: Subsystem? = nil, insets: CGFloat = 12) {
        stack = vstack([], spacing: 8)
        titleLabel = Label.make(L(title), size: 14, weight: .regular)
        iconView = symbol(icon, size: 13, weight: .medium, color: accent.map { P.accent($0) })
        super.init(accent: accent)
        let header = hstack([iconView, titleLabel, spacer(), trailing], spacing: 10)
        trailing.orientation = .horizontal
        trailing.spacing = 8
        stack.addArrangedSubview(header)
        header.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        stack.pin(to: self, insets: NSEdgeInsets(top: insets - 2, left: insets, bottom: insets, right: insets))
        applyTheme()
    }
    required init?(coder: NSCoder) { fatalError() }

    override func applyTheme() {
        super.applyTheme()
        titleLabel.textColor = P.text
        iconView.contentTintColor = accent.map { P.accent($0) } ?? P.textDim
    }

    func add(_ v: NSView, fill: Bool = true) {
        stack.addArrangedSubview(v)
        if fill { v.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
    }
}

/// Nagłówek „wyświetlacz LED” (CPU OVERVIEW ·· 26%) z Podsumowania TMOG
final class DisplayHeader: ThemedView {
    let left = NSTextField(labelWithString: "")
    let right = NSTextField(labelWithString: "")
    var accent: Subsystem?
    private var stack: NSStackView!

    /// Dokłada element po prawej stronie nagłówka (np. przycisk powrotu do bieżących danych)
    func addTrailing(_ v: NSView) { stack.addArrangedSubview(v) }

    init(_ text: String, accent: Subsystem? = nil) {
        self.accent = accent
        super.init(frame: .zero)
        left.stringValue = L(text)
        left.font = Fonts.display(12); right.font = Fonts.display(12)
        layer?.cornerRadius = 4
        let h = hstack([left, spacer(), right], spacing: 8)
        stack = h
        h.pin(to: self, insets: NSEdgeInsets(top: 4, left: 10, bottom: 4, right: 10))
        size(height: 24)
        applyTheme()
    }
    required init?(coder: NSCoder) { fatalError() }

    override func applyTheme() {
        layer?.backgroundColor = P.graphBg.cgColor
        let c = P.valueColor
        left.textColor = c; right.textColor = c
        let bloom = ThemeManager.shared.bloomFactor
        for l in [left, right] {
            l.shadow = nil
            guard P.isDark, bloom > 0.01 else { continue }
            let sh = NSShadow()
            sh.shadowColor = c.alpha(min(1, 0.8 * bloom))
            sh.shadowBlurRadius = 6 * min(2, bloom)
            l.shadow = sh
        }
    }
}

/// Wiersz tabeli z zaokrąglonym zaznaczeniem w kolorze palety
final class ThemedRowView: NSTableRowView {
    var inset: CGFloat = 8
    var zebra = false
    override func drawSelection(in dirtyRect: NSRect) {
        guard selectionHighlightStyle != .none else { return }
        let r = bounds.insetBy(dx: inset, dy: 1)
        // nowoczesny styl: pigułka w kolorze akcentu systemowego, jak w natywnych paskach bocznych
        if Prefs.shared.modernUI {
            NSColor.controlAccentColor.alpha(P.isDark ? 0.85 : 0.9).setFill()
            NSBezierPath(roundedRect: r, xRadius: 7, yRadius: 7).fill()
            return
        }
        P.selection.setFill()
        NSBezierPath(roundedRect: r, xRadius: 6, yRadius: 6).fill()
    }
    override func drawBackground(in dirtyRect: NSRect) {
        if zebra {
            P.hover.setFill()
            bounds.insetBy(dx: inset, dy: 1).fill()
        }
    }
}
