// DriversViewController.swift - „Sterowniki”: rozszerzenia jądra (kext), sterowniki przestrzeni użytkownika (DriverKit)
// i rozszerzenia systemowe. Dane: kmutil showloaded, katalogi rozszerzeń, systemextensionsctl.
import AppKit

struct DriverInfo {
    enum Kind: String {
        case kext = "Rozszerzenie jądra"
        case dext = "Sterownik DriverKit"
        case systemExtension = "Rozszerzenie systemowe"
    }
    var name: String
    var bundleID: String
    var version: String
    var path: String
    var vendor: String
    var kind: Kind
    var loaded: Bool
    var index: Int?
    var refs: Int?
    var size: UInt64?
    var wired: UInt64?
    var uuid: String?
    var dependencies: [Int] = []
    var libraryCount: Int = 0
    var state: String = ""
    var isApple: Bool { bundleID.hasPrefix("com.apple.") || vendor == "Apple" }
}

/// Wpis z `kmutil showloaded`
private struct LoadedKext {
    var index: Int, refs: Int
    var size: UInt64, wired: UInt64
    var version: String, uuid: String
    var dependencies: [Int]
}

final class DriversViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, PageRefreshable {
    private let table = NSTableView()
    private let search = NSSearchField()
    private let filter = NSSegmentedControl(labels: ["Wszystkie", L("Załadowane"), L("Niezaładowane"), L("Zewnętrzne"), "Rozszerzenia"].map { L($0) },
                                            trackingMode: .selectOne, target: nil, action: nil)
    private let shownLabel = Label.make("", size: 11, dim: true)
    private let updatedLabel = Label.make("", size: 11, dim: true)
    private var tiles: [String: TileStat] = [:]

    // panel szczegółów
    private let dIcon = NSImageView()
    private let dName = Label.make("", size: 17, weight: .semibold)
    private let dBundle = Label.make("", size: 11.5, dim: true, mono: true)
    private let dState = Label.make("", size: 12, weight: .medium)
    private var dRows: [String: NSTextField] = [:]
    private let dNote = Label.make("", size: 11, dim: true)
    private let revealButton = NSButton(title: L("Pokaż w Finderze"), target: nil, action: nil)
    private let copyButton = NSButton(title: L("Kopiuj szczegóły"), target: nil, action: nil)

    private var all: [DriverInfo] = []
    private var rows: [DriverInfo] = []
    private var loading = false
    private var lastLoad = Date.distantPast
    private var sortKey = "state", sortAsc = true

    private static let detailKeys = ["Rodzaj", "Wersja", "Producent", "Indeks ładowania", "Odwołania", "Rozmiar",
                                     "Pamięć zablokowana", "Zależy od", "UUID", "Lokalizacja"]

