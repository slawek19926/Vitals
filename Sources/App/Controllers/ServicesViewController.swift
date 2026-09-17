// ServicesViewController.swift - strona „Usługi”: usługi launchd (domena systemowa, użytkownika i GUI)
import AppKit
import HelperKit

struct ServiceInfo {
    let label: String
    let pid: Int?        // nil = nie działa
    let status: Int?     // ostatni kod wyjścia (jeśli liczbowy)
    let flags: String    // np. "(pe)" = zablokowana przez bezpieczeństwo
    let domain: String
}

final class ServicesViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate, PageRefreshable {
    private let table = NSTableView()
    private let search = NSSearchField()
    private let domainPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let onlyRunning = NSButton(checkboxWithTitle: L("Tylko działające"), target: nil, action: nil)
    private let refresh = NSButton(title: L("Odśwież"), target: nil, action: nil)
    private let countLabel = Label.make("", size: 11, dim: true)
    private let detailText = NSTextView()
    private let details = CardView()
    private var all: [ServiceInfo] = []
    private var rows: [ServiceInfo] = []
    private var sortKey = "label"
    private var sortAsc = true
    private var lastLoad = Date.distantPast
    private var loading = false

    override func loadView() {
        view = NSView()
        let title = PageTitleView(L("Usługi"))
        domainPopup.addItems(withTitles: ["Wszystkie domeny", "Systemowa (root)", "Użytkownika", "GUI (sesja)"].map { L($0) })
        domainPopup.target = self; domainPopup.action = #selector(filterChanged); domainPopup.font = Fonts.ui(12)
        search.placeholderString = L("Filtruj etykietę")
        search.target = self; search.action = #selector(filterChanged); search.sendsSearchStringImmediately = true
        search.font = Fonts.ui(12); search.size(width: 240)
        onlyRunning.target = self; onlyRunning.action = #selector(filterChanged); onlyRunning.font = Fonts.ui(12)
        refresh.bezelStyle = .rounded; refresh.controlSize = .small; refresh.font = Fonts.ui(12)
        refresh.target = self; refresh.action = #selector(reload)
        title.accessory = hstack([countLabel, domainPopup, onlyRunning, search, refresh], spacing: 8)

        for (id, t, w) in [("label", "Etykieta", 460), ("pid", "PID", 70), ("status", "Status", 140), ("domain", "Domena", 130)] {
            let c = NSTableColumn(identifier: .init(id)); c.title = L(t); c.width = CGFloat(w); c.minWidth = 50
            c.sortDescriptorPrototype = NSSortDescriptor(key: id, ascending: id != "pid")
            if id == "pid" { c.headerCell.alignment = .right }
            table.addTableColumn(c)
        }
        table.sortDescriptors = [NSSortDescriptor(key: "label", ascending: true)]
        table.rowHeight = 22
        table.intercellSpacing = NSSize(width: 8, height: 1)
        table.backgroundColor = .clear
        table.style = .plain
        table.focusRingType = .none
        table.dataSource = self; table.delegate = self
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        // prawy przycisk na nagłówku: wybór widocznych kolumn
        ColumnMenu.attach(to: table, key: "services", locked: ["label"])
        table.menu = buildActionMenu()
        let scroll = NSScrollView()
        scroll.documentView = table; scroll.drawsBackground = false; scroll.hasVerticalScroller = true; scroll.scrollerStyle = .overlay; scroll.autohidesScrollers = true
        scroll.setContentHuggingPriority(.init(1), for: .vertical)

        detailText.isEditable = false
        detailText.drawsBackground = false
        detailText.font = Fonts.mono(11)
        detailText.textContainerInset = NSSize(width: 6, height: 6)
        let dScroll = NSScrollView()
        dScroll.documentView = detailText; dScroll.drawsBackground = false; dScroll.hasVerticalScroller = true; dScroll.scrollerStyle = .overlay; dScroll.autohidesScrollers = true
        detailText.autoresizingMask = [.width]
        detailText.isVerticallyResizable = true
        detailText.textContainer?.widthTracksTextView = true
        dScroll.pin(to: details, insets: NSEdgeInsets(top: 6, left: 6, bottom: 6, right: 6))
        details.size(height: 170)

        let root = vstack([title, scroll, details], spacing: 8)
        for v in [title, scroll, details] { v.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true }
        root.pin(to: view, insets: NSEdgeInsets(top: 2, left: 18, bottom: 10, right: 18))
        NotificationCenter.default.addObserver(forName: .themeChanged, object: nil, queue: .main) { [weak self] _ in
            self?.table.reloadData(); self?.detailText.textColor = P.text; self?.countLabel.textColor = P.textDim
        }
        detailText.string = L("Wybierz usługę, aby zobaczyć szczegóły (launchctl print).")
        detailText.textColor = P.textDim
    }

