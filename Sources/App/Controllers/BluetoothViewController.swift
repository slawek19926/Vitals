// BluetoothViewController.swift - sparowane urządzenia i skanowanie BLE na żądanie
import AppKit
import CoreBluetooth
import IOBluetooth

struct BluetoothNearbyDevice {
    let id: UUID
    let name: String?
    let rssi: Int?
}

enum BluetoothReading {
    /// +127 oznacza niedostępny odczyt IOBluetooth, a nie silny sygnał.
    static func rssi(_ value: Int) -> Int? { (-127...0).contains(value) ? value : nil }

    /// Łączymy poziom baterii tylko przy dokładnie jednej zgodnej nazwie produktu.
    static func batteries(from data: Data) -> [String: Int] {
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) else { return [:] }
        var values: [String: Int] = [:]
        var ambiguous = Set<String>()
        func visit(_ object: Any) {
            if let dict = object as? [String: Any] {
                if let name = dict["Product"] as? String,
                   let percent = dict["BatteryPercent"] as? Int, (0...100).contains(percent) {
                    if values[name] != nil { ambiguous.insert(name) }
                    else { values[name] = percent }
                }
                for value in dict.values { visit(value) }
            } else if let array = object as? [Any] {
                for value in array { visit(value) }
            }
        }
        visit(plist)
        for name in ambiguous { values.removeValue(forKey: name) }
        return values
    }
}

/// Core Bluetooth wykrywa tylko reklamujące się urządzenia Low Energy.
/// Sam menedżer powstaje dopiero po naciśnięciu przycisku skanowania.
private final class BluetoothScanner: NSObject, CBCentralManagerDelegate {
    enum Phase: Equatable { case idle, waiting, scanning, finished, poweredOff, unauthorized, unavailable }
    private(set) var phase: Phase = .idle
    private(set) var devices: [UUID: BluetoothNearbyDevice] = [:]
    var onChange: (() -> Void)?
    private var central: CBCentralManager?
    private var timeout: Timer?
    private var requested = false

    func start() {
        stop()
        devices.removeAll()
        requested = true
        phase = .waiting
        onChange?()
        if let central { centralManagerDidUpdateState(central) }
        else {
            central = CBCentralManager(delegate: self, queue: .main,
                                       options: [CBCentralManagerOptionShowPowerAlertKey: false])
        }
    }

    func stop() {
        requested = false
        timeout?.invalidate(); timeout = nil
        central?.stopScan()
        if phase == .waiting || phase == .scanning { phase = .finished; onChange?() }
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard requested else { return }
        switch central.state {
        case .poweredOn:
            guard phase != .scanning else { return }
            phase = .scanning
            central.scanForPeripherals(withServices: nil, options: nil)
            timeout = Timer.scheduledTimer(withTimeInterval: 12, repeats: false) { [weak self] _ in self?.stop() }
        case .poweredOff: phase = .poweredOff; requested = false
        case .unauthorized: phase = .unauthorized; requested = false
        case .unsupported: phase = .unavailable; requested = false
        case .resetting, .unknown: phase = .waiting
        @unknown default: phase = .unavailable; requested = false
        }
        onChange?()
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard requested else { return }
        let advertised = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        let name = [advertised, peripheral.name].compactMap { $0 }.first { !$0.isEmpty }
        devices[peripheral.identifier] = BluetoothNearbyDevice(id: peripheral.identifier, name: name,
                                                                rssi: BluetoothReading.rssi(RSSI.intValue))
        onChange?()
    }

}

private struct BluetoothPairedDevice {
    let name: String
    let address: String
    let kind: String
    let icon: String
    let connected: Bool
    let rssi: Int?
    let battery: Int?
}