    override func loadView() {
        view = NSView()
        let title = PageTitleView(L("Sterowniki"))
        search.placeholderString = L("Filtruj sterowniki"); search.font = Fonts.ui(11.5); search.size(width: 260)
        search.target = self; search.action = #selector(filterChanged); search.sendsSearchStringImmediately = true
        let refresh = NSButton(title: L("Odśwież"), target: self, action: #selector(reload))
        refresh.bezelStyle = .rounded; refresh.controlSize = .small; refresh.font = Fonts.ui(11.5)
        title.accessory = hstack([search, refresh], spacing: 8)

        // kafelki podsumowania
        let defs: [(String, String, Subsystem)] = [
            ("Sterowniki", "shippingbox", .gpu), ("Załadowane", "bolt.fill", .cpu),
            ("Zewnętrzne", "person.crop.square", .npu), ("Pamięć zablokowana", "memorychip", .memory),
        ]
        var tileViews: [NSView] = []
        for (t, ic, a) in defs { let tile = TileStat(t, icon: ic, accent: a); tiles[t] = tile; tileViews.append(tile) }
        let tileRow = hstack(tileViews, spacing: 10, distribution: .fillEqually)

        filter.selectedSegment = 0
        filter.target = self; filter.action = #selector(filterChanged)
        filter.font = Fonts.ui(11.5); filter.controlSize = .small
        let filterRow = hstack([filter, shownLabel, spacer(), updatedLabel], spacing: 10)

        for (id, t, w) in [("name", "Sterownik", 250), ("state", "Stan", 95), ("version", "Wersja", 80),
                           ("wired", "Zablokowana", 85), ("vendor", "Producent", 95)] {
            let c = NSTableColumn(identifier: .init(id)); c.title = L(t); c.width = CGFloat(w); c.minWidth = 60
            c.sortDescriptorPrototype = NSSortDescriptor(key: id, ascending: id != "wired")
            if id == "wired" { c.headerCell.alignment = .right }
            table.addTableColumn(c)
        }
        table.sortDescriptors = [NSSortDescriptor(key: "state", ascending: true)]
        table.rowHeight = 34
        table.intercellSpacing = NSSize(width: 8, height: 1)
        table.backgroundColor = .clear
        table.style = .plain
        table.focusRingType = .none
        table.dataSource = self; table.delegate = self
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        // prawy przycisk na nagłówku: wybór widocznych kolumn
        ColumnMenu.attach(to: table, key: "drivers", locked: ["name"])
        table.target = self; table.doubleAction = #selector(reveal)
        let scroll = NSScrollView(); scroll.documentView = table; scroll.drawsBackground = false; scroll.hasVerticalScroller = true; scroll.scrollerStyle = .overlay; scroll.autohidesScrollers = true

        // szczegóły po prawej
        dIcon.image = NSImage(systemSymbolName: "puzzlepiece.extension.fill", accessibilityDescription: nil)
        dIcon.symbolConfiguration = .init(pointSize: 26, weight: .regular)
        dIcon.size(width: 38, height: 38)
        let head = hstack([dIcon, vstack([dName, dBundle, dState], spacing: 2), spacer()], spacing: 12, alignment: .top)
        var kv: [NSView] = []
        for k in Self.detailKeys {
            let row = KeyValueRow(k, "—", keyWidth: 150)
            row.valueLabel.lineBreakMode = .byWordWrapping
            row.valueLabel.maximumNumberOfLines = 3
            dRows[k] = row.valueLabel
            kv.append(row)
        }
        dNote.lineBreakMode = .byWordWrapping; dNote.maximumNumberOfLines = 4
        for b in [revealButton, copyButton] { b.bezelStyle = .rounded; b.controlSize = .small; b.font = Fonts.ui(11.5) }
        revealButton.target = self; revealButton.action = #selector(reveal)
        copyButton.target = self; copyButton.action = #selector(copyDetails)
        let buttons = hstack([revealButton, copyButton, spacer()], spacing: 8)
        let dStack = vstack([head] + kv + [dNote, buttons], spacing: 5)
        dStack.setCustomSpacing(12, after: head)
        dStack.setCustomSpacing(12, after: kv.last!)
        let dScroll = NSScrollView(); dScroll.drawsBackground = false; dScroll.hasVerticalScroller = true; dScroll.scrollerStyle = .overlay; dScroll.autohidesScrollers = true
        let doc = FlippedView(); dScroll.documentView = doc
        dStack.pin(to: doc, insets: NSEdgeInsets(top: 10, left: 16, bottom: 16, right: 16))
        doc.translatesAutoresizingMaskIntoConstraints = false
        doc.widthAnchor.constraint(equalTo: dScroll.contentView.widthAnchor).isActive = true
        dScroll.size(width: 340)

        let divider = ThemedView(); divider.size(width: 1); divider.layer?.backgroundColor = P.border.alpha(0.6).cgColor
        let body = hstack([scroll, divider, dScroll], spacing: 0, alignment: .top)
        for v in [scroll, divider, dScroll] { v.heightAnchor.constraint(equalTo: body.heightAnchor).isActive = true }
        body.setContentHuggingPriority(.init(1), for: .vertical)

        let root = vstack([title, tileRow, filterRow, body], spacing: 10)
        for v in [title, tileRow, filterRow, body] { v.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true }
        root.pin(to: view, insets: NSEdgeInsets(top: 2, left: 18, bottom: 10, right: 18))

        NotificationCenter.default.addObserver(forName: .themeChanged, object: nil, queue: .main) { [weak self] _ in
            divider.layer?.backgroundColor = P.border.alpha(0.6).cgColor
            self?.table.reloadData(); self?.showDetails(self?.selected)
        }
        showDetails(nil)
    }

    func pageDidAppear() { if Date().timeIntervalSince(lastLoad) > 120 { reload() } }

    // MARK: wczytywanie
    @objc private func reload() {
        guard !loading else { return }
        loading = true
        shownLabel.stringValue = L("skanowanie…")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let list = Self.collect()
            DispatchQueue.main.async {
                guard let self else { return }
                self.all = list
                self.loading = false
                self.lastLoad = Date()
                self.updatedLabel.stringValue = L("Zaktualizowano ") + Fmt.time.string(from: Date())
                self.updateTiles()
                self.rebuild()
            }
        }
    }

