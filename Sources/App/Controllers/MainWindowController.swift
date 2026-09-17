// MainWindowController.swift - okno z paskiem bocznym, stronami i paskiem stanu
import AppKit

final class ContentViewController: NSViewController {
    let summary = SummaryViewController()
    let performance = PerformanceViewController()
    let processes = ProcessesViewController()
    let systemInfo = SystemInfoViewController()
    let services = ServicesViewController()
    let users = UsersViewController()
    let powerFreq = PowerFreqViewController()
    let appleSilicon = AppleSiliconViewController()
    let connections = ConnectionsViewController()
    let startup = StartupViewController()
    let installed = InstalledAppsViewController()
    let drivers = DriversViewController()
    let diskSpace = DiskSpaceViewController()
    let benchmarks = BenchmarksViewController()
    let bluetooth = BluetoothViewController()
    let health = HealthViewController()
    let overview = SystemOverviewViewController()
    let settings = SettingsViewController()
    lazy var pages: [NSViewController] = [summary, performance, processes, systemInfo, services, users, powerFreq, appleSilicon, connections, startup, installed, drivers, diskSpace, benchmarks, bluetooth, health, overview, settings]
    /// Indeks strony ustawień – wyliczany, żeby dodanie nowej strony nie rozjeżdżało menu i przycisku
    var settingsPage: Int { pages.count - 1 }
    private let container = NSView()
    private let topSeparator = NSView()
    private let topBar = NSView()
    private let status = StatusBarView()
    private var statusHeight: NSLayoutConstraint!
    private(set) var current = -1

    override func loadView() {
        let root = ThemedView()
        root.layer?.backgroundColor = P.windowBg.cgColor
        view = root
        container.translatesAutoresizingMaskIntoConstraints = false
        status.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(container); view.addSubview(status)
        // pasek nad treścią: własne tło i wyraźna krawędź, żeby oddzielić stronę od obszaru okna
        topBar.wantsLayer = true
        topBar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(topBar)
        topSeparator.wantsLayer = true
        topSeparator.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(topSeparator)
        NSLayoutConstraint.activate([
            topBar.topAnchor.constraint(equalTo: view.topAnchor),
            topBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            topBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            // dolna krawędź paska to realny dół obszaru narzędzi, a nie stała wysokość
            topBar.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            topSeparator.topAnchor.constraint(equalTo: topBar.bottomAnchor),
            topSeparator.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            topSeparator.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            topSeparator.heightAnchor.constraint(equalToConstant: 1),
        ])
        statusHeight = status.heightAnchor.constraint(equalToConstant: 26)
        NSLayoutConstraint.activate([
            container.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            container.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            container.bottomAnchor.constraint(equalTo: status.topAnchor),
            status.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            status.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            status.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            statusHeight,
        ])
        for p in pages { addChild(p) }
        NotificationCenter.default.addObserver(forName: .themeChanged, object: nil, queue: .main) { [weak self] _ in
            self?.view.layer?.backgroundColor = P.windowBg.cgColor
            self?.applyBarColors()
        }
        applyBarColors()
        NotificationCenter.default.addObserver(forName: .prefsChanged, object: nil, queue: .main) { [weak self] _ in self?.applyPrefs() }
        applyPrefs()
    }

    private func applyPrefs() {
        let show = Prefs.shared.showStatusBar
        status.isHidden = !show
        statusHeight.constant = show ? 26 : 0
    }

    /// Kolory paska nad treścią: ciemniejsza (lub jaśniejsza) warstwa i wyraźna krawędź
    private func applyBarColors() {
        let barTint = P.isDark ? NSColor.black.alpha(0.22) : NSColor.white.alpha(0.55)
        topBar.layer?.backgroundColor = barTint.cgColor
        topSeparator.layer?.backgroundColor = P.border.alpha(P.isDark ? 0.9 : 0.8).cgColor
    }

    func show(_ index: Int) {
        guard index != current, index >= 0, index < pages.count else { return }
        container.subviews.forEach { $0.removeFromSuperview() }
        pages[index].view.pin(to: container)
        current = index
        if index < settingsPage { UserDefaults.standard.set(index, forKey: "page") }
        (pages[index] as? PageRefreshable)?.pageDidAppear()
    }
}

protocol PageRefreshable: AnyObject { func pageDidAppear() }

final class MainWindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate {
    let sidebar = SidebarViewController()
    let content = ContentViewController()

