// StatusItemController.swift - odczyty w pasku menu, wykresy w rozwijanych panelach
import AppKit

/// Presentation of the expanded panel; collapsed items always show values.
enum ModulePopoverStyle: Int, CaseIterable {
    case valueOnly = 0, graphOnly = 1, both = 2
    var title: String { L(["Tylko wartość", "Tylko wykres", "Wartość i wykres"][rawValue]) }
}

enum NetworkMenuBarLayout: Int, CaseIterable {
    case singleRow = 0, twoRows = 1
    var title: String { L(self == .singleRow ? "settings.network_layout.single_row" : "settings.network_layout.two_rows") }
}

/// Two fixed-width rate rows that follow the menu bar's native appearance.
enum NetworkMenuBarDisplay {
    static let font = NSFont.monospacedSystemFont(ofSize: 9, weight: .medium)
    static var rowHeight: CGFloat { ceil(NSAttributedString(string: "0", attributes: [.font: font]).size().height) }
    static var size: NSSize {
        NSSize(width: ceil(NSAttributedString(string: "↓ 1023.9 TB/s", attributes: [.font: font]).size().width) + 4,
               height: rowHeight * 2)
    }
    static func rows(download: Double, upload: Double) -> [String] {
        ["↓ " + Fmt.rate(download), "↑ " + Fmt.rate(upload)]
    }

    static func image(download: Double, upload: Double) -> NSImage {
        let lines = rows(download: download, upload: upload)
        let image = NSImage(size: size, flipped: false) { rect in
            let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.black]
            for (index, line) in lines.enumerated() {
                let arrow = NSAttributedString(string: String(line.prefix(1)), attributes: attributes)
                let value = NSAttributedString(string: String(line.dropFirst(2)), attributes: attributes)
                let y = CGFloat(1 - index) * rowHeight
                arrow.draw(at: NSPoint(x: 0, y: y))
                value.draw(at: NSPoint(x: rect.width - value.size().width, y: y))
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = lines.joined(separator: ", ")
        return image
    }
}

/// Pojedyncza pozycja w pasku menu odpowiadająca jednej metryce
final class MenuBarModule {
    let kind: WidgetKind
    let item: NSStatusItem
    static let horizontalPadding: CGFloat = 4

    /// Panel otwierany kliknięciem tej pozycji – jeden na moduł
    let popover = NSPopover()

    init(kind: WidgetKind, target: AnyObject, action: Selector) {
        self.kind = kind
        popover.behavior = .transient
        popover.contentViewController = ModulePopoverController(kind: kind, detailed: Prefs.shared.menuBarDetailed.contains(kind.rawValue))
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.font = kind.menuBarFont
        item.button?.imagePosition = .imageLeading
        item.button?.imageHugsTitle = true
        item.button?.target = target
        item.button?.action = action
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        item.button?.toolTip = kind.title
        applyLength()
    }

    /// Przebudowuje panel, gdy zmieni się tryb (prosty ↔ zaawansowany)
    func applyDetailMode() {
        let wanted = Prefs.shared.menuBarDetailed.contains(kind.rawValue)
        guard (popover.contentViewController as? ModulePopoverController)?.detailed != wanted else { return }
        if popover.isShown { popover.performClose(nil) }
        popover.contentViewController = ModulePopoverController(kind: kind, detailed: wanted)
    }

    /// Szerokość pozycji jest stała – inaczej zmiana liczby przesuwałaby cały pasek
    func applyLength() {
        let twoRows = kind == .network && Prefs.shared.menuBarNetworkLayout == .twoRows
        // Measure the native cell with its longest title rather than reserving oversized slots.
        guard let cell = item.button?.cell?.copy() as? NSButtonCell else {
            item.length = twoRows ? NetworkMenuBarDisplay.size.width + Self.horizontalPadding
                : kind.menuBarWidth + (symbolImage()?.size.width ?? 14) + 8
            return
        }
        cell.imagePosition = twoRows ? .imageOnly : .imageLeading
        cell.attributedTitle = NSAttributedString(string: twoRows ? "" : kind.menuBarSizingText,
                                                  attributes: [.font: kind.menuBarFont])
        cell.image = twoRows ? NetworkMenuBarDisplay.image(download: 0, upload: 0) : symbolImage()
        item.length = ceil(cell.cellSize.width) + Self.horizontalPadding
    }

    func remove() { NSStatusBar.system.removeStatusItem(item) }

    func update(_ s: Snapshot) {
        guard let b = item.button else { return }
        if kind == .network {
            b.toolTip = kind.title + ": " + NetworkMenuBarDisplay.rows(download: s.net.rxRate, upload: s.net.txRate).joined(separator: ", ")
            if Prefs.shared.menuBarNetworkLayout == .twoRows {
                b.attributedTitle = NSAttributedString(string: "")
                b.imagePosition = .imageOnly
                b.image = NetworkMenuBarDisplay.image(download: s.net.rxRate, upload: s.net.txRate)
                return
            }
        }
        b.imagePosition = .imageLeading

        // kolor zależny od poziomu: spokojny akcent, ostrzeżenie, wartość krytyczna
        b.attributedTitle = NSAttributedString(string: kind.menuBarText(s), attributes: [
            .font: kind.menuBarFont,
            .foregroundColor: kind.menuBarColor(s),
        ])
        b.alignment = .left
        b.image = symbolImage()
        b.imageHugsTitle = true
    }

    /// Ikona modułu, gdy wykres jest wyłączony
    private func symbolImage() -> NSImage? {
        let img = NSImage(systemSymbolName: kind.symbol, accessibilityDescription: kind.title)
        img?.isTemplate = true
        return img
    }

}

final class StatusItemController: NSObject {
    private var modules: [WidgetKind: MenuBarModule] = [:]
    private let menu = NSMenu()
    private let info = NSMenuItem(title: "", action: nil, keyEquivalent: "")

    override init() {
        super.init()
        menu.addItem(info)
        menu.addItem(.separator())
        menu.addItem(withTitle: L("Pokaż Vitals"), action: #selector(AppDelegate.showMainWindow(_:)), keyEquivalent: "")
        menu.addItem(withTitle: L("Ustawienia…"), action: #selector(AppDelegate.openSettings), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: L("Zakończ"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
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
        for m in modules.values {
            m.applyLength(); m.applyDetailMode()
            m.update(Monitor.shared.latest)
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
        // każdy moduł ma własny panel ze szczegółami tej metryki
        for other in modules.values where other !== module && other.popover.isShown { other.popover.performClose(nil) }
        if module.popover.isShown { module.popover.performClose(nil) }
        else {
            module.popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .maxY)
            module.popover.contentViewController?.view.window?.makeKey()
        }
    }

    @objc private func snapshot(_ n: Notification) {
        guard let s = n.object as? Snapshot else { return }
        for m in modules.values { m.update(s) }
        info.title = "CPU \(Fmt.percent(s.cpu.total)) · RAM \(Fmt.bytes(s.mem.used)) / \(Fmt.bytes(s.mem.total, precision: 0)) · \(s.processes.count) " + L("procesów")
            + (s.hotspot.map { " · \(Fmt.temp($0))" } ?? "") + (s.sysWatts.map { " · \(Fmt.watts($0))" } ?? "")
    }
}
