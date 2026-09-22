// ConnectionsViewController.swift - połączenia sieciowe pogrupowane według procesu i celu
import AppKit

extension Notification.Name { static let filterConnections = Notification.Name("FilterConnections") }

struct Connection {
    let proto: String
    let local: String, localPort: String
    let remote: String, remotePort: String
    let state: String
    let pid: Int
    var processName: String
    let socketID: String

    var identity: String {
        if !socketID.isEmpty { return "\(pid)\u{1F}\(socketID)" }
        return [String(pid), proto, local, localPort, remote, remotePort, state].joined(separator: "\u{1F}")
    }
    var hasPeer: Bool { remote != "*" && !remote.isEmpty }
    var destinationKey: String {
        (hasPeer ? ["remote", proto, remote, remotePort] : ["local", proto, local, localPort]).joined(separator: "\u{1F}")
    }
}

struct ConnectionDestination {
    let key: String
    let sockets: [Connection]
    var first: Connection { sockets[0] }
    var localAddresses: [String] { Array(Set(sockets.map(\.local))).sorted() }
    var localPorts: [String] { Array(Set(sockets.map(\.localPort))).sorted { (Int($0) ?? -1) < (Int($1) ?? -1) } }
    var local: String { localAddresses.count == 1 ? first.local : ConnectionPresentation.quantity(localAddresses.count, one: "adres", few: "adresy", many: "adresów") }
    var localPort: String { localPorts.count == 1 ? first.localPort : ConnectionPresentation.quantity(localPorts.count, one: "port", few: "porty", many: "portów") }
    var state: String { Set(sockets.map(\.state)).count == 1 ? first.state : "" }
    var hasMixedStates: Bool { Set(sockets.map(\.state)).count > 1 }
}

struct ConnectionProcess {
    let pid: Int
    let name: String
    let destinations: [ConnectionDestination]
    var socketCount: Int { destinations.reduce(0) { $0 + $1.sockets.count } }
}

enum ConnectionPresentation {
    static func quantity(_ count: Int, one: String, few: String, many: String) -> String {
        let form: String
        if count == 1 { form = one }
        else if !L10n.isEnglish && (2...4).contains(count % 10) && !(12...14).contains(count % 100) { form = few }
        else { form = many }
        return "\(count) \(L(form))"
    }

    static func isLocalPeer(_ address: String) -> Bool {
        let host = address.lowercased()
        if host == "localhost" || host == "::1" || host.hasPrefix("fe80:") ||
           host.hasPrefix("fc") || host.hasPrefix("fd") { return true }
        if host.hasPrefix("::ffff:") { return isLocalPeer(String(host.dropFirst(7))) }
        let octets = host.split(separator: ".").compactMap { UInt8($0) }
        guard octets.count == 4 else { return false }
        return octets[0] == 10 || octets[0] == 127 ||
               (octets[0] == 172 && (16...31).contains(octets[1])) ||
               (octets[0] == 192 && octets[1] == 168) ||
               (octets[0] == 169 && octets[1] == 254)
    }

    /// "Zdalne" means a known nonlocal peer; socket direction cannot be inferred from lsof.
    static func matches(_ c: Connection, scope: Int, proto: Int, query: String) -> Bool {
        if proto == 1 && !c.proto.hasPrefix("TCP") { return false }
        if proto == 2 && !c.proto.hasPrefix("UDP") { return false }
        switch scope {
        case 0: if !c.hasPeer || isLocalPeer(c.remote) { return false }
        case 1: if c.state != "LISTEN" { return false }
        case 2: if !c.hasPeer || !isLocalPeer(c.remote) { return false }
        default: break
        }
        if query.isEmpty { return true }
        let f = query.lowercased()
        return c.processName.lowercased().contains(f) || c.local.lowercased().contains(f) ||
               c.remote.lowercased().contains(f) || c.localPort == f || c.remotePort == f ||
               String(c.pid) == f || c.state.lowercased().contains(f)
    }

