// MenuBarPopover.swift - panel pod ikoną w pasku menu: miniwykresy i najcięższe procesy
import AppKit

final class MenuBarPopoverController: NSViewController {
    private struct Row {
        let title: String
        let graph: GraphView
        let value: FlashLabel
        let caption: NSTextField
        let values: (Snapshot) -> [Double]
        let headline: (Snapshot) -> String
        let sub: (Snapshot) -> String
    }

    private var rows: [Row] = []
    private let procRows: [(name: FlashLabel, cpu: FlashLabel)] = (0..<5).map { _ in
        (FlashLabel("", size: 11), FlashLabel("", size: 11, mono: true))
    }
    private let header = Label.make("", size: 11, dim: true)

    override func loadView() {
        let root = ThemedView()
        root.translatesAutoresizingMaskIntoConstraints = false
        view = root

        let defs: [(WidgetKind, Bool)] = [(.cpu, true), (.memory, true), (.network, false), (.temperature, false)]
        var cards: [NSView] = []
        for (kind, percent) in defs {
            let g = GraphView(series: kind.series, history: 120, accents: Array(repeating: kind.accent, count: kind.series))
            g.compact = true
            g.fillAlpha = 0.16
            if percent { g.maxValue = 100 } else { g.autoScale = true }
            g.heightAnchor.constraint(equalToConstant: 38).isActive = true
            let value = FlashLabel("—", size: 15, weight: .semibold, mono: true)
            value.textColor = P.accent(kind.accent)
            let caption = Label.make("", size: 10, dim: true)
            let title = Label.make(kind.title, size: 10.5, weight: .semibold, dim: true)
            let card = vstack([hstack([title, spacer(), value], spacing: 6), g, caption], spacing: 3)
            cards.append(card)
            rows.append(Row(title: kind.title, graph: g, value: value, caption: caption,
                            values: { kind.values($0) }, headline: { kind.headline($0) }, sub: { kind.caption($0) }))
        }

        let grid = vstack([hstack([cards[0], cards[1]], spacing: 14, distribution: .fillEqually),
                           hstack([cards[2], cards[3]], spacing: 14, distribution: .fillEqually)], spacing: 10)

        let procHead = Label.make(L("Najcięższe procesy"), size: 10.5, weight: .semibold, dim: true)
        let procList = vstack(procRows.map { hstack([$0.name, spacer(), $0.cpu], spacing: 8) }, spacing: 2)

        let open = NSButton(title: L("Pokaż Vitals"), target: NSApp.delegate, action: #selector(AppDelegate.showMainWindow(_:)))
        let settings = NSButton(title: L("Ustawienia…"), target: NSApp.delegate, action: #selector(AppDelegate.openSettings))
        let quit = NSButton(title: L("Zakończ"), target: NSApp, action: #selector(NSApplication.terminate(_:)))
        for b in [open, settings, quit] { b.bezelStyle = .rounded; b.controlSize = .small; b.font = Fonts.ui(11.5) }

        let stack = vstack([header, grid, procHead, procList, hstack([open, settings, spacer(), quit], spacing: 8)], spacing: 10)
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -14),
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12),
            root.widthAnchor.constraint(equalToConstant: 380),
        ])

        NotificationCenter.default.addObserver(self, selector: #selector(snapshot(_:)), name: .snapshotUpdated, object: nil)
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    @objc private func snapshot(_ n: Notification) {
        guard let s = n.object as? Snapshot, view.window?.isVisible == true else { return }
        header.stringValue = "\(s.processes.count) " + L("procesów") + " · \(s.totalThreads) " + L("wątków")
            + (s.sysWatts.map { " · \(Fmt.watts($0))" } ?? "")
        for r in rows {
            r.graph.push(r.values(s))
            r.value.update(r.headline(s), flash: false)
            r.caption.stringValue = r.sub(s)
        }
        let top = s.processes.sorted { $0.cpuPercent > $1.cpuPercent }.prefix(procRows.count)
        for (i, row) in procRows.enumerated() {
            if i < top.count {
                let p = top[Array(top).startIndex + i]
                row.name.update(p.name, flash: false)
                row.cpu.update(Fmt.percent(p.cpuPercent), flash: false)
            } else {
                row.name.update("", flash: false)
                row.cpu.update("", flash: false)
            }
        }
    }
}
