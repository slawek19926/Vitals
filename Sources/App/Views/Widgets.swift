// Widgets.swift - proste widoki pomocnicze: etykiety, karty, statystyki, tytuł strony, pasek stanu
import AppKit
import QuartzCore

/// Bazowa klasa widoku reagującego na zmianę motywu
class ThemedView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        NotificationCenter.default.addObserver(self, selector: #selector(themeChanged), name: .themeChanged, object: nil)
        setup()
    }
    required init?(coder: NSCoder) { fatalError() }
    convenience init() { self.init(frame: .zero) }
    func setup() {}
    @objc func themeChanged() { applyTheme(); needsDisplay = true }
    func applyTheme() {}
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        ThemeManager.shared.systemAppearanceChanged()
    }
}

/// Etykieta podświetlająca zmianę wartości (jak w TMOG)
/// Wspólny efekt przenikania starej i nowej wartości.
/// CATransition na etykiecie AppKit nic nie daje (warstwa jest przerysowywana bez migawki),
/// więc robimy migawkę starego tekstu, wygaszamy ją i równocześnie wyłaniamy nową wartość.
enum ValueFade {
    static let duration: CFTimeInterval = 0.3

    /// Przenikanie dowolnego widoku rysowanego ręcznie (np. komórki z paskiem)
    static func apply(to view: NSView, duration d: CFTimeInterval = duration) {
        guard Prefs.shared.crossfadeValues, view.window != nil, !view.isHiddenOrHasHiddenAncestor else { return }
        view.wantsLayer = true
        guard let layer = view.layer else { return }
        pulse(layer, d)
    }

    /// Podmiana tekstu etykiety: stara wartość gaśnie, po chwili wyłania się nowa.
    /// Bez migawek bitmapowych – te kosztowały tyle, że winda CPU była widoczna w samej aplikacji.
    static func swap(_ field: NSTextField, to text: String) {
        let old = field.stringValue
        guard Prefs.shared.crossfadeValues, old != text, !old.isEmpty,
              field.window != nil, !field.isHiddenOrHasHiddenAncestor else {
            setRaw(field, text)
            return
        }
        field.wantsLayer = true
        guard let layer = field.layer else { setRaw(field, text); return }
        let half = duration / 2
        layer.removeAnimation(forKey: "valueFade")
        CATransaction.begin()
        CATransaction.setCompletionBlock {
            setRaw(field, text)
            let fadeIn = CABasicAnimation(keyPath: "opacity")
            fadeIn.fromValue = 0
            fadeIn.toValue = 1
            fadeIn.duration = half
            fadeIn.timingFunction = CAMediaTimingFunction(name: .easeOut)
            layer.opacity = 1
            layer.add(fadeIn, forKey: "valueFade")
        }
        let fadeOut = CABasicAnimation(keyPath: "opacity")
        fadeOut.fromValue = 1
        fadeOut.toValue = 0
        fadeOut.duration = half
        fadeOut.timingFunction = CAMediaTimingFunction(name: .easeIn)
        fadeOut.fillMode = .forwards
        fadeOut.isRemovedOnCompletion = false
        layer.add(fadeOut, forKey: "valueFade")
        CATransaction.commit()
    }

    /// Ustawia tekst z pominięciem przenikania (używane wewnątrz animacji)
    private static func setRaw(_ field: NSTextField, _ text: String) {
        if let f = field as? FadeLabel { f.setRawValue(text) } else { field.stringValue = text }
    }

    /// Krótkie przygaszenie i rozjaśnienie warstwy – dla widoków rysowanych ręcznie
    private static func pulse(_ layer: CALayer, _ d: CFTimeInterval) {
        let a = CAKeyframeAnimation(keyPath: "opacity")
        a.values = [1, 0.05, 1]
        a.keyTimes = [0, 0.5, 1]
        a.duration = d
        a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer.add(a, forKey: "valueFade")
    }
}