    /// Zbiera sterowniki z jądra, katalogów rozszerzeń i listy rozszerzeń systemowych
    static func collect() -> [DriverInfo] {
        var loaded: [String: LoadedKext] = [:]
        for line in Shell.run("/usr/bin/kmutil", ["showloaded", "--no-kernel-components"], timeout: 60).split(separator: "\n") {
            if let (id, info) = parseLoaded(String(line)) { loaded[id] = info }
        }
        // komponenty jądra (KPI) też pokazujemy, ale bez rozmiaru
        for line in Shell.run("/usr/bin/kmutil", ["showloaded"], timeout: 60).split(separator: "\n") {
            if let (id, info) = parseLoaded(String(line)), loaded[id] == nil { loaded[id] = info }
        }

        var out: [DriverInfo] = []
        var seen = Set<String>()
        let dirs: [(String, DriverInfo.Kind)] = [
            ("/System/Library/Extensions", .kext), ("/Library/Extensions", .kext),
            ("/Library/Apple/System/Library/Extensions", .kext), ("/Library/StagedExtensions/Library/Extensions", .kext),
            ("/System/Library/DriverExtensions", .dext), ("/Library/DriverExtensions", .dext),
        ]
        let fm = FileManager.default
        for (dir, kind) in dirs {
            guard let items = try? fm.contentsOfDirectory(atPath: dir) else { continue }
            for item in items where item.hasSuffix(".kext") || item.hasSuffix(".dext") {
                let path = dir + "/" + item
                if let d = inspect(path: path, kind: kind, loaded: loaded), !seen.contains(d.bundleID) {
                    seen.insert(d.bundleID); out.append(d)
                }
                // wtyczki wewnątrz pakietu (np. AppleThunderboltUSBAdapters.kext/Contents/PlugIns)
                let plugins = path + "/Contents/PlugIns"
                if let subs = try? fm.contentsOfDirectory(atPath: plugins) {
                    for sub in subs where sub.hasSuffix(".kext") || sub.hasSuffix(".dext") {
                        if let d = inspect(path: plugins + "/" + sub, kind: kind, loaded: loaded), !seen.contains(d.bundleID) {
                            seen.insert(d.bundleID); out.append(d)
                        }
                    }
                }
            }
        }
        // sterowniki załadowane z kolekcji startowej, bez pliku na dysku
        for (id, info) in loaded where !seen.contains(id) {
            seen.insert(id)
            out.append(DriverInfo(name: shortName(id), bundleID: id, version: info.version, path: L("kolekcja jądra (Boot Kernel Collection)"),
                                  vendor: vendorFor(id), kind: .kext, loaded: true, index: info.index, refs: info.refs,
                                  size: info.size, wired: info.wired, uuid: info.uuid, dependencies: info.dependencies, state: L("Załadowany")))
        }
        // rozszerzenia systemowe (DriverKit / kamera / sieć), instalowane przez aplikacje
        for e in parseSystemExtensions(Shell.run("/usr/bin/systemextensionsctl", ["list"], timeout: 30)) where !seen.contains(e.bundleID) {
            seen.insert(e.bundleID); out.append(e)
        }
        return out
    }

