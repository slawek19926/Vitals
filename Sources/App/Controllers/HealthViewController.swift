// HealthViewController.swift - strona „Zdrowie systemu”: lista kontroli z poziomem ważności
import AppKit

final class HealthViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, PageRefreshable {
    private let table = NSTableView()
    private var items: [HealthItem] = []
    private let summary = Label.make(L("Sprawdzanie…"), size: 13, weight: .medium)
    private let summaryDot = NSView()
    private let counters = Label.make("", size: 11.5, dim: true)
    private let exportButton = NSButton(title: L("Eksportuj historię pomiarów…"), target: nil, action: nil)
    private var lastCheck = Date.distantPast

    override func loadView() {
        view = NSView()
        let title = PageTitleView(L("Zdrowie systemu"))

        summaryDot.wantsLayer = true
        summaryDot.layer?.cornerRadius = 6
        summaryDot.size(width: 12, height: 12)
        let card = CardView()
        card.accent = .cpu
        let head = hstack([summaryDot, summary, spacer(), counters], spacing: 10)
        head.pin(to: card, insets: NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 14))

        for (id, t, w) in [("level", "Stan", 110), ("category", "Obszar", 150), ("title", "Kontrola", 280), ("detail", "Szczegóły", 520)] {
            let c = NSTableColumn(identifier: .init(id))
            c.title = L(t); c.width = CGFloat(w); c.minWidth = 70
            table.addTableColumn(c)
        }
        table.rowHeight = 24
        table.backgroundColor = .clear
        table.style = .plain
        table.dataSource = self
        table.delegate = self
        table.focusRingType = .none
        table.doubleAction = #selector(openRelatedPage)
        table.target = self
        ColumnMenu.attach(to: table, key: "health", locked: ["title"])
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true; scroll.scrollerStyle = .overlay; scroll.autohidesScrollers = true