/// Etykieta, której każda zmiana tekstu przenika zamiast przeskakiwać
class FadeLabel: NSTextField {
    /// Wyłączane tam, gdzie tekst zmienia się w trakcie pisania użytkownika
    var fadesValue = true
    override var stringValue: String {
        get { super.stringValue }
        set {
            guard fadesValue else { super.stringValue = newValue; return }
            ValueFade.swap(self, to: newValue)
        }
    }

    /// Ustawia tekst bez animacji (używane przez sam efekt przenikania)
    func setRawValue(_ text: String) { super.stringValue = text }
}

final class FlashLabel: NSTextField {
    var flashColor: NSColor?
    /// Zmiana tekstu przenika (stara wartość zanika, nowa się wyłania) zamiast podmieniać się skokowo
    var crossfade = true
    init(_ text: String = "", size: CGFloat = 12, weight: NSFont.Weight = .regular, mono: Bool = false) {
        super.init(frame: .zero)
        isEditable = false; isBordered = false; drawsBackground = false; isSelectable = false
        stringValue = text
        font = mono ? Fonts.mono(size, weight: weight) : Fonts.ui(size, weight)
        textColor = P.text
        lineBreakMode = .byTruncatingTail
        wantsLayer = true
        layer?.cornerRadius = 3
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }
    required init?(coder: NSCoder) { fatalError() }

    func update(flash: Bool, _ text: String) { update(text, flash: flash) }

    /// Ustawia tekst; jeśli się zmienił (i był już jakiś), krótko podświetla tło
    func update(_ text: String, flash: Bool = true) {
        let old = stringValue
        guard old != text else { return }
        if crossfade, !old.isEmpty { ValueFade.swap(self, to: text) } else { stringValue = text }
        guard flash, Prefs.shared.flashChanges, !old.isEmpty, old != "—", let layer else { return }
        let c = (flashColor ?? P.selection).alpha(P.isDark ? 0.75 : 0.9)
        let anim = CABasicAnimation(keyPath: "backgroundColor")
        anim.fromValue = c.cgColor
        anim.toValue = NSColor.clear.cgColor
        anim.duration = 1.0
        anim.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(anim, forKey: "flash")
    }
}

enum Label {
    static func make(_ text: String = "", size: CGFloat = 12, weight: NSFont.Weight = .regular, dim: Bool = false, mono: Bool = false) -> NSTextField {
        let l = FadeLabel(labelWithString: L(text))
        l.font = mono ? Fonts.mono(size, weight: weight) : Fonts.ui(size, weight)
        l.textColor = dim ? P.textDim : P.text
        l.lineBreakMode = .byTruncatingTail
        l.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return l
    }
}

/// Karta z zaokrągloną ramką w kolorze podsystemu (jak kafelki TMOG)
class CardView: ThemedView {
    var accent: Subsystem? { didSet { applyTheme() } }
    var borderAlpha: CGFloat = 0.55

    init(accent: Subsystem? = nil) {
        self.accent = accent
        super.init(frame: .zero)
        layer?.cornerRadius = Prefs.shared.modernUI ? 12 : 10
        layer?.borderWidth = 1
        applyTheme()
    }
    required init?(coder: NSCoder) { fatalError() }

    override func applyTheme() {
        layer?.backgroundColor = P.panelBg.cgColor
        layer?.cornerRadius = Prefs.shared.modernUI ? 12 : 10
        if Prefs.shared.modernUI {
            // spokojna ramka i miękki cień zamiast kolorowej obwódki podsystemu
            layer?.borderColor = P.border.alpha(P.isDark ? 0.55 : 0.8).cgColor
            layer?.shadowColor = NSColor.black.cgColor
            layer?.shadowOpacity = P.isDark ? 0.28 : 0.10
            layer?.shadowRadius = 8
            layer?.shadowOffset = CGSize(width: 0, height: -1)
            layer?.masksToBounds = false
        } else {
            let c = accent.map { P.accent($0) } ?? P.border
            layer?.borderColor = (accent == nil ? c : c.alpha(borderAlpha)).cgColor
            layer?.shadowOpacity = 0
        }
    }
}