    /// „  203    5 0xfffffe.. 0x560da 0x560da com.apple.filesystems.apfs (3288.1.3) UUID <50 23 …>”
    private static func parseLoaded(_ line: String) -> (String, LoadedKext)? {
        let f = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard f.count >= 8, let index = Int(f[0]), let refs = Int(f[1]) else { return nil }
        func num(_ s: String) -> UInt64 {
            s.hasPrefix("0x") ? (UInt64(s.dropFirst(2), radix: 16) ?? 0) : (UInt64(s) ?? 0)
        }
        let id = f[5]
        let version = f[6].trimmingCharacters(in: CharacterSet(charactersIn: "()"))
        let uuid = f.count > 7 ? f[7] : ""
        var deps: [Int] = []
        if let open = line.firstIndex(of: "<"), let close = line.lastIndex(of: ">"), open < close {
            deps = line[line.index(after: open)..<close].split(separator: " ").compactMap { Int($0) }
        }
        return (id, LoadedKext(index: index, refs: refs, size: num(f[3]), wired: num(f[4]), version: version, uuid: uuid, dependencies: deps))
    }

    private static func inspect(path: String, kind: DriverInfo.Kind, loaded: [String: LoadedKext]) -> DriverInfo? {
        let plist = path + "/Contents/Info.plist"
        guard let data = FileManager.default.contents(atPath: plist),
              let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let id = info["CFBundleIdentifier"] as? String else { return nil }
        let name = (info["CFBundleName"] as? String) ?? String((path as NSString).lastPathComponent.split(separator: ".").dropLast().joined(separator: "."))
        let version = (info["CFBundleShortVersionString"] as? String) ?? (info["CFBundleVersion"] as? String) ?? "—"
        let libs = (info["OSBundleLibraries"] as? [String: Any])?.count ?? 0
        let l = loaded[id]
        var d = DriverInfo(name: name, bundleID: id, version: version, path: path, vendor: vendorFor(id), kind: kind,
                           loaded: l != nil, index: l?.index, refs: l?.refs, size: l?.size, wired: l?.wired, uuid: l?.uuid,
                           dependencies: l?.dependencies ?? [], libraryCount: libs)
        d.state = l != nil ? L("Załadowany") : L("Niezaładowany")
        return d
    }

    /// systemextensionsctl list: „*\t*\tTEAMID\tbundle (wersja)\tnazwa\t[stan]”
    private static func parseSystemExtensions(_ out: String) -> [DriverInfo] {
        var result: [DriverInfo] = []
        for line in out.split(separator: "\n") {
            let cols = line.split(separator: "\t").map { $0.trimmingCharacters(in: .whitespaces) }
            guard cols.count >= 5, cols[3].contains("(") else { continue }
            let team = cols[2]
            let idAndVersion = cols[3]
            guard let open = idAndVersion.firstIndex(of: "(") else { continue }
            let id = String(idAndVersion[..<open]).trimmingCharacters(in: .whitespaces)
            let version = String(idAndVersion[idAndVersion.index(after: open)...].dropLast())
            let name = cols[4]
            let state = cols.count > 5 ? cols[5].trimmingCharacters(in: CharacterSet(charactersIn: "[]")) : ""
            let active = state.contains("activated") && state.contains("enabled")
            var d = DriverInfo(name: name.isEmpty ? shortName(id) : name, bundleID: id, version: version,
                               path: L("rozszerzenie systemowe (zarządzane przez aplikację)"), vendor: team.isEmpty ? vendorFor(id) : team,
                               kind: .systemExtension, loaded: active, index: nil, refs: nil, size: nil, wired: nil, uuid: nil)
            d.state = active ? L("Aktywne") : (state.isEmpty ? L("Nieaktywne") : state)
            result.append(d)
        }
        return result
    }

    private static func shortName(_ id: String) -> String { id.split(separator: ".").last.map(String.init) ?? id }

