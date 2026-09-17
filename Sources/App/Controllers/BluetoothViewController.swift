// BluetoothViewController.swift - stan kontrolera Bluetooth i lista sparowanych urządzeń
import AppKit
import IOBluetooth

/// Jedno urządzenie Bluetooth z danymi widocznymi w tabeli
private struct BTDevice {
    let name: String
    let address: String
    let kind: String
    let connected: Bool
    let paired: Bool
    let rssi: Int?
    let battery: Int?
}

final class BluetoothViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, PageRefreshable {
    private let table = NSTableView()
    private var devices: [BTDevice] = []
    private let stateLabel = Label.make(L("—"), size: 12, dim: true)
    private let addressLabel = Label.make(L("—"), size: 12, dim: true)
    private let countLabel = Label.make(L("—"), size: 12, dim: true)
    private var timer: Timer?

    override func loadView() {
        view = NSView()
        let title = PageTitleView(L("Bluetooth"))

        let card = CardView()
        card.accent = .network
        let head = hstack([Label.make(L("Kontroler:"), size: 12, dim: true), stateLabel, spacer(),
                           Label.make(L("Adres:"), size: 12, dim: true), addressLabel, spacer(),
                           Label.make(L("Urządzenia:"), size: 12, dim: true), countLabel], spacing: 8)
        head.pin(to: card, insets: NSEdgeInsets(top: 10, left: 14, bottom: 10, right: 14))

        for (id, t, w) in [("name", "Urządzenie", 260), ("kind", "Rodzaj", 150), ("state", "Stan", 110),
                           ("rssi", "Sygnał", 90), ("battery", "Bateria", 90), ("addr", "Adres", 170)] {
            let c = NSTableColumn(identifier: .init(id))
            c.title = L(t); c.width = CGFloat(w); c.minWidth = 60
            if ["rssi", "battery"].contains(id) { c.headerCell.alignment = .right }
            table.addTableColumn(c)
        }
        table.rowHeight = 23
        table.usesAlternatingRowBackgroundColors = false
        table.backgroundColor = .clear
        table.style = .plain
        table.dataSource = self
        table.delegate = self
        table.focusRingType = .none
        ColumnMenu.attach(to: table, key: "bluetooth", locked: ["name"])
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true; scroll.scrollerStyle = .overlay; scroll.autohidesScrollers = true

        let root = vstack([title, card, scroll], spacing: 8)
        for v in [card, scroll] { v.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -36).isActive = true }
        root.alignment = .leading
        root.pin(to: view, insets: NSEdgeInsets(top: 2, left: 18, bottom: 12, right: 18))
        scroll.setContentHuggingPriority(.init(1), for: .vertical)
    }

    func pageDidAppear() {
        reload()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in self?.reload() }
    }

    override func viewDidDisappear() {
        super.viewDidDisappear()
        timer?.invalidate(); timer = nil
    }

    /// Odczyt stanu kontrolera i listy sparowanych urządzeń z IOBluetooth
    private func reload() {
        let host = IOBluetoothHostController.default()
        let powered = host?.powerState == kBluetoothHCIPowerStateON
        stateLabel.stringValue = host == nil ? L("brak kontrolera") : (powered ? L("włączony") : L("wyłączony"))
        stateLabel.textColor = powered ? P.good : P.textDim
        addressLabel.stringValue = host?.addressAsString() ?? L("—")

        var list: [BTDevice] = []
        for d in IOBluetoothDevice.pairedDevices() ?? [] {
            guard let dev = d as? IOBluetoothDevice else { continue }
            let connected = dev.isConnected()
            list.append(BTDevice(name: dev.nameOrAddress ?? dev.addressString ?? "—",
                                 address: dev.addressString ?? "—",
                                 kind: Self.kind(dev),
                                 connected: connected,
                                 paired: dev.isPaired(),
                                 rssi: connected ? Int(dev.rawRSSI()) : nil,
                                 battery: Self.battery(for: dev.nameOrAddress ?? "")))
        }
        list.sort { ($0.connected ? 0 : 1, $0.name.lowercased()) < ($1.connected ? 0 : 1, $1.name.lowercased()) }
        devices = list
        let connected = list.filter(\.connected).count
        countLabel.stringValue = "\(list.count) " + L("sparowanych") + " · \(connected) " + L("połączonych")
        table.reloadData()
    }

    /// Poziom baterii akcesoriów (klawiatura, mysz, słuchawki) z IORegistry; odczyt w tle co kilkanaście sekund
    private static var batteries: [String: Int] = [:]
    private static var batteriesAt = Date.distantPast
    private static var batteryPending = false

    private static func battery(for name: String) -> Int? {
        if !batteryPending, Date().timeIntervalSince(batteriesAt) > 15 {
            batteryPending = true
            DispatchQueue.global(qos: .utility).async {
                let out = Shell.run("/usr/sbin/ioreg", ["-r", "-k", "BatteryPercent", "-l"], timeout: 8)
                var map: [String: Int] = [:]
                var product = ""
                for line in out.split(separator: "\n") {
                    if let r = line.range(of: "\"Product\" = \"") {
                        product = String(line[r.upperBound...]).replacingOccurrences(of: "\"", with: "")
                    }
                    if let r = line.range(of: "\"BatteryPercent\" = ") {
                        let v = String(line[r.upperBound...]).trimmingCharacters(in: .whitespaces)
                        if let n = Int(v), !product.isEmpty { map[product] = n }
                    }
                }
                DispatchQueue.main.async {
                    batteries = map
                    batteriesAt = Date()
                    batteryPending = false
                }
            }
        }
        guard !name.isEmpty else { return nil }
        if let v = batteries[name] { return v }
        // nazwy w IORegistry bywają skrócone („Magic Keyboard” vs „Klawiatura Sławka”)
        return batteries.first { $0.key.contains(name) || name.contains($0.key) }?.value
    }

    /// Rodzaj urządzenia z klasy urządzenia (Class of Device)
    private static func kind(_ d: IOBluetoothDevice) -> String {
        switch d.deviceClassMajor {
        case UInt32(kBluetoothDeviceClassMajorComputer): return "Komputer"
        case UInt32(kBluetoothDeviceClassMajorPhone): return "Telefon"
        case UInt32(kBluetoothDeviceClassMajorLANAccessPoint): return "Punkt dostępu"
        case UInt32(kBluetoothDeviceClassMajorAudio): return "Audio"
        case UInt32(kBluetoothDeviceClassMajorPeripheral):
            switch d.deviceClassMinor {
            case UInt32(kBluetoothDeviceClassMinorPeripheral1Keyboard): return "Klawiatura"
            case UInt32(kBluetoothDeviceClassMinorPeripheral1Pointing): return "Mysz / gładzik"
            default: return "Urządzenie peryferyjne"
            }
        case UInt32(kBluetoothDeviceClassMajorImaging): return "Obraz / drukarka"
        case UInt32(kBluetoothDeviceClassMajorWearable): return "Urządzenie ubieralne"
        case UInt32(kBluetoothDeviceClassMajorToy): return "Zabawka"
        case UInt32(kBluetoothDeviceClassMajorHealth): return "Zdrowie"
        default: return "Inne"
        }
    }

    // MARK: tabela
    func numberOfRows(in tableView: NSTableView) -> Int { devices.count }
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let r = ThemedRowView(); r.inset = 0; r.zebra = row % 2 == 1; return r
    }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let col = tableColumn, row < devices.count else { return nil }
        let d = devices[row]
        let cell: ProcCell
        if let c = table.makeView(withIdentifier: col.identifier, owner: nil) as? ProcCell { cell = c } else {
            cell = ProcCell(); cell.identifier = col.identifier
            cell.flash.pinCentered(to: cell, leading: 4, trailing: 4)
        }
        let tf = cell.flash
        tf.font = Fonts.ui(11.5); tf.alignment = .left; tf.textColor = d.connected ? P.text : P.textDim
        switch col.identifier.rawValue {
        case "name": tf.update(d.name, flash: false)
        case "kind": tf.update(d.kind, flash: false)
        case "state":
            tf.update(d.connected ? L("Połączone") : (d.paired ? L("Sparowane") : L("—")), flash: false)
            if d.connected { tf.textColor = P.good }
        case "rssi":
            tf.alignment = .right; tf.font = Fonts.mono(11.5)
            tf.update(d.rssi.map { "\($0) dBm" } ?? L("—"), flash: false)
            if let r = d.rssi { tf.textColor = r > -60 ? P.good : (r > -75 ? P.warn : P.bad) }
        case "battery":
            tf.alignment = .right; tf.font = Fonts.mono(11.5)
            tf.update(d.battery.map { "\($0)%" } ?? L("—"), flash: false)
        default:
            tf.font = Fonts.mono(11.5)
            tf.update(d.address, flash: false)
        }
        return cell
    }
}
