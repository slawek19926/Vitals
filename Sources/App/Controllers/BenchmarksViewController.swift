// BenchmarksViewController.swift - „Benchmarki”: CPU (1 rdzeń / wszystkie), pamięć, dysk (zapis/odczyt); historia wyników
import AppKit
import Metal

/// Pojedynczy test, który można zaznaczyć i uruchomić osobno
enum BenchTest: String, CaseIterable, Codable {
    case cpuSingle, cpuMulti, memory, diskWrite, diskRead, gpu

    var title: String {
        switch self {
        case .cpuSingle: return L("CPU – jeden rdzeń")
        case .cpuMulti: return L("CPU – wszystkie rdzenie")
        case .memory: return L("Pamięć – przepustowość")
        case .diskWrite: return L("Dysk – zapis sekwencyjny")
        case .diskRead: return L("Dysk – odczyt sekwencyjny")
        case .gpu: return L("GPU – obliczenia (Metal)")
        }
    }
    var icon: String {
        switch self {
        case .cpuSingle: return "cpu"
        case .cpuMulti: return "cpu.fill"
        case .memory: return "memorychip"
        case .diskWrite: return "internaldrive"
        case .diskRead: return "internaldrive.fill"
        case .gpu: return "display"
        }
    }
    var accent: Subsystem {
        switch self {
        case .cpuSingle, .cpuMulti: return .cpu
        case .memory: return .memory
        case .diskWrite, .diskRead: return .disk
        case .gpu: return .gpu
        }
    }
    var unit: String {
        switch self {
        case .cpuSingle, .cpuMulti: return "Mop/s"
        case .memory: return "GB/s"
        case .diskWrite, .diskRead: return "MB/s"
        case .gpu: return "GFLOP/s"
        }
    }
    var precision: Int { self == .memory ? 1 : 0 }
    /// Waga w wyniku łącznym
    var weight: Double {
        switch self {
        case .cpuSingle: return 2
        case .cpuMulti: return 0.5
        case .memory: return 40
        case .diskWrite, .diskRead: return 0.05
        case .gpu: return 1
        }
    }
    func format(_ v: Double) -> String { String(format: "%.\(precision)f %@", v, unit) }
}

/// Wynik serii: data i wartości tych testów, które faktycznie zostały uruchomione
struct BenchResult: Codable {
    var date: Date
    var values: [String: Double] = [:]

    subscript(_ t: BenchTest) -> Double? { values[t.rawValue] }

    /// Zgodność ze starym formatem zapisu (pojedyncze pola)
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        date = try c.decode(Date.self, forKey: .date)
        if let v = try? c.decode([String: Double].self, forKey: .values) {
            values = v
        } else {
            let legacy = try decoder.container(keyedBy: LegacyKeys.self)
            for (key, test) in [(LegacyKeys.cpuSingle, BenchTest.cpuSingle), (.cpuMulti, .cpuMulti),
                                (.memory, .memory), (.diskWrite, .diskWrite), (.diskRead, .diskRead)] {
                if let v = try? legacy.decode(Double.self, forKey: key) { values[test.rawValue] = v }
            }
        }
    }
    init(date: Date, values: [String: Double]) { self.date = date; self.values = values }
    private enum CodingKeys: String, CodingKey { case date, values }
    private enum LegacyKeys: String, CodingKey { case cpuSingle, cpuMulti, memory, diskWrite, diskRead }
}

enum Bench {
    /// Mieszana praca całkowito-zmiennoprzecinkowa z zależnością danych (nie do usunięcia przez optymalizator)
    @inline(never) static func work(_ iters: Int, seed: UInt64) -> UInt64 {
        var x = seed &+ 0x9E3779B97F4A7C15
        var f = 1.0001
        for i in 0..<iters {
            x ^= x << 13; x ^= x >> 7; x ^= x << 17
            f = f * 1.0000001 + Double(x & 0xFF) * 1e-9
            x = x &+ UInt64(i)
        }
        return x ^ UInt64(f.bitPattern)
    }

    static func cpuSingle(seconds: Double) -> Double {
        let chunk = 2_000_000
        var ops = 0
        var acc: UInt64 = 1
        let end = CACurrentMediaTime() + seconds
        while CACurrentMediaTime() < end { acc = work(chunk, seed: acc); ops += chunk }
        return Double(ops) / seconds / 1e6 + Double(acc & 1) * 1e-9
    }