    private static func vendorFor(_ id: String) -> String {
        if id.hasPrefix("com.apple.") { return "Apple" }
        let parts = id.split(separator: ".")
        guard parts.count >= 2 else { return "—" }
        let v = String(parts[1])
        return v.prefix(1).uppercased() + v.dropFirst()
    }

    // MARK: prezentacja
    private func updateTiles() {
        let loadedCount = all.filter { $0.loaded }.count
        let third = all.filter { !$0.isApple }.count
        let wired = all.compactMap { $0.wired }.reduce(0, +)
        tiles["Sterowniki"]?.value.update("\(all.count)", flash: false)
        tiles["Załadowane"]?.value.update("\(loadedCount)", flash: false)
        tiles["Zewnętrzne"]?.value.update("\(third)", flash: false)
        tiles["Pamięć zablokowana"]?.value.update(Fmt.bytes(wired), flash: false)
        tiles["Sterowniki"]?.caption.stringValue = L("Zainstalowane w systemie")
        tiles["Załadowane"]?.caption.stringValue = L("Aktywne w jądrze")
        tiles["Zewnętrzne"]?.caption.stringValue = L("Spoza Apple")
        tiles["Pamięć zablokowana"]?.caption.stringValue = L("Zajęta przez jądro")
    }

    @objc private func filterChanged() { rebuild() }

    private func rebuild() {
        let f = search.stringValue.lowercased()
        rows = all.filter { d in
            switch filter.selectedSegment {
            case 1: if !d.loaded { return false }
            case 2: if d.loaded { return false }
            case 3: if d.isApple { return false }
            case 4: if d.kind == .kext { return false }
            default: break
            }
            return f.isEmpty || d.name.lowercased().contains(f) || d.bundleID.lowercased().contains(f) || d.vendor.lowercased().contains(f)
        }
        rows.sort { a, b in
            // przy równych wartościach porządkujemy alfabetycznie, żeby lista nie skakała
            if sortKey != "name" {
                let eq: Bool
                switch sortKey {
                case "state": eq = a.loaded == b.loaded
                case "version": eq = a.version == b.version
                case "wired": eq = (a.wired ?? 0) == (b.wired ?? 0)
                default: eq = a.vendor == b.vendor
                }
                if eq { return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending }
            }
            let r: Bool
            switch sortKey {
            case "state": r = (a.loaded ? 0 : 1) < (b.loaded ? 0 : 1)
            case "version": r = a.version.compare(b.version, options: .numeric) == .orderedAscending
            case "wired": r = (a.wired ?? 0) < (b.wired ?? 0)
            case "vendor": r = a.vendor.localizedCaseInsensitiveCompare(b.vendor) == .orderedAscending
            default: r = a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
            }
            return sortAsc ? r : !r
        }
        shownLabel.stringValue = "\(rows.count) pokazanych"
        table.reloadData()
    }

    private var selected: DriverInfo? { table.selectedRow >= 0 && table.selectedRow < rows.count ? rows[table.selectedRow] : nil }