    private static func compare(_ a: Connection, _ b: Connection, key: String) -> ComparisonResult {
        switch key {
        case "pid": return NSNumber(value: a.pid).compare(NSNumber(value: b.pid))
        case "lport": return NSNumber(value: Int(a.localPort) ?? -1).compare(NSNumber(value: Int(b.localPort) ?? -1))
        case "rport": return NSNumber(value: Int(a.remotePort) ?? -1).compare(NSNumber(value: Int(b.remotePort) ?? -1))
        case "proto": return a.proto.localizedStandardCompare(b.proto)
        case "local": return a.local.localizedStandardCompare(b.local)
        case "remote": return a.remote.localizedStandardCompare(b.remote)
        case "state": return a.state.localizedStandardCompare(b.state)
        default: return a.processName.localizedStandardCompare(b.processName)
        }
    }

    static func sorted(_ list: [Connection], key: String, ascending: Bool) -> [Connection] {
        list.sorted { a, b in
            let order = compare(a, b, key: key)
            if order == .orderedSame { return a.identity < b.identity }
            return ascending ? order == .orderedAscending : order == .orderedDescending
        }
    }

    static func grouped(_ list: [Connection], sortKey: String, ascending: Bool) -> [ConnectionProcess] {
        Dictionary(grouping: list, by: \.pid).map { pid, sockets in
            let destinations = Dictionary(grouping: sockets, by: \.destinationKey).map { key, sameDestination in
                ConnectionDestination(key: key, sockets: sorted(sameDestination, key: sortKey, ascending: ascending))
            }.sorted { a, b in
                let order = compare(a.first, b.first, key: sortKey)
                if order == .orderedSame { return a.key < b.key }
                return ascending ? order == .orderedAscending : order == .orderedDescending
            }
            return ConnectionProcess(pid: pid, name: sockets[0].processName, destinations: destinations)
        }.sorted { a, b in
            let result = a.name.localizedStandardCompare(b.name)
            return result == .orderedSame ? a.pid < b.pid : result == .orderedAscending
        }
    }
}

final class ConnectionsViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, PageRefreshable {
    private enum DisplayRow {
        case process(ConnectionProcess)
        case destination(ConnectionDestination)
        case socketDetail(Connection)
        case socket(Connection)
    }

    private let table = NSTableView()
    private let search = NSSearchField()
    private let mode = NSPopUpButton(frame: .zero, pullsDown: false)
    private let scope = NSPopUpButton(frame: .zero, pullsDown: false)
    private let proto = NSPopUpButton(frame: .zero, pullsDown: false)
    private let countLabel = Label.make("", size: 11, dim: true)
    private var all: [Connection] = []
    private var rows: [DisplayRow] = []
    private var timer: Timer?
    private var loading = false
    private var sortKey = "process"
    private var sortAsc = true
    private var collapsedPIDs = Set<Int>()
    private var expandedDestinations = Set<String>()
    private var firstSeen: [String: Date] = [:]
    private var hasLoaded = false
    private var readWarning: String?
    private var usesGroupedColumns = false
    private var rawHiddenColumns = Set<String>()
    private var rawColumnWidths: [String: CGFloat] = [:]
    private var rawHeaderMenu: NSMenu?

