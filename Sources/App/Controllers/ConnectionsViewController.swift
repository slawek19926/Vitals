// ConnectionsViewController.swift - aktywne połączenia sieciowe (netstat -anv) z przypisaniem do procesów
import AppKit

extension Notification.Name { static let filterConnections = Notification.Name("FilterConnections") }

struct Connection {
    let proto: String
    let local: String, localPort: String
    let remote: String, remotePort: String
    let state: String
    let pid: Int
    var processName: String
}

final class ConnectionsViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, PageRefreshable {
    private let table = NSTableView()
    private let search = NSSearchField()
    private let kind = NSPopUpButton(frame: .zero, pullsDown: false)
    private let countLabel = Label.make("", size: 11, dim: true)
    private var all: [Connection] = []
    private var rows: [Connection] = []
    private var timer: Timer?
    private var loading = false
    private var sortKey = "process"
    private var sortAsc = true
    private var iconCache: [Int: NSImage] = [:]

    override func loadView() {
        view = NSView()
        let title = PageTitleView(L("Połączenia"))
        kind.addItems(withTitles: ["Wszystkie", "TCP", "UDP", "Ustanowione", "Nasłuchujące"].map { L($0) })
        kind.target = self; kind.action = #selector(filterChanged); kind.font = Fonts.ui(11.5); kind.controlSize = .small
        search.placeholderString = L("Filtruj: proces, adres, port"); search.font = Fonts.ui(11.5); search.size(width: 240)
        search.target = self; search.action = #selector(filterChanged); search.sendsSearchStringImmediately = true
        let refresh = NSButton(title: L("Odśwież"), target: self, action: #selector(reload))
        refresh.bezelStyle = .rounded; refresh.controlSize = .small; refresh.font = Fonts.ui(11.5)
        title.accessory = hstack([countLabel, kind, search, refresh], spacing: 8)

        for (id, t, w) in [("process", "Proces", 220), ("pid", "PID", 64), ("proto", "Protokół", 70), ("local", "Adres lokalny", 200), ("lport", "Port", 70),
                           ("remote", "Adres zdalny", 220), ("rport", "Port zdalny", 80), ("state", "Stan", 130)] {
            let c = NSTableColumn(identifier: .init(id)); c.title = L(t); c.width = CGFloat(w); c.minWidth = 40
            c.sortDescriptorPrototype = NSSortDescriptor(key: id, ascending: true)
            if id == "pid" || id == "lport" || id == "rport" { c.headerCell.alignment = .right }
            table.addTableColumn(c)
        }
        table.sortDescriptors = [NSSortDescriptor(key: "process", ascending: true)]
        table.rowHeight = 22
        table.intercellSpacing = NSSize(width: 8, height: 1)
        table.backgroundColor = .clear
        table.style = .plain
        table.focusRingType = .none
        table.dataSource = self; table.delegate = self
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        // prawy przycisk na nagłówku: wybór widocznych kolumn
        ColumnMenu.attach(to: table, key: "connections", locked: ["process"])
        let scroll = NSScrollView(); scroll.documentView = table; scroll.drawsBackground = false; scroll.hasVerticalScroller = true; scroll.scrollerStyle = .overlay; scroll.autohidesScrollers = true
        scroll.setContentHuggingPriority(.init(1), for: .vertical)
        let root = vstack([title, scroll], spacing: 6)
        for v in [title, scroll] { v.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true }
        root.pin(to: view, insets: NSEdgeInsets(top: 2, left: 18, bottom: 10, right: 18))
        NotificationCenter.default.addObserver(forName: .themeChanged, object: nil, queue: .main) { [weak self] _ in self?.table.reloadData() }
        NotificationCenter.default.addObserver(forName: .filterConnections, object: nil, queue: .main) { [weak self] n in
            if let pid = n.object as? Int { self?.search.stringValue = "\(pid)"; self?.rebuild() }
        }
    }

    func pageDidAppear() {
        reload()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            guard let self, self.view.window != nil else { self?.timer?.invalidate(); return }
            self.reload()
        }
    }

