// UsersViewController.swift - „Użytkownicy” jak w TMOG: drzewo kont z ich procesami (CPU, pamięć, PID)
// oraz panel szczegółów: konto, sesja i najaktywniejsze procesy.
import AppKit

struct UserAccount {
    var name: String
    var uid: Int
    var fullName = ""
    var home = ""
    var shell = ""
    var group = ""
    var isAdmin = false
    var sessions: [String] = []
    var loggedIn: Bool { !sessions.isEmpty }
    var isSystem: Bool { uid < 500 && name != "root" }
}

/// Proces w drzewie użytkownika (klasa, żeby zachować tożsamość wiersza między odświeżeniami)
final class UserProcess {
    let pid: Int
    var info: ProcInfo
    init(_ p: ProcInfo) { pid = p.pid; info = p }
}

/// Węzeł drzewa: konto użytkownika z bieżącymi procesami
final class UserNode {
    var account: UserAccount
    var processes: [UserProcess] = []
    private var byPID: [Int: UserProcess] = [:]
    var cpu: Double = 0
    var memory: UInt64 = 0
    private var lastSort = Date.distantPast
    init(_ a: UserAccount) { account = a }

    /// Aktualizuje listę procesów, zachowując obiekty dla tych samych PID-ów
    func update(with procs: [ProcInfo]) {
        var next: [UserProcess] = []
        var map: [Int: UserProcess] = [:]
        for p in procs {
            let node = byPID[p.pid] ?? UserProcess(p)
            node.info = p
            map[p.pid] = node
            next.append(node)
        }
        byPID = map
        // kolejność odświeżamy co 5 s – inaczej wiersze przeskakują przy każdym pomiarze
        if Date().timeIntervalSince(lastSort) > 5 || processes.isEmpty {
            lastSort = Date()
            processes = next.sorted { $0.info.cpuPercent > $1.info.cpuPercent }
        } else {
            let order = Dictionary(uniqueKeysWithValues: processes.enumerated().map { ($0.element.pid, $0.offset) })
            processes = next.sorted { (order[$0.pid] ?? Int.max, $0.pid) < (order[$1.pid] ?? Int.max, $1.pid) }
        }
        cpu = procs.reduce(0) { $0 + $1.cpuPercent }
        memory = procs.reduce(0) { $0 + $1.memBytes }
    }
}

/// Komórka z paskiem w tle i wartością po prawej
final class MeterCell: NSView {
    var fraction: Double = 0 { didSet { needsDisplay = true } }
    var text = "" { didSet { needsDisplay = true } }
    var color: NSColor = .green
    var dim = false
    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 2, dy: 6)
        if fraction > 0.001 {
            color.alpha(0.28).setFill()
            NSBezierPath(roundedRect: NSRect(x: r.minX, y: r.minY, width: max(2, r.width * CGFloat(min(1, fraction))), height: r.height),
                         xRadius: 2, yRadius: 2).fill()
        }
        let a = NSAttributedString(string: text, attributes: [.font: Fonts.mono(11.5), .foregroundColor: dim ? P.textDim : P.text])
        let sz = a.size()
        a.draw(at: NSPoint(x: bounds.maxX - sz.width - 6, y: (bounds.height - sz.height) / 2))
    }
}

final class UsersViewController: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate, PageRefreshable {
    private let outline = NSOutlineView()
    private let search = NSSearchField()
    private let showSystem = NSButton(checkboxWithTitle: L("Konta systemowe"), target: nil, action: nil)
    private let countLabel = Label.make("", size: 11, dim: true)

    // panel szczegółów
    private let details = CardView()
    private let dFullName = Label.make(L("Wybierz użytkownika"), size: 17, weight: .semibold)
    private let dLogin = Label.make("", size: 12, dim: true, mono: true)
    private var dRows: [String: NSTextField] = [:]
    private let topStack = vstack([], spacing: 3)

    private var accounts: [UserAccount] = []
    private var nodes: [UserNode] = []
    private var nodeCache: [Int: UserNode] = [:]
    private var lastStructure = ""
    private var visible: [UserNode] = []
    private var selectedUID: Int?
    private var selectedPID: Int?
    private var restoringSelection = false
    private var loading = false
    private var lastLoad = Date.distantPast
    private var totalMemory: UInt64 = 1
    private var cores: Double = 1

