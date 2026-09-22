// StartupViewController.swift - „Elementy startowe”: agenty i demony launchd (użytkownika i systemowe) oraz elementy logowania
import AppKit

struct StartupItem {
    enum Kind: String { case userAgent = "Agent użytkownika", systemAgent = "Agent systemowy", daemon = "Demon systemowy", loginItem = "Element logowania" }
    let label: String
    let kind: Kind
    let path: String            // plist lub ścieżka aplikacji
    let program: String
    let arguments: [String]
    let runAtLoad: Bool
    let keepAlive: Bool
    var enabled: Bool
    var running: Int?           // PID jeśli działa
}

final class StartupViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, PageRefreshable {
    private let table = NSTableView()
    private let search = NSSearchField()
    private let countLabel = Label.make("", size: 11, dim: true)
    private let details = CardView()
    private let dTitle = Label.make(L("Wybierz pozycję, aby zobaczyć szczegóły."), size: 13.5, weight: .semibold)
    private var dRows: [String: NSTextField] = [:]
    private let revealButton = NSButton(title: L("Pokaż w Finderze"), target: nil, action: nil)
    private var all: [StartupItem] = []
    private var rows: [StartupItem] = []
    private var loading = false
    private var lastLoad = Date.distantPast

    override func loadView() {
        view = NSView()
        let title = PageTitleView(L("Elementy startowe"))
        search.placeholderString = L("Filtruj elementy startowe"); search.font = Fonts.ui(11.5); search.size(width: 260)
        search.target = self; search.action = #selector(filterChanged); search.sendsSearchStringImmediately = true
        let refresh = NSButton(title: L("Odśwież"), target: self, action: #selector(reload))
        refresh.bezelStyle = .rounded; refresh.controlSize = .small; refresh.font = Fonts.ui(11.5)
        title.accessory = hstack([countLabel, search, refresh], spacing: 8)

        for (id, t, w) in [("enabled", "Włączony", 70), ("name", "Nazwa", 300), ("kind", "Rodzaj", 140), ("state", "Stan", 90), ("command", "Polecenie", 500)] {
            let c = NSTableColumn(identifier: .init(id)); c.title = L(t); c.width = CGFloat(w); c.minWidth = 50
            if id != "enabled" { c.sortDescriptorPrototype = NSSortDescriptor(key: id, ascending: true) }
            table.addTableColumn(c)
        }
        table.sortDescriptors = [NSSortDescriptor(key: "name", ascending: true)]
        table.rowHeight = 24
        table.intercellSpacing = NSSize(width: 8, height: 1)
        table.backgroundColor = .clear
        table.style = .plain
        table.focusRingType = .none
        table.dataSource = self; table.delegate = self
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        // prawy przycisk na nagłówku: wybór widocznych kolumn
        ColumnMenu.attach(to: table, key: "startup", locked: ["name"])
        table.target = self; table.doubleAction = #selector(reveal)
        let scroll = NSScrollView(); scroll.documentView = table; scroll.drawsBackground = false; scroll.hasVerticalScroller = true; scroll.scrollerStyle = .overlay; scroll.autohidesScrollers = true
        scroll.setContentHuggingPriority(.init(1), for: .vertical)

        var kv: [NSView] = [dTitle]
        for k in ["Etykieta", "Rodzaj", "Program", "Argumenty", "Uruchamianie przy starcie", "Utrzymywanie (KeepAlive)", "Stan", "Plik"] {
            let row = KeyValueRow(k, "—", keyWidth: 170); dRows[k] = row.valueLabel; kv.append(row)
        }
        revealButton.bezelStyle = .rounded; revealButton.controlSize = .small; revealButton.font = Fonts.ui(11.5)
        revealButton.target = self; revealButton.action = #selector(reveal); revealButton.isEnabled = false
        kv.append(revealButton)
        let dv = vstack(kv, spacing: 3)
        dv.setCustomSpacing(8, after: dTitle)
        dv.pin(to: details, insets: NSEdgeInsets(top: 10, left: 14, bottom: 10, right: 14))
        details.size(height: 240)

        let root = vstack([title, scroll, details], spacing: 8)
        for v in [title, scroll, details] { v.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true }
        root.pin(to: view, insets: NSEdgeInsets(top: 2, left: 18, bottom: 10, right: 18))
        NotificationCenter.default.addObserver(forName: .themeChanged, object: nil, queue: .main) { [weak self] _ in self?.table.reloadData() }
    }

    func pageDidAppear() { if Date().timeIntervalSince(lastLoad) > 30 { reload() } }

    @objc private func reload() {
        guard !loading else { return }
        loading = true
        countLabel.stringValue = L("ładowanie…")
        let uid = getuid()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var items: [StartupItem] = []
            let home = NSHomeDirectory()
            let dirs: [(String, StartupItem.Kind)] = [
                ("\(home)/Library/LaunchAgents", .userAgent), ("/Library/LaunchAgents", .systemAgent), ("/Library/LaunchDaemons", .daemon),
            ]
            // stany z launchctl
            let disabledUser = Self.disabledLabels(Shell.run("/bin/launchctl", ["print-disabled", "gui/\(uid)"]))
            let disabledSystem = Self.disabledLabels(Shell.run("/bin/launchctl", ["print-disabled", "system"]))
            var running: [String: Int] = [:]
            for dom in ["system", "gui/\(uid)", "user/\(uid)"] {
                for s in ServicesViewController.parsePrint(Shell.run("/bin/launchctl", ["print", dom]), domain: dom) where s.pid != nil { running[s.label] = s.pid }
            }
            for (dir, kind) in dirs {
                guard let files = try? FileManager.default.contentsOfDirectory(atPath: dir) else { continue }
                for f in files where f.hasSuffix(".plist") {
                    let path = dir + "/" + f
                    guard let data = FileManager.default.contents(atPath: path),
                          let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { continue }
                    let label = (plist["Label"] as? String) ?? String(f.dropLast(6))
                    var args = plist["ProgramArguments"] as? [String] ?? []
                    var program = plist["Program"] as? String ?? args.first ?? ""
                    if program.isEmpty, let a = args.first { program = a }
                    if !args.isEmpty { args.removeFirst() }
                    let disabledKey = plist["Disabled"] as? Bool ?? false
                    let disabledDom = kind == .daemon ? disabledSystem : disabledUser
                    let keepAlive: Bool = (plist["KeepAlive"] as? Bool) ?? (plist["KeepAlive"] != nil)
                    items.append(StartupItem(label: label, kind: kind, path: path, program: program, arguments: args,
                                             runAtLoad: plist["RunAtLoad"] as? Bool ?? false, keepAlive: keepAlive,
                                             enabled: !(disabledKey || disabledDom.contains(label)), running: running[label]))
                }
            }
            // elementy logowania (System Events)
            let li = Shell.run("/usr/bin/osascript", ["-e", "tell application \"System Events\" to get {name, path, hidden} of every login item"], timeout: 10)
            let parts = li.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: ", ")
            if parts.count >= 3, parts.count % 3 == 0 {
                let n = parts.count / 3
                for i in 0..<n {
                    let name = parts[i]
                    var path = parts[n + i]
                    if path == "missing value" { path = "" }
                    items.append(StartupItem(label: name, kind: .loginItem, path: path, program: path, arguments: [], runAtLoad: true, keepAlive: false, enabled: true,
                                             running: NSWorkspace.shared.runningApplications.first { $0.bundleURL?.path == path }.map { Int($0.processIdentifier) }))
                }
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.all = items; self.loading = false; self.lastLoad = Date(); self.rebuild()
            }
        }
    }

    /// launchctl print-disabled: linie "\"label\" => disabled"
    static func disabledLabels(_ out: String) -> Set<String> {
        var set = Set<String>()
        for line in out.split(separator: "\n") where line.contains("=> disabled") || line.contains("=> true") {
            if let q1 = line.firstIndex(of: "\""), let q2 = line[line.index(after: q1)...].firstIndex(of: "\"") {
                set.insert(String(line[line.index(after: q1)..<q2]))
            }
        }
        return set
    }

    @objc private func filterChanged() { rebuild() }

    private var sortKey = "name", sortAsc = true
    private func rebuild() {
        let f = search.stringValue.lowercased()
        rows = all.filter { f.isEmpty || $0.label.lowercased().contains(f) || $0.program.lowercased().contains(f) || $0.path.lowercased().contains(f) }
        rows.sort { a, b in
            let r: Bool
            switch sortKey {
            case "kind": r = a.kind.rawValue < b.kind.rawValue
            case "state": r = (a.running ?? -1) < (b.running ?? -1)
            case "command": r = a.path < b.path
            default: r = a.label.localizedCaseInsensitiveCompare(b.label) == .orderedAscending
            }
            return sortAsc ? r : !r
        }
        countLabel.stringValue = "\(rows.count) " + L("elementów") + " · " + L("działa") + " \(all.filter { $0.running != nil }.count)"
        table.reloadData()
        updateDetails()
    }

    private var selected: StartupItem? { table.selectedRow >= 0 && table.selectedRow < rows.count ? rows[table.selectedRow] : nil }

    private func updateDetails() {
        guard let it = selected else {
            dTitle.stringValue = L("Wybierz pozycję, aby zobaczyć szczegóły.")
            for v in dRows.values { v.stringValue = L("—") }
            revealButton.isEnabled = false
            return
        }
        revealButton.isEnabled = true
        dTitle.stringValue = it.label
        dRows["Etykieta"]?.stringValue = it.label
        dRows["Rodzaj"]?.stringValue = it.kind.rawValue
        dRows["Program"]?.stringValue = it.program.isEmpty ? L("—") : it.program
        dRows["Argumenty"]?.stringValue = it.arguments.isEmpty ? L("—") : it.arguments.joined(separator: " ")
        dRows["Uruchamianie przy starcie"]?.stringValue = it.runAtLoad ? L("tak (RunAtLoad)") : L("na żądanie")
        dRows["Utrzymywanie (KeepAlive)"]?.stringValue = it.keepAlive ? L("tak") : L("nie")
        dRows["Stan"]?.stringValue = it.running.map { L("działa") + " (PID \($0))" } ?? (it.enabled ? L("włączony, nie działa") : L("wyłączony"))
        dRows["Plik"]?.stringValue = it.path
    }

    @objc private func reveal() {
        guard let it = selected else { return }
        NSWorkspace.shared.selectFile(it.path, inFileViewerRootedAtPath: "")
    }

    @objc private func toggle(_ sender: NSButton) {
        let row = sender.tag
        guard row >= 0, row < rows.count else { return }
        let it = rows[row]
        guard it.kind != .loginItem, it.kind != .daemon else {
            let a = NSAlert()
            a.messageText = it.kind == .daemon ? L("Demony systemowe wymagają uprawnień administratora") : L("Elementy logowania zarządza się w Ustawieniach systemowych")
            a.informativeText = it.kind == .daemon ? L("Użyj") + ": sudo launchctl \(it.enabled ? "disable" : "enable") system/\(it.label)" : L("Ustawienia systemowe → Ogólne → Elementy logowania i rozszerzenia.")
            a.runModal(); sender.state = it.enabled ? .on : .off; return
        }
        let uid = getuid()
        let enable = sender.state == .on
        DispatchQueue.global().async { [weak self] in
            let commands = enable
                ? [["enable", "gui/\(uid)/\(it.label)"], ["bootstrap", "gui/\(uid)", it.path]]
                : [["bootout", "gui/\(uid)/\(it.label)"], ["disable", "gui/\(uid)/\(it.label)"]]
            var failure: String?
            for arguments in commands {
                let result = Shell.execute("/bin/launchctl", arguments)
                if let error = result.failureDescription { failure = error; break }
            }
            DispatchQueue.main.async {
                if let failure {
                    let alert = NSAlert(); alert.messageText = L("Nie udało się wykonać operacji")
                    alert.informativeText = failure; alert.runModal()
                }
                self?.lastLoad = .distantPast; self?.reload()
            }
        }
    }

    // MARK: tabela
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { let r = ThemedRowView(); r.inset = 0; r.zebra = row % 2 == 1; return r }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let col = tableColumn else { return nil }
        let it = rows[row]
        let cell = NSTableCellView()
        switch col.identifier.rawValue {
        case "enabled":
            let cb = NSButton(checkboxWithTitle: "", target: self, action: #selector(toggle(_:)))
            cb.state = it.enabled ? .on : .off; cb.tag = row; cb.controlSize = .small
            cb.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(cb)
            NSLayoutConstraint.activate([cb.centerXAnchor.constraint(equalTo: cell.centerXAnchor), cb.centerYAnchor.constraint(equalTo: cell.centerYAnchor)])
        case "kind": Label.make(it.kind.rawValue, size: 11.5, dim: true).pinCentered(to: cell, leading: 2, trailing: 4)
        case "state":
            let l = Label.make(it.running != nil ? L("działa") : (it.enabled ? L("gotowy") : L("wyłączony")), size: 11.5)
            l.textColor = it.running != nil ? P.good : (it.enabled ? P.textDim : P.warn)
            l.pinCentered(to: cell, leading: 2, trailing: 4)
        case "command": Label.make(it.path.isEmpty ? L("(element logowania bez ścieżki)") : it.path, size: 11.5, dim: true).pinCentered(to: cell, leading: 2, trailing: 4)
        default:
            let l = Label.make(it.label, size: 11.5, dim: !it.enabled)
            let iv = NSImageView(); iv.size(width: 14, height: 14)
            if it.kind == .loginItem, !it.path.isEmpty { let img = NSWorkspace.shared.icon(forFile: it.path); img.size = NSSize(width: 14, height: 14); iv.image = img }
            else if it.kind == .loginItem { iv.image = NSImage(systemSymbolName: "app.dashed", accessibilityDescription: nil); iv.contentTintColor = P.textDim }
            else { iv.image = NSImage(systemSymbolName: it.kind == .daemon ? "gearshape.2" : "gearshape", accessibilityDescription: nil); iv.contentTintColor = P.textDim }
            hstack([iv, l], spacing: 6).pinCentered(to: cell, leading: 2, trailing: 2)
        }
        return cell
    }
    func tableViewSelectionDidChange(_ notification: Notification) { updateDetails() }
    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        guard let d = tableView.sortDescriptors.first, let k = d.key else { return }
        sortKey = k; sortAsc = d.ascending; rebuild()
    }
}
