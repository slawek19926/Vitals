// InstalledAppsViewController.swift - „Zainstalowane aplikacje”: lista z rozmiarami, szczegóły, pliki powiązane, odinstalowanie
import AppKit
import CoreServices

final class InstalledApp {
    let path: String
    let name: String
    let version: String
    let bundleID: String
    let source: String          // App Store / Apple / Inny
    let lastUsed: Date?
    let modified: Date?
    var size: UInt64? = nil
    var related: [(String, UInt64)]? = nil
    init(path: String, name: String, version: String, bundleID: String, source: String, lastUsed: Date?, modified: Date?) {
        self.path = path; self.name = name; self.version = version; self.bundleID = bundleID; self.source = source; self.lastUsed = lastUsed; self.modified = modified
    }
}

enum FileSizer {
    /// Suma rozmiarów plików w katalogu (rozmiar alokacji), rekurencyjnie
    static func directorySize(_ path: String) -> UInt64 {
        var total: UInt64 = 0
        let url = URL(fileURLWithPath: path)
        guard let en = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey], options: [], errorHandler: { _, _ in true }) else { return 0 }
        for case let f as URL in en {
            if let v = try? f.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey]), v.isRegularFile == true, let s = v.totalFileAllocatedSize { total += UInt64(s) }
        }
        return total
    }
}

final class InstalledAppsViewController: NSViewController, NSSplitViewDelegate, NSTableViewDataSource, NSTableViewDelegate, PageRefreshable {
    private let table = NSTableView()
    private let search = NSSearchField()
    private let kind = NSPopUpButton(frame: .zero, pullsDown: false)
    private let countLabel = Label.make("", size: 11, dim: true)
    private var all: [InstalledApp] = []
    private var rows: [InstalledApp] = []
    private var loading = false
    private var lastLoad = Date.distantPast
    private var sortKey = "name", sortAsc = true
    private let sizeQueue = DispatchQueue(label: "appsizes", qos: .utility, attributes: .concurrent)

    // panel szczegółów
    private let icon = NSImageView()
    private let dName = NSTextField(labelWithString: "")
    private let dVersion = Label.make("", size: 14, dim: true)
    private var dRows: [String: NSTextField] = [:]
    private let relatedTitle = Label.make(L("Pliki powiązane"), size: 14, weight: .semibold)
    private let relatedStack = vstack([], spacing: 3)
    private weak var splitView: NSSplitView?
    /// true dopiero po ustawieniu podziału na znanej szerokości – wcześniej nie zapisujemy pozycji
    private var splitApplied = false
    private let uninstall = NSButton(title: L("Odinstaluj…"), target: nil, action: nil)
    private let reveal = NSButton(title: L("Pokaż w Finderze"), target: nil, action: nil)

