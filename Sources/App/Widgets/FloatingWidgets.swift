// FloatingWidgets.swift - pływające panele na pulpicie: mały wykres i wartość, zawsze pod ręką
import AppKit

/// Rodzaj panelu – definiuje tytuł, kolor, formatowanie i źródło danych z migawki
enum WidgetKind: String, CaseIterable {
    case cpu, memory, gpu, temperature, network, disk, power

    var title: String {
        switch self {
        case .cpu: return L("CPU")
        case .memory: return L("Pamięć")
        case .gpu: return L("GPU")
        case .temperature: return L("Temperatura")
        case .network: return L("Sieć")
        case .disk: return L("Dyski")
        case .power: return L("Zasilanie")
        }
    }

    var accent: Subsystem {
        switch self {
        case .cpu: return .cpu
        case .memory: return .memory
        case .gpu: return .gpu
        case .temperature: return .thermal
        case .network: return .network
        case .disk: return .disk
        case .power: return .energy
        }
    }

    /// Ikona modułu w pasku menu
    var symbol: String {
        switch self {
        case .cpu: return "cpu"
        case .memory: return "memorychip"
        case .gpu: return "display"
        case .temperature: return "thermometer.medium"
        case .network: return "network"
        case .disk: return "internaldrive"
        case .power: return "bolt"
        }
    }

    /// Liczba rysowana na mini wykresie w pasku menu
    func menuBarValue(_ s: Snapshot) -> Double {
        switch self {
        case .network: return s.net.rxRate + s.net.txRate
        case .disk: return s.disk.readRate + s.disk.writeRate
        default: return values(s).first ?? 0
        }
    }

    /// Krótki napis mieszczący się w pasku menu
    func menuBarText(_ s: Snapshot) -> String {
        switch self {
        case .cpu: return Fmt.percent(s.cpu.total, precision: 0)
        case .memory: return Fmt.percent(s.mem.total > 0 ? 100 * Double(s.mem.used) / Double(s.mem.total) : 0, precision: 0)
        case .gpu: return s.gpuUtil.map { Fmt.percent($0, precision: 0) } ?? "—"
        case .temperature: return s.hotspot.map { Fmt.temp($0, precision: 0) } ?? "—"
        case .network: return "↓\(Fmt.rate(s.net.rxRate)) ↑\(Fmt.rate(s.net.txRate))"
        case .disk: return Fmt.rate(s.disk.readRate + s.disk.writeRate)
        case .power: return s.sysWatts.map { Fmt.watts($0) } ?? "—"
        }
    }

    /// Ile serii rysuje wykres (sieć i dysk mają dwie: odbiór/nadawanie, odczyt/zapis)
    var series: Int { self == .network || self == .disk ? 2 : 1 }

    /// Skala 0…100 dla procentów, automatyczna dla przepływności
    var isPercent: Bool { self == .cpu || self == .memory || self == .gpu }

    /// Wartości do wykresu
    func values(_ s: Snapshot) -> [Double] {
        switch self {
        case .cpu: return [s.cpu.total]
        case .memory: return [s.mem.total > 0 ? 100 * Double(s.mem.used) / Double(s.mem.total) : 0]
        case .gpu: return [s.gpuUtil ?? 0]
        case .temperature: return [s.hotspot ?? 0]
        case .network: return [s.net.rxRate, s.net.txRate]
        case .disk: return [s.disk.readRate, s.disk.writeRate]
        case .power: return [s.sysWatts ?? 0]
        }
    }

    /// Duża liczba na panelu
    func headline(_ s: Snapshot) -> String {
        switch self {
        case .cpu: return Fmt.percent(s.cpu.total)
        case .memory: return Fmt.bytes(s.mem.used)
        case .gpu: return s.gpuUtil.map { Fmt.percent($0) } ?? "—"
        case .temperature: return s.hotspot.map { Fmt.temp($0) } ?? "—"
        case .network: return Fmt.rate(s.net.rxRate + s.net.txRate)
        case .disk: return Fmt.rate(s.disk.readRate + s.disk.writeRate)
        case .power: return s.sysWatts.map { Fmt.watts($0) } ?? "—"
        }
    }