    private static let accountKeys = ["UID", "Grupa", "Katalog domowy", "Powłoka", "Administrator"]
    private static let sessionKeys = ["Stan", "Procesy", "CPU", "Pamięć", "Sesje"]

    override func loadView() {
        view = NSView()
        let title = PageTitleView(L("Użytkownicy"))
        search.placeholderString = L("Filtruj użytkowników i procesy"); search.font = Fonts.ui(11.5); search.size(width: 250)
        search.target = self; search.action = #selector(filterChanged); search.sendsSearchStringImmediately = true
        showSystem.target = self; showSystem.action = #selector(filterChanged); showSystem.font = Fonts.ui(11.5)
        let refresh = NSButton(title: L("Odśwież"), target: self, action: #selector(reload))
        refresh.bezelStyle = .rounded; refresh.controlSize = .small; refresh.font = Fonts.ui(11.5)
        title.accessory = hstack([countLabel, showSystem, search, refresh], spacing: 10)

        for (id, t, w) in [("user", "Użytkownik", 300), ("state", "Stan", 110), ("procs", "Procesy", 90),
                           ("cpu", "CPU", 120), ("mem", "Pamięć", 120), ("pid", "PID", 70)] {
            let c = NSTableColumn(identifier: .init(id)); c.title = L(t); c.width = CGFloat(w); c.minWidth = 50
            if id == "procs" || id == "pid" { c.headerCell.alignment = .right }
            outline.addTableColumn(c)
        }
        outline.outlineTableColumn = outline.tableColumns[0]
        outline.rowHeight = 26
        outline.intercellSpacing = NSSize(width: 8, height: 1)
        outline.backgroundColor = .clear
        outline.style = .plain
        outline.focusRingType = .none
        outline.indentationPerLevel = 16
        outline.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        // prawy przycisk na nagłówku: wybór widocznych kolumn
        ColumnMenu.attach(to: outline, key: "users", locked: ["user"])
        outline.dataSource = self; outline.delegate = self
        let scroll = NSScrollView(); scroll.documentView = outline; scroll.drawsBackground = false; scroll.hasVerticalScroller = true; scroll.scrollerStyle = .overlay; scroll.autohidesScrollers = true
        scroll.setContentHuggingPriority(.init(1), for: .vertical)

        // dół: konto / sesja / najaktywniejsze procesy (układ jak w TMOG)
        func column(_ header: String, _ keys: [String]) -> NSView {
            var items: [NSView] = [Label.make(header, size: 10.5, weight: .semibold, dim: true)]
            for k in keys {
                let row = KeyValueRow(k, "—", keyWidth: 120)
                row.valueLabel.font = Fonts.ui(11.5)
                dRows[k] = row.valueLabel
                items.append(row)
            }
            return vstack(items, spacing: 2)
        }
        let topCol = vstack([Label.make(L("NAJAKTYWNIEJSZE PROCESY"), size: 10.5, weight: .semibold, dim: true), topStack], spacing: 4)
        let columns = hstack([column("KONTO", Self.accountKeys), column("SESJA", Self.sessionKeys), topCol],
                             spacing: 28, alignment: .top, distribution: .fillEqually)
        let dv = vstack([dFullName, dLogin, columns], spacing: 3)
        dv.setCustomSpacing(10, after: dLogin)
        dv.pin(to: details, insets: NSEdgeInsets(top: 12, left: 16, bottom: 12, right: 16))
        details.size(height: 176)

        let root = vstack([title, scroll, details], spacing: 8)
        for v in [title, scroll, details] { v.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true }
        root.pin(to: view, insets: NSEdgeInsets(top: 2, left: 18, bottom: 10, right: 18))

        cores = Double(max(1, Monitor.shared.hardware.ncpu))
        NotificationCenter.default.addObserver(self, selector: #selector(snapshot(_:)), name: .snapshotUpdated, object: nil)
        NotificationCenter.default.addObserver(forName: .themeChanged, object: nil, queue: .main) { [weak self] _ in
            self?.outline.reloadData(); self?.updateDetails()
        }
        updateDetails()
    }

    func pageDidAppear() {
        if Date().timeIntervalSince(lastLoad) > 120 { reload() } else { apply(Monitor.shared.latest) }
    }

    // MARK: konta
    @objc private func reload() {
        guard !loading else { return }
        loading = true
        countLabel.stringValue = L("ładowanie…")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var users: [UserAccount] = []
            for line in Shell.run("/usr/bin/dscl", [".", "-list", "/Users", "UniqueID"]).split(separator: "\n") {
                let parts = line.split(separator: " ", omittingEmptySubsequences: true)
                guard parts.count >= 2, let uid = Int(parts.last!) else { continue }
                users.append(UserAccount(name: String(parts[0]), uid: uid))
            }
            let admins = Set(Shell.run("/usr/bin/dscl", [".", "-read", "/Groups/admin", "GroupMembership"])
                .replacingOccurrences(of: "GroupMembership:", with: "")
                .split(separator: " ").map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) })
            var sessions: [String: [String]] = [:]
            for line in Shell.run("/usr/bin/who", []).split(separator: "\n") {
                let p = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
                guard p.count >= 2 else { continue }
                sessions[p[0], default: []].append(p[1])
            }
            for i in users.indices {
                let u = users[i]
                users[i].isAdmin = admins.contains(u.name)
                users[i].sessions = sessions[u.name] ?? []
                if u.uid >= 500 || u.name == "root" {
                    let out = Shell.run("/usr/bin/dscl", [".", "-read", "/Users/\(u.name)", "RealName", "NFSHomeDirectory", "UserShell", "PrimaryGroupID"], timeout: 5)
                    users[i].fullName = Self.value("RealName", in: out)
                    users[i].home = Self.value("NFSHomeDirectory", in: out)
                    users[i].shell = Self.value("UserShell", in: out)
                    let gid = Self.value("PrimaryGroupID", in: out)
                    if let g = Int(gid) {
                        let gname = Shell.run("/usr/bin/dscl", [".", "-search", "/Groups", "PrimaryGroupID", "\(g)"], timeout: 5)
                            .split(separator: "\n").first?.split(separator: "\t").first.map(String.init) ?? ""
                        users[i].group = gname.isEmpty ? gid : "\(gname) (\(gid))"
                    }
                }
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.accounts = users
                self.loading = false
                self.lastLoad = Date()
                self.apply(Monitor.shared.latest)
            }
        }
    }

    static func value(_ key: String, in out: String) -> String {
        let lines = out.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        for (i, l) in lines.enumerated() where l.hasPrefix(key + ":") {
            let rest = l.dropFirst(key.count + 1).trimmingCharacters(in: .whitespaces)
            if !rest.isEmpty { return rest }
            if i + 1 < lines.count { return lines[i + 1].trimmingCharacters(in: .whitespaces) }
        }
        return ""
    }

    // MARK: dane na żywo
    @objc private func snapshot(_ n: Notification) {
        guard let s = n.object as? Snapshot, view.window != nil, !view.isHiddenOrHasHiddenAncestor else { return }
        apply(s)
    }

    private func apply(_ s: Snapshot) {
        totalMemory = max(1, s.mem.total)
        var byUID: [Int: [ProcInfo]] = [:]
        for p in s.processes { byUID[p.uid, default: []].append(p) }
        var known = Set(accounts.map { $0.uid })
        var list: [UserNode] = []
        func node(for a: UserAccount) -> UserNode {
            if let existing = nodeCache[a.uid] { existing.account = a; return existing }
            let n = UserNode(a); nodeCache[a.uid] = n; return n
        }
        for a in accounts {
            let n = node(for: a)
            n.update(with: byUID[a.uid] ?? [])
            list.append(n)
        }
        // konta widoczne tylko w tabeli procesów (np. _windowserver) też pokazujemy
        for (uid, procs) in byUID where !known.contains(uid) {
            known.insert(uid)
            let a = UserAccount(name: procs.first?.user ?? "uid \(uid)", uid: uid)
            let n = node(for: a)
            n.update(with: procs)
            list.append(n)
        }
        nodes = list
        rebuild()
    }

    @objc private func filterChanged() { rebuild() }

    private func rebuild() {
        let f = search.stringValue.lowercased()
        visible = nodes.filter { n in
            if !showSystem.state.isOn && n.account.isSystem && n.processes.isEmpty { return false }
            if !showSystem.state.isOn && n.account.isSystem && !n.account.loggedIn && n.account.uid < 500 && n.processes.isEmpty { return false }
            if f.isEmpty { return true }
            return n.account.name.lowercased().contains(f) || n.account.fullName.lowercased().contains(f)
                || n.processes.contains { $0.info.name.lowercased().contains(f) }
        }
        if !showSystem.state.isOn { visible = visible.filter { !$0.account.isSystem || !$0.processes.isEmpty } }
        visible.sort { a, b in
            if a.account.loggedIn != b.account.loggedIn { return a.account.loggedIn }
            if a.processes.isEmpty != b.processes.isEmpty { return !a.processes.isEmpty }
            return a.account.name.localizedCaseInsensitiveCompare(b.account.name) == .orderedAscending
        }
        let logged = nodes.filter { $0.account.loggedIn }.count
        countLabel.stringValue = "\(visible.count) kont · zalogowanych \(logged)"
        let structure = visible.map { n in "\(n.account.uid):\(n.processes.count)" }.joined(separator: ",")
        if structure != lastStructure {
            lastStructure = structure
            let expanded = Set(nodeCache.values.filter { outline.isItemExpanded($0) }.map { $0.account.uid })
            outline.reloadData()
            for n in visible where expanded.contains(n.account.uid) { outline.expandItem(n) }
        } else {
            // te same wiersze – odświeżamy tylko zawartość komórek
            outline.reloadData(forRowIndexes: IndexSet(integersIn: 0..<outline.numberOfRows),
                               columnIndexes: IndexSet(integersIn: 0..<outline.numberOfColumns))
        }
        restoreSelection()
        updateDetails()
    }

    /// Po przebudowie przywraca zaznaczenie – także wtedy, gdy zaznaczony był proces użytkownika
    private func restoreSelection() {
        var target: Any?
        if let pid = selectedPID {
            for n in visible {
                if let p = n.processes.first(where: { $0.pid == pid }) { target = p; break }
            }
        }
        if target == nil, let uid = selectedUID { target = visible.first { $0.account.uid == uid } }
        guard let item = target else { return }
        let row = outline.row(forItem: item)
        guard row >= 0, outline.selectedRow != row else { return }
        restoringSelection = true
        outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        restoringSelection = false
    }

    private var selectedNode: UserNode? {
        if let uid = selectedUID { return nodes.first { $0.account.uid == uid } }
        return nil
    }

    private func updateDetails() {
        topStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        guard let n = selectedNode else {
            dFullName.stringValue = L("Wybierz użytkownika")
            dFullName.textColor = P.text
            dLogin.stringValue = ""
            for v in dRows.values { v.stringValue = L("—") }
            return
        }
        let a = n.account
        dFullName.stringValue = a.fullName.isEmpty ? a.name : a.fullName
        dFullName.textColor = P.text
        dLogin.stringValue = a.name
        dLogin.textColor = P.textDim
        dRows["UID"]?.stringValue = "\(a.uid)"
        dRows["Grupa"]?.stringValue = a.group.isEmpty ? L("—") : a.group
        dRows["Katalog domowy"]?.stringValue = a.home.isEmpty ? L("—") : a.home
        dRows["Powłoka"]?.stringValue = a.shell.isEmpty ? L("—") : a.shell
        dRows["Administrator"]?.stringValue = a.isAdmin ? L("tak") : L("nie")
        dRows["Stan"]?.stringValue = a.loggedIn ? L("zalogowany") : (n.processes.isEmpty ? L("brak procesów") : L("aktywny (usługi)"))
        dRows["Procesy"]?.stringValue = "\(n.processes.count)"
        dRows["CPU"]?.stringValue = Fmt.percent(n.cpu)
        dRows["Pamięć"]?.stringValue = Fmt.bytes(n.memory)
        dRows["Sesje"]?.stringValue = a.sessions.isEmpty ? L("—") : a.sessions.joined(separator: ", ")
        for v in dRows.values { v.textColor = P.text }
        for up in n.processes.prefix(5) {
            let p = up.info
            let name = Label.make("\(p.name) (\(p.pid))", size: 11.5)
            name.lineBreakMode = .byTruncatingMiddle
            let val = Label.make(p.accessible ? "\(Fmt.percent(p.cpuPercent)) · \(Fmt.bytes(p.memBytes))" : "brak dostępu", size: 11.5, dim: !p.accessible, mono: true)
            let row = hstack([name, spacer(), val], spacing: 8)
            topStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: topStack.widthAnchor).isActive = true
        }
        if n.processes.isEmpty { topStack.addArrangedSubview(Label.make(L("brak uruchomionych procesów"), size: 11.5, dim: true)) }
    }

    // MARK: drzewo
    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if item == nil { return visible.count }
        return (item as? UserNode)?.processes.count ?? 0
    }
    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if item == nil { return visible[index] }
        return (item as! UserNode).processes[index]
    }
    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        !((item as? UserNode)?.processes.isEmpty ?? true)
    }
    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
        let r = ThemedRowView(); r.inset = 0; r.zebra = outlineView.row(forItem: item) % 2 == 1; return r
    }
    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool { true }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let col = tableColumn else { return nil }
        let cell = NSTableCellView()
        let id = col.identifier.rawValue

        if let n = item as? UserNode {
            let a = n.account
            switch id {
            case "user":
                let icon = symbol(a.isSystem ? "gearshape" : (a.loggedIn ? "person.crop.circle.fill" : "person.crop.circle"),
                                  size: 14, color: a.loggedIn ? P.network : P.textDim)
                icon.size(width: 20)
                let name = Label.make(a.fullName.isEmpty ? a.name : "\(a.fullName) (\(a.name))", size: 12, weight: a.loggedIn ? .medium : .regular, dim: a.isSystem)
                hstack([icon, name], spacing: 8).pinCentered(to: cell, leading: 2, trailing: 2)
            case "state":
                let l = Label.make(a.loggedIn ? "zalogowany" : (n.processes.isEmpty ? "—" : "usługi"), size: 11.5)
                l.textColor = a.loggedIn ? P.good : P.textDim
                l.pinCentered(to: cell, leading: 2, trailing: 4)
            case "procs":
                let l = Label.make("\(n.processes.count)", size: 11.5, mono: true); l.alignment = .right
                l.pinCentered(to: cell, leading: 2, trailing: 4)
            case "cpu":
                let m = MeterCell(); m.color = P.cpu
                m.fraction = n.cpu / (cores * 100); m.text = Fmt.percent(n.cpu)
                m.pin(to: cell)
            case "mem":
                let m = MeterCell(); m.color = P.memory
                m.fraction = Double(n.memory) / Double(totalMemory); m.text = Fmt.bytes(n.memory)
                m.pin(to: cell)
            default:
                Label.make("", size: 11.5).pin(to: cell)
            }
            return cell
        }

        guard let p = (item as? UserProcess)?.info else { return nil }
        switch id {
        case "user":
            let iv = NSImageView(); iv.size(width: 16, height: 16)
            if let app = NSRunningApplication(processIdentifier: pid_t(p.pid)), let img = app.icon {
                img.size = NSSize(width: 16, height: 16); iv.image = img
            } else {
                iv.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: nil); iv.contentTintColor = P.textDim
            }
            hstack([iv, Label.make(p.name, size: 11.5)], spacing: 6).pinCentered(to: cell, leading: 2, trailing: 2)
        case "state":
            let l = Label.make(p.accessible ? p.state : L("Działa"), size: 11.5, dim: true)
            l.pinCentered(to: cell, leading: 2, trailing: 4)
        case "cpu":
            let m = MeterCell(); m.color = P.cpu; m.dim = !p.accessible
            m.fraction = p.accessible ? p.cpuPercent / 100 : 0
            m.text = p.accessible ? Fmt.percent(p.cpuPercent) : "—"
            m.pin(to: cell)
        case "mem":
            let m = MeterCell(); m.color = P.memory; m.dim = !p.accessible
            m.fraction = p.accessible ? Double(p.memBytes) / Double(totalMemory) : 0
            m.text = p.accessible ? Fmt.bytes(p.memBytes) : "—"
            m.pin(to: cell)
        case "pid":
            let l = Label.make("\(p.pid)", size: 11.5, dim: true, mono: true); l.alignment = .right
            l.pinCentered(to: cell, leading: 2, trailing: 4)
        default:
            Label.make("", size: 11.5).pin(to: cell)
        }
        return cell
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !restoringSelection else { return }
        let r = outline.selectedRow
        guard r >= 0 else { return }
        if let n = outline.item(atRow: r) as? UserNode {
            selectedUID = n.account.uid
            selectedPID = nil
        } else if let p = outline.item(atRow: r) as? UserProcess {
            selectedUID = p.info.uid
            selectedPID = p.pid
        }
        updateDetails()
    }
}

private extension NSControl.StateValue {
    var isOn: Bool { self == .on }
}