    static func cpuMulti(seconds: Double) -> Double {
        let n = ProcessInfo.processInfo.activeProcessorCount
        var totals = [Double](repeating: 0, count: n)
        DispatchQueue.concurrentPerform(iterations: n) { i in totals[i] = cpuSingle(seconds: seconds) }
        return totals.reduce(0, +)
    }

    static func memory(seconds: Double) -> Double {
        let size = 256 * 1024 * 1024
        let a = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 4096)
        let b = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 4096)
        defer { a.deallocate(); b.deallocate() }
        memset(a, 1, size); memset(b, 2, size)
        var bytes: UInt64 = 0
        let end = CACurrentMediaTime() + seconds
        var flip = false
        while CACurrentMediaTime() < end {
            if flip { memcpy(a, b, size) } else { memcpy(b, a, size) }
            flip.toggle(); bytes += UInt64(size) * 2   // odczyt + zapis
        }
        return Double(bytes) / seconds / 1e9
    }

    /// Obliczenia na GPU: prosty kernel wektorowy w Metalu; zwraca GFLOP/s albo 0, gdy brak wsparcia
    static func gpu(seconds: Double) -> Double {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { return 0 }
        let source = """
        #include <metal_stdlib>
        using namespace metal;
        kernel void bench(device float* out [[buffer(0)]], constant uint& iters [[buffer(1)]], uint id [[thread_position_in_grid]]) {
            float x = out[id];
            for (uint i = 0; i < iters; ++i) { x = fma(x, 1.0000001f, 0.000001f); }
            out[id] = x;
        }
        """
        guard let library = try? device.makeLibrary(source: source, options: nil),
              let fn = library.makeFunction(name: "bench"),
              let pipeline = try? device.makeComputePipelineState(function: fn) else { return 0 }
        let count = 1 << 20
        guard let buffer = device.makeBuffer(length: count * MemoryLayout<Float>.size, options: .storageModeShared) else { return 0 }
        var iters: UInt32 = 512
        let start = CACurrentMediaTime()
        var flops: Double = 0
        while CACurrentMediaTime() - start < seconds {
            guard let cmd = queue.makeCommandBuffer(), let enc = cmd.makeComputeCommandEncoder() else { break }
            enc.setComputePipelineState(pipeline)
            enc.setBuffer(buffer, offset: 0, index: 0)
            enc.setBytes(&iters, length: MemoryLayout<UInt32>.size, index: 1)
            let w = min(pipeline.maxTotalThreadsPerThreadgroup, 256)
            enc.dispatchThreads(MTLSize(width: count, height: 1, depth: 1),
                                threadsPerThreadgroup: MTLSize(width: w, height: 1, depth: 1))
            enc.endEncoding()
            cmd.commit()
            cmd.waitUntilCompleted()
            flops += Double(count) * Double(iters) * 2   // fma = mnożenie + dodawanie
        }
        let elapsed = CACurrentMediaTime() - start
        return flops / max(elapsed, 1e-6) / 1e9
    }

    static func disk(dir: String, totalMB: Int = 512) -> (write: Double, read: Double) {
        let path = dir + "/.mactaskmanager-bench-\(getpid()).bin"
        defer { unlink(path) }
        let chunk = 4 * 1024 * 1024
        let buf = UnsafeMutableRawPointer.allocate(byteCount: chunk, alignment: 4096)
        defer { buf.deallocate() }
        for i in stride(from: 0, to: chunk, by: 8) { buf.storeBytes(of: UInt64(i) &* 0x9E3779B97F4A7C15, toByteOffset: i, as: UInt64.self) }
        let fd = open(path, O_CREAT | O_TRUNC | O_RDWR, 0o600)
        guard fd >= 0 else { return (0, 0) }
        fcntl(fd, F_NOCACHE, 1)
        let t0 = CACurrentMediaTime()
        for _ in 0..<totalMB / 4 { _ = write(fd, buf, chunk) }
        fcntl(fd, F_FULLFSYNC)
        let tw = CACurrentMediaTime() - t0
        lseek(fd, 0, SEEK_SET)
        let t1 = CACurrentMediaTime()
        var readBytes = 0
        while true { let r = read(fd, buf, chunk); if r <= 0 { break }; readBytes += r }
        let tr = CACurrentMediaTime() - t1
        close(fd)
        return (Double(totalMB) / max(tw, 1e-6), Double(readBytes) / 1e6 / max(tr, 1e-6))
    }
}