/// Etykieta „dim” nad wartością (Utilization / 9.8%)
final class StatView: NSStackView {
    let caption: NSTextField
    let valueLabel: FlashLabel
    var value: String { get { valueLabel.stringValue } set { valueLabel.update(newValue, flash: false) } }

    init(_ caption: String, value: String = "—", valueSize: CGFloat = 13, accent: Subsystem? = nil) {
        self.caption = Label.make(caption, size: 10.5, dim: true)
        self.valueLabel = FlashLabel(value, size: valueSize, weight: .semibold)
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 2
        addArrangedSubview(self.caption)
        addArrangedSubview(valueLabel)
        self.caption.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        valueLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        NotificationCenter.default.addObserver(forName: .themeChanged, object: nil, queue: .main) { [weak self] _ in
            self?.caption.textColor = P.textDim
            self?.valueLabel.textColor = accent.map { P.accent($0) } ?? P.text
        }
        if let accent { valueLabel.textColor = P.accent(accent) }
    }
    required init?(coder: NSCoder) { fatalError() }
}

/// Wiersz „klucz: wartość” dla System Info
final class KeyValueRow: NSStackView {
    let keyLabel: NSTextField
    let valueLabel: NSTextField
    init(_ key: String, _ value: String, keyWidth: CGFloat = 170) {
        keyLabel = Label.make(L(key), size: 11.5, dim: true)
        valueLabel = Label.make(L(value), size: 11.5)
        valueLabel.isSelectable = true
        super.init(frame: .zero)
        orientation = .horizontal
        alignment = .firstBaseline
        spacing = 12
        addArrangedSubview(keyLabel)
        addArrangedSubview(valueLabel)
        keyLabel.widthAnchor.constraint(equalToConstant: keyWidth).isActive = true
        keyLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        NotificationCenter.default.addObserver(forName: .themeChanged, object: nil, queue: .main) { [weak self] _ in
            self?.keyLabel.textColor = P.textDim
            self?.valueLabel.textColor = P.text
        }
    }
    required init?(coder: NSCoder) { fatalError() }
}

/// Duży tytuł strony z ikoną, jak „Summary” w TMOG
final class PageTitleView: NSView {
    let label = NSTextField(labelWithString: "")
    let icon = NSImageView()
    var accessory: NSView? {
        didSet {
            oldValue?.removeFromSuperview()
            if let a = accessory {
                addSubview(a)
                a.translatesAutoresizingMaskIntoConstraints = false
                NSLayoutConstraint.activate([
                    a.trailingAnchor.constraint(equalTo: trailingAnchor),
                    a.centerYAnchor.constraint(equalTo: centerYAnchor),
                ])
            }
        }
    }

    /// Nazwa strony trafia do paska tytułowego okna; tutaj zostaje tylko rząd kontrolek
    let pageTitle: String

    /// Ikona odpowiadająca pozycji w pasku bocznym (albo przyciskom na jego dole)
    static func iconName(for title: String) -> String? {
        for row in SidebarViewController.staticRows {
            if case .item(let it) = row, it.title == title { return it.icon }
        }
        let extras = [L("Ustawienia"): "gearshape", L("Kolory"): "paintpalette"]
        return extras[title]
    }

