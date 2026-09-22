// ProcessesViewController.swift - strona „Procesy” w stylu TMOG: grupy Aplikacje / Procesy w tle, drzewo po PPID,
// ikony aplikacji, procesy zakończone podświetlone przez chwilę, szczegóły na dole
import AppKit

final class ProcNode {
    let pid: Int
    var info: ProcInfo
    var children: [ProcNode] = []
    var exited = false
    var exitedAt: Date?
    var isApp = false
    init(_ p: ProcInfo) { pid = p.pid; info = p }
}

final class ProcGroup {
    let title: String
    var nodes: [ProcNode] = []
    var total = 0
    init(_ t: String) { title = t }
}

/// Komórka tabeli pamiętająca PID wiersza, żeby podświetlać tylko rzeczywiste zmiany (nie przy ponownym użyciu komórki)
final class ProcCell: NSTableCellView {
    var pid = -1
    let flash = FlashLabel("", size: 11.5)
    func setText(_ t: String, pid: Int) {
        if self.pid != pid { self.pid = pid; flash.update(t, flash: false) } else { flash.update(t) }
    }
}

/// Komórka CPU z paskiem w tle
final class CPUBarCell: NSView {
    var pid = -1
    var value: Double = 0 { didSet { needsDisplay = true } }
    var text = "" {
        didSet {
            guard oldValue != text else { return }
            if !oldValue.isEmpty { ValueFade.apply(to: self) }
            if !oldValue.isEmpty, Prefs.shared.flashChanges { flashNow() }
            needsDisplay = true
        }
    }
    var dim = false
    private func flashNow() {
        wantsLayer = true
        guard let layer else { return }
        layer.cornerRadius = 3
        let a = CABasicAnimation(keyPath: "backgroundColor")
        a.fromValue = P.selection.alpha(0.75).cgColor; a.toValue = NSColor.clear.cgColor; a.duration = 1.0
        layer.add(a, forKey: "flash")
    }
    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 2, dy: 6)
        if value > 0 {
            let w = r.width * CGFloat(min(1, value / 100))
            P.cpu.alpha(0.28).setFill()
            NSBezierPath(roundedRect: NSRect(x: r.minX, y: r.minY, width: max(2, w), height: r.height), xRadius: 2, yRadius: 2).fill()
        }
        let a = NSAttributedString(string: text, attributes: [.font: Fonts.mono(11.5), .foregroundColor: dim ? P.textDim : P.text])
        let sz = a.size()
        a.draw(at: NSPoint(x: bounds.maxX - sz.width - 6, y: (bounds.height - sz.height) / 2))
    }
}

final class ProcessRowView: NSTableRowView {
    var exited = false
    var zebra = false
    override func drawBackground(in dirtyRect: NSRect) {
        if exited {
            P.bad.alpha(0.18).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 0, dy: 1), xRadius: 5, yRadius: 5).fill()
        } else if zebra {
            P.hover.setFill(); bounds.insetBy(dx: 0, dy: 1).fill()
        }
    }
    override func drawSelection(in dirtyRect: NSRect) {
        P.selection.setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 0, dy: 1), xRadius: 6, yRadius: 6).fill()
    }
}

final class ProcessesViewController: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate, PageRefreshable {
    private let outline = NSOutlineView()
    private let search = NSSearchField()
    private let viewMode = NSPopUpButton(frame: .zero, pullsDown: false)
    private let endButton = NSButton(title: L("Zakończ"), target: nil, action: nil)
    private let forceButton = NSButton(title: L("Wymuś"), target: nil, action: nil)
    private let details = CardView()
    private let dName = Label.make(L("Wybierz proces, aby zobaczyć szczegóły"), size: 13.5, weight: .semibold)
    private let dPath = Label.make("", size: 10.5, dim: true)
    private var dValues: [String: NSTextField] = [:]

    private var nodes: [Int: ProcNode] = [:]
    private let groupApps = ProcGroup(L("Aplikacje"))
    private let groupBg = ProcGroup(L("Procesy w tle"))
    private var groups: [ProcGroup] { [groupApps, groupBg] }
    private var all: [ProcInfo] = []
    private var selectedPid: Int?
    private var sortKey = "mem"
    private var sortAsc = false
    private var lastSortAt = Date.distantPast
    private var frozenOrder: [Int: Int] = [:]   // pid -> pozycja przy ostatnim sortowaniu
    private var followPid: Int?
    private var iconCache: [String: NSImage] = [:]
    private var expandedInitially = false

