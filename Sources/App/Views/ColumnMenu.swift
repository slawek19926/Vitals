// ColumnMenu.swift - menu kontekstowe nagłówka tabeli: wybór widocznych kolumn (zapamiętywany między uruchomieniami)
import AppKit

final class ColumnMenu: NSObject, NSMenuDelegate {
    private weak var table: NSTableView?
    private let key: String
    private let locked: Set<String>
    private let defaultHidden: Set<String>
    /// Szerokości kolumn zapamiętane przy podpięciu – układ liczymy zawsze od nich, żeby nic się nie „kurczyło” z każdym przełączeniem
    private var defaultWidths: [String: CGFloat] = [:]
    /// Kontrolery trzymamy przy życiu tak długo, jak żyje tabela
    private static var instances: [ObjectIdentifier: ColumnMenu] = [:]

    /// Podpina menu do nagłówka tabeli.
    /// - Parameters:
    ///   - key: nazwa pod jaką zapisywany jest układ kolumn
    ///   - locked: kolumny, których nie można ukryć (np. nazwa)
    ///   - hiddenByDefault: kolumny domyślnie ukryte przy pierwszym uruchomieniu
    @discardableResult
    static func attach(to table: NSTableView, key: String, locked: [String] = [], hiddenByDefault: [String] = []) -> ColumnMenu {
        let m = ColumnMenu(table: table, key: key, locked: Set(locked), defaultHidden: Set(hiddenByDefault))
        instances[ObjectIdentifier(table)] = m
        return m
    }

    private init(table: NSTableView, key: String, locked: Set<String>, defaultHidden: Set<String>) {
        self.table = table
        self.key = key
        self.locked = locked
        self.defaultHidden = defaultHidden
        super.init()
        for c in table.tableColumns { defaultWidths[c.identifier.rawValue] = c.width }
        restore()
        DispatchQueue.main.async { [weak self] in self?.layoutColumns() }
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        table.headerView?.menu = menu
        // to samo menu pod prawym przyciskiem na pustym obszarze nagłówka i w rogu przewijania
        (table.enclosingScrollView?.documentView as? NSTableView)?.headerView?.menu = menu
    }

    // MARK: zapis układu
    private var defaultsKey: String { "columns.\(key)" }

    private func restore() {
        guard let table else { return }
        let saved = UserDefaults.standard.object(forKey: defaultsKey) as? [String]
        let hidden = Set(saved ?? Array(defaultHidden))
        for c in table.tableColumns where !locked.contains(c.identifier.rawValue) {
            c.isHidden = hidden.contains(c.identifier.rawValue)
        }
    }

    private func save() {
        guard let table else { return }
        let hidden = table.tableColumns.filter { $0.isHidden }.map { $0.identifier.rawValue }
        UserDefaults.standard.set(hidden, forKey: defaultsKey)
    }

    // MARK: menu
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard let table else { return }
        menu.removeAllItems()
        let header = NSMenuItem(title: L("Widoczne kolumny"), action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        for c in table.tableColumns {
            let title = (c.title.isEmpty ? c.identifier.rawValue : c.title)
            let item = NSMenuItem(title: title, action: #selector(toggle(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = c
            item.state = c.isHidden ? .off : .on
            // kolumny kluczowe zostają zawsze widoczne
            item.isEnabled = !locked.contains(c.identifier.rawValue)
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let all = menu.addItem(withTitle: L("Pokaż wszystkie kolumny"), action: #selector(showAll), keyEquivalent: "")
        all.target = self
        let reset = menu.addItem(withTitle: L("Przywróć domyślne"), action: #selector(resetLayout), keyEquivalent: "")
        reset.target = self
        let fit = menu.addItem(withTitle: L("Dopasuj szerokości do zawartości"), action: #selector(sizeToFit), keyEquivalent: "")
        fit.target = self
    }

    @objc private func toggle(_ sender: NSMenuItem) {
        guard let c = sender.representedObject as? NSTableColumn, !locked.contains(c.identifier.rawValue) else { return }
        c.isHidden.toggle()
        save()
        layoutColumns()
    }

    @objc private func showAll() {
        table?.tableColumns.forEach { $0.isHidden = false }
        save()
        layoutColumns()
    }

    @objc private func resetLayout() {
        guard let table else { return }
        for c in table.tableColumns {
            c.isHidden = defaultHidden.contains(c.identifier.rawValue)
            if let w = defaultWidths[c.identifier.rawValue] { c.width = w }
        }
        UserDefaults.standard.removeObject(forKey: defaultsKey)
        layoutColumns()
    }

    /// Rozkłada szerokości tak, aby widoczne kolumny dokładnie wypełniły okno.
    /// Liczy zawsze od szerokości wyjściowych, więc ukrycie i ponowne pokazanie kolumny wraca do tego samego układu.
    private func layoutColumns() {
        guard let table, let scroll = table.enclosingScrollView else { return }
        let visible = table.tableColumns.filter { !$0.isHidden }
        guard !visible.isEmpty else { return }
        let spacing = table.intercellSpacing.width * CGFloat(max(0, visible.count - 1))
        let available = scroll.contentView.bounds.width - spacing
        guard available > 100 else { return }
        let base = visible.map { defaultWidths[$0.identifier.rawValue] ?? $0.width }
        let total = base.reduce(0, +)
        guard total > 0 else { return }
        let scale = available / total
        for (c, w) in zip(visible, base) { c.width = max(c.minWidth, floor(w * scale)) }
        table.sizeLastColumnToFit()
        // po zmianie układu wracamy na początek, żeby żadna kolumna nie została poza widokiem
        scroll.contentView.scroll(to: NSPoint(x: 0, y: scroll.contentView.bounds.origin.y))
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    @objc private func sizeToFit() {
        guard let table else { return }
        table.sizeToFit()
        for c in table.tableColumns where !c.isHidden {
            var w = c.headerCell.cellSize.width + 16
            for row in 0..<min(table.numberOfRows, 200) {
                guard let cell = table.view(atColumn: table.column(withIdentifier: c.identifier), row: row, makeIfNecessary: false) else { continue }
                w = max(w, cell.fittingSize.width + 12)
            }
            c.width = min(max(w, c.minWidth), 600)
        }
    }
}
