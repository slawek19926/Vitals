// StatusItemController.swift - moduły w pasku menu: osobna pozycja na metrykę, każda z wartością i mini wykresem
import AppKit

/// Sposób pokazywania modułu w pasku menu
enum MenuBarStyle: Int, CaseIterable {
    case valueOnly = 0, graphOnly = 1, both = 2
    var title: String { L(["Tylko wartość", "Tylko wykres", "Wartość i wykres"][rawValue]) }
}

/// Pojedyncza pozycja w pasku menu odpowiadająca jednej metryce
final class MenuBarModule {
    let kind: WidgetKind
    let item: NSStatusItem
    private var history: [Double] = []
    private let historyLimit = 40

    init(kind: WidgetKind, target: AnyObject, action: Selector) {
        self.kind = kind
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.font = Fonts.mono(10.5, weight: .medium)
        item.button?.imagePosition = .imageLeading
        item.button?.target = target
        item.button?.action = action
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        item.button?.toolTip = kind.title
    }

    func remove() { NSStatusBar.system.removeStatusItem(item) }

    func update(_ s: Snapshot) {
        guard let b = item.button else { return }
        let style = MenuBarStyle(rawValue: Prefs.shared.menuBarStyle) ?? .both
        history.append(kind.menuBarValue(s))
        if history.count > historyLimit { history.removeFirst(history.count - historyLimit) }

        b.title = style == .graphOnly ? "" : " " + kind.menuBarText(s)
        b.image = style == .valueOnly ? symbolImage() : sparkline()
        b.imageHugsTitle = true
    }

    /// Ikona modułu, gdy wykres jest wyłączony
    private func symbolImage() -> NSImage? {
        let img = NSImage(systemSymbolName: kind.symbol, accessibilityDescription: kind.title)
        img?.isTemplate = true
        return img
    }

    /// Mini wykres rysowany w kolorze podsystemu, wysokość dopasowana do paska menu
    private func sparkline() -> NSImage {
        let size = NSSize(width: 34, height: 16)
        let img = NSImage(size: size)
        guard history.count > 1 else { return img }
        let maxV = kind.isPercent ? 100 : max(history.max() ?? 1, 1)
        img.lockFocus()
        let color = P.accent(kind.accent)
        let path = NSBezierPath()
        let stepX = size.width / CGFloat(max(1, historyLimit - 1))
        let firstIndex = historyLimit - history.count
        for (i, v) in history.enumerated() {
            let x = CGFloat(firstIndex + i) * stepX
            let y = 1 + CGFloat(min(1, max(0, v / maxV))) * (size.height - 3)
            if i == 0 { path.move(to: NSPoint(x: x, y: y)) } else { path.line(to: NSPoint(x: x, y: y)) }
        }
        // wypełnienie pod linią, żeby wykres był czytelny przy 16 punktach wysokości
        let fill = path.copy() as! NSBezierPath
        fill.line(to: NSPoint(x: CGFloat(historyLimit - 1) * stepX, y: 0))
        fill.line(to: NSPoint(x: CGFloat(firstIndex) * stepX, y: 0))
        fill.close()
        color.withAlphaComponent(0.25).setFill()
        fill.fill()
        color.setStroke()
        path.lineWidth = 1.2
        path.stroke()
        img.unlockFocus()
        img.isTemplate = false
        return img
    }
}

final class StatusItemController: NSObject {
    private var modules: [WidgetKind: MenuBarModule] = [:]
    private let menu = NSMenu()
    private let info = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    /// panel z miniwykresami otwierany lewym przyciskiem
    private let popover = NSPopover()

    override init() {
        super.init()
        menu.addItem(info)
        menu.addItem(.separator())
        menu.addItem(withTitle: L("Pokaż Vitals"), action: #selector(AppDelegate.showMainWindow(_:)), keyEquivalent: "")
        menu.addItem(withTitle: L("Ustawienia…"), action: #selector(AppDelegate.openSettings), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: L("Zakończ"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        popover.behavior = .transient
        popover.contentViewController = MenuBarPopoverController()
        NotificationCenter.default.addObserver(self, selector: #selector(snapshot(_:)), name: .snapshotUpdated, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(prefsChanged), name: .prefsChanged, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(prefsChanged), name: .themeChanged, object: nil)
        prefsChanged()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        for m in modules.values { m.remove() }
    }

    /// Tworzy i usuwa pozycje zgodnie z listą modułów w ustawieniach
    @objc private func prefsChanged() {
        let wanted = Prefs.shared.menuBarModules.compactMap { WidgetKind(rawValue: $0) }
        for kind in modules.keys where !wanted.contains(kind) {
            modules[kind]?.remove()
            modules[kind] = nil
        }
        // kolejność w pasku menu odpowiada kolejności na liście: tworzymy od końca
        for kind in wanted.reversed() where modules[kind] == nil {
            modules[kind] = MenuBarModule(kind: kind, target: self, action: #selector(buttonClicked(_:)))
        }
    }

    @objc private func buttonClicked(_ sender: NSStatusBarButton) {
        guard let module = modules.values.first(where: { $0.item.button === sender }) else { return }
        if NSApp.currentEvent?.type == .rightMouseUp {
            module.item.menu = menu
            module.item.button?.performClick(nil)
            module.item.menu = nil
            return
        }
        if popover.isShown { popover.performClose(nil) }
        else {
            popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .maxY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    @objc private func snapshot(_ n: Notification) {
        guard let s = n.object as? Snapshot else { return }
        for m in modules.values { m.update(s) }
        info.title = "CPU \(Fmt.percent(s.cpu.total)) · RAM \(Fmt.bytes(s.mem.used)) / \(Fmt.bytes(s.mem.total, precision: 0)) · \(s.processes.count) " + L("procesów")
            + (s.hotspot.map { " · \(Fmt.temp($0))" } ?? "") + (s.sysWatts.map { " · \(Fmt.watts($0))" } ?? "")
    }
}