final class BenchmarksViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, PageRefreshable {
    private let runSelected = NSButton(title: L("Uruchom zaznaczone"), target: nil, action: nil)
    private let runAllButton = NSButton(title: L("Uruchom wszystkie"), target: nil, action: nil)
    private let stopButton = NSButton(title: L("Zatrzymaj"), target: nil, action: nil)
    private let durationPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let status = Label.make(L("Zaznacz testy i uruchom. W trakcie testu zamknij inne obciążające aplikacje."), size: 11, dim: true)
    private let progress = LEDBarView()
    private var tiles: [BenchTest: TileStat] = [:]
    private let testTable = NSTableView()
    private let historyTable = NSTableView()
    private var history: [BenchResult] = []
    private var selected: Set<BenchTest> = Set(BenchTest.allCases)
    private var running = false
    private var cancelRequested = false
    private let hw = Monitor.shared.hardware
    /// Czas jednego testu: szybki, standardowy, dokładny
    private var seconds: Double { [1.0, 3.0, 6.0][max(0, min(2, durationPopup.indexOfSelectedItem))] }

    override func loadView() {
        view = NSView()
        let title = PageTitleView(L("Benchmarki"))
        for b in [runSelected, runAllButton, stopButton] {
            b.bezelStyle = .rounded; b.controlSize = .small; b.font = Fonts.ui(11.5); b.target = self
        }
        runSelected.action = #selector(runSelectedTests)
        runSelected.keyEquivalent = "\r"
        runAllButton.action = #selector(runAllTests)
        stopButton.action = #selector(stopRun)
        stopButton.isEnabled = false
        durationPopup.addItems(withTitles: [L("Szybki (1 s)"), L("Standardowy (3 s)"), L("Dokładny (6 s)")])
        durationPopup.selectItem(at: UserDefaults.standard.object(forKey: "benchDuration") as? Int ?? 1)
        durationPopup.target = self; durationPopup.action = #selector(durationChanged)
        durationPopup.controlSize = .small; durationPopup.font = Fonts.ui(11.5)
        title.accessory = hstack([durationPopup, runSelected, runAllButton, stopButton], spacing: 8)

        let chip = Label.make("\(hw.cpuBrand) · \(hw.ncpu) " + L("procesorów logicznych") + " (\(hw.perfCores) P + \(hw.effCores) E) · \(Fmt.bytes(hw.memTotal, precision: 0)) · \(hw.gpuName)", size: 12, dim: true)

        // lista testów z polami wyboru
        for (id, t, w) in [("on", "", 26), ("name", "Test", 230), ("last", "Ostatni wynik", 150)] {
            let c = NSTableColumn(identifier: .init(id)); c.title = L(t); c.width = CGFloat(w); c.minWidth = 24
            testTable.addTableColumn(c)
        }
        testTable.rowHeight = 24
        testTable.backgroundColor = .clear
        testTable.style = .plain
        testTable.focusRingType = .none
        testTable.dataSource = self
        testTable.delegate = self
        let testScroll = NSScrollView()
        testScroll.documentView = testTable
        testScroll.drawsBackground = false
        testScroll.hasVerticalScroller = true; testScroll.scrollerStyle = .overlay; testScroll.autohidesScrollers = true
        testScroll.widthAnchor.constraint(equalToConstant: 430).isActive = true
        testScroll.heightAnchor.constraint(equalToConstant: 170).isActive = true
        let testsCard = CardView()
        let testsHead = hstack([Label.make(L("Testy do uruchomienia"), size: 12.5, weight: .semibold), spacer(),
                                { let b = NSButton(title: L("Zaznacz wszystkie"), target: self, action: #selector(selectAll(_:)));
                                  b.bezelStyle = .rounded; b.controlSize = .mini; b.font = Fonts.ui(10.5); return b }(),
                                { let b = NSButton(title: L("Odznacz wszystkie"), target: self, action: #selector(deselectAll));
                                  b.bezelStyle = .rounded; b.controlSize = .mini; b.font = Fonts.ui(10.5); return b }()], spacing: 6)
        let testsStack = vstack([testsHead, testScroll], spacing: 8)
        testsHead.widthAnchor.constraint(equalTo: testsStack.widthAnchor).isActive = true
        testScroll.widthAnchor.constraint(equalTo: testsStack.widthAnchor).isActive = true
        testsStack.pin(to: testsCard, insets: NSEdgeInsets(top: 10, left: 12, bottom: 12, right: 12))

        // kafelki wyników
        var rows: [NSView] = []
        var row: [NSView] = []
        for t in BenchTest.allCases {
            let tile = TileStat(L(t.title), icon: t.icon, accent: t.accent)
            tiles[t] = tile
            row.append(tile)
            if row.count == 3 { rows.append(hstack(row, spacing: 10, distribution: .fillEqually)); row = [] }
        }
        let totalTile = TileStat(L("Wynik łączny"), icon: "star", accent: .energy)
        totalTiles = totalTile
        row.append(totalTile)
        while row.count < 3 { row.append(spacer()) }
        rows.append(hstack(row, spacing: 10, distribution: .fillEqually))
        let tilesStack = vstack(rows, spacing: 10)
        for r in rows { r.widthAnchor.constraint(equalTo: tilesStack.widthAnchor).isActive = true }

        progress.accent = .energy
        progress.heightAnchor.constraint(equalToConstant: 12).isActive = true

        // historia
        var cols: [(String, String, Int)] = [("date", "Data", 150)]
        cols += BenchTest.allCases.map { ($0.rawValue, $0.title, 150) }
        cols.append(("score", "Wynik", 90))
        for (id, t, w) in cols {
            let c = NSTableColumn(identifier: .init(id)); c.title = L(t); c.width = CGFloat(w); c.minWidth = 60
            if id != "date" { c.headerCell.alignment = .right }
            historyTable.addTableColumn(c)
        }
        historyTable.rowHeight = 22
        historyTable.intercellSpacing = NSSize(width: 8, height: 1)
        historyTable.backgroundColor = .clear
        historyTable.style = .plain
        historyTable.focusRingType = .none
        historyTable.dataSource = self
        historyTable.delegate = self
        ColumnMenu.attach(to: historyTable, key: "benchmarks", locked: ["date"])
        let histScroll = NSScrollView()
        histScroll.documentView = historyTable
        histScroll.drawsBackground = false
        histScroll.hasVerticalScroller = true; histScroll.scrollerStyle = .overlay; histScroll.autohidesScrollers = true
        histScroll.setContentHuggingPriority(.init(1), for: .vertical)
        let clear = NSButton(title: L("Wyczyść historię"), target: self, action: #selector(clearHistory))
        clear.bezelStyle = .rounded; clear.controlSize = .small; clear.font = Fonts.ui(11.5)
        let exportButton = NSButton(title: L("Eksportuj wyniki…"), target: self, action: #selector(exportResults))
        exportButton.bezelStyle = .rounded; exportButton.controlSize = .small; exportButton.font = Fonts.ui(11.5)
        let histHead = hstack([Label.make(L("Historia wyników"), size: 14, weight: .semibold), spacer(), exportButton, clear], spacing: 8)

        let top = hstack([testsCard, tilesStack], spacing: 14, alignment: .top)
        let root = vstack([title, chip, top, progress, status, histHead, histScroll], spacing: 8)
        for v in [title, top, progress, histHead, histScroll] { v.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true }
        testsCard.heightAnchor.constraint(equalTo: top.heightAnchor).isActive = true
        root.pin(to: view, insets: NSEdgeInsets(top: 2, left: 18, bottom: 12, right: 18))

        loadSelection()
        loadHistory()
        NotificationCenter.default.addObserver(forName: .themeChanged, object: nil, queue: .main) { [weak self] _ in
            self?.historyTable.reloadData(); self?.testTable.reloadData()
        }
    }

    private var totalTiles: TileStat?

    func pageDidAppear() {}

    // MARK: dane
    private func loadSelection() {
        if let saved = UserDefaults.standard.stringArray(forKey: "benchSelected") {
            selected = Set(saved.compactMap(BenchTest.init(rawValue:)))
            if selected.isEmpty { selected = Set(BenchTest.allCases) }
        }
        testTable.reloadData()
    }

    private func saveSelection() {
        UserDefaults.standard.set(selected.map(\.rawValue), forKey: "benchSelected")
    }

    private func loadHistory() {
        if let d = UserDefaults.standard.data(forKey: "benchHistory"),
           let h = try? JSONDecoder().decode([BenchResult].self, from: d) { history = h }
        historyTable.reloadData()
        testTable.reloadData()
        if let last = history.first { show(last, previous: history.count > 1 ? history[1] : nil) }
    }

    private func score(_ r: BenchResult) -> Double {
        BenchTest.allCases.reduce(0) { $0 + ($1.weight * (r[$1] ?? 0)) }
    }

    /// Najnowszy zapisany wynik danego testu
    private func lastValue(_ t: BenchTest) -> Double? {
        history.first { $0[t] != nil }?[t]
    }

    private func show(_ r: BenchResult, previous: BenchResult?) {
        func delta(_ a: Double, _ b: Double?) -> String {
            guard let b, b > 0 else { return "" }
            let d = (a - b) / b * 100
            return String(format: "  (%@%.1f%%)", d >= 0 ? "+" : "", d)
        }
        for t in BenchTest.allCases {
            guard let v = r[t] else { continue }
            tiles[t]?.value.update(t.format(v) + delta(v, previous?[t]), flash: false)
        }
        let s = score(r)
        totalTiles?.value.update(String(format: "%.0f " + L("pkt"), s) + delta(s, previous.map(score)), flash: false)
    }

    // MARK: uruchamianie
    @objc private func durationChanged() { UserDefaults.standard.set(durationPopup.indexOfSelectedItem, forKey: "benchDuration") }
    @objc private func runAllTests() { run(Set(BenchTest.allCases)) }
    @objc private func runSelectedTests() { run(selected) }
    @objc private func stopRun() { cancelRequested = true; status.stringValue = L("Zatrzymywanie po bieżącym teście…") }
    @objc override func selectAll(_ sender: Any?) { selected = Set(BenchTest.allCases); saveSelection(); testTable.reloadData() }
    @objc private func deselectAll() { selected.removeAll(); saveSelection(); testTable.reloadData() }

    private func run(_ tests: Set<BenchTest>) {
        guard !running else { return }
        let order = BenchTest.allCases.filter { tests.contains($0) }
        guard !order.isEmpty else {
            status.stringValue = L("Nie zaznaczono żadnego testu.")
            return
        }
        running = true
        cancelRequested = false
        runSelected.isEnabled = false
        runAllButton.isEnabled = false
        stopButton.isEnabled = true
        progress.value = 0
        for t in order { tiles[t]?.value.update("…", flash: false) }
        let dir = NSTemporaryDirectory()
        let secs = seconds
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var values: [String: Double] = [:]
            for (i, test) in order.enumerated() {
                if self?.cancelRequested == true { break }
                DispatchQueue.main.async {
                    self?.status.stringValue = L(test.title) + "…"
                    self?.progress.value = Double(i) / Double(order.count)
                }
                let v: Double
                switch test {
                case .cpuSingle: v = Bench.cpuSingle(seconds: secs)
                case .cpuMulti: v = Bench.cpuMulti(seconds: secs)
                case .memory: v = Bench.memory(seconds: max(1, secs * 0.7))
                case .diskWrite, .diskRead:
                    if let cached = values["diskPair"] {
                        v = test == .diskWrite ? cached : (values["diskReadPair"] ?? 0)
                    } else {
                        let d = Bench.disk(dir: dir, totalMB: secs >= 6 ? 1024 : (secs <= 1 ? 256 : 512))
                        values["diskPair"] = d.write
                        values["diskReadPair"] = d.read
                        v = test == .diskWrite ? d.write : d.read
                    }
                case .gpu: v = Bench.gpu(seconds: max(1, secs * 0.7))
                }
                values[test.rawValue] = v
                DispatchQueue.main.async { self?.tiles[test]?.value.update(test.format(v), flash: false) }
            }
            values["diskPair"] = nil
            values["diskReadPair"] = nil
            let result = BenchResult(date: Date(), values: values)
            DispatchQueue.main.async {
                guard let self else { return }
                self.progress.value = 1
                self.status.stringValue = (self.cancelRequested ? L("Przerwano") : L("Gotowe")) + " · " + Fmt.dateTime.string(from: result.date)
                if !result.values.isEmpty {
                    let prev = self.history.first
                    self.history.insert(result, at: 0)
                    if self.history.count > 30 { self.history.removeLast() }
                    if let data = try? JSONEncoder().encode(self.history) { UserDefaults.standard.set(data, forKey: "benchHistory") }
                    self.show(result, previous: prev)
                }
                self.historyTable.reloadData()
                self.testTable.reloadData()
                self.running = false
                self.cancelRequested = false
                self.runSelected.isEnabled = true
                self.runAllButton.isEnabled = true
                self.stopButton.isEnabled = false
            }
        }
    }

    @objc private func clearHistory() {
        history.removeAll()
        UserDefaults.standard.removeObject(forKey: "benchHistory")
        historyTable.reloadData()
        testTable.reloadData()
    }

    @objc private func exportResults() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "vitals-benchmarki.csv"
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.begin { [weak self] resp in
            guard resp == .OK, let url = panel.url, let self else { return }
            var text = "data;" + BenchTest.allCases.map { $0.title + " (" + $0.unit + ")" }.joined(separator: ";") + ";wynik\n"
            let f = ISO8601DateFormatter()
            for r in self.history {
                let cells = BenchTest.allCases.map { t in
                    r[t].map { String(format: "%.2f", $0).replacingOccurrences(of: ".", with: ",") } ?? ""
                }
                text += f.string(from: r.date) + ";" + cells.joined(separator: ";") + ";"
                    + String(format: "%.0f", self.score(r)) + "\n"
            }
            try? text.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    @objc private func toggleTest(_ sender: NSButton) {
        guard let t = BenchTest(rawValue: sender.identifier?.rawValue ?? "") else { return }
        if sender.state == .on { selected.insert(t) } else { selected.remove(t) }
        saveSelection()
    }

    // MARK: tabele
    func numberOfRows(in tableView: NSTableView) -> Int {
        tableView === testTable ? BenchTest.allCases.count : history.count
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let r = ThemedRowView(); r.inset = 0; r.zebra = row % 2 == 1; return r
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let col = tableColumn else { return nil }
        if tableView === testTable {
            let t = BenchTest.allCases[row]
            let cell = NSTableCellView()
            switch col.identifier.rawValue {
            case "on":
                let box = NSButton(checkboxWithTitle: "", target: self, action: #selector(toggleTest(_:)))
                box.identifier = NSUserInterfaceItemIdentifier(t.rawValue)
                box.state = selected.contains(t) ? .on : .off
                box.pinCentered(to: cell, leading: 4, trailing: 0)
            case "name":
                let icon = symbol(t.icon, size: 13, weight: .regular, color: P.accent(t.accent))
                icon.widthAnchor.constraint(equalToConstant: 20).isActive = true
                let label = Label.make(L(t.title), size: 12)
                hstack([icon, label], spacing: 6).pinCentered(to: cell, leading: 2, trailing: 2)
            default:
                let label = Label.make(lastValue(t).map { t.format($0) } ?? "—", size: 11.5, dim: true, mono: true)
                label.alignment = .right
                label.pinCentered(to: cell, leading: 2, trailing: 6)
            }
            return cell
        }

        guard row < history.count else { return nil }
        let r = history[row]
        let cell = ProcCell()
        cell.flash.pinCentered(to: cell, leading: 4, trailing: 4)
        let tf = cell.flash
        tf.font = Fonts.mono(11.5)
        tf.alignment = .right
        tf.textColor = P.text
        switch col.identifier.rawValue {
        case "date":
            tf.alignment = .left
            tf.update(Fmt.dateTime.string(from: r.date), flash: false)
            tf.textColor = P.textDim
        case "score":
            tf.update(String(format: "%.0f", score(r)), flash: false)
        default:
            if let t = BenchTest(rawValue: col.identifier.rawValue) {
                tf.update(r[t].map { String(format: "%.\(t.precision)f", $0) } ?? L("—"), flash: false)
                if r[t] == nil { tf.textColor = P.textDim }
            }
        }
        return cell
    }
}