final class BluetoothViewController: NSViewController, PageRefreshable {
    private let state = Label.make("—", size: 12, dim: true)
    private let address = Label.make("—", size: 12, dim: true)
    private let summary = Label.make("—", size: 12, dim: true)
    private let scanButton = NSButton(title: L("Skanuj w pobliżu"), target: nil, action: nil)
    private let connectedCard = SectionCard(title: "Połączone", icon: "dot.radiowaves.left.and.right", accent: .network)
    private let pairedCard = SectionCard(title: "Sparowane, niepołączone", icon: "link", accent: .network)
    private let nearbyCard = SectionCard(title: "W pobliżu (BLE)", icon: "waveform.path", accent: .network)
    private let connectedCount = Label.make("", size: 11, dim: true)
    private let pairedCount = Label.make("", size: 11, dim: true)
    private let nearbyCount = Label.make("", size: 11, dim: true)
    private let scanner = BluetoothScanner()
    private var timer: Timer?
    private var batteries: [String: Int] = [:]
    private var batteriesAt = Date.distantPast
    private var batteryPending = false

    override func loadView() {
        view = NSView()
        let title = PageTitleView(L("Bluetooth"))
        let refresh = NSButton(title: L("Odśwież"), target: self, action: #selector(reload))
        let settings = NSButton(title: L("Ustawienia Bluetooth…"), target: self, action: #selector(openSettings))
        for button in [refresh, settings, scanButton] {
            button.bezelStyle = .rounded; button.controlSize = .small; button.font = Fonts.ui(11.5)
        }
        scanButton.target = self; scanButton.action = #selector(toggleScan)
        title.accessory = hstack([settings, refresh, scanButton], spacing: 8)

        let host = CardView(accent: .network)
        hstack([Label.make(L("Kontroler:"), size: 12, dim: true), state, spacer(),
                Label.make(L("Adres:"), size: 12, dim: true), address, spacer(), summary], spacing: 8)
            .pin(to: host, insets: NSEdgeInsets(top: 10, left: 14, bottom: 10, right: 14))
        connectedCard.trailing.addArrangedSubview(connectedCount)
        pairedCard.trailing.addArrangedSubview(pairedCount)
        nearbyCard.trailing.addArrangedSubview(nearbyCount)

        let scroll = NSScrollView()
        scroll.drawsBackground = false; scroll.hasVerticalScroller = true
        scroll.scrollerStyle = .overlay; scroll.autohidesScrollers = true
        let doc = FlippedView()
        scroll.documentView = doc
        let sections = vstack([connectedCard, pairedCard, nearbyCard], spacing: 10)
        for card in [connectedCard, pairedCard, nearbyCard] {
            card.widthAnchor.constraint(equalTo: sections.widthAnchor).isActive = true
        }
        sections.pin(to: doc, insets: NSEdgeInsets(top: 4, left: 0, bottom: 12, right: 0))
        doc.translatesAutoresizingMaskIntoConstraints = false
        doc.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor).isActive = true
        scroll.setContentHuggingPriority(.init(1), for: .vertical)

        let root = vstack([title, host, scroll], spacing: 8)
        for item in [title, host, scroll] { item.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true }
        root.pin(to: view, insets: NSEdgeInsets(top: 2, left: 18, bottom: 10, right: 18))
        scanner.onChange = { [weak self] in self?.renderNearby() }
        renderNearby()
    }

    func pageDidAppear() {
        reload()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in self?.reload() }
    }

    override func viewDidDisappear() {
        super.viewDidDisappear()
        timer?.invalidate(); timer = nil
        scanner.stop()
    }

    @objc private func toggleScan() {
        if scanner.phase == .waiting || scanner.phase == .scanning { scanner.stop() }
        else { scanner.start() }
    }

    @objc private func openSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.BluetoothSettings") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func copyIdentifier(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? String else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }

    @objc private func reload() {
        let host = IOBluetoothHostController.default()
        let powered = host?.powerState == kBluetoothHCIPowerStateON
        state.stringValue = host == nil ? L("brak kontrolera") : (powered ? L("włączony") : L("wyłączony"))
        state.textColor = powered ? P.good : P.textDim
        address.stringValue = host?.addressAsString() ?? "—"

        var list: [BluetoothPairedDevice] = []
        for item in IOBluetoothDevice.pairedDevices() ?? [] {
            guard let device = item as? IOBluetoothDevice else { continue }
            let connected = device.isConnected()
            let name = device.nameOrAddress ?? device.addressString ?? L("Nieznane urządzenie")
            let (kind, icon) = Self.kind(device)
            list.append(BluetoothPairedDevice(name: name, address: device.addressString ?? "—",
                                              kind: kind, icon: icon, connected: connected,
                                              rssi: connected ? BluetoothReading.rssi(Int(device.rawRSSI())) : nil,
                                              battery: connected ? batteries[name] : nil))
        }
        list.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        let connected = list.filter(\.connected)
        let saved = list.filter { !$0.connected }
        summary.stringValue = "\(list.count) \(L("sparowanych")) · \(connected.count) \(L("połączonych"))"
        connectedCount.stringValue = "\(connected.count)"
        pairedCount.stringValue = "\(saved.count)"
        render(connected, in: connectedCard, empty: "Brak połączonych urządzeń.")
        render(saved, in: pairedCard, empty: "Brak innych sparowanych urządzeń.")
        updateBatteriesIfNeeded()
    }