    private func showDetails(_ d: DriverInfo?) {
        guard let d else {
            dName.stringValue = L("Wybierz sterownik")
            dBundle.stringValue = ""
            dState.stringValue = ""
            for v in dRows.values { v.stringValue = L("—") }
            dNote.stringValue = ""
            revealButton.isEnabled = false; copyButton.isEnabled = false
            dIcon.contentTintColor = P.textDim
            return
        }
        revealButton.isEnabled = d.path.hasPrefix("/"); copyButton.isEnabled = true
        dIcon.contentTintColor = d.loaded ? P.cpu : P.textDim
        dName.stringValue = d.name
        dName.textColor = P.text
        dBundle.stringValue = d.bundleID
        dBundle.textColor = P.textDim
        dState.stringValue = d.loaded ? "● " + d.state : "○ " + d.state
        dState.textColor = d.loaded ? P.good : P.textDim
        dRows["Rodzaj"]?.stringValue = d.kind.rawValue
        dRows["Wersja"]?.stringValue = d.version
        dRows["Producent"]?.stringValue = d.vendor
        dRows["Indeks ładowania"]?.stringValue = d.index.map { "\($0)" } ?? L("—")
        dRows["Odwołania"]?.stringValue = d.refs.map { "\($0)" } ?? L("—")
        dRows["Rozmiar"]?.stringValue = d.size.map { Fmt.bytes($0) } ?? L("—")
        dRows["Pamięć zablokowana"]?.stringValue = d.wired.map { Fmt.bytes($0) } ?? L("—")
        dRows["Zależy od"]?.stringValue = d.dependencies.isEmpty
            ? (d.libraryCount > 0 ? "\(d.libraryCount) bibliotek" : "—")
            : "\(d.dependencies.count) " + L("rozszerzeń (indeksy:") + " \(d.dependencies.prefix(8).map(String.init).joined(separator: ", "))\(d.dependencies.count > 8 ? "…" : ""))"
        dRows["UUID"]?.stringValue = d.uuid ?? L("—")
        dRows["Lokalizacja"]?.stringValue = d.path
        for v in dRows.values { v.textColor = P.text }
        dNote.textColor = P.textDim
        if d.isApple {
            dNote.stringValue = L("Rozszerzenie Apple. Ochrona integralności systemu (SIP) nie pozwala go wyładować, a system zależy od niego podczas pracy.")
        } else if d.kind == .systemExtension {
            dNote.stringValue = L("Rozszerzenie systemowe instalowane przez aplikację. Można je usunąć w Ustawieniach systemowych → Ogólne → Elementy logowania i rozszerzenia.")
        } else {
            dNote.stringValue = L("Rozszerzenie zewnętrzne. Wyładowanie wymaga uprawnień administratora i obniżenia poziomu zabezpieczeń rozruchu.")
        }
    }

    @objc private func reveal() {
        guard let d = selected, d.path.hasPrefix("/") else { return }
        NSWorkspace.shared.selectFile(d.path, inFileViewerRootedAtPath: "")
    }

    @objc private func copyDetails() {
        guard let d = selected else { return }
        var text = "\(d.name)\n\(d.bundleID)\n\(d.state)\n\n"
        for k in Self.detailKeys { text += "\(k): \(dRows[k]?.stringValue ?? "—")\n" }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    // MARK: tabela
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let r = ThemedRowView(); r.inset = 0; r.zebra = row % 2 == 1; return r
    }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let col = tableColumn else { return nil }
        let d = rows[row]
        let cell = NSTableCellView()
        switch col.identifier.rawValue {
        case "state":
            let l = Label.make(d.state, size: 11.5)
            l.textColor = d.loaded ? P.good : P.textDim
            l.pinCentered(to: cell, leading: 2, trailing: 4)
        case "version":
            Label.make(d.version, size: 11.5, dim: true, mono: true).pinCentered(to: cell, leading: 2, trailing: 4)
        case "wired":
            let l = Label.make(d.wired.map { Fmt.bytes($0) } ?? "—", size: 11.5, dim: d.wired == nil, mono: true)
            l.alignment = .right
            l.pinCentered(to: cell, leading: 2, trailing: 4)
        case "vendor":
            let l = Label.make(d.vendor, size: 11.5, dim: d.isApple)
            if !d.isApple { l.textColor = P.npu }
            l.pinCentered(to: cell, leading: 2, trailing: 4)
        default:
            let icon = symbol(d.kind == .kext ? "cpu" : (d.kind == .dext ? "puzzlepiece.extension" : "app.badge.checkmark"),
                              size: 13, color: d.loaded ? P.cpu : P.textDim)
            icon.size(width: 20)
            let name = Label.make(d.name, size: 12)
            let bid = Label.make(d.bundleID, size: 10, dim: true, mono: true)
            let texts = vstack([name, bid], spacing: 0)
            hstack([icon, texts], spacing: 8).pin(to: cell, insets: NSEdgeInsets(top: 2, left: 2, bottom: 2, right: 2))
        }
        return cell
    }
    func tableViewSelectionDidChange(_ notification: Notification) { showDetails(selected) }
    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        guard let d = tableView.sortDescriptors.first, let k = d.key else { return }
        sortKey = k; sortAsc = d.ascending; rebuild()
    }
}