    func pageDidAppear() {
        if Date().timeIntervalSince(lastLoad) > 30 { reload() }
    }

    @objc private func reload() {
        guard !loading else { return }
        loading = true
        countLabel.stringValue = L("ładowanie…")
        let uid = getuid()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var list: [ServiceInfo] = []
            list += Self.parsePrint(Shell.run("/bin/launchctl", ["print", "system"]), domain: "system")
            list += Self.parsePrint(Shell.run("/bin/launchctl", ["print", "user/\(uid)"]), domain: "user")
            list += Self.parsePrint(Shell.run("/bin/launchctl", ["print", "gui/\(uid)"]), domain: "gui")
            DispatchQueue.main.async {
                guard let self else { return }
                self.all = list
                self.loading = false
                self.lastLoad = Date()
                self.rebuild()
            }
        }
    }

    /// Parsuje blok "services = { ... }" z wyjścia launchctl print
    static func parsePrint(_ out: String, domain: String) -> [ServiceInfo] {
        var result: [ServiceInfo] = []
        var inServices = false
        for raw in out.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("services = {") { inServices = true; continue }
            if inServices {
                if line == "}" { break }
                // format: "<pid lub 0>  <status: - | kod | (pe)>  <etykieta>"
                let cols = line.split(whereSeparator: { $0 == "\t" || $0 == " " }).map(String.init)
                guard cols.count >= 3 else { continue }
                let pidRaw = Int(cols[0]) ?? 0
                let pid: Int? = pidRaw > 0 ? pidRaw : nil
                let status = Int(cols[1])
                let flags = cols[1].hasPrefix("(") ? cols[1] : ""
                let label = cols[2...].joined(separator: " ")
                result.append(ServiceInfo(label: label, pid: pid, status: status, flags: flags, domain: domain))
            }
        }
        return result
    }

    @objc private func filterChanged() { rebuild() }

    private func rebuild() {
        let f = search.stringValue.lowercased()
        let dom = ["", "system", "user", "gui"][domainPopup.indexOfSelectedItem]
        rows = all.filter { s in
            if !dom.isEmpty && s.domain != dom { return false }
            if onlyRunning.state == .on && s.pid == nil { return false }
            return f.isEmpty || s.label.lowercased().contains(f)
        }
        rows.sort { a, b in
            let r: Bool
            switch sortKey {
            case "pid": r = (a.pid ?? -1) < (b.pid ?? -1)
            case "status": r = (a.status ?? 0) < (b.status ?? 0)
            case "domain": r = a.domain < b.domain
            default: r = a.label.localizedCaseInsensitiveCompare(b.label) == .orderedAscending
            }
            return sortAsc ? r : !r
        }
        let running = all.filter { $0.pid != nil }.count
        countLabel.stringValue = "\(rows.count) " + L("z") + " \(all.count) " + L("usług") + " · " + L("działa") + " \(running)"
        table.reloadData()
    }

    private func statusText(_ s: ServiceInfo) -> String {
        if s.pid != nil { return L("działa") }
        if s.flags == "(pe)" { return L("wyłączona przez system") }
        if !s.flags.isEmpty { return s.flags }
        guard let st = s.status else { return L("nie działa") }
        if st == 0 { return L("zakończona (0)") }
        if st < 0 { return L("sygnał") + " \(-st)" }
        if st == 78 { return L("błąd konfiguracji (78)") }
        return L("kod wyjścia") + " \(st)"
    }

    // MARK: tabela
    /// Menu akcji dla zaznaczonej usługi; operacje idą przez pomocnika uprzywilejowanego
    private func buildActionMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self
        for action in ServiceAction.allCases {
            let item = NSMenuItem(title: L(action.title), action: #selector(runServiceAction(_:)), keyEquivalent: "")
            item.representedObject = action.rawValue
            item.target = self
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let plist = NSMenuItem(title: L("Pokaż plik konfiguracyjny w Finderze"), action: #selector(revealPlist), keyEquivalent: "")
        plist.target = self
        menu.addItem(plist)
        let copy = NSMenuItem(title: L("Kopiuj etykietę"), action: #selector(copyLabel), keyEquivalent: "")
        copy.target = self
        menu.addItem(copy)
        return menu
    }

    /// Usługa, której dotyczy menu: klikniętą w tabeli albo zaznaczona
    private var targetService: ServiceInfo? {
        let row = table.clickedRow >= 0 ? table.clickedRow : table.selectedRow
        guard row >= 0, row < rows.count else { return nil }
        return rows[row]
    }

    private func launchctlDomain(_ s: ServiceInfo) -> String {
        switch s.domain {
        case "system": return "system"
        case "user": return "user/\(getuid())"
        default: return "gui/\(getuid())"
        }
    }

    @objc private func runServiceAction(_ sender: NSMenuItem) {
        guard let svc = targetService,
              let raw = sender.representedObject as? String,
              let action = ServiceAction(rawValue: raw) else { return }
        let confirm = NSAlert()
        confirm.messageText = "\(L(action.title)): \(svc.label)?"
        confirm.informativeText = L("Operacja zostanie wykonana przez pomocnika uprzywilejowanego w domenie") + " \(launchctlDomain(svc))."
        confirm.addButton(withTitle: L(action.title))
        confirm.addButton(withTitle: L("Anuluj"))
        guard confirm.runModal() == .alertFirstButtonReturn else { return }

        let domain = launchctlDomain(svc)
        let label = svc.label
        DispatchQueue.global(qos: .userInitiated).async {
            let error: String?
            if Monitor.isRoot {
                let out = Shell.run("/bin/launchctl", action.arguments(domain: domain, label: label), timeout: 10)
                error = out.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : out
            } else {
                error = HelperClient.shared.serviceAction(action, domain: domain, label: label)
            }
            DispatchQueue.main.async { [weak self] in
                if let error {
                    let a = NSAlert()
                    a.messageText = L("Nie udało się wykonać operacji")
                    a.informativeText = error
                    a.addButton(withTitle: "OK")
                    a.runModal()
                }
                self?.reload()
            }
        }
    }

    @objc private func revealPlist() {
        guard let svc = targetService else { return }
        let dirs = ["/Library/LaunchDaemons", "/Library/LaunchAgents", "/System/Library/LaunchDaemons",
                    "/System/Library/LaunchAgents", NSHomeDirectory() + "/Library/LaunchAgents"]
        for dir in dirs {
            let path = dir + "/" + svc.label + ".plist"
            if FileManager.default.fileExists(atPath: path) {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                return
            }
        }
        let a = NSAlert()
        a.messageText = L("Nie znaleziono pliku konfiguracyjnego")
        a.informativeText = L("Usługa") + " \(svc.label) " + L("nie ma pliku .plist w standardowych katalogach. Może być wbudowana w system.")
        a.addButton(withTitle: "OK")
        a.runModal()
    }

    @objc private func copyLabel() {
        guard let svc = targetService else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(svc.label, forType: .string)
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { let r = ThemedRowView(); r.inset = 0; r.zebra = row % 2 == 1; return r }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let col = tableColumn else { return nil }
        let s = rows[row]
        let cell = NSTableCellView()
        let l: NSTextField
        switch col.identifier.rawValue {
        case "pid": l = Label.make(s.pid.map { "\($0)" } ?? "—", size: 11.5, dim: s.pid == nil, mono: true); l.alignment = .right
        case "status":
            l = Label.make(statusText(s), size: 11.5)
            l.textColor = s.pid != nil ? P.good : ((s.status ?? 0) == 0 ? P.textDim : P.warn)
        case "domain": l = Label.make(L(["system": "systemowa", "user": "użytkownika", "gui": "GUI"][s.domain] ?? s.domain), size: 11.5, dim: true)
        default: l = Label.make(s.label, size: 11.5, dim: s.pid == nil)
        }
        l.pinCentered(to: cell, leading: 2, trailing: 4)
        return cell
    }
    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        guard let d = tableView.sortDescriptors.first, let k = d.key else { return }
        sortKey = k; sortAsc = d.ascending; rebuild()
    }
    func tableViewSelectionDidChange(_ notification: Notification) {
        let r = table.selectedRow
        guard r >= 0, r < rows.count else { return }
        let s = rows[r]
        let target = s.domain == "system" ? "system/\(s.label)" : "\(s.domain)/\(getuid())/\(s.label)"
        detailText.string = L("Ładowanie…")
        detailText.textColor = P.textDim
        Shell.async("/bin/launchctl", ["print", target], timeout: 10) { [weak self] out in
            guard let self, self.table.selectedRow == r else { return }
            self.detailText.string = out.isEmpty ? L("Brak szczegółów") + " (launchctl print \(target))." : out
            self.detailText.textColor = P.text
        }
    }
}
