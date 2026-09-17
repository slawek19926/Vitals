// SidebarViewController.swift - pasek boczny jak w TMOG: sekcje, ikony + nazwy stron, na dole Ustawienia | Kolory
import AppKit

/// Wiersz akcji na dole paska bocznego: ten sam rytm co pozycje listy (ikona 22 pt, tekst 13 pt)
final class SidebarActionRow: NSView {
    private let icon: NSImageView
    private let label: NSTextField
    private let action: () -> Void
    private var hovering = false { didSet { needsDisplay = true } }

    init(title: String, symbol name: String, action: @escaping () -> Void) {
        icon = symbol(name, size: 14, weight: .regular, color: P.text)
        label = Label.make(title, size: 13)
        self.action = action
        super.init(frame: .zero)
        wantsLayer = true
        icon.widthAnchor.constraint(equalToConstant: 22).isActive = true
        let h = hstack([icon, label], spacing: 10)
        h.pin(to: self, insets: NSEdgeInsets(top: 0, left: 14, bottom: 0, right: 8))
        heightAnchor.constraint(equalToConstant: 30).isActive = true
        applyTheme()
    }
    required init?(coder: NSCoder) { fatalError() }

    func applyTheme() {
        icon.contentTintColor = P.text
        label.textColor = P.text
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard hovering else { return }
        P.hover.setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 4, dy: 1), xRadius: 7, yRadius: 7).fill()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }
    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func mouseUp(with event: NSEvent) { hovering = false; action() }
}