    /// Drobny opis pod liczbą
    func caption(_ s: Snapshot) -> String {
        switch self {
        case .cpu: return "\(L("użytkownik")) \(Fmt.percent(s.cpu.user)) · \(L("jądro")) \(Fmt.percent(s.cpu.system))"
        case .memory: return "\(Fmt.percent(s.mem.total > 0 ? 100 * Double(s.mem.used) / Double(s.mem.total) : 0)) \(L("z")) \(Fmt.bytes(s.mem.total, precision: 0))"
        case .gpu: return Monitor.shared.hardware.gpuName
        case .temperature: return s.thermalText
        case .network: return "↓ \(Fmt.rate(s.net.rxRate))  ↑ \(Fmt.rate(s.net.txRate))"
        case .disk: return "R \(Fmt.rate(s.disk.readRate))  W \(Fmt.rate(s.disk.writeRate))"
        case .power: return s.battery.map { $0.onAC ? L("zasilanie sieciowe") : "\($0.percent)% " + L("na baterii") } ?? ""
        }
    }
}

/// Pojedynczy panel: bez ramki, przeciągany za tło, zapamiętuje położenie
final class WidgetPanel: NSPanel {
    let kind: WidgetKind
    private let titleLabel: NSTextField
    private let value = FlashLabel("—", size: 22, weight: .semibold, mono: true)
    private let caption: NSTextField
    private let graph: GraphView
    private let effect = NSVisualEffectView()
    private let closeButton = NSButton()

    init(kind: WidgetKind) {
        self.kind = kind
        titleLabel = Label.make(kind.title, size: 11, weight: .semibold, dim: true)
        caption = Label.make("", size: 10.5, dim: true)
        graph = GraphView(series: kind.series, history: 120, accents: Array(repeating: kind.accent, count: kind.series))
        super.init(contentRect: NSRect(x: 0, y: 0, width: 220, height: 132),
                   styleMask: [.borderless, .nonactivatingPanel, .resizable],
                   backing: .buffered, defer: false)

        isFloatingPanel = true
        level = Prefs.shared.widgetsOnTop ? .floating : .normal
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        isMovableByWindowBackground = true
        hasShadow = true
        backgroundColor = .clear
        isOpaque = false
        hidesOnDeactivate = false
        minSize = NSSize(width: 170, height: 104)
        maxSize = NSSize(width: 520, height: 320)
        alphaValue = CGFloat(Prefs.shared.widgetOpacity)

        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 12
        effect.layer?.masksToBounds = true

        graph.compact = true
        graph.fillAlpha = 0.18
        if kind.isPercent { graph.maxValue = 100 } else { graph.autoScale = true }
        if kind.series == 2 { graph.colorProvider = { i, p in i == 0 ? P.accent(kind.accent) : P.accent(kind.accent).blended(withFraction: 0.45, of: .white) ?? P.accent(kind.accent) } }
        graph.heightAnchor.constraint(equalToConstant: 46).isActive = true
        value.textColor = P.accent(kind.accent)

        closeButton.isBordered = false
        closeButton.bezelStyle = .inline
        closeButton.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: L("Zamknij"))
        closeButton.contentTintColor = P.textDim
        closeButton.target = self
        closeButton.action = #selector(closeWidget)
        closeButton.alphaValue = 0