    @objc private func reload() {
        guard !loading else { return }
        loading = true
        let procs = Dictionary(uniqueKeysWithValues: Monitor.shared.latest.processes.map { ($0.pid, $0.name) })
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            // netstat nie zwraca gniazd internetowych dla aplikacji GUI na nowych macOS; lsof działa
            let out = Shell.run("/usr/sbin/lsof", ["-nP", "-iTCP", "-iUDP"], timeout: 20)
            let list = Self.parseLsof(out, procs: procs)
            DispatchQueue.main.async {
                guard let self else { return }
                self.all = list; self.loading = false; self.rebuild()
            }
        }
    }

    /// „host:port” → (host, port); obsługuje IPv6 w nawiasach i „*”
    static func splitHostPort(_ s: String) -> (String, String) {
        guard let colon = s.lastIndex(of: ":") else { return (s, "") }
        var host = String(s[..<colon]); let port = String(s[s.index(after: colon)...])
        if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        return (host, port)
    }

    /// lsof -nP -iTCP -iUDP: COMMAND PID USER FD TYPE DEVICE SIZE/OFF NODE NAME
    static func parseLsof(_ out: String, procs: [Int: String]) -> [Connection] {
        var result: [Connection] = []
        for line in out.split(separator: "\n").dropFirst() {
            let f = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard f.count >= 9, let pid = Int(f[1]) else { continue }
            let proto = f[7]            // TCP / UDP
            guard proto == "TCP" || proto == "UDP" else { continue }
            var name = f[8...].joined(separator: " ")
            var state = ""
            if let p = name.range(of: " (") , name.hasSuffix(")") {
                state = String(name[p.upperBound..<name.index(before: name.endIndex)])
                name = String(name[..<p.lowerBound])
            }
            let parts = name.components(separatedBy: "->")
            let (lh, lp) = splitHostPort(parts[0])
            let (rh, rp) = parts.count > 1 ? splitHostPort(parts[1]) : ("*", "*")
            let cmd = f[0].replacingOccurrences(of: "\\x20", with: " ")
            let pname = procs[pid] ?? cmd
            result.append(Connection(proto: proto + (f[4].contains("6") ? "6" : "4"), local: lh, localPort: lp, remote: rh, remotePort: rp, state: state, pid: pid, processName: pname))
        }
        return result
    }

    private func stateText(_ s: String) -> String {
        L(["ESTABLISHED": "ustanowione", "LISTEN": "nasłuchuje", "CLOSE_WAIT": "zamykanie (CLOSE_WAIT)", "TIME_WAIT": "TIME_WAIT", "SYN_SENT": "łączenie (SYN_SENT)",
         "CLOSED": "zamknięte", "FIN_WAIT_1": "FIN_WAIT_1", "FIN_WAIT_2": "FIN_WAIT_2", "LAST_ACK": "LAST_ACK", "CLOSING": "zamykanie"][s] ?? (s.isEmpty ? "—" : s))
    }

    @objc private func filterChanged() { rebuild() }

    private func rebuild() {
        let f = search.stringValue.lowercased()
        rows = all.filter { c in
            switch kind.indexOfSelectedItem {
            case 1: if c.proto != "TCP" && c.proto != "TCP4" && c.proto != "TCP6" { return false }
            case 2: if !c.proto.hasPrefix("UDP") { return false }
            case 3: if c.state != "ESTABLISHED" { return false }
            case 4: if c.state != "LISTEN" { return false }
            default: break
            }
            if f.isEmpty { return true }
            return c.processName.lowercased().contains(f) || c.local.contains(f) || c.remote.contains(f) || c.localPort == f || c.remotePort == f || String(c.pid) == f
        }
        rows.sort { a, b in
            let r: Bool
            switch sortKey {
            case "pid": r = a.pid < b.pid
            case "proto": r = a.proto < b.proto
            case "local": r = a.local < b.local
            case "lport": r = (Int(a.localPort) ?? 0) < (Int(b.localPort) ?? 0)
            case "remote": r = a.remote < b.remote
            case "rport": r = (Int(a.remotePort) ?? 0) < (Int(b.remotePort) ?? 0)
            case "state": r = a.state < b.state
            default: r = a.processName.localizedCaseInsensitiveCompare(b.processName) == .orderedAscending
            }
            return sortAsc ? r : !r
        }
        let est = all.filter { $0.state == "ESTABLISHED" }.count, lis = all.filter { $0.state == "LISTEN" }.count
        countLabel.stringValue = "\(rows.count) " + L("z") + " \(all.count) · " + L("ustanowione") + " \(est) · " + L("nasłuchujące") + " \(lis)"
        table.reloadData()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { let r = ThemedRowView(); r.inset = 0; r.zebra = row % 2 == 1; return r }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let col = tableColumn else { return nil }
        let c = rows[row]
        let cell = NSTableCellView()
        let l: NSTextField
        switch col.identifier.rawValue {
        case "pid": l = Label.make(c.pid > 0 ? "\(c.pid)" : "—", size: 11.5, dim: true, mono: true); l.alignment = .right
        case "proto": l = Label.make(c.proto, size: 11.5, dim: true, mono: true)
        case "local": l = Label.make(c.local, size: 11.5, mono: true)
        case "lport": l = Label.make(c.localPort, size: 11.5, mono: true); l.alignment = .right
        case "remote": l = Label.make(c.remote, size: 11.5, mono: true); if c.remote == "*" { l.textColor = P.textDim }
        case "rport": l = Label.make(c.remotePort, size: 11.5, mono: true); l.alignment = .right
        case "state":
            l = Label.make(stateText(c.state), size: 11.5)
            l.textColor = c.state == "ESTABLISHED" ? P.good : (c.state == "LISTEN" ? P.network : P.textDim)
        default:
            l = Label.make(c.processName, size: 11.5)
            let iv = NSImageView(); iv.size(width: 14, height: 14)
            if c.pid > 0, let app = NSRunningApplication(processIdentifier: pid_t(c.pid)), let img = app.icon { img.size = NSSize(width: 14, height: 14); iv.image = img }
            else { iv.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: nil); iv.contentTintColor = P.textDim }
            hstack([iv, l], spacing: 6).pinCentered(to: cell, leading: 2, trailing: 2)
            return cell
        }
        l.pinCentered(to: cell, leading: 2, trailing: 4)
        return cell
    }
    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        guard let d = tableView.sortDescriptors.first, let k = d.key else { return }
        sortKey = k; sortAsc = d.ascending; rebuild()
    }
}