    init(_ title: String) {
        pageTitle = title
        super.init(frame: .zero)
        // ikona strony taka sama jak w pasku bocznym
        if let name = PageTitleView.iconName(for: title) {
            icon.image = NSImage(systemSymbolName: name, accessibilityDescription: nil)
            icon.symbolConfiguration = .init(pointSize: 17, weight: .medium)
            icon.contentTintColor = P.textDim
        } else {
            icon.isHidden = true
        }
        let attrs: [NSAttributedString.Key: Any] = [.font: Fonts.title(27), .kern: 1.2, .foregroundColor: P.text]
        label.attributedStringValue = NSAttributedString(string: title, attributes: attrs)
        for v in [icon, label] { addSubview(v); v.translatesAutoresizingMaskIntoConstraints = false }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 44),
            icon.leadingAnchor.constraint(equalTo: leadingAnchor),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.leadingAnchor.constraint(equalTo: icon.isHidden ? leadingAnchor : icon.trailingAnchor,
                                           constant: icon.isHidden ? 0 : 12),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        for name in [Notification.Name.themeChanged, .prefsChanged] {
        NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.icon.contentTintColor = P.textDim
            self.label.attributedStringValue = NSAttributedString(string: self.label.stringValue, attributes: [.font: Fonts.title(27), .kern: 1.2, .foregroundColor: P.text])
        }
        }
    }
    required init?(coder: NSCoder) { fatalError() }
}

/// Pasek stanu na dole: „● Dane systemowe OK · 710 procesów · Generacja 281”
final class StatusBarView: ThemedView {
    private let dot = NSView()
    private let left = Label.make("", size: 11, dim: true)
    private let right = Label.make(L("00:00:00"), size: 11, dim: true, mono: true)

    override func setup() {
        // pasek zmienia się z każdym pomiarem – przenikanie dawałoby tu tylko migotanie
        (left as? FadeLabel)?.fadesValue = false
        (right as? FadeLabel)?.fadesValue = false
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 4
        for v in [dot, left, right] { addSubview(v); v.translatesAutoresizingMaskIntoConstraints = false }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 26),
            dot.widthAnchor.constraint(equalToConstant: 8), dot.heightAnchor.constraint(equalToConstant: 8),
            dot.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 22),
            dot.centerYAnchor.constraint(equalTo: centerYAnchor),
            left.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 10),
            left.centerYAnchor.constraint(equalTo: centerYAnchor),
            right.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -22),
            right.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        applyTheme()
        NotificationCenter.default.addObserver(self, selector: #selector(snapshot(_:)), name: .snapshotUpdated, object: nil)
    }

    override func applyTheme() {
        layer?.backgroundColor = P.windowBg.cgColor
        dot.layer?.backgroundColor = P.good.cgColor
        dot.layer?.shadowColor = P.good.cgColor
        dot.layer?.shadowOpacity = 0.9
        dot.layer?.shadowRadius = 4
        dot.layer?.shadowOffset = .zero
        left.textColor = P.textDim; right.textColor = P.textDim
    }

    override func draw(_ dirtyRect: NSRect) {
        P.border.alpha(0.6).setFill()
        NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
    }

    @objc private func snapshot(_ n: Notification) {
        guard let s = n.object as? Snapshot else { return }
        let ip = Monitor.interfaces().first(where: { $0.up && $0.addrs.contains(".") })?.addrs.split(separator: ",").first.map(String.init) ?? "—"
        let admin = Monitor.isRoot ? " · " + L("administrator") : (Monitor.shared.helperActive ? " · " + L("pomocnik aktywny") : "")
        left.stringValue = "\(L("Dane systemowe OK")) · \(s.processes.count) \(L("procesów")) · \(s.totalThreads) \(L("wątków"))   |   IP \(ip)   |   \(L("Generacja")) \(s.generation)\(admin)"
        right.stringValue = "CPU \(Fmt.percent(s.cpu.total, precision: 0))   RAM \(Fmt.bytes(s.mem.used)) / \(Fmt.bytes(s.mem.total, precision: 0))   " + Fmt.time.string(from: s.timestamp)
    }
}

/// Obraz SF Symbol z kolorem
func symbol(_ name: String, size: CGFloat = 18, weight: NSFont.Weight = .regular, color: NSColor? = nil) -> NSImageView {
    let iv = NSImageView()
    iv.image = NSImage(systemSymbolName: name, accessibilityDescription: nil)
    iv.symbolConfiguration = .init(pointSize: size, weight: weight)
    iv.contentTintColor = color ?? P.text
    iv.setContentHuggingPriority(.required, for: .horizontal)
    return iv
}