    init() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1240, height: 800),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                         backing: .buffered, defer: false)
        w.title = "Vitals"
        w.titleVisibility = .hidden
        w.minSize = NSSize(width: 980, height: 640)
        w.isReleasedWhenClosed = false
        super.init(window: w)
        w.delegate = self

        let split = NSSplitViewController()
        let side = NSSplitViewItem(sidebarWithViewController: sidebar)
        side.minimumThickness = 190
        side.maximumThickness = 260
        side.canCollapse = true
        side.allowsFullHeightLayout = true
        let main = NSSplitViewItem(viewController: content)
        split.addSplitViewItem(side)
        split.addSplitViewItem(main)
        // szerokość paska bocznego zapamiętuje się sama; pozycję startową ustawiamy tylko przy pierwszym uruchomieniu
        split.splitView.autosaveName = "MainSplit"
        split.splitView.identifier = NSUserInterfaceItemIdentifier("MainSplit")
        if UserDefaults.standard.object(forKey: "NSSplitView Subview Frames MainSplit") == nil {
            split.splitView.setPosition(210, ofDividerAt: 0)
        }
        split.view.frame = NSRect(x: 0, y: 0, width: 1240, height: 800)
        w.contentViewController = split
        w.setContentSize(NSSize(width: 1240, height: 800))
        w.styleMask.insert(.resizable)
        w.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)

        setupToolbar(w)
        sidebar.settingsPage = content.settingsPage
        sidebar.onSelect = { [weak self] i in self?.content.show(i); self?.sidebar.select(i) }
        // Ramkę okna zapisujemy i odtwarzamy sami: mechanizm AppKit bywał nadpisywany
        // przez układ stron przy pierwszym rysowaniu.
        if !restoreFrame(w) { w.center() }
        DispatchQueue.main.async { [weak self, weak w] in
            guard let self, let w else { return }
            _ = self.restoreFrame(w)
            self.frameRestored = true
        }
        let page = Prefs.shared.rememberPage ? UserDefaults.standard.integer(forKey: "page") : Prefs.shared.startPage
        selectPage(page)
        NotificationCenter.default.addObserver(forName: .openPage, object: nil, queue: .main) { [weak self] n in
            if let i = n.object as? Int { self?.selectPage(i) }
        }
        NotificationCenter.default.addObserver(forName: .openSystemInfoCategory, object: nil, queue: .main) { [weak self] n in
            self?.selectPage(3)
            if let t = n.object as? String { self?.content.systemInfo.select(type: t) }
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    // MARK: pasek narzędzi z wyszukiwarką globalną
    private let searchField = NSSearchField()
    private var searchPopover: NSPopover?
    private let resultsController = SearchResultsController()

    private func setupToolbar(_ w: NSWindow) {
        // Pasek okna jest niewidoczny: treść i pasek boczny sięgają samej góry, a elementy paska
        // (wyszukiwarka) unoszą się nad tłem. Tak wygląda okno w Codeksie.
        let tb = NSToolbar(identifier: "main")
        tb.delegate = self
        tb.displayMode = .iconOnly
        tb.allowsUserCustomization = false
        w.toolbar = tb
        w.toolbarStyle = .unified
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.titlebarSeparatorStyle = .none
        w.backgroundColor = P.windowBg
        NotificationCenter.default.addObserver(forName: .themeChanged, object: nil, queue: .main) { [weak w] _ in
            w?.backgroundColor = P.windowBg
        }
        // nazwa strony zostaje w treści okna, pasek pokazuje tylko narzędzia
        w.titleVisibility = .hidden
        searchField.placeholderString = L("Szukaj procesów, dysków, czujników…")
        searchField.target = self
        searchField.action = #selector(searchChanged)
        searchField.sendsSearchStringImmediately = true
        searchField.sendsWholeSearchString = false
        resultsController.onPick = { [weak self] hit in
            self?.searchPopover?.close()
            self?.searchField.stringValue = ""
            self?.selectPage(hit.page)
            if !hit.filter.isEmpty { NotificationCenter.default.post(name: .applySearchFilter, object: hit.filter) }
        }
    }

    @objc private func searchChanged() {
        let hits = GlobalSearch.find(searchField.stringValue)
        guard !hits.isEmpty else { searchPopover?.close(); return }
        resultsController.hits = hits
        if searchPopover == nil {
            let pop = NSPopover()
            pop.behavior = .semitransient
            pop.contentViewController = resultsController
            searchPopover = pop
        }
        if searchPopover?.isShown != true {
            searchPopover?.show(relativeTo: searchField.bounds, of: searchField, preferredEdge: .maxY)
        }
        resultsController.reload()
    }

    /// Fokus w polu wyszukiwania (⌘F)
    func focusSearch() {
        window?.makeFirstResponder(searchField)
    }

    /// Indeks strony ustawień znany reszcie aplikacji (menu, skrót ⌘,)
    var settingsPage: Int { content.settingsPage }

    func selectPage(_ i: Int) {
        sidebar.select(i)
        content.show(i)
        updateWindowTitle(i)
    }

    /// Nazwa okna zostaje stała; tytuł strony jest w jej treści
    private func updateWindowTitle(_ index: Int) { window?.title = "Vitals" }

    private var frameRestored = false

    /// Odtwarza zapisaną ramkę, jeśli mieści się na którymś z podłączonych ekranów
    @discardableResult
    private func restoreFrame(_ w: NSWindow) -> Bool {
        guard let text = UserDefaults.standard.string(forKey: "windowFrame") else { return false }
        let frame = NSRectFromString(text)
        guard frame.width > 400, frame.height > 300 else { return false }
        let visible = NSScreen.screens.contains { $0.visibleFrame.intersects(frame) }
        w.setFrame(visible ? frame : NSRect(origin: NSScreen.main?.visibleFrame.origin ?? .zero, size: frame.size),
                   display: true)
        return true
    }

    private func saveFrame() {
        guard frameRestored, let w = window else { return }
        UserDefaults.standard.set(NSStringFromRect(w.frame), forKey: "windowFrame")
    }

    func windowDidResize(_ notification: Notification) { saveFrame() }
    func windowDidMove(_ notification: Notification) { saveFrame() }
    func windowWillClose(_ notification: Notification) { saveFrame() }

    func toggleSidebar() {
        (window?.contentViewController as? NSSplitViewController)?.toggleSidebar(nil)
    }
}