    override func loadView() {
        view = NSView()
        let title = PageTitleView(L("Zainstalowane aplikacje"))
        kind.addItems(withTitles: ["Wszystkie", "App Store", "Inne (poza App Store)", "Systemowe Apple"].map { L($0) })
        kind.target = self; kind.action = #selector(filterChanged); kind.font = Fonts.ui(11.5); kind.controlSize = .small
        search.placeholderString = L("Filtruj aplikacje"); search.font = Fonts.ui(11.5); search.size(width: 240)
        search.target = self; search.action = #selector(filterChanged); search.sendsSearchStringImmediately = true
        let refresh = NSButton(title: L("Odśwież"), target: self, action: #selector(reload))
        refresh.bezelStyle = .rounded; refresh.controlSize = .small; refresh.font = Fonts.ui(11.5)
        title.accessory = hstack([countLabel, kind, search, refresh], spacing: 8)

        for (id, t, w) in [("name", "Nazwa", 260), ("version", "Wersja", 90), ("source", "Źródło", 110), ("used", "Ostatnio otwarta", 150), ("size", "Rozmiar", 90)] {
            let c = NSTableColumn(identifier: .init(id)); c.title = L(t); c.width = CGFloat(w); c.minWidth = 50
            c.sortDescriptorPrototype = NSSortDescriptor(key: id, ascending: id != "size" && id != "used")
            if id == "size" { c.headerCell.alignment = .right }
            table.addTableColumn(c)
        }
        table.sortDescriptors = [NSSortDescriptor(key: "name", ascending: true)]
        table.rowHeight = 26
        table.intercellSpacing = NSSize(width: 8, height: 1)
        table.backgroundColor = .clear
        table.style = .plain
        table.focusRingType = .none
        table.dataSource = self; table.delegate = self
        table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        // prawy przycisk na nagłówku: wybór widocznych kolumn
        ColumnMenu.attach(to: table, key: "installedApps", locked: ["name"])
        table.target = self; table.doubleAction = #selector(revealApp)
        let scroll = NSScrollView(); scroll.documentView = table; scroll.drawsBackground = false; scroll.hasVerticalScroller = true; scroll.scrollerStyle = .overlay; scroll.autohidesScrollers = true

        // szczegóły
        icon.size(width: 72, height: 72)
        dName.font = Fonts.ui(20, .semibold)
        let head = hstack([icon, vstack([hstack([dName, dVersion], spacing: 8, alignment: .firstBaseline)], spacing: 2), spacer()], spacing: 14, alignment: .top)
        var kv: [NSView] = []
        for k in ["Identyfikator", "Źródło", "Ostatnio otwarta", "Zmodyfikowana", "Rozmiar", "Ścieżka"] {
            let row = KeyValueRow(k, "—", keyWidth: 130); dRows[k] = row.valueLabel; kv.append(row)
        }
        uninstall.bezelStyle = .rounded; uninstall.controlSize = .small; uninstall.font = Fonts.ui(11.5); uninstall.target = self; uninstall.action = #selector(uninstallApp)
        reveal.bezelStyle = .rounded; reveal.controlSize = .small; reveal.font = Fonts.ui(11.5); reveal.target = self; reveal.action = #selector(revealApp)
        let buttons = hstack([reveal, uninstall, spacer()], spacing: 8)
        let dv = vstack([head] + kv + [buttons, relatedTitle, relatedStack], spacing: 4)
        dv.setCustomSpacing(12, after: head)
        dv.setCustomSpacing(12, after: buttons)
        dv.setCustomSpacing(6, after: relatedTitle)
        let dScroll = NSScrollView(); dScroll.drawsBackground = false; dScroll.hasVerticalScroller = true; dScroll.scrollerStyle = .overlay; dScroll.autohidesScrollers = true
        let doc = FlippedView(); dScroll.documentView = doc
        dv.pin(to: doc, insets: NSEdgeInsets(top: 8, left: 16, bottom: 16, right: 16))
        doc.translatesAutoresizingMaskIntoConstraints = false
        doc.widthAnchor.constraint(equalTo: dScroll.contentView.widthAnchor).isActive = true

        // lista i szczegóły rozdzielone uchwytem, którego pozycję można przeciągać i która się zapamiętuje
        let divider = ThemedView(); divider.size(width: 1); divider.layer?.backgroundColor = P.border.alpha(0.6).cgColor
        divider.isHidden = true
        let body = NSSplitView()
        body.isVertical = true
        body.dividerStyle = .thin
        // bez autozapisu AppKit: pozycję trzymamy sami, inaczej dwa mechanizmy się nadpisują
        body.addArrangedSubview(scroll)
        body.addArrangedSubview(dScroll)
        body.delegate = self
        splitView = body
        body.setContentHuggingPriority(.init(1), for: .vertical)
        let root = vstack([title, body], spacing: 6)
        for v in [title, body] { v.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true }
        root.pin(to: view, insets: NSEdgeInsets(top: 2, left: 18, bottom: 0, right: 18))
        NotificationCenter.default.addObserver(forName: .themeChanged, object: nil, queue: .main) { [weak self] _ in
            self?.table.reloadData(); divider.layer?.backgroundColor = P.border.alpha(0.6).cgColor; self?.dName.textColor = P.text
        }
        dName.textColor = P.text
        showDetails(nil)
    }

    func pageDidAppear() { if Date().timeIntervalSince(lastLoad) > 300 { reload() } }

    @objc private func reload() {
        guard !loading else { return }
        loading = true
        countLabel.stringValue = L("skanowanie…")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var apps: [InstalledApp] = []
            let dirs = ["/Applications", "/Applications/Utilities", "\(NSHomeDirectory())/Applications", "/System/Applications", "/System/Applications/Utilities"]
            var seen = Set<String>()
            func scanDir(_ dir: String, depth: Int) {
                guard let items = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return }
                for item in items {
                    let path = dir + "/" + item
                    if item.hasSuffix(".app") {
                        guard !seen.contains(path) else { continue }
                        seen.insert(path)
                        if let app = Self.inspect(path) { apps.append(app) }
                    } else if depth < 2, !item.hasPrefix("."), (try? FileManager.default.attributesOfItem(atPath: path))?[.type] as? FileAttributeType == .typeDirectory {
                        scanDir(path, depth: depth + 1)
                    }
                }
            }
            for dir in dirs { scanDir(dir, depth: 0) }
            DispatchQueue.main.async {
                guard let self else { return }
                self.all = apps; self.loading = false; self.lastLoad = Date(); self.rebuild()
                self.computeSizes()
            }
        }
    }

    static func inspect(_ path: String) -> InstalledApp? {
        let bundle = Bundle(path: path)
        let info = bundle?.infoDictionary ?? [:]
        let name = (info["CFBundleDisplayName"] as? String) ?? (info["CFBundleName"] as? String) ?? String(path.split(separator: "/").last!.dropLast(4))
        let version = (info["CFBundleShortVersionString"] as? String) ?? (info["CFBundleVersion"] as? String) ?? ""
        let bid = bundle?.bundleIdentifier ?? ""
        var source = "Inny"
        if path.hasPrefix("/System/") || bid.hasPrefix("com.apple.") { source = "Apple" }
        else if FileManager.default.fileExists(atPath: path + "/Contents/_MASReceipt/receipt") { source = "App Store" }
        var lastUsed: Date? = nil
        if let md = MDItemCreate(kCFAllocatorDefault, path as CFString) {
            lastUsed = MDItemCopyAttribute(md, kMDItemLastUsedDate) as? Date
        }
        let modified = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
        return InstalledApp(path: path, name: name, version: version, bundleID: bid, source: source, lastUsed: lastUsed, modified: modified)
    }

    private func computeSizes() {
        for app in all where app.size == nil {
            sizeQueue.async { [weak self] in
                let s = FileSizer.directorySize(app.path)
                DispatchQueue.main.async {
                    app.size = s
                    guard let self, let idx = self.rows.firstIndex(where: { $0 === app }) else { return }
                    self.table.reloadData(forRowIndexes: IndexSet(integer: idx), columnIndexes: IndexSet(integer: 4))
                    if self.selected === app { self.dRows["Rozmiar"]?.stringValue = Fmt.bytes(s) }
                }
            }
        }
    }

    @objc private func filterChanged() { rebuild() }

    private func rebuild() {
        let f = search.stringValue.lowercased()
        rows = all.filter { a in
            switch kind.indexOfSelectedItem {
            case 1: if a.source != "App Store" { return false }
            case 2: if a.source != "Inny" { return false }
            case 3: if a.source != "Apple" { return false }
            default: break
            }
            return f.isEmpty || a.name.lowercased().contains(f) || a.bundleID.lowercased().contains(f)
        }
        rows.sort { a, b in
            let r: Bool
            switch sortKey {
            case "version": r = a.version < b.version
            case "source": r = a.source < b.source
            case "used": r = (a.lastUsed ?? .distantPast) < (b.lastUsed ?? .distantPast)
            case "size": r = (a.size ?? 0) < (b.size ?? 0)
            default: r = a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
            }
            return sortAsc ? r : !r
        }
        let total = all.compactMap { $0.size }.reduce(0, +)
        countLabel.stringValue = "\(rows.count) " + L("z") + " \(all.count) " + L("aplikacji") + " · \(Fmt.bytes(total))"
        table.reloadData()
    }

    private var selected: InstalledApp? { table.selectedRow >= 0 && table.selectedRow < rows.count ? rows[table.selectedRow] : nil }

    private func showDetails(_ a: InstalledApp?) {
        relatedStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        guard let a else {
            icon.image = nil; dName.stringValue = L("Wybierz aplikację"); dVersion.stringValue = ""
            for v in dRows.values { v.stringValue = L("—") }
            uninstall.isEnabled = false; reveal.isEnabled = false
            relatedTitle.stringValue = L("Pliki powiązane")
            return
        }
        let img = NSWorkspace.shared.icon(forFile: a.path); img.size = NSSize(width: 72, height: 72); icon.image = img
        dName.stringValue = a.name; dVersion.stringValue = a.version
        dRows["Identyfikator"]?.stringValue = a.bundleID.isEmpty ? L("—") : a.bundleID
        dRows["Źródło"]?.stringValue = a.source
        dRows["Ostatnio otwarta"]?.stringValue = a.lastUsed.map { Fmt.dateTime.string(from: $0) } ?? L("nigdy / nieznane")
        dRows["Zmodyfikowana"]?.stringValue = a.modified.map { Fmt.dateTime.string(from: $0) } ?? L("—")
        dRows["Rozmiar"]?.stringValue = a.size.map { Fmt.bytes($0) } ?? L("obliczanie…")
        dRows["Ścieżka"]?.stringValue = a.path
        uninstall.isEnabled = a.source != "Apple"; reveal.isEnabled = true
        relatedTitle.stringValue = L("Pliki powiązane (szukanie…)")
        let home = NSHomeDirectory()
        let candidates = [
            "\(home)/Library/Application Support/\(a.name)", "\(home)/Library/Application Support/\(a.bundleID)",
            "\(home)/Library/Caches/\(a.bundleID)", "\(home)/Library/Preferences/\(a.bundleID).plist",
            "\(home)/Library/Containers/\(a.bundleID)", "\(home)/Library/Logs/\(a.name)", "\(home)/Library/Logs/\(a.bundleID)",
            "\(home)/Library/Saved Application State/\(a.bundleID).savedState", "\(home)/Library/HTTPStorages/\(a.bundleID)",
            "\(home)/Library/WebKit/\(a.bundleID)", "\(home)/Library/Cookies/\(a.bundleID).binarycookies",
        ].filter { !a.bundleID.isEmpty || !$0.contains("//") }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var found: [(String, UInt64)] = []
            for c in candidates where FileManager.default.fileExists(atPath: c) {
                var isDir: ObjCBool = false
                FileManager.default.fileExists(atPath: c, isDirectory: &isDir)
                let size = isDir.boolValue ? FileSizer.directorySize(c) : UInt64((try? FileManager.default.attributesOfItem(atPath: c))?[.size] as? Int ?? 0)
                found.append((c, size))
            }
            DispatchQueue.main.async {
                guard let self, self.selected === a else { return }
                a.related = found
                self.relatedTitle.stringValue = L("Pliki powiązane") + " (\(found.count)) · \(Fmt.bytes(found.reduce(0) { $0 + $1.1 }))"
                if found.isEmpty { self.relatedStack.addArrangedSubview(Label.make(L("Nie znaleziono plików poza pakietem aplikacji."), size: 11.5, dim: true)) }
                for (p, s) in found {
                    let l = Label.make(p.replacingOccurrences(of: home, with: "~"), size: 11.5)
                    let r = Label.make(Fmt.bytes(s), size: 11.5, dim: true, mono: true)
                    let row = hstack([l, spacer(), r])
                    self.relatedStack.addArrangedSubview(row)
                    row.widthAnchor.constraint(equalTo: self.relatedStack.widthAnchor).isActive = true
                }
            }
        }
    }

    @objc private func revealApp() { if let a = selected { NSWorkspace.shared.selectFile(a.path, inFileViewerRootedAtPath: "") } }

    @objc private func uninstallApp() {
        guard let a = selected else { return }
        let alert = NSAlert()
        alert.messageText = L("Przenieść „") + "\(a.name)” " + L("do Kosza?")
        let rel = a.related ?? []
        alert.informativeText = L("Aplikacja") + (rel.isEmpty ? "" : " oraz \(rel.count) plików powiązanych (\(Fmt.bytes(rel.reduce(0) { $0 + $1.1 })))") + " zostaną przeniesione do Kosza. Możesz je przywrócić z Kosza."
        alert.alertStyle = .warning
        alert.addButton(withTitle: L("Przenieś do Kosza")); alert.addButton(withTitle: L("Anuluj"))
        if !rel.isEmpty { alert.showsSuppressionButton = true; alert.suppressionButton?.title = L("Tylko aplikacja, bez plików powiązanych") }
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        var urls = [URL(fileURLWithPath: a.path)]
        if alert.suppressionButton?.state != .on { urls += rel.map { URL(fileURLWithPath: $0.0) } }
        NSWorkspace.shared.recycle(urls) { [weak self] _, error in
            if let error { let e = NSAlert(error: error); e.runModal() }
            self?.lastLoad = .distantPast; self?.reload()
        }
    }

    // MARK: tabela
    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMin: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat { 240 }
    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMax: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        max(240, splitView.bounds.width - 320)
    }
    func splitViewDidResizeSubviews(_ notification: Notification) {
        guard splitApplied, let sv = splitView, sv.subviews.count == 2 else { return }
        UserDefaults.standard.set(sv.subviews[0].frame.width, forKey: "InstalledAppsSplitPos")
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        guard !splitApplied, let sv = splitView, sv.subviews.count == 2, sv.bounds.width > 400 else { return }
        let d = UserDefaults.standard
        // jednorazowy reset zapamiętanej pozycji zapisanej przed pierwszym layoutem (50/50)
        if !d.bool(forKey: "InstalledAppsSplitDefaultV4") {
            d.set(true, forKey: "InstalledAppsSplitDefaultV4")
            d.removeObject(forKey: "InstalledAppsSplitPos")
        }
        let saved = d.double(forKey: "InstalledAppsSplitPos")
        let fallback = max(240, sv.bounds.width - 340)   // szczegóły 340 pt, jak na stronie Sterowniki
        let pos = saved > 240 ? min(saved, max(240, sv.bounds.width - 320)) : fallback
        sv.setPosition(pos, ofDividerAt: 0)
        splitApplied = true
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { let r = ThemedRowView(); r.inset = 0; r.zebra = row % 2 == 1; return r }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let col = tableColumn else { return nil }
        let a = rows[row]
        let cell = NSTableCellView()
        switch col.identifier.rawValue {
        case "version": Label.make(a.version, size: 11.5, dim: true).pinCentered(to: cell, leading: 2, trailing: 4)
        case "source":
            let l = Label.make(a.source, size: 11.5); l.textColor = a.source == "App Store" ? P.network : (a.source == "Apple" ? P.textDim : P.text)
            l.pinCentered(to: cell, leading: 2, trailing: 4)
        case "used": Label.make(a.lastUsed.map { Fmt.dateTime.string(from: $0) } ?? "—", size: 11.5, dim: true, mono: true).pinCentered(to: cell, leading: 2, trailing: 4)
        case "size":
            let l = Label.make(a.size.map { Fmt.bytes($0) } ?? "…", size: 11.5, mono: true); l.alignment = .right
            l.pinCentered(to: cell, leading: 2, trailing: 4)
        default:
            let iv = NSImageView(); iv.size(width: 18, height: 18)
            let img = NSWorkspace.shared.icon(forFile: a.path); img.size = NSSize(width: 18, height: 18); iv.image = img
            hstack([iv, Label.make(a.name, size: 12)], spacing: 8).pinCentered(to: cell, leading: 2, trailing: 2)
        }
        return cell
    }
    func tableViewSelectionDidChange(_ notification: Notification) { showDetails(selected) }
    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        guard let d = tableView.sortDescriptors.first, let k = d.key else { return }
        sortKey = k; sortAsc = d.ascending; rebuild()
    }
}