    override func loadView() {
        view = NSView()
        let title = PageTitleView(L("Procesy"))
        viewMode.addItems(withTitles: ["Drzewo procesów", "Lista płaska", "Tylko moje procesy", "Procesy systemowe"].map { L($0) })
        viewMode.target = self; viewMode.action = #selector(filterChanged)
        viewMode.font = Fonts.ui(12)
        search.placeholderString = L("Filtruj: nazwa, użytkownik lub PID")
        search.target = self; search.action = #selector(filterChanged)
        search.sendsSearchStringImmediately = true
        search.font = Fonts.ui(12)
        search.size(width: 260)
        for b in [endButton, forceButton] { b.bezelStyle = .rounded; b.font = Fonts.ui(12); b.controlSize = .small }
        endButton.target = self; endButton.action = #selector(endProcess)
        forceButton.target = self; forceButton.action = #selector(forceEndProcess)
        title.accessory = hstack([viewMode, search, endButton, forceButton], spacing: 8)

        setupOutline()
        let scroll = NSScrollView()
        scroll.documentView = outline
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true; scroll.scrollerStyle = .overlay; scroll.autohidesScrollers = true
        scroll.setContentHuggingPriority(.init(1), for: .vertical)

        // szczegóły (jak IDENTITY / LIFETIME / PROCESSOR / MEMORY w TMOG)
        let groupsDef: [(String, [String])] = [
            ("TOŻSAMOŚĆ", ["Rodzic", "Użytkownik", "Stan", "UID"]),
            ("CZAS ŻYCIA", ["Uruchomiony", "Czas działania", "Wątki", "PID"]),
            ("PROCESOR", ["CPU", "Czas CPU", "Udział CPU"]),
            ("PAMIĘĆ", ["Ślad (footprint)", "Udział RAM"]),
        ]
        var groupViews: [NSView] = []
        for (g, keys) in groupsDef {
            var items: [NSView] = [Label.make(g, size: 10, weight: .semibold, dim: true)]
            for k in keys {
                let row = KeyValueRow(k, "—", keyWidth: 96)
                row.valueLabel.font = Fonts.mono(10.5); row.keyLabel.font = Fonts.ui(10.5)
                dValues[k] = row.valueLabel
                items.append(row)
            }
            groupViews.append(vstack(items, spacing: 2))
        }
        let dv = vstack([dName, dPath, hstack(groupViews, spacing: 26, alignment: .top)], spacing: 3)
        dv.setCustomSpacing(8, after: dPath)
        dv.pin(to: details, insets: NSEdgeInsets(top: 10, left: 14, bottom: 10, right: 14))
        details.size(height: 132)

        let root = vstack([title, scroll, details], spacing: 8)
        for v in [title, scroll, details] { v.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true }
        root.pin(to: view, insets: NSEdgeInsets(top: 2, left: 18, bottom: 10, right: 18))

        let menu = NSMenu()
        menu.delegate = self
        menu.addItem(withTitle: L("Śledź proces"), action: #selector(followProcess), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: L("Inspekcja…"), action: #selector(inspectProcess), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: L("Zakończ proces"), action: #selector(endProcess), keyEquivalent: "")
        menu.addItem(withTitle: L("Wymuś zakończenie"), action: #selector(forceEndProcess), keyEquivalent: "")
        menu.addItem(withTitle: L("Zakończ drzewo procesów"), action: #selector(endTree), keyEquivalent: "")
        menu.addItem(withTitle: L("Wymuś zakończenie drzewa procesów"), action: #selector(forceEndTree), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: L("Wstrzymaj (SIGSTOP)"), action: #selector(suspendProcess), keyEquivalent: "")
        menu.addItem(withTitle: L("Wznów (SIGCONT)"), action: #selector(resumeProcess), keyEquivalent: "")
        let sig = NSMenu(title: L("Wyślij sygnał"))
        for (name, num) in [("SIGHUP (1)", 1), ("SIGINT (2)", 2), ("SIGQUIT (3)", 3), ("SIGABRT (6)", 6), ("SIGKILL (9)", 9), ("SIGUSR1 (30)", 30), ("SIGUSR2 (31)", 31), ("SIGALRM (14)", 14), ("SIGTERM (15)", 15), ("SIGSTOP (17)", 17), ("SIGCONT (19)", 19)] {
            let it = sig.addItem(withTitle: name, action: #selector(sendSignal(_:)), keyEquivalent: ""); it.tag = num; it.target = self
        }
        let sigItem = menu.addItem(withTitle: L("Wyślij sygnał"), action: nil, keyEquivalent: ""); sigItem.submenu = sig
        let prio = NSMenu(title: L("Ustaw priorytet"))
        for (name, nice) in [(L("Wysoki (nice -10, wymaga administratora)"), -10), (L("Powyżej normalnego (-5)"), -5), (L("Normalny (0)"), 0), (L("Poniżej normalnego (5)"), 5), (L("Niski (10)"), 10), (L("Bezczynny (19)"), 19)] {
            let it = prio.addItem(withTitle: name, action: #selector(setPriority(_:)), keyEquivalent: ""); it.tag = nice; it.target = self
        }
        let prioItem = menu.addItem(withTitle: L("Ustaw priorytet"), action: nil, keyEquivalent: ""); prioItem.submenu = prio
        menu.addItem(withTitle: L("Utwórz próbkę procesu…"), action: #selector(sampleProcess), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: L("Pokaż w Finderze"), action: #selector(revealInFinder), keyEquivalent: "")
        menu.addItem(withTitle: L("Pokaż połączenia sieciowe"), action: #selector(showConnections), keyEquivalent: "")
        menu.addItem(withTitle: L("Szukaj w internecie"), action: #selector(searchOnline), keyEquivalent: "")
        menu.addItem(withTitle: L("Kopiuj nazwę procesu"), action: #selector(copyName), keyEquivalent: "")
        menu.addItem(withTitle: L("Kopiuj ścieżkę"), action: #selector(copyPath), keyEquivalent: "")
        menu.addItem(withTitle: L("Kopiuj PID"), action: #selector(copyPid), keyEquivalent: "")
        for it in menu.items where it.target == nil && it.action != nil { it.target = self }
        outline.menu = menu

        NotificationCenter.default.addObserver(self, selector: #selector(snapshot(_:)), name: .snapshotUpdated, object: nil)
        NotificationCenter.default.addObserver(forName: .applySearchFilter, object: nil, queue: .main) { [weak self] n in
            guard let text = n.object as? String else { return }
            self?.search.stringValue = text
            self?.rebuild(force: true)
        }
        NotificationCenter.default.addObserver(forName: .themeChanged, object: nil, queue: .main) { [weak self] _ in
            self?.outline.reloadData(); self?.updateDetails()
        }
        updateDetails()
    }

    private func setupOutline() {
        let cols: [(String, String, CGFloat)] = [
            ("name", "Nazwa", 320), ("pid", "PID", 70), ("state", "Stan", 100), ("user", "Użytkownik", 100),
            ("cpu", "CPU", 120), ("mem", "Pamięć", 100), ("threads", "Wątki", 60),
            ("diskR", "Dysk odczyt", 90), ("diskW", "Dysk zapis", 90),
            ("energy", "Wpływ na energię", 120), ("wakeups", "Wybudzenia/s", 100),
            ("time", "Czas CPU", 90), ("path", "Ścieżka", 260),
        ]
        for (id, t, w) in cols {
            let c = NSTableColumn(identifier: .init(id))
            c.title = L(t); c.width = w; c.minWidth = 50
            c.sortDescriptorPrototype = NSSortDescriptor(key: id, ascending: ["name", "user", "state", "path", "pid"].contains(id))
            if ["pid", "cpu", "mem", "threads", "time", "diskR", "diskW", "energy", "wakeups"].contains(id) { c.headerCell.alignment = .right }
            switch id {
            case "cpu": c.headerToolTip = L("100% oznacza jeden w pełni obciążony rdzeń. Proces wielowątkowy może przekroczyć 100%.")
            case "energy": c.headerToolTip = L("Szacunkowy wskaźnik na podstawie CPU, operacji dyskowych i przełączeń kontekstu; nie jest pomiarem w watach.")
            case "wakeups": c.headerToolTip = L("Przełączenia kontekstu na sekundę; przybliżenie aktywności procesu, nie bezpośredni pomiar wybudzeń.")
            default: break
            }
            outline.addTableColumn(c)
        }
        outline.outlineTableColumn = outline.tableColumns[0]
        outline.sortDescriptors = [NSSortDescriptor(key: "mem", ascending: false)]
        outline.rowHeight = 23
        outline.intercellSpacing = NSSize(width: 8, height: 2)
        outline.backgroundColor = .clear
        outline.style = .plain
        outline.usesAlternatingRowBackgroundColors = false
        outline.focusRingType = .none
        outline.allowsMultipleSelection = false
        outline.floatsGroupRows = false
        outline.indentationPerLevel = 14
        outline.dataSource = self
        outline.delegate = self
        outline.target = self
        outline.doubleAction = #selector(revealInFinder)
        outline.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        // prawy przycisk na nagłówku: wybór widocznych kolumn
        ColumnMenu.attach(to: outline, key: "processes", locked: ["name"])
        outline.autosaveExpandedItems = false
    }

    func pageDidAppear() { rebuild() }

    private var lastStructureHash = 0

    private var lastProcGeneration = -1

    @objc private func snapshot(_ n: Notification) {
        guard let s = n.object as? Snapshot else { return }
        // strona niewidoczna nie ma po co przeliczać drzewa ani odrysowywać wierszy
        guard view.window != nil, !view.isHiddenOrHasHiddenAncestor else { return }
        // dane o procesach przychodzą rzadziej niż pozostałe pomiary – bez nowej porcji nie ma czego odświeżać
        guard s.processGeneration != lastProcGeneration else { return }
        lastProcGeneration = s.processGeneration
        all = s.processes
        rebuild()
    }

    @objc private func filterChanged() { rebuild(force: true) }

    // MARK: budowa drzewa
    private var lastReloadAt = Date.distantPast

    private var appPids = Set<Int>()
    private var appPidsAt = Date.distantPast

    private func rebuild(force: Bool = false) {
        let now = Date()
        // lista uruchomionych aplikacji z NSWorkspace jest droga – wystarczy odświeżać ją co sekundę
        if force || now.timeIntervalSince(appPidsAt) >= 1.0 {
            appPidsAt = now
            appPids = Set(NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }.map { Int($0.processIdentifier) })
        }
        let apps = appPids
        var seen = Set<Int>()
        for p in all {
            seen.insert(p.pid)
            if let n = nodes[p.pid], n.info.startTimeMicros == p.startTimeMicros {
                n.info = p; n.exited = false; n.exitedAt = nil
            } else {
                nodes[p.pid] = ProcNode(p)
            }
            let n = nodes[p.pid]!
            n.isApp = apps.contains(p.pid)
        }
        for (pid, n) in nodes where !seen.contains(pid) {
            if !n.exited { n.exited = true; n.exitedAt = now }
            if !Prefs.shared.showExited || (n.exitedAt.map { now.timeIntervalSince($0) > Double(Prefs.shared.keepExited) } ?? false) { nodes.removeValue(forKey: pid) }
        }

        // Pełna przebudowa drzewa (filtrowanie, sortowanie, reload tabeli) jest droga, więc robimy ją
        // najwyżej raz na sekundę. Pomiędzy nimi odświeżamy wartości w widocznych wierszach – węzły już mają nowe dane.
        if !force, now.timeIntervalSince(lastReloadAt) < 1.5, outline.numberOfRows > 0 {
            refreshVisibleRows()
            updateDetails()
            return
        }
        lastReloadAt = now

        let filter = search.stringValue.lowercased()
        let mode = viewMode.indexOfSelectedItem
        let me = Int(getuid())
        func passes(_ n: ProcNode) -> Bool {
            let p = n.info
            if mode == 2 && p.uid != me { return false }
            if mode == 3 && p.uid == me { return false }
            if filter.isEmpty { return true }
            return p.name.lowercased().contains(filter) || p.user.lowercased().contains(filter) || String(p.pid) == filter || p.path.lowercased().contains(filter)
        }
        let tree = mode == 0 && filter.isEmpty

        for n in nodes.values { n.children.removeAll(keepingCapacity: true) }
        groupApps.nodes.removeAll(); groupBg.nodes.removeAll()
        var visible = nodes.values.filter(passes)
        groupApps.total = visible.filter { $0.isApp }.count
        groupBg.total = visible.count - groupApps.total

        if tree {
            var top: [ProcNode] = []
            for n in visible {
                let pp = n.info.ppid
                if pp > 0, pp != n.pid, let parent = nodes[pp], passes(parent), !(parent.isApp != n.isApp && !n.isApp && false) {
                    // aplikacje zawsze na górze swojej grupy; pozostałe pod rodzicem
                    if n.isApp { top.append(n) } else { parent.children.append(n) }
                } else {
                    top.append(n)
                }
            }
            visible = top
        }
        // Kolumny zmienne (CPU, wątki, czas) przesortowujemy co 5 s, żeby wiersze nie skakały; między sortowaniami
        // nowe procesy trafiają na koniec, a istniejące zachowują pozycję
        let volatileKey = ["cpu", "threads", "time", "state"].contains(sortKey)
        let resort = !volatileKey || Date().timeIntervalSince(lastSortAt) > 5 || frozenOrder.isEmpty
        let cmp = comparator()
        func sortRec(_ arr: inout [ProcNode]) {
            if resort {
                arr.sort(by: cmp)
            } else {
                arr.sort { a, b in
                    let pa = frozenOrder[a.pid], pb = frozenOrder[b.pid]
                    switch (pa, pb) {
                    case let (x?, y?): return x < y
                    case (nil, nil): return cmp(a, b)
                    case (nil, _): return false
                    default: return true
                    }
                }
            }
            for n in arr where !n.children.isEmpty { sortRec(&n.children) }
        }
        var appsTop = visible.filter { $0.isApp }
        var bgTop = visible.filter { !$0.isApp }
        sortRec(&appsTop); sortRec(&bgTop)
        groupApps.nodes = appsTop
        groupBg.nodes = bgTop
        if resort {
            lastSortAt = Date()
            frozenOrder.removeAll(keepingCapacity: true)
            var i = 0
            func index(_ arr: [ProcNode]) { for n in arr { frozenOrder[n.pid] = i; i += 1; index(n.children) } }
            index(appsTop); index(bgTop)
        }

        let hash = structureHash()
        if hash == lastStructureHash, outline.numberOfRows > 0 {
            refreshVisibleRows()
            updateDetails()
            return
        }
        lastStructureHash = hash
        outline.reloadData()
        if !expandedInitially, !nodes.isEmpty {
            outline.expandItem(groupApps); outline.expandItem(groupBg)
            if let launchd = nodes[1] { outline.expandItem(launchd) }
            expandedInitially = true
        }
        if let pid = selectedPid, let n = nodes[pid] {
            let row = outline.row(forItem: n)
            if row >= 0 {
                outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                if followPid == pid { outline.scrollRowToVisible(row) }
            }
        }
        updateDetails()
    }

    private func comparator() -> (ProcNode, ProcNode) -> Bool {
        let key = sortKey, asc = sortAsc
        return { x, y in
            let a = asc ? x.info : y.info, b = asc ? y.info : x.info
            let r: Bool
            switch key {
            case "name": r = a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
            case "pid": r = a.pid < b.pid
            case "state": r = a.state < b.state
            case "user": r = a.user < b.user
            case "cpu": r = a.cpuPercent < b.cpuPercent
            case "mem": r = a.memBytes < b.memBytes
            case "threads": r = a.threads < b.threads
            case "time": r = a.cpuTimeNs < b.cpuTimeNs
            case "diskR": r = a.diskReadRate < b.diskReadRate
            case "diskW": r = a.diskWriteRate < b.diskWriteRate
            case "energy": r = a.energyImpact < b.energyImpact
            case "wakeups": r = a.cswRate < b.cswRate
            case "path": r = a.path < b.path
            default: r = a.pid < b.pid
            }
            return r
        }
    }

    private var selected: ProcNode? { selectedPid.flatMap { nodes[$0] } }

    private func updateDetails() {
        guard let n = selected else {
            dName.stringValue = L("Wybierz proces, aby zobaczyć szczegóły")
            dName.textColor = P.text
            dPath.stringValue = Monitor.privileged ? L("Dwukrotne kliknięcie pokazuje plik w Finderze.") :
                "Dwukrotne kliknięcie pokazuje plik w Finderze. CPU i pamięć procesów innych użytkowników: „Brak dostępu” – włącz pomocnika uprzywilejowanego w Ustawieniach."
            dPath.textColor = P.textDim
            for v in dValues.values { v.stringValue = L("—") }
            endButton.isEnabled = false; forceButton.isEnabled = false
            return
        }
        let p = n.info
        endButton.isEnabled = !n.exited && n.info.actionIdentity != nil; forceButton.isEnabled = endButton.isEnabled
        dName.stringValue = "\(p.name) (\(p.pid))" + (n.exited ? " — " + L("zakończony") : "")
        dName.textColor = n.exited ? P.bad : P.text
        dPath.stringValue = p.path.isEmpty ? L("(ścieżka niedostępna)") : p.path
        dPath.textColor = P.textDim
        let parent = nodes[p.ppid]?.info
        dValues["Rodzic"]?.stringValue = "\(parent?.name ?? (p.ppid == 0 ? "kernel_task" : "?")) (\(p.ppid))"
        dValues["Użytkownik"]?.stringValue = p.user
        dValues["Stan"]?.stringValue = n.exited ? L("Zakończony") : L(p.state)
        dValues["UID"]?.stringValue = "\(p.uid)"
        dValues["Uruchomiony"]?.stringValue = p.startTime.map { Fmt.dateTime.string(from: $0) } ?? L("—")
        dValues["Czas działania"]?.stringValue = p.startTime.map { Fmt.duration(Date().timeIntervalSince($0)) } ?? L("—")
        dValues["Wątki"]?.stringValue = p.accessible ? "\(p.threads)" : L("Brak dostępu")
        dValues["PID"]?.stringValue = "\(p.pid)"
        dValues["CPU"]?.stringValue = p.accessible ? Fmt.percent(p.cpuPercent) : L("Brak dostępu")
        dValues["Czas CPU"]?.stringValue = p.accessible ? Fmt.cpuTime(p.cpuTimeNs) : L("—")
        dValues["Udział CPU"]?.stringValue = p.accessible ? Fmt.percent(p.cpuPercent / Double(max(1, Monitor.shared.hardware.ncpu)), precision: 2) + L(" całości") : L("—")
        dValues["Ślad (footprint)"]?.stringValue = p.accessible ? Fmt.bytes(p.memBytes) : L("Brak dostępu")
        let total = Monitor.shared.latest.mem.total
        dValues["Udział RAM"]?.stringValue = p.accessible && total > 0 ? Fmt.percent(100 * Double(p.memBytes) / Double(total), precision: 2) : L("—")
    }

    // MARK: ikony
    private func icon(for n: ProcNode) -> NSImage? {
        let p = n.info
        if n.isApp, let app = NSRunningApplication(processIdentifier: pid_t(p.pid)), let img = app.icon { img.size = NSSize(width: 16, height: 16); return img }
        guard !p.path.isEmpty else { return NSImage(systemSymbolName: "gearshape", accessibilityDescription: nil) }
        var key = p.path
        if let r = p.path.range(of: ".app/") { key = String(p.path[..<r.lowerBound]) + ".app" }
        if let img = iconCache[key] { return img }
        let img = NSWorkspace.shared.icon(forFile: key)
        img.size = NSSize(width: 16, height: 16)
        iconCache[key] = img
        return img
    }

    // MARK: outline
    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if item == nil { return groups.count }
        if let g = item as? ProcGroup { return g.nodes.count }
        if let n = item as? ProcNode { return n.children.count }
        return 0
    }
    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if item == nil { return groups[index] }
        if let g = item as? ProcGroup { return g.nodes[index] }
        return (item as! ProcNode).children[index]
    }
    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        if item is ProcGroup { return true }
        return !((item as? ProcNode)?.children.isEmpty ?? true)
    }
    func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool { item is ProcGroup }
    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool { item is ProcNode }
    func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat { item is ProcGroup ? 22 : 23 }

    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
        let r = ProcessRowView()
        if let n = item as? ProcNode {
            r.exited = n.exited
            r.zebra = outlineView.row(forItem: item) % 2 == 1
        }
        return r
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        if let g = item as? ProcGroup {
            let cell = NSTableCellView()
            let tf = Label.make("\(g.title) (\(g.total))", size: 12, weight: .semibold)
            cell.textField = tf
            tf.pinCentered(to: cell, leading: 2, trailing: 2)
            return cell
        }
        guard let n = item as? ProcNode, let col = tableColumn else { return nil }
        let id = col.identifier
        if id.rawValue == "cpu" {
            let cell = (outline.makeView(withIdentifier: id, owner: nil) as? CPUBarCell) ?? { let c = CPUBarCell(); c.identifier = id; return c }()
            configure(cell, id: id, node: n)
            return cell
        }
        let cell: ProcCell
        if let c = outline.makeView(withIdentifier: id, owner: nil) as? ProcCell {
            cell = c
        } else {
            cell = ProcCell()
            cell.identifier = id
            let tf = cell.flash
            if id.rawValue == "name" {
                let iv = NSImageView(); iv.size(width: 16, height: 16)
                cell.imageView = iv
                hstack([iv, tf], spacing: 6).pinCentered(to: cell, leading: 2, trailing: 2)
            } else {
                tf.pinCentered(to: cell, leading: 2, trailing: 4)
            }
        }
        configure(cell, id: id, node: n)
        return cell
    }

    /// Wypełnia komórkę wartościami – używane przy tworzeniu wiersza i przy odświeżaniu bez przebudowy tabeli
    private func configure(_ view: NSView, id: NSUserInterfaceItemIdentifier, node n: ProcNode) {
        let p = n.info
        let denied = L("Brak dostępu")
        if let cell = view as? CPUBarCell {
            if cell.pid != p.pid { cell.pid = p.pid; cell.text = "" }
            cell.value = p.accessible && !n.exited ? p.cpuPercent : 0
            cell.text = p.accessible ? Fmt.percent(p.cpuPercent) : denied
            cell.dim = !p.accessible || n.exited
            return
        }
        guard let cell = view as? ProcCell else { return }
        let tf = cell.flash
        tf.textColor = n.exited ? P.bad : (p.accessible ? P.text : P.textDim)
        tf.font = Fonts.ui(11.5)
        tf.alignment = .left
        func mono() { tf.alignment = .right; tf.font = Fonts.mono(11.5) }
        switch id.rawValue {
        case "name":
            cell.setText(p.name, pid: p.pid)
            cell.imageView?.image = icon(for: n)
            cell.imageView?.contentTintColor = P.textDim
        case "pid": cell.setText("\(p.pid)", pid: p.pid); mono(); if !n.exited { tf.textColor = P.textDim }
        case "state":
            cell.setText(n.exited ? L("Zakończony") : L(p.accessible ? p.state : "Działa"), pid: p.pid)
            if p.state == "Zombie" { tf.textColor = P.warn }
        case "user": cell.setText(p.user, pid: p.pid)
        case "mem": cell.setText(p.accessible ? Fmt.bytes(p.memBytes) : denied, pid: p.pid); mono()
        case "threads": cell.setText(p.accessible ? "\(p.threads)" : "—", pid: p.pid); mono()
        case "diskR":
            cell.setText(p.accessible ? (p.diskReadRate > 0 ? Fmt.rate(p.diskReadRate) : "—") : "—", pid: p.pid); mono()
            if p.diskReadRate > 0, !n.exited { tf.textColor = P.disk }
        case "diskW":
            cell.setText(p.accessible ? (p.diskWriteRate > 0 ? Fmt.rate(p.diskWriteRate) : "—") : "—", pid: p.pid); mono()
            if p.diskWriteRate > 0, !n.exited { tf.textColor = P.disk }
        case "energy":
            let e = p.energyImpact
            cell.setText(p.accessible ? String(format: "%.1f", e) : "—", pid: p.pid); mono()
            if !n.exited, p.accessible { tf.textColor = e > 50 ? P.bad : (e > 10 ? P.warn : (e > 1 ? P.text : P.textDim)) }
        case "wakeups":
            cell.setText(p.accessible ? String(format: "%.0f", p.cswRate) : "—", pid: p.pid); mono()
            if !n.exited, p.cswRate > 2000 { tf.textColor = P.warn }
        case "time": cell.setText(p.accessible ? Fmt.cpuTime(p.cpuTimeNs) : "—", pid: p.pid); mono()
        case "path": cell.setText(p.path, pid: p.pid); if !n.exited { tf.textColor = P.textDim }
        default: cell.setText("", pid: p.pid)
        }
    }

    /// Odświeża tylko widoczne wiersze, bez tworzenia nowych widoków (pełny reload był najdroższą rzeczą w aplikacji)
    private func refreshVisibleRows() {
        let rows = outline.rows(in: outline.visibleRect)
        guard rows.length > 0 else { return }
        for row in rows.location..<(rows.location + rows.length) {
            guard let n = outline.item(atRow: row) as? ProcNode else { continue }
            for c in 0..<outline.numberOfColumns {
                guard let v = outline.view(atColumn: c, row: row, makeIfNecessary: false) else { continue }
                configure(v, id: outline.tableColumns[c].identifier, node: n)
            }
        }
    }

    /// Odcisk struktury drzewa – zmienia się, gdy dochodzą/znikają procesy albo zmienia się kolejność
    private func structureHash() -> Int {
        var h = Hasher()
        h.combine(groupApps.total); h.combine(groupBg.total)
        func walk(_ arr: [ProcNode]) {
            for n in arr { h.combine(n.pid); h.combine(n.exited); h.combine(n.children.count); walk(n.children) }
        }
        walk(groupApps.nodes); walk(groupBg.nodes)
        return h.finalize()
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        let r = outline.selectedRow
        selectedPid = r >= 0 ? (outline.item(atRow: r) as? ProcNode)?.pid : nil
        updateDetails()
    }

    func outlineView(_ outlineView: NSOutlineView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        guard let d = outlineView.sortDescriptors.first, let k = d.key else { return }
        sortKey = k; sortAsc = d.ascending
        rebuild()
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        let r = outline.clickedRow
        if r >= 0, outline.item(atRow: r) is ProcNode {
            outline.selectRowIndexes(IndexSet(integer: r), byExtendingSelection: false)
        }
        let ok = selected != nil && !(selected?.exited ?? true)
        for it in menu.items { it.isEnabled = ok }
        let canAct = ok && selected?.info.actionIdentity != nil
        let mutations: Set<Selector> = [#selector(endProcess), #selector(forceEndProcess), #selector(endTree),
                                       #selector(forceEndTree), #selector(suspendProcess), #selector(resumeProcess)]
        for item in menu.items {
            if let action = item.action, mutations.contains(action) { item.isEnabled = canAct }
            if let submenu = item.submenu { for child in submenu.items { child.isEnabled = canAct } }
        }
        menu.items.first?.state = (selected != nil && followPid == selected?.pid) ? .on : .off
    }

    // MARK: akcje
    @objc func endProcess() { terminate(force: false) }
    @objc func forceEndProcess() { terminate(force: true) }

    private func terminate(force: Bool) {
        guard let n = selected, !n.exited, n.info.actionIdentity != nil else { return }
        let p = n.info
        let alert = NSAlert()
        alert.messageText = (force ? L("Wymusić zakończenie procesu „") : L("Zakończyć proces „")) + "\(p.name)” (PID \(p.pid))?"
        alert.informativeText = force ? L("Proces zostanie natychmiast zabity (SIGKILL). Niezapisane dane zostaną utracone.")
                                      : L("Proces otrzyma sygnał SIGTERM i będzie mógł zakończyć się poprawnie.")
        alert.alertStyle = force ? .critical : .warning
        alert.addButton(withTitle: force ? L("Wymuś zakończenie") : L("Zakończ"))
        alert.addButton(withTitle: L("Anuluj"))
        guard let w = view.window else { return }
        alert.beginSheetModal(for: w) { resp in
            guard resp == .alertFirstButtonReturn else { return }
            if let message = ProcessActions.signal(force ? SIGKILL : SIGTERM, process: p) {
                let err = NSAlert()
                err.messageText = L("Nie udało się zakończyć procesu „") + "\(p.name)”"
                err.informativeText = message
                err.alertStyle = .critical
                err.beginSheetModal(for: w)
            }
        }
    }

    private func signal(_ sig: Int32, to process: ProcInfo, name: String) {
        if let message = ProcessActions.signal(sig, process: process) {
            let err = NSAlert()
            err.messageText = L("Nie udało się wysłać sygnału") + " \(name) · PID \(process.pid)"
            err.informativeText = message; err.alertStyle = .warning; err.runModal()
        }
    }

    private func treeProcesses(_ node: ProcNode) -> [ProcInfo] {
        guard !node.exited, node.info.actionIdentity != nil else { return [] }
        return node.children.flatMap(treeProcesses) + [node.info]
    }

    @objc func followProcess() {
        guard let n = selected else { return }
        followPid = followPid == n.pid ? nil : n.pid
        if followPid != nil { outline.scrollRowToVisible(outline.row(forItem: n)) }
    }

    @objc func endTree() { terminateTree(force: false) }
    @objc func forceEndTree() { terminateTree(force: true) }
    private func terminateTree(force: Bool) {
        guard let n = selected, !n.exited, n.info.actionIdentity != nil else { return }
        let processes = treeProcesses(n)
        let alert = NSAlert()
        alert.messageText = (force ? L("Wymusić zakończenie drzewa procesów „") : L("Zakończyć drzewo procesów „")) + "\(n.info.name)” (\(processes.count) " + L("procesów") + ")?"
        alert.informativeText = L("Sygnał") + " \(force ? "SIGKILL" : "SIGTERM") " + L("zostanie wysłany do procesu i wszystkich jego potomków.")
        alert.alertStyle = .warning
        alert.addButton(withTitle: force ? L("Wymuś zakończenie") : L("Zakończ")); alert.addButton(withTitle: L("Anuluj"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let failures = processes.compactMap { process -> String? in
            ProcessActions.signal(force ? SIGKILL : SIGTERM, process: process).map { "\(process.name) (\(process.pid)): \($0)" }
        }
        if !failures.isEmpty {
            let error = NSAlert(); error.messageText = L("Nie udało się zakończyć wszystkich procesów")
            error.informativeText = failures.prefix(10).joined(separator: "\n"); error.runModal()
        }
    }

    @objc func suspendProcess() { if let n = selected, !n.exited { signal(SIGSTOP, to: n.info, name: "SIGSTOP") } }
    @objc func resumeProcess() { if let n = selected, !n.exited { signal(SIGCONT, to: n.info, name: "SIGCONT") } }
    @objc func sendSignal(_ sender: NSMenuItem) { if let n = selected, !n.exited { signal(Int32(sender.tag), to: n.info, name: sender.title) } }

    @objc func setPriority(_ sender: NSMenuItem) {
        guard let n = selected, !n.exited, let identity = n.info.actionIdentity else { return }
        let nice = sender.tag
        guard (-20...20).contains(nice), identity.isCurrent() else { return }
        // The helper rechecks the captured identity immediately before setpriority.
        DispatchQueue.global(qos: .userInitiated).async {
            var message: String?
            if !identity.isCurrent() {
                message = L("Proces zakończył się, zmienił tożsamość lub jest chroniony. Odśwież listę.")
            } else if setpriority(PRIO_PROCESS, id_t(identity.pid), Int32(nice)) != 0 {
                if HelperClient.shared.isEnabled {
                    message = HelperClient.shared.setPriority(pid: Int32(identity.pid), startTimeMicros: identity.startTimeMicros, value: Int32(nice))
                } else {
                    message = String(cString: strerror(errno)) + "\n" + L("Włącz lub zaktualizuj pomocnika w Ustawieniach.")
                }
            }
            if let message {
                DispatchQueue.main.async {
                    let error = NSAlert(); error.messageText = L("Nie udało się zmienić priorytetu")
                    error.informativeText = message; error.runModal()
                }
            }
        }
    }

    @objc func sampleProcess() {
        guard let n = selected else { return }
        let file = NSTemporaryDirectory() + "sample-\(n.info.name)-\(n.pid).txt"
        let alert = NSAlert()
        alert.messageText = L("Próbkowanie procesu „") + "\(n.info.name)” (3 s)…"
        alert.informativeText = L("Wynik zostanie otwarty w domyślnym edytorze tekstu.")
        alert.addButton(withTitle: "OK")
        DispatchQueue.global().async {
            _ = Shell.run("/usr/bin/sample", ["\(n.pid)", "3", "-file", file], timeout: 30)
            DispatchQueue.main.async { NSWorkspace.shared.open(URL(fileURLWithPath: file)) }
        }
        alert.runModal()
    }

    @objc func inspectProcess() {
        guard let n = selected else { return }
        let p = n.info
        DispatchQueue.global().async {
            let ps = Shell.run("/bin/ps", ["-p", "\(p.pid)", "-o", "pid=,ppid=,pgid=,sess=,tty=,nice=,pri=,stat=,lstart=,command="], timeout: 5)
            let files = Shell.run("/bin/sh", ["-c", "/usr/sbin/lsof -p \(p.pid) 2>/dev/null | wc -l"], timeout: 10).trimmingCharacters(in: .whitespacesAndNewlines)
            let net = Shell.run("/bin/sh", ["-c", "/usr/sbin/lsof -nP -a -i -p \(p.pid) 2>/dev/null | tail -n +2 | wc -l"], timeout: 10).trimmingCharacters(in: .whitespacesAndNewlines)
            DispatchQueue.main.async {
                let a = NSAlert()
                a.messageText = "\(p.name) (PID \(p.pid))"
                var text = L("Ścieżka") + ": \(p.path.isEmpty ? "—" : p.path)\n"
                text += L("Użytkownik") + ": \(p.user) (UID \(p.uid)) · " + L("Rodzic") + ": \(p.ppid)\n"
                text += "CPU: \(p.accessible ? Fmt.percent(p.cpuPercent) : L("brak dostępu")) · " + L("Czas CPU") + ": \(p.accessible ? Fmt.cpuTime(p.cpuTimeNs) : "—") · " + L("Wątki") + ": \(p.accessible ? "\(p.threads)" : "—")\n"
                text += L("Pamięć (footprint)") + ": \(p.accessible ? Fmt.bytes(p.memBytes) : L("brak dostępu"))\n"
                text += L("Uruchomiony") + ": \(p.startTime.map { Fmt.dateTime.string(from: $0) } ?? "—")\n"
                text += L("Otwarte pliki") + ": \(files.isEmpty ? "—" : files) · " + L("Gniazda sieciowe") + ": \(net.isEmpty ? "—" : net)\n\n"
                text += "ps: \(ps.trimmingCharacters(in: .whitespacesAndNewlines))"
                a.informativeText = text
                a.addButton(withTitle: L("Zamknij")); a.addButton(withTitle: L("Kopiuj"))
                if a.runModal() == .alertSecondButtonReturn { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(a.messageText + "\n" + text, forType: .string) }
            }
        }
    }

    @objc func showConnections() {
        guard let n = selected else { return }
        NotificationCenter.default.post(name: .openPage, object: 8)
        NotificationCenter.default.post(name: .filterConnections, object: n.pid)
    }
    @objc func searchOnline() {
        guard let n = selected, let q = n.info.name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed), let url = URL(string: "https://www.google.com/search?q=" + q + "+macos+process") else { return }
        NSWorkspace.shared.open(url)
    }
    @objc func copyName() {
        guard let n = selected else { return }
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(n.info.name, forType: .string)
    }

    @objc func revealInFinder() {
        guard let n = selected, !n.info.path.isEmpty else { return }
        NSWorkspace.shared.selectFile(n.info.path, inFileViewerRootedAtPath: "")
    }
    @objc func copyPath() {
        guard let n = selected else { return }
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(n.info.path, forType: .string)
    }
    @objc func copyPid() {
        guard let n = selected else { return }
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString("\(n.pid)", forType: .string)
    }
}