    private func updateBatteriesIfNeeded() {
        guard !batteryPending, Date().timeIntervalSince(batteriesAt) > 30 else { return }
        batteryPending = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let output = Shell.run("/usr/sbin/ioreg", ["-a", "-r", "-k", "BatteryPercent"], timeout: 8)
            let values = BluetoothReading.batteries(from: Data(output.utf8))
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.batteries = values
                self.batteriesAt = Date()
                self.batteryPending = false
                if self.view.window != nil { self.reload() }
            }
        }
    }

    private func render(_ devices: [BluetoothPairedDevice], in card: SectionCard, empty: String) {
        clearRows(in: card)
        if devices.isEmpty { card.add(note(empty)); return }
        for device in devices {
            let detail = [device.kind == L("Inne") ? nil : device.kind,
                          device.address == "—" ? nil : device.address].compactMap { $0 }.joined(separator: " · ")
            let row = deviceRow(name: device.name, detail: detail, icon: device.icon,
                                rssi: device.rssi, battery: device.battery)
            if device.address != "—" {
                let menu = NSMenu()
                let copy = NSMenuItem(title: L("Kopiuj adres"), action: #selector(copyIdentifier(_:)), keyEquivalent: "")
                copy.target = self; copy.representedObject = device.address; menu.addItem(copy)
                row.menu = menu
            }
            card.add(row)
        }
    }

    private func renderNearby() {
        clearRows(in: nearbyCard)
        let found = scanner.devices.values.sorted {
            let a = $0.name ?? "~"; let b = $1.name ?? "~"
            let order = a.localizedStandardCompare(b)
            return order == .orderedSame ? $0.id.uuidString < $1.id.uuidString : order == .orderedAscending
        }
        nearbyCount.stringValue = "\(found.count)"
        scanButton.title = (scanner.phase == .waiting || scanner.phase == .scanning)
            ? L("Zatrzymaj skanowanie") : L("Skanuj w pobliżu")
        let message: String
        switch scanner.phase {
        case .idle: message = "Skanowanie wykrywa reklamujące się urządzenia BLE. Sparowane urządzenia są widoczne powyżej."
        case .waiting: message = "Oczekiwanie na dostęp do Bluetooth…"
        case .scanning: message = "Skanowanie BLE trwa 12 sekund. Wyniki pojawiają się poniżej."
        case .finished:
            if found.isEmpty {
                message = "Nic nie wykryto. Włącz tryb parowania w akcesorium i spróbuj ponownie."
            } else { message = "Wyniki ostatniego skanowania BLE. Urządzenia bez nadawanej nazwy są oznaczone jako nieznane." }
        case .poweredOff: message = "Bluetooth jest wyłączony. Włącz go w Ustawieniach systemowych."
        case .unauthorized: message = "Brak dostępu do Bluetooth. Przyznaj go w Ustawieniach systemowych → Prywatność i ochrona → Bluetooth."
        case .unavailable: message = "Skanowanie BLE jest niedostępne na tym komputerze."
        }
        nearbyCard.add(note(message))
        for device in found {
            let id = device.id.uuidString
            let row = deviceRow(name: device.name ?? L("Nieznane urządzenie"), detail: "BLE · \(id.prefix(8))",
                                icon: "antenna.radiowaves.left.and.right", rssi: device.rssi,
                                battery: nil, showsBattery: false)
            let menu = NSMenu()
            let copy = NSMenuItem(title: L("Kopiuj identyfikator"), action: #selector(copyIdentifier(_:)), keyEquivalent: "")
            copy.target = self; copy.representedObject = id; menu.addItem(copy)
            row.menu = menu
            nearbyCard.add(row)
        }
    }

    private func clearRows(in card: SectionCard) {
        for row in card.stack.arrangedSubviews.dropFirst() {
            card.stack.removeArrangedSubview(row); row.removeFromSuperview()
        }
    }

    private func note(_ text: String) -> NSView {
        let label = Label.make(L(text), size: 11.5, dim: true)
        label.lineBreakMode = .byWordWrapping; label.maximumNumberOfLines = 3
        return label
    }

    private func deviceRow(name: String, detail: String, icon: String, rssi: Int?, battery: Int?,
                           showsBattery: Bool = true) -> NSView {
        let image = symbol(icon, size: 15, color: P.textDim)
        image.size(width: 20)
        let nameLabel = Label.make(name, size: 12.5, weight: .medium)
        nameLabel.lineBreakMode = .byTruncatingMiddle
        let detailLabel = Label.make(detail, size: 10.5, dim: true)
        detailLabel.lineBreakMode = .byTruncatingMiddle
        let identity = vstack([nameLabel, detailLabel], spacing: 2)
        identity.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let signal = metric("Sygnał", rssi.map { "\($0) dBm" } ?? "—", width: 92)
        var columns: [NSView] = [image, identity, spacer(), signal]
        if showsBattery { columns.append(metric("Bateria", battery.map { "\($0)%" } ?? "—", width: 65)) }
        let row = hstack(columns, spacing: 10)
        row.heightAnchor.constraint(greaterThanOrEqualToConstant: 42).isActive = true
        return row
    }

    private func metric(_ title: String, _ value: String, width: CGFloat) -> NSView {
        let caption = Label.make(L(title), size: 9.5, dim: true)
        let reading = Label.make(value, size: 11.5)
        reading.font = Fonts.mono(11.5)
        let stack = vstack([caption, reading], spacing: 1)
        stack.size(width: width)
        return stack
    }

    private static func kind(_ device: IOBluetoothDevice) -> (String, String) {
        switch device.deviceClassMajor {
        case UInt32(kBluetoothDeviceClassMajorComputer): return (L("Komputer"), "laptopcomputer")
        case UInt32(kBluetoothDeviceClassMajorPhone): return (L("Telefon"), "iphone")
        case UInt32(kBluetoothDeviceClassMajorAudio): return (L("Audio"), "headphones")
        case UInt32(kBluetoothDeviceClassMajorPeripheral):
            switch device.deviceClassMinor {
            case UInt32(kBluetoothDeviceClassMinorPeripheral1Keyboard): return (L("Klawiatura"), "keyboard")
            case UInt32(kBluetoothDeviceClassMinorPeripheral1Pointing): return (L("Mysz / gładzik"), "computermouse")
            default: return (L("Urządzenie peryferyjne"), "keyboard")
            }
        case UInt32(kBluetoothDeviceClassMajorImaging): return (L("Obraz / drukarka"), "printer")
        case UInt32(kBluetoothDeviceClassMajorWearable): return (L("Urządzenie ubieralne"), "applewatch")
        case UInt32(kBluetoothDeviceClassMajorHealth): return (L("Zdrowie"), "heart")
        default: return (L("Inne"), "dot.radiowaves.left.and.right")
        }
    }
}
