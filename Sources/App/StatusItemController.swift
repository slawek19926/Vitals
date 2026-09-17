// StatusItemController.swift - ikona w pasku menu z bieżącymi wartościami (CPU / RAM / temperatura / moc)
import AppKit

final class StatusItemController {
    private var item: NSStatusItem?
    private let menu = NSMenu()
    private let info = NSMenuItem(title: "", action: nil, keyEquivalent: "")

    init() {
        menu.addItem(info)
        menu.addItem(.separator())
        menu.addItem(withTitle: L("Pokaż Vitals"), action: #selector(AppDelegate.showMainWindow(_:)), keyEquivalent: "")
        menu.addItem(withTitle: L("Zakończ"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        NotificationCenter.default.addObserver(self, selector: #selector(snapshot(_:)), name: .snapshotUpdated, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(prefsChanged), name: .prefsChanged, object: nil)
        prefsChanged()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        if let i = item { NSStatusBar.system.removeStatusItem(i) }
    }

    @objc private func prefsChanged() {
        let mode = Prefs.shared.menuBarItem
        if mode == 0 { if let i = item { NSStatusBar.system.removeStatusItem(i); item = nil }; return }
        if item == nil {
            item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            item?.menu = menu
            item?.button?.font = Fonts.mono(11, weight: .medium)
            item?.button?.image = NSImage(systemSymbolName: "gauge.with.dots.needle.33percent", accessibilityDescription: nil)
            item?.button?.imagePosition = .imageLeading
        }
    }

    @objc private func snapshot(_ n: Notification) {
        guard let s = n.object as? Snapshot, let b = item?.button else { return }
        var parts = ["CPU \(Fmt.percent(s.cpu.total, precision: 0))"]
        let mode = Prefs.shared.menuBarItem
        if mode >= 2 { parts.append("RAM \(Fmt.percent(s.mem.total > 0 ? 100 * Double(s.mem.used) / Double(s.mem.total) : 0, precision: 0))") }
        if mode >= 3, let t = s.hotspot { parts.append(Fmt.temp(t, precision: 0)) }
        if mode == 4, let w = s.sysWatts { parts = [Fmt.watts(w)] }
        b.title = " " + parts.joined(separator: "  ")
        info.title = "CPU \(Fmt.percent(s.cpu.total)) · RAM \(Fmt.bytes(s.mem.used)) / \(Fmt.bytes(s.mem.total, precision: 0)) · \(s.processes.count) " + L("procesów") + (s.hotspot.map { " · \(Fmt.temp($0))" } ?? "") + (s.sysWatts.map { " · \(Fmt.watts($0))" } ?? "")
    }
}