// MARK: - pasek narzędzi
extension MainWindowController {
    private static let searchItemID = NSToolbarItem.Identifier("globalSearch")

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, Self.searchItemID, .toggleSidebar, .sidebarTrackingSeparator]
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.toggleSidebar, .sidebarTrackingSeparator, .flexibleSpace, Self.searchItemID]
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        guard id == Self.searchItemID else { return nil }
        let item = NSSearchToolbarItem(itemIdentifier: id)
        item.searchField = searchField
        item.label = L("Szukaj")
        item.toolTip = L("Szukaj procesów, dysków, interfejsów, czujników i stron (⌘F)")
        item.resignsFirstResponderWithCancel = true
        return item
    }
}

/// Lista wyników wyszukiwania pokazywana pod polem
final class SearchResultsController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    var hits: [SearchHit] = []
    var onPick: ((SearchHit) -> Void)?
    private let table = NSTableView()

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 460, height: 260))
        let col = NSTableColumn(identifier: .init("hit"))
        col.width = 440
        table.addTableColumn(col)
        table.headerView = nil
        table.rowHeight = 40
        table.backgroundColor = .clear
        table.style = .plain
        table.focusRingType = .none
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(pick)
        let scroll = NSScrollView(frame: root.bounds)
        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true; scroll.scrollerStyle = .overlay; scroll.autohidesScrollers = true
        scroll.autoresizingMask = [.width, .height]
        root.addSubview(scroll)
        view = root
    }

    func reload() { table.reloadData() }

    @objc private func pick() {
        let row = table.clickedRow >= 0 ? table.clickedRow : table.selectedRow
        guard row >= 0, row < hits.count else { return }
        onPick?(hits[row])
    }

    func numberOfRows(in tableView: NSTableView) -> Int { hits.count }
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let r = ThemedRowView(); r.inset = 4; return r
    }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < hits.count else { return nil }
        let h = hits[row]
        let cell = NSTableCellView()
        let icon = symbol(h.icon, size: 15, weight: .regular, color: P.textDim)
        icon.widthAnchor.constraint(equalToConstant: 22).isActive = true
        let title = Label.make(h.title, size: 12.5, weight: .medium)
        let sub = Label.make(h.subtitle, size: 11, dim: true)
        let texts = vstack([title, sub], spacing: 1)
        let stack = hstack([icon, texts], spacing: 10)
        stack.pin(to: cell, insets: NSEdgeInsets(top: 3, left: 10, bottom: 3, right: 10))
        return cell
    }
}

extension Notification.Name {
    /// Wynik wyszukiwania prosi stronę o ustawienie filtra
    static let applySearchFilter = Notification.Name("ApplySearchFilter")
}