        exportButton.target = self
        exportButton.action = #selector(exportHistory)
        exportButton.bezelStyle = .rounded
        exportButton.controlSize = .regular
        let recordButton = NSButton(title: L("Nagrywaj pomiary do pliku…"), target: self, action: #selector(toggleRecording))
        recordButton.bezelStyle = .rounded
        self.recordButton = recordButton
        let buttons = hstack([exportButton, recordButton, spacer()], spacing: 10)

        // dziennik alertów
        for (id, t, w) in [("time", "Czas", 150), ("elevel", "Stan", 110), ("etitle", "Zdarzenie", 300), ("edetail", "Szczegóły", 500)] {
            let c = NSTableColumn(identifier: .init(id))
            c.title = L(t); c.width = CGFloat(w); c.minWidth = 70
            eventTable.addTableColumn(c)
        }
        eventTable.rowHeight = 22
        eventTable.backgroundColor = .clear
        eventTable.style = .plain
        eventTable.dataSource = self
        eventTable.delegate = self
        eventTable.focusRingType = .none
        let eventScroll = NSScrollView()
        eventScroll.documentView = eventTable
        eventScroll.drawsBackground = false
        eventScroll.hasVerticalScroller = true; eventScroll.scrollerStyle = .overlay; eventScroll.autohidesScrollers = true
        eventScroll.heightAnchor.constraint(equalToConstant: 180).isActive = true
        let eventsHead = hstack([Label.make(L("Dziennik alertów"), size: 11.5, weight: .semibold), spacer(),
                                 { let b = NSButton(title: L("Wyczyść"), target: self, action: #selector(clearEvents)); b.bezelStyle = .rounded; b.controlSize = .small; return b }()], spacing: 8)

        let root = vstack([title, card, scroll, eventsHead, eventScroll, buttons], spacing: 10)
        for v in [card, scroll, eventsHead, eventScroll, buttons] { v.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -36).isActive = true }
        root.alignment = .leading
        root.pin(to: view, insets: NSEdgeInsets(top: 2, left: 18, bottom: 12, right: 18))
        scroll.setContentHuggingPriority(.init(1), for: .vertical)

        NotificationCenter.default.addObserver(self, selector: #selector(snapshot(_:)), name: .snapshotUpdated, object: nil)
        NotificationCenter.default.addObserver(forName: .alertsChanged, object: nil, queue: .main) { [weak self] _ in
            self?.eventTable.reloadData()
        }
        AlertCenter.shared.requestAuthorizationIfNeeded()
    }

    private let eventTable = NSTableView()

    @objc private func clearEvents() { AlertCenter.shared.clear() }

    private var recordButton: NSButton?

    func pageDidAppear() {
        lastCheck = .distantPast
        if let s = Monitor.shared.latest as Snapshot? { refresh(s) }
        updateRecordButton()
    }

    @objc private func snapshot(_ n: Notification) {
        guard let s = n.object as? Snapshot, view.window != nil, !view.isHiddenOrHasHiddenAncestor else { return }
        // reguły liczą się rzadko – to nie są dane, które zmieniają się dziesięć razy na sekundę
        guard Date().timeIntervalSince(lastCheck) > 2 else { return }
        refresh(s)
    }

    private func refresh(_ s: Snapshot) {
        lastCheck = Date()
        items = HealthChecker.shared.check(s)
        let worst = items.map(\.level).max() ?? .ok
        let warn = items.filter { $0.level == .warning }.count
        let crit = items.filter { $0.level == .critical }.count
        let info = items.filter { $0.level == .info }.count
        switch worst {
        case .critical: summary.stringValue = L("Wymaga uwagi")
        case .warning: summary.stringValue = L("Są ostrzeżenia")
        case .info: summary.stringValue = L("Drobne uwagi")
        case .ok: summary.stringValue = L("Wszystko w porządku")
        }
        summaryDot.layer?.backgroundColor = Self.color(worst).cgColor
        counters.stringValue = "\(items.count) " + L("kontroli") + " · \(crit) " + L("do sprawdzenia") + " · \(warn) " + L("ostrzeżeń") + " · \(info) " + L("uwag")
        table.reloadData()
    }

    private static func color(_ l: HealthLevel) -> NSColor {
        switch l {
        case .ok: return P.good
        case .info: return P.accent(.network)
        case .warning: return P.warn
        case .critical: return P.bad
        }
    }

    @objc private func openRelatedPage() {
        let row = table.selectedRow
        guard row >= 0, row < items.count, let page = items[row].page else { return }
        NotificationCenter.default.post(name: .openPage, object: page)
    }

    // MARK: eksport i nagrywanie
    @objc private func exportHistory() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "vitals-history.csv"
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.message = L("Zapis historii pomiarów z pamięci aplikacji")
        panel.begin { [weak self] resp in
            guard resp == .OK, let url = panel.url else { return }
            do {
                try HistoryExport.writeCSV(to: url)
                self?.presentInfo(L("Zapisano") + " \(Monitor.shared.history.count) " + L("pomiarów do pliku") + " \(url.lastPathComponent).")
            } catch {
                self?.presentInfo(L("Nie udało się zapisać pliku") + ": \(error.localizedDescription)")
            }
        }
    }

    @objc private func toggleRecording() {
        if HistoryExport.shared.isRecording {
            let url = HistoryExport.shared.stopRecording()
            presentInfo(L("Nagrywanie zakończone. Plik") + ": \(url?.lastPathComponent ?? "—")")
            updateRecordButton()
            return
        }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "vitals-recording.csv"
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.message = L("Każdy pomiar będzie dopisywany do tego pliku aż do zatrzymania")
        panel.begin { [weak self] resp in
            guard resp == .OK, let url = panel.url else { return }
            HistoryExport.shared.startRecording(to: url)
            self?.updateRecordButton()
        }
    }

    private func updateRecordButton() {
        recordButton?.title = HistoryExport.shared.isRecording ? L("Zatrzymaj nagrywanie") : L("Nagrywaj pomiary do pliku…")
        recordButton?.contentTintColor = HistoryExport.shared.isRecording ? P.bad : nil
    }

    /// Komórka dziennika zdarzeń
    private func eventCell(_ tableColumn: NSTableColumn?, _ row: Int) -> NSView? {
        let events = AlertCenter.shared.events
        guard let col = tableColumn, row < events.count else { return nil }
        let e = events[row]
        let cell: ProcCell
        if let c = eventTable.makeView(withIdentifier: col.identifier, owner: nil) as? ProcCell { cell = c } else {
            cell = ProcCell(); cell.identifier = col.identifier
            cell.flash.pinCentered(to: cell, leading: 4, trailing: 4)
        }
        let tf = cell.flash
        tf.font = Fonts.ui(11.5)
        tf.textColor = P.text
        switch col.identifier.rawValue {
        case "time": tf.update(Fmt.time.string(from: e.time), flash: false); tf.textColor = P.textDim; tf.font = Fonts.mono(11.5)
        case "elevel": tf.update(e.resolved ? L("Ustąpiło") : L(e.level.title), flash: false); tf.textColor = Self.color(e.level)
        case "etitle": tf.update(L(e.title), flash: false)
        default: tf.update(e.detail, flash: false); tf.textColor = P.textDim
        }
        return cell
    }

    private func presentInfo(_ text: String) {
        let a = NSAlert()
        a.messageText = "Vitals"
        a.informativeText = text
        a.addButton(withTitle: "OK")
        a.runModal()
    }

    // MARK: tabela
    func numberOfRows(in tableView: NSTableView) -> Int {
        tableView === eventTable ? AlertCenter.shared.events.count : items.count
    }
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let r = ThemedRowView(); r.inset = 0; r.zebra = row % 2 == 1; return r
    }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        if tableView === eventTable { return eventCell(tableColumn, row) }
        guard let col = tableColumn, row < items.count else { return nil }
        let item = items[row]
        let cell: ProcCell
        if let c = table.makeView(withIdentifier: col.identifier, owner: nil) as? ProcCell { cell = c } else {
            cell = ProcCell(); cell.identifier = col.identifier
            cell.flash.pinCentered(to: cell, leading: 4, trailing: 4)
        }
        let tf = cell.flash
        tf.font = Fonts.ui(11.5)
        tf.textColor = P.text
        switch col.identifier.rawValue {
        case "level":
            tf.update(L(item.level.title), flash: false)
            tf.textColor = Self.color(item.level)
        case "category": tf.update(L(item.category), flash: false); tf.textColor = P.textDim
        case "title": tf.update(L(item.title), flash: false)
        default: tf.update(item.detail, flash: false); tf.textColor = P.textDim
        }
        return cell
    }
}