final class SidebarViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    struct Item { let title: String; let icon: String; let page: Int }
    enum Row { case header(String); case item(Item) }
    static let staticRows: [Row] = [
        .item(Item(title: L("Podsumowanie"), icon: "gauge.with.dots.needle.33percent", page: 0)),
        .item(Item(title: L("Wydajność"), icon: "waveform.path.ecg", page: 1)),
        .item(Item(title: L("Procesy"), icon: "list.bullet.rectangle", page: 2)),
        .item(Item(title: L("Informacje o systemie"), icon: "info.circle", page: 16)),
        .item(Item(title: L("Sprzęt"), icon: "cpu.fill", page: 3)),
        .item(Item(title: L("Usługi"), icon: "gearshape.2", page: 4)),
        .item(Item(title: L("Użytkownicy"), icon: "person.2", page: 5)),
        .header(L("ZAAWANSOWANE")),
        .item(Item(title: L("Zasilanie i czujniki"), icon: "bolt.heart", page: 6)),
        .item(Item(title: L("Apple Silicon"), icon: "cpu", page: 7)),
        .item(Item(title: L("Połączenia"), icon: "network", page: 8)),
        .item(Item(title: L("Bluetooth"), icon: "wave.3.right", page: 14)),
        .item(Item(title: L("Elementy startowe"), icon: "power", page: 9)),
        .item(Item(title: L("Zainstalowane aplikacje"), icon: "square.grid.2x2", page: 10)),
        .item(Item(title: L("Sterowniki"), icon: "wrench.and.screwdriver", page: 11)),
        .item(Item(title: L("Miejsce na dysku"), icon: "chart.pie", page: 12)),
        .item(Item(title: L("Benchmarki"), icon: "speedometer", page: 13)),
        .item(Item(title: L("Zdrowie systemu"), icon: "heart.text.square", page: 15)),
    ]
    let rows: [Row] = SidebarViewController.staticRows
    var onSelect: ((Int) -> Void)?

    private let effect = NSVisualEffectView()
    private let solid = NSView()
    private let table = NSTableView()
    private var actionRows: [SidebarActionRow] = []
    private let separator = NSView()
    private let brand = NSTextField(labelWithString: "VITALS")
    /// Wyszukiwarka globalna mieszka w pasku bocznym, dzięki czemu okno nie potrzebuje paska narzędzi
    let searchField = NSSearchField()
    private var suppress = false

    override func loadView() {
        view = NSView()
        view.wantsLayer = true
        effect.material = .sidebar
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.pin(to: view)
        solid.wantsLayer = true
        solid.pin(to: view)

        let col = NSTableColumn(identifier: .init("c"))
        table.addTableColumn(col)
        table.headerView = nil
        table.rowHeight = 30
        table.intercellSpacing = NSSize(width: 0, height: 1)
        table.backgroundColor = .clear
        table.selectionHighlightStyle = .regular
        table.floatsGroupRows = false
        table.dataSource = self
        table.delegate = self
        table.style = .plain
        table.focusRingType = .none
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scroll)

        brand.font = Fonts.ui(10, .semibold)
        brand.alignment = .left
        brand.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(brand)
        separator.wantsLayer = true
        separator.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(separator)

        let settingsRow = SidebarActionRow(title: L("Ustawienia"), symbol: "gearshape") { [weak self] in
            self?.onSelect?(self?.settingsPage ?? 0)
        }
        var colorsRowRef: SidebarActionRow?
        let colorsRow = SidebarActionRow(title: L("Kolory"), symbol: "paintpalette") { [weak self] in
            guard let self, let row = colorsRowRef else { return }
            self.showColorsPopover(relativeTo: row)
        }
        colorsRowRef = colorsRow
        actionRows = [settingsRow, colorsRow]
        let bottom = vstack([settingsRow, colorsRow], spacing: 2)
        for r in actionRows { r.widthAnchor.constraint(equalTo: bottom.widthAnchor).isActive = true }
        bottom.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(bottom)

        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: view.topAnchor, constant: 44),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 6),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -6),
            scroll.bottomAnchor.constraint(equalTo: separator.topAnchor, constant: -6),
            // nazwa aplikacji jako dyskretna stopka obok przycisków
            brand.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 14),
            brand.bottomAnchor.constraint(equalTo: separator.topAnchor, constant: -8),
            separator.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 10),
            separator.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -10),
            separator.heightAnchor.constraint(equalToConstant: 1),
            separator.bottomAnchor.constraint(equalTo: bottom.topAnchor, constant: -8),
            bottom.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            bottom.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
            bottom.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -10),
            bottom.heightAnchor.constraint(equalToConstant: 62),
        ])
        NotificationCenter.default.addObserver(self, selector: #selector(themeChanged), name: .themeChanged, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(themeChanged), name: .prefsChanged, object: nil)
        themeChanged()
    }

    @objc private func themeChanged() {
        let phosphor = P.isPhosphor
        effect.isHidden = phosphor
        solid.isHidden = !phosphor
        solid.layer?.backgroundColor = P.sidebarBg.cgColor
        separator.layer?.backgroundColor = P.border.alpha(0.7).cgColor
        for r in actionRows { r.applyTheme() }
        brand.font = Fonts.ui(10, .semibold)
        brand.textColor = P.textDim.alpha(0.8)
        table.reloadData()
    }

    func select(_ page: Int) {
        suppress = true
        if let idx = rows.firstIndex(where: { if case .item(let it) = $0 { return it.page == page }; return false }) {
            table.selectRowIndexes(IndexSet(integer: idx), byExtendingSelection: false)
        } else {
            table.deselectAll(nil)
        }
        suppress = false
    }

    // MARK: tabela
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool { if case .header = rows[row] { return true }; return false }
    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { if case .item = rows[row] { return true }; return false }
    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat { if case .header = rows[row] { return 28 }; return 30 }
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { let r = ThemedRowView(); r.inset = 4; return r }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = NSTableCellView()
        switch rows[row] {
        case .header(let t):
            let line = ThemedView(); line.layer?.backgroundColor = P.selection.alpha(0.9).cgColor; line.size(height: 1)
            let l = Label.make(t, size: 10, weight: .semibold)
            l.textColor = Prefs.shared.modernUI ? P.textDim : P.network
            if Prefs.shared.modernUI { line.isHidden = true }
            let h = hstack([l, line], spacing: 8)
            h.pin(to: cell, insets: NSEdgeInsets(top: 12, left: 16, bottom: 2, right: 12))
        case .item(let it):
            let selected = table.selectedRow == row
            let fg = (Prefs.shared.modernUI && selected) ? NSColor.white : P.text
            let icon = symbol(it.icon, size: 14, weight: .regular, color: fg)
            let label = Label.make(it.title, size: 13, weight: selected ? .medium : .regular)
            label.textColor = fg
            let h = hstack([icon, label], spacing: 10)
            icon.widthAnchor.constraint(equalToConstant: 22).isActive = true
            h.pinCentered(to: cell, leading: 14, trailing: 8)
        }
        return cell
    }

    private var lastSelectedRow = -1

    func tableViewSelectionDidChange(_ notification: Notification) {
        // odświeżamy tylko poprzedni i bieżący wiersz, bo zmieniają kolor tekstu i ikony
        if Prefs.shared.modernUI {
            let current = table.selectedRow
            var idx = IndexSet()
            if lastSelectedRow >= 0, lastSelectedRow < rows.count { idx.insert(lastSelectedRow) }
            if current >= 0 { idx.insert(current) }
            lastSelectedRow = current
            if !idx.isEmpty {
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.table.reloadData(forRowIndexes: idx, columnIndexes: IndexSet(integer: 0))
                }
            }
        }
        guard !suppress, table.selectedRow >= 0, case .item(let it) = rows[table.selectedRow] else { return }
        onSelect?(it.page)
    }

    /// Indeks strony ustawień podawany z zewnątrz (okno zna kolejność stron)
    var settingsPage = -1
    @objc private func showSettings(_ sender: NSButton) { onSelect?(settingsPage) }

    /// Panel kolorów otwierany przy wierszu na dole paska
    func showColorsPopover(relativeTo view: NSView) { ColorsPopoverController.shared.show(relativeTo: view) }

    /// Otwiera panel kolorów z menu (Widok → Kolory…)
    func presentColorsPopover() {
        if let row = actionRows.last { showColorsPopover(relativeTo: row) }
    }
}