    override func loadView() {
        view = NSView()
        let title = PageTitleView(L("Połączenia"))
        let refresh = NSButton(title: L("Odśwież"), target: self, action: #selector(reload))
        refresh.bezelStyle = .rounded; refresh.controlSize = .small; refresh.font = Fonts.ui(11.5)
        title.accessory = hstack([countLabel, refresh], spacing: 10)

        mode.addItems(withTitles: ["Aplikacje", "Gniazda"].map { L($0) })
        scope.addItems(withTitles: ["Zdalne", "Nasłuchujące", "Lokalne", "Wszystkie"].map { L($0) })
        proto.addItems(withTitles: ["TCP + UDP", "TCP", "UDP"])
        for popup in [mode, scope, proto] {
            popup.font = Fonts.ui(11.5); popup.controlSize = .small
            popup.target = self; popup.action = #selector(filterChanged)
        }
        search.placeholderString = L("Filtruj: proces, adres, port")
        search.font = Fonts.ui(11.5); search.size(width: 240)
        search.target = self; search.action = #selector(filterChanged); search.sendsSearchStringImmediately = true
        let filters = hstack([mode, scope, proto, search, spacer()], spacing: 8)

        for (id, t, w) in [("process", "Proces", 230), ("pid", "PID", 64), ("proto", "Protokół", 70),
                           ("local", "Adres lokalny", 200), ("lport", "Port", 70),
                           ("remote", "Adres zdalny", 220), ("rport", "Port zdalny", 80), ("state", "Stan", 150)] {
            let c = NSTableColumn(identifier: .init(id)); c.title = L(t); c.width = CGFloat(w); c.minWidth = 40
            c.sortDescriptorPrototype = NSSortDescriptor(key: id, ascending: true)
            if id == "pid" || id == "lport" || id == "rport" { c.headerCell.alignment = .right }
            table.addTableColumn(c)
        }
        table.sortDescriptors = [NSSortDescriptor(key: "process", ascending: true)]
        table.rowHeight = 24
        table.intercellSpacing = NSSize(width: 8, height: 1)
        table.backgroundColor = .clear; table.style = .plain; table.focusRingType = .none
        table.dataSource = self; table.delegate = self
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        ColumnMenu.attach(to: table, key: "connections", locked: ["process"])
        rawHiddenColumns = Set(table.tableColumns.filter(\.isHidden).map { $0.identifier.rawValue })
        rawHeaderMenu = table.headerView?.menu
        let scroll = NSScrollView(); scroll.documentView = table
        scroll.drawsBackground = false; scroll.hasVerticalScroller = true
        scroll.scrollerStyle = .overlay; scroll.autohidesScrollers = true
        scroll.setContentHuggingPriority(.init(1), for: .vertical)
        let root = vstack([title, filters, scroll], spacing: 8)
        for v in [title, filters, scroll] { v.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true }
        root.pin(to: view, insets: NSEdgeInsets(top: 2, left: 18, bottom: 10, right: 18))
        DispatchQueue.main.async { [weak self] in self?.updateColumnMode() }
        NotificationCenter.default.addObserver(forName: .themeChanged, object: nil, queue: .main) { [weak self] _ in self?.table.reloadData() }
        NotificationCenter.default.addObserver(forName: .filterConnections, object: nil, queue: .main) { [weak self] n in
            if let pid = n.object as? Int {
                self?.scope.selectItem(at: 3)
                self?.search.stringValue = "\(pid)"
                self?.rebuild()
            }
        }
    }

    func pageDidAppear() {
        reload()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            guard let self, self.view.window != nil, !self.view.isHiddenOrHasHiddenAncestor else {
                self?.timer?.invalidate(); self?.timer = nil; return
            }
            self.reload()
        }
    }