        let head = hstack([titleLabel, spacer(), closeButton], spacing: 6)
        let body = vstack([head, value, caption, graph], spacing: 3)
        body.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(body)
        NSLayoutConstraint.activate([
            body.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: 12),
            body.trailingAnchor.constraint(equalTo: effect.trailingAnchor, constant: -12),
            body.topAnchor.constraint(equalTo: effect.topAnchor, constant: 10),
            body.bottomAnchor.constraint(equalTo: effect.bottomAnchor, constant: -10),
        ])
        contentView = effect

        restoreFrame()
        trackMouse()
        NotificationCenter.default.addObserver(self, selector: #selector(snapshot(_:)), name: .snapshotUpdated, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(themeChanged), name: .themeChanged, object: nil)
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    // przycisk zamykania pojawia się dopiero pod kursorem
    override func mouseEntered(with event: NSEvent) { animator().alphaValue = 1; closeButton.animator().alphaValue = 1 }
    override func mouseExited(with event: NSEvent) {
        animator().alphaValue = CGFloat(Prefs.shared.widgetOpacity)
        closeButton.animator().alphaValue = 0
    }

    private var tracking: NSTrackingArea?
    func refreshTracking() { trackMouse() }
    private func trackMouse() {
        guard let v = contentView else { return }
        if let t = tracking { v.removeTrackingArea(t) }
        let t = NSTrackingArea(rect: v.bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        v.addTrackingArea(t)
        tracking = t
    }

    @objc private func closeWidget() { WidgetManager.shared.setEnabled(kind, false) }

    @objc private func themeChanged() {
        value.textColor = P.accent(kind.accent)
        closeButton.contentTintColor = P.textDim
    }

    @objc private func snapshot(_ n: Notification) {
        guard let s = n.object as? Snapshot else { return }
        graph.push(kind.values(s))
        value.update(kind.headline(s), flash: false)
        caption.stringValue = kind.caption(s)
    }

    // MARK: - położenie

    private var frameKey: String { "widgetFrame-" + kind.rawValue }
    /// dopóki panel nie stanie na swoim miejscu, nie zapisujemy pozycji (inaczej trafia tam 0,0 z tworzenia okna)
    private var placed = false

    private func restoreFrame() {
        defer { placed = true }
        if let text = UserDefaults.standard.string(forKey: frameKey) {
            let r = NSRectFromString(text)
            if r.width > 120, NSScreen.screens.contains(where: { $0.visibleFrame.intersects(r) }) {
                setFrame(r, display: false)
                return
            }
        }
        cascade()
    }

    /// Ustawia panel w kaskadzie przy prawej krawędzi ekranu z kursorem
    func cascade() {
        let mouse = NSEvent.mouseLocation
        let screen = (NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main ?? NSScreen.screens[0]).visibleFrame
        let index = CGFloat(WidgetKind.allCases.firstIndex(of: kind) ?? 0)
        let step = frame.height + 12
        var origin = NSPoint(x: screen.maxX - frame.width - 24, y: screen.maxY - frame.height - 24 - index * step)
        // gdy kolumna nie mieści się na ekranie, zaczynamy nową w lewo
        if origin.y < screen.minY {
            let column = floor((screen.maxY - 24 - origin.y) / max(1, screen.height - 24))
            origin.x -= column * (frame.width + 12)
            origin.y = screen.maxY - frame.height - 24 - (index - column * floor(screen.height / step)) * step
        }
        origin.x = min(max(screen.minX + 8, origin.x), screen.maxX - frame.width - 8)
        origin.y = min(max(screen.minY + 8, origin.y), screen.maxY - frame.height - 8)
        setFrameOrigin(origin)
    }

    func saveFrame() {
        guard placed, frame.width > 120 else { return }
        UserDefaults.standard.set(NSStringFromRect(frame), forKey: frameKey)
    }
}

/// Tworzy, chowa i zapamiętuje panele
final class WidgetManager: NSObject, NSWindowDelegate {
    static let shared = WidgetManager()
    private var panels: [WidgetKind: WidgetPanel] = [:]

    func restore() {
        for kind in WidgetKind.allCases where Prefs.shared.widgets.contains(kind.rawValue) { show(kind) }
    }

    func isEnabled(_ kind: WidgetKind) -> Bool { panels[kind] != nil }

    func setEnabled(_ kind: WidgetKind, _ on: Bool) {
        var list = Set(Prefs.shared.widgets)
        if on { list.insert(kind.rawValue); show(kind) } else { list.remove(kind.rawValue); hide(kind) }
        Prefs.shared.widgets = Array(list).sorted()
        NotificationCenter.default.post(name: .widgetsChanged, object: nil)
    }

    func toggle(_ kind: WidgetKind) { setEnabled(kind, !isEnabled(kind)) }

    private func show(_ kind: WidgetKind) {
        if let p = panels[kind] { p.orderFront(nil); return }
        let p = WidgetPanel(kind: kind)
        p.delegate = self
        panels[kind] = p
        p.orderFront(nil)
    }

    private func hide(_ kind: WidgetKind) {
        panels[kind]?.saveFrame()
        panels[kind]?.orderOut(nil)
        panels[kind] = nil
    }

    /// Przezroczystość i „zawsze na wierzchu” z ustawień
    func applyPrefs() {
        for p in panels.values {
            p.alphaValue = CGFloat(Prefs.shared.widgetOpacity)
            p.level = Prefs.shared.widgetsOnTop ? .floating : .normal
        }
    }

    var anyVisible: Bool { !panels.isEmpty }

    func saveAll() { for p in panels.values { p.saveFrame() } }

    func windowDidMove(_ notification: Notification) { (notification.object as? WidgetPanel)?.saveFrame() }
    func windowDidResize(_ notification: Notification) {
        guard let p = notification.object as? WidgetPanel else { return }
        p.refreshTracking()
        p.saveFrame()
    }
}

extension Notification.Name {
    static let widgetsChanged = Notification.Name("WidgetsChanged")
}