    @objc private func reload() {
        guard !loading else { return }
        loading = true
        let procs = Dictionary(Monitor.shared.latest.processes.map { ($0.pid, $0.name) }, uniquingKeysWith: { first, _ in first })
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Shell.execute("/usr/sbin/lsof", ["-nP", "-iTCP", "-iUDP"], timeout: 20)
            let list = Self.parseLsof(result.stdout, procs: procs)
            DispatchQueue.main.async {
                guard let self else { return }
                self.loading = false
                if result.succeeded || !list.isEmpty {
                    self.all = list
                    self.markNewConnections(list)
                    self.readWarning = result.succeeded ? nil : L("Niepełny odczyt połączeń")
                } else {
                    self.readWarning = L("Błąd odświeżania; pokazano ostatni odczyt")
                }
                self.rebuild()
            }
        }
    }

    private func markNewConnections(_ list: [Connection]) {
        let keys = Set(list.map(\.identity))
        let now = Date()
        firstSeen = firstSeen.filter { keys.contains($0.key) }
        for key in keys where firstSeen[key] == nil { firstSeen[key] = hasLoaded ? now : .distantPast }
        hasLoaded = true
    }

    static func splitHostPort(_ s: String) -> (String, String) {
        guard let colon = s.lastIndex(of: ":") else { return (s, "") }
        var host = String(s[..<colon]); let port = String(s[s.index(after: colon)...])
        if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        return (host, port)
    }

    /// lsof -nP -iTCP -iUDP: COMMAND PID USER FD TYPE DEVICE SIZE/OFF NODE NAME
    static func parseLsof(_ out: String, procs: [Int: String]) -> [Connection] {
        var result: [Connection] = []
        var seenSockets = Set<String>()
        for line in out.split(separator: "\n").dropFirst() {
            let f = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard f.count >= 9, let pid = Int(f[1]) else { continue }
            let proto = f[7]
            guard proto == "TCP" || proto == "UDP" else { continue }
            var name = f[8...].joined(separator: " ")
            var state = ""
            if let p = name.range(of: " ("), name.hasSuffix(")") {
                state = String(name[p.upperBound..<name.index(before: name.endIndex)])
                name = String(name[..<p.lowerBound])
            }
            let parts = name.components(separatedBy: "->")
            let (lh, lp) = splitHostPort(parts[0])
            let (rh, rp) = parts.count > 1 ? splitHostPort(parts[1]) : ("*", "*")
            let cmd = f[0].replacingOccurrences(of: "\\x20", with: " ")
            let socketID = f[5]
            let identity = "\(pid)\u{1F}\(socketID)"
            if !socketID.isEmpty && !seenSockets.insert(identity).inserted { continue }
            result.append(Connection(proto: proto + (f[4].contains("6") ? "6" : "4"), local: lh, localPort: lp,
                                     remote: rh, remotePort: rp, state: state, pid: pid, processName: procs[pid] ?? cmd,
                                     socketID: socketID))
        }
        return result
    }

    private func stateText(_ s: String) -> String {
        L(["ESTABLISHED": "ustanowione", "LISTEN": "nasłuchuje", "CLOSE_WAIT": "zamykanie (CLOSE_WAIT)",
           "TIME_WAIT": "TIME_WAIT", "SYN_SENT": "łączenie (SYN_SENT)", "CLOSED": "zamknięte",
           "FIN_WAIT_1": "FIN_WAIT_1", "FIN_WAIT_2": "FIN_WAIT_2", "LAST_ACK": "LAST_ACK", "CLOSING": "zamykanie"][s] ??
          (s.isEmpty ? "—" : s))
    }

    @objc private func filterChanged() { updateColumnMode(); rebuild() }

    private func updateColumnMode() {
        let grouped = mode.indexOfSelectedItem == 0
        guard grouped != usesGroupedColumns else { return }
        if grouped {
            rawHiddenColumns = Set(table.tableColumns.filter(\.isHidden).map { $0.identifier.rawValue })
            rawColumnWidths = Dictionary(uniqueKeysWithValues: table.tableColumns.map { ($0.identifier.rawValue, $0.width) })
            table.headerView?.menu = nil
        } else {
            table.headerView?.menu = rawHeaderMenu
        }
        let groupedVisible: Set<String> = ["process", "local", "lport", "state"]
        let groupedWidths: [String: CGFloat] = ["process": 440, "local": 245, "lport": 130, "state": 210]
        for column in table.tableColumns {
            let id = column.identifier.rawValue
            column.isHidden = grouped ? !groupedVisible.contains(id) : rawHiddenColumns.contains(id)
            column.width = grouped ? (groupedWidths[id] ?? column.width) : (rawColumnWidths[id] ?? column.width)
            if id == "process" { column.title = L(grouped ? "Proces i cel" : "Proces") }
            if id == "lport" { column.title = L(grouped ? "Port lokalny" : "Port") }
        }
        usesGroupedColumns = grouped
        table.sizeLastColumnToFit()
        table.headerView?.needsDisplay = true
    }

    private func isNew(_ c: Connection) -> Bool {
        firstSeen[c.identity].map { Date().timeIntervalSince($0) < 10 } ?? false
    }

    private func rebuild() {
        let filtered = all.filter { ConnectionPresentation.matches($0, scope: scope.indexOfSelectedItem,
                                                                    proto: proto.indexOfSelectedItem,
                                                                    query: search.stringValue) }
        if mode.indexOfSelectedItem == 0 {
            rows = []
            for process in ConnectionPresentation.grouped(filtered, sortKey: sortKey, ascending: sortAsc) {
                rows.append(.process(process))
                if !collapsedPIDs.contains(process.pid) || !search.stringValue.isEmpty {
                    for destination in process.destinations {
                        rows.append(.destination(destination))
                        if destination.sockets.count > 1 && expandedDestinations.contains(destinationExpansionKey(destination)) {
                            rows.append(contentsOf: destination.sockets.map(DisplayRow.socketDetail))
                        }
                    }
                }
            }
        } else {
            rows = ConnectionPresentation.sorted(filtered, key: sortKey, ascending: sortAsc).map(DisplayRow.socket)
        }
        let processCount = Set(filtered.map(\.pid)).count
        let count = ConnectionPresentation.quantity(processCount, one: "proces", few: "procesy", many: "procesów") +
                    " · " + ConnectionPresentation.quantity(filtered.count, one: "gniazdo", few: "gniazda", many: "gniazd")
        countLabel.stringValue = readWarning.map { count + " · ⚠ " + $0 } ?? count
        countLabel.textColor = readWarning == nil ? P.textDim : P.bad
        countLabel.toolTip = readWarning
        table.reloadData()
    }

    @objc private func toggleProcess(_ sender: NSButton) {
        guard search.stringValue.isEmpty else { return }
        guard sender.tag < rows.count, case .process(let process) = rows[sender.tag] else { return }
        if collapsedPIDs.contains(process.pid) { collapsedPIDs.remove(process.pid) }
        else { collapsedPIDs.insert(process.pid) }
        rebuild()
    }

    private func destinationExpansionKey(_ destination: ConnectionDestination) -> String {
        "\(destination.first.pid)\u{1F}\(destination.key)"
    }

    private func endpointLabel(_ connection: Connection) -> String {
        let host = connection.hasPeer ? connection.remote : connection.local
        let port = connection.hasPeer ? connection.remotePort : connection.localPort
        let displayHost = host.contains(":") ? "[\(host)]" : host
        return "\(connection.proto)  \(displayHost):\(port)"
    }

    @objc private func toggleDestination(_ sender: NSButton) {
        guard sender.tag < rows.count, case .destination(let destination) = rows[sender.tag],
              destination.sockets.count > 1 else { return }
        let key = destinationExpansionKey(destination)
        if expandedDestinations.contains(key) { expandedDestinations.remove(key) }
        else { expandedDestinations.insert(key) }
        rebuild()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let r = ThemedRowView(); r.inset = 0
        if usesGroupedColumns {
            switch rows[row] {
            case .process, .socketDetail: r.zebra = true
            default: r.zebra = false
            }
        } else { r.zebra = row % 2 == 1 }
        return r
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let col = tableColumn else { return nil }
        let item = rows[row]
        let id = col.identifier.rawValue
        let cell = NSTableCellView()
        var label: NSTextField
        var fresh = false
        switch item {
        case .process(let process):
            fresh = process.destinations.contains { $0.sockets.contains(where: isNew) }
            if id == "process" {
                let expanded = !collapsedPIDs.contains(process.pid) || !search.stringValue.isEmpty
                let button = NSButton(title: expanded ? "▾" : "▸", target: self, action: #selector(toggleProcess(_:)))
                button.isBordered = false; button.tag = row; button.size(width: 18, height: 18)
                button.isEnabled = search.stringValue.isEmpty
                button.setAccessibilityLabel(L(expanded ? "Zwiń" : "Rozwiń"))
                let icon = processIcon(process.pid)
                let summary = ConnectionPresentation.quantity(process.socketCount, one: "gniazdo", few: "gniazda", many: "gniazd")
                label = Label.make((fresh ? "● " : "") + process.name + "  ·  PID \(process.pid)  ·  " + summary, size: 11.5, weight: .medium)
                if fresh { label.textColor = P.network }
                hstack([button, icon, label], spacing: 5).pinCentered(to: cell, leading: 2, trailing: 2)
                return cell
            }
            let value: String
            switch id {
            case "pid": value = "\(process.pid)"
            case "state": value = usesGroupedColumns ? "" : ConnectionPresentation.quantity(process.socketCount, one: "gniazdo", few: "gniazda", many: "gniazd")
            default: value = ""
            }
            label = Label.make(value, size: 11.5, dim: true, mono: id == "pid")
        case .destination(let destination):
            fresh = destination.sockets.contains(where: isNew)
            let c = destination.first
            if id == "process" && destination.sockets.count > 1 {
                let expanded = expandedDestinations.contains(destinationExpansionKey(destination))
                let button = NSButton(title: expanded ? "▾" : "▸", target: self, action: #selector(toggleDestination(_:)))
                button.isBordered = false; button.tag = row; button.size(width: 18, height: 18)
                button.setAccessibilityLabel(L(expanded ? "Zwiń" : "Rozwiń"))
                let count = ConnectionPresentation.quantity(destination.sockets.count, one: "gniazdo", few: "gniazda", many: "gniazd")
                label = Label.make(endpointLabel(c) + "  ·  " + count, size: 11.5)
                label.toolTip = endpointLabel(c)
                hstack([button, label], spacing: 4).pinCentered(to: cell, leading: 20, trailing: 2)
                return cell
            }
            let value: String
            switch id {
            case "process": value = endpointLabel(c)
            case "pid": value = ""
            case "proto": value = c.proto
            case "local": value = destination.local
            case "lport": value = destination.localPort
            case "remote": value = c.remote
            case "rport": value = c.remotePort
            default: value = destination.hasMixedStates ? L("różne") : stateText(destination.state)
            }
            label = Label.make(value, size: 11.5, dim: id == "process" || id == "proto" || value == "*", mono: ["proto", "local", "lport", "remote", "rport"].contains(id))
            if id == "process" { label.toolTip = value }
            if id == "local" && destination.localAddresses.count > 1 { label.toolTip = destination.localAddresses.joined(separator: ", ") }
            if id == "lport" && destination.localPorts.count > 1 { label.toolTip = destination.localPorts.joined(separator: ", ") }
        case .socket(let c), .socketDetail(let c):
            let nested: Bool
            if case .socketDetail = item { nested = true } else { nested = false }
            fresh = isNew(c)
            if id == "process" {
                if nested {
                    label = Label.make((fresh ? "● " : "") + L("Gniazdo") + " " + c.proto, size: 11.5, dim: !fresh)
                    if fresh { label.textColor = P.network }
                    label.pinCentered(to: cell, leading: 48, trailing: 2)
                    return cell
                }
                let icon = processIcon(c.pid)
                label = Label.make((fresh ? "● " : "") + c.processName, size: 11.5)
                if fresh { label.textColor = P.network }
                hstack([icon, label], spacing: 6).pinCentered(to: cell, leading: 2, trailing: 2)
                return cell
            }
            let value: String
            switch id {
            case "pid": value = nested ? "" : "\(c.pid)"
            case "proto": value = c.proto
            case "local": value = c.local
            case "lport": value = c.localPort
            case "remote": value = c.remote
            case "rport": value = c.remotePort
            default: value = stateText(c.state)
            }
            label = Label.make(value, size: 11.5, dim: id == "pid" || id == "proto" || value == "*", mono: ["pid", "proto", "local", "lport", "remote", "rport"].contains(id))
        }
        if ["pid", "lport", "rport"].contains(id) { label.alignment = .right }
        if id == "state" {
            let state = switch item {
            case .process: ""
            case .destination(let d): d.state
            case .socket(let c), .socketDetail(let c): c.state
            }
            label.textColor = state == "ESTABLISHED" ? P.good : (state == "LISTEN" ? P.network : P.textDim)
        }
        if fresh && id == "process" { label.textColor = P.network }
        label.pinCentered(to: cell, leading: id == "process" ? 24 : 2, trailing: 4)
        return cell
    }

    private func processIcon(_ pid: Int) -> NSImageView {
        let icon = NSImageView(); icon.size(width: 14, height: 14)
        if pid > 0, let app = NSRunningApplication(processIdentifier: pid_t(pid)), let image = app.icon {
            image.size = NSSize(width: 14, height: 14); icon.image = image
        } else {
            icon.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: nil)
            icon.contentTintColor = P.textDim
        }
        return icon
    }

    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        guard let descriptor = tableView.sortDescriptors.first, let key = descriptor.key else { return }
        sortKey = key; sortAsc = descriptor.ascending; rebuild()
    }
}
