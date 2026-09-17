// SystemInfoViewController.swift - „Informacje o systemie” w stylu TMOG: kategorie po lewej (Sprzęt / Sieć / Oprogramowanie),
// drzewo klucz-wartość po prawej, dane z system_profiler (JSON) + własny przegląd
import AppKit

/// Węzeł drzewa klucz/wartość
final class KVNode {
    let key: String
    var value: String
    var children: [KVNode] = []
    init(_ k: String, _ v: String = "") { key = k; value = v }
}

final class SystemInfoViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSOutlineViewDataSource, NSOutlineViewDelegate, PageRefreshable {
    struct Category { let title: String; let icon: String; let type: String?; let section: String }

    private let categories: [Category] = [
        .init(title: "Przegląd sprzętu", icon: "laptopcomputer", type: "SPHardwareDataType", section: "Sprzęt"),
        .init(title: "Pamięć", icon: "memorychip", type: "SPMemoryDataType", section: "Sprzęt"),
        .init(title: "Audio", icon: "speaker.wave.2", type: "SPAudioDataType", section: "Sprzęt"),
        .init(title: "Bluetooth", icon: "wave.3.right", type: "SPBluetoothDataType", section: "Sprzęt"),
        .init(title: "Kamera", icon: "camera", type: "SPCameraDataType", section: "Sprzęt"),
        .init(title: "Grafika i ekrany", icon: "display", type: "SPDisplaysDataType", section: "Sprzęt"),
        .init(title: "NVMe", icon: "internaldrive", type: "SPNVMeDataType", section: "Sprzęt"),
        .init(title: "Pamięć masowa", icon: "externaldrive", type: "SPStorageDataType", section: "Sprzęt"),
        .init(title: "PCI", icon: "cpu", type: "SPPCIDataType", section: "Sprzęt"),
        .init(title: "Thunderbolt / USB4", icon: "bolt.horizontal", type: "SPThunderboltDataType", section: "Sprzęt"),
        .init(title: "USB", icon: "cable.connector", type: "SPUSBHostDataType", section: "Sprzęt"),
        .init(title: "Zasilanie", icon: "bolt.circle", type: "SPPowerDataType", section: "Sprzęt"),
        .init(title: "Czytniki kart", icon: "creditcard", type: "SPCardReaderDataType", section: "Sprzęt"),
        .init(title: "Secure Element", icon: "lock.shield", type: "SPSecureElementDataType", section: "Sprzęt"),
        .init(title: "Diagnostyka", icon: "stethoscope", type: "SPDiagnosticsDataType", section: "Sprzęt"),
        .init(title: "Wi‑Fi", icon: "wifi", type: "SPAirPortDataType", section: "Sieć"),
        .init(title: "Ethernet", icon: "network", type: "SPEthernetDataType", section: "Sieć"),
        .init(title: "Sieć", icon: "globe", type: "SPNetworkDataType", section: "Sieć"),
        .init(title: "Lokalizacje", icon: "location", type: "SPNetworkLocationDataType", section: "Sieć"),
        .init(title: "Woluminy sieciowe", icon: "externaldrive.connected.to.line.below", type: "SPNetworkVolumeDataType", section: "Sieć"),
        .init(title: "Zapora", icon: "shield", type: "SPFirewallDataType", section: "Sieć"),
        .init(title: "Przegląd oprogramowania", icon: "apple.logo", type: "SPSoftwareDataType", section: "Oprogramowanie"),
        .init(title: "Aplikacje", icon: "square.grid.2x2", type: "SPApplicationsDataType", section: "Oprogramowanie"),
        .init(title: "Rozszerzenia", icon: "puzzlepiece.extension", type: "SPExtensionsDataType", section: "Oprogramowanie"),
        .init(title: "Frameworki", icon: "shippingbox", type: "SPFrameworksDataType", section: "Oprogramowanie"),
        .init(title: "Elementy startowe", icon: "power", type: "SPStartupItemDataType", section: "Oprogramowanie"),
        .init(title: "Historia instalacji", icon: "clock.arrow.circlepath", type: "SPInstallHistoryDataType", section: "Oprogramowanie"),
        .init(title: "Drukarki", icon: "printer", type: "SPPrintersDataType", section: "Oprogramowanie"),
        .init(title: "Profile", icon: "person.text.rectangle", type: "SPConfigurationProfileDataType", section: "Oprogramowanie"),
        .init(title: "Język i region", icon: "character.book.closed", type: "SPInternationalDataType", section: "Oprogramowanie"),
        .init(title: "Narzędzia programistyczne", icon: "hammer", type: "SPDeveloperToolsDataType", section: "Oprogramowanie"),
    ]
    /// Wiersze lewej listy: nagłówki sekcji (String) lub indeksy kategorii (Int)
    private var rows: [Any] = []

    private let list = NSTableView()
    private let outline = NSOutlineView()
    private let header = Label.make("", size: 15, weight: .semibold)
    private let headerIcon = NSImageView()
    private let status = Label.make("", size: 11, dim: true)
    private let refreshButton = NSButton(title: L("Odśwież"), target: nil, action: nil)
    private let exportButton = NSButton(title: L("Kopiuj"), target: nil, action: nil)
    private var cache: [String: [KVNode]] = [:]
    private var loading: Set<String> = []
    private var current: [KVNode] = []
    private var selectedCategory = 0

    override func loadView() {
        view = NSView()
        let title = PageTitleView(L("Sprzęt"))
        refreshButton.bezelStyle = .rounded; refreshButton.controlSize = .small; refreshButton.font = Fonts.ui(12)
        refreshButton.target = self; refreshButton.action = #selector(reloadCurrent)
        exportButton.bezelStyle = .rounded; exportButton.controlSize = .small; exportButton.font = Fonts.ui(12)
        exportButton.target = self; exportButton.action = #selector(copyCurrent)
        title.accessory = hstack([refreshButton, exportButton], spacing: 8)

        var section = ""
        for (i, c) in categories.enumerated() {
            if c.section != section { section = c.section; rows.append(section) }
            rows.append(i)
        }

        // lewa lista
        let col = NSTableColumn(identifier: .init("c"))
        list.addTableColumn(col)
        list.headerView = nil
        list.rowHeight = 24
        list.intercellSpacing = NSSize(width: 0, height: 1)
        list.backgroundColor = .clear
        list.style = .plain
        list.focusRingType = .none
        list.floatsGroupRows = false
        list.dataSource = self
        list.delegate = self
        let listScroll = NSScrollView()
        listScroll.documentView = list
        listScroll.drawsBackground = false
        listScroll.hasVerticalScroller = true; listScroll.scrollerStyle = .overlay; listScroll.autohidesScrollers = true
        listScroll.size(width: 220)

        // prawa: nagłówek + drzewo
        headerIcon.symbolConfiguration = .init(pointSize: 18, weight: .regular)
        headerIcon.size(width: 28)
        let head = hstack([headerIcon, header, spacer(), status], spacing: 10)
        let keyCol = NSTableColumn(identifier: .init("k")); keyCol.title = L("Właściwość"); keyCol.width = 300; keyCol.minWidth = 120
        let valCol = NSTableColumn(identifier: .init("v")); valCol.title = L("Wartość"); valCol.width = 500; valCol.minWidth = 120
        outline.addTableColumn(keyCol); outline.addTableColumn(valCol)
        outline.outlineTableColumn = keyCol
        outline.rowHeight = 21
        outline.intercellSpacing = NSSize(width: 10, height: 1)
        outline.backgroundColor = .clear
        outline.style = .plain
        outline.focusRingType = .none
        outline.indentationPerLevel = 16
        outline.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        // prawy przycisk na nagłówku: wybór widocznych kolumn
        ColumnMenu.attach(to: outline, key: "systemInfo", locked: ["k"])
        outline.dataSource = self
        outline.delegate = self
        outline.headerView?.frame.size.height = 22
        let outScroll = NSScrollView()
        outScroll.documentView = outline
        outScroll.drawsBackground = false
        outScroll.hasVerticalScroller = true; outScroll.scrollerStyle = .overlay; outScroll.autohidesScrollers = true
        outScroll.setContentHuggingPriority(.init(1), for: .vertical)
        let right = vstack([head, outScroll], spacing: 8)
        head.widthAnchor.constraint(equalTo: right.widthAnchor).isActive = true
        outScroll.widthAnchor.constraint(equalTo: right.widthAnchor).isActive = true

        let divider = ThemedView(); divider.size(width: 1)
        divider.layer?.backgroundColor = P.border.alpha(0.6).cgColor
        NotificationCenter.default.addObserver(forName: .themeChanged, object: nil, queue: .main) { [weak self] _ in
            divider.layer?.backgroundColor = P.border.alpha(0.6).cgColor
            self?.list.reloadData(); self?.outline.reloadData(); self?.applyHeaderTheme()
        }

        let body = hstack([listScroll, divider, right], spacing: 12, alignment: .top)
        for v in [listScroll, divider, right] { v.heightAnchor.constraint(equalTo: body.heightAnchor).isActive = true }
        body.setContentHuggingPriority(.init(1), for: .vertical)
        let root = vstack([title, body], spacing: 6)
        for v in [title, body] { v.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true }
        root.pin(to: view, insets: NSEdgeInsets(top: 2, left: 18, bottom: 10, right: 18))

        list.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        select(0)
    }

    func pageDidAppear() {}

    func select(type: String) {
        guard let i = categories.firstIndex(where: { $0.type == type }), let row = rows.firstIndex(where: { ($0 as? Int) == i }) else { return }
        list.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        select(i)
    }

    private func applyHeaderTheme() {
        header.textColor = P.text; status.textColor = P.textDim
        headerIcon.contentTintColor = P.gpu
    }

    // MARK: kategorie
    private func select(_ i: Int) {
        selectedCategory = i
        let c = categories[i]
        header.stringValue = L(c.title)
        headerIcon.image = NSImage(systemSymbolName: c.icon, accessibilityDescription: nil)
        applyHeaderTheme()
        if let t = c.type {
            if let cached = cache[t] { current = cached; status.stringValue = "\(countLeaves(cached)) " + L("właściwości"); outline.reloadData(); expandAll() }
            else { current = [KVNode(L("Ładowanie danych z system_profiler…"))]; outline.reloadData(); status.stringValue = L("ładowanie…"); load(t) }
        }
    }

    private func load(_ type: String) {
        guard !loading.contains(type) else { return }
        loading.insert(type)
        let slow = ["SPApplicationsDataType", "SPFrameworksDataType", "SPExtensionsDataType", "SPInstallHistoryDataType"].contains(type)
        if slow { status.stringValue = L("ładowanie… (ta kategoria może potrwać kilkanaście sekund)") }
        Shell.async("/usr/sbin/system_profiler", ["-json", "-detailLevel", slow ? "mini" : "full", type], timeout: 120) { [weak self] out in
            guard let self else { return }
            self.loading.remove(type)
            var nodes: [KVNode] = []
            if let data = out.data(using: .utf8), let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let arr = json[type] as? [Any] {
                nodes = arr.enumerated().compactMap { self.node(from: $0.element, fallbackTitle: L("Pozycja") + " \($0.offset + 1)") }
            }
            if nodes.isEmpty { nodes = [KVNode(L("Brak danych"), L("system_profiler nie zwrócił informacji dla tej kategorii"))] }
            // rozwiń „hardware_overview”-podobne pojedyncze pozycje do korzenia
            if nodes.count == 1, !nodes[0].children.isEmpty, nodes[0].value.isEmpty { nodes = nodes[0].children }
            self.cache[type] = nodes
            if self.categories[self.selectedCategory].type == type {
                self.current = nodes
                self.status.stringValue = "\(self.countLeaves(nodes)) " + L("właściwości")
                self.outline.reloadData()
                self.expandAll()
            }
        }
    }

    private func countLeaves(_ nodes: [KVNode]) -> Int { nodes.reduce(0) { $0 + ($1.children.isEmpty ? 1 : countLeaves($1.children)) } }

    private func expandAll() {
        func exp(_ n: KVNode, depth: Int) {
            if depth < 2 { outline.expandItem(n) }
            for c in n.children { exp(c, depth: depth + 1) }
        }
        for n in current { exp(n, depth: 0) }
    }

    // MARK: konwersja JSON -> drzewo
    private func node(from any: Any, fallbackTitle: String) -> KVNode? {
        if let dict = any as? [String: Any] {
            let title = (dict["_name"] as? String) ?? fallbackTitle
            let n = KVNode(prettify(title))
            for key in dict.keys.sorted(by: keyOrder) where key != "_name" {
                let v = dict[key]!
                if let sub = v as? [String: Any] {
                    if let child = node(from: sub, fallbackTitle: translate(key)) { child.value = ""; n.children.append(KVNode(translate(key), "", children: child.children)) }
                } else if let arr = v as? [Any] {
                    if arr.allSatisfy({ $0 is String || $0 is NSNumber }) {
                        n.children.append(KVNode(translate(key), arr.map { "\($0)" }.joined(separator: ", ")))
                    } else {
                        let grp = KVNode(translate(key), "\(arr.count)")
                        for (i, item) in arr.enumerated() { if let c = node(from: item, fallbackTitle: "\(translate(key)) \(i + 1)") { grp.children.append(c) } }
                        n.children.append(grp)
                    }
                } else {
                    n.children.append(KVNode(translate(key), format(v)))
                }
            }
            return n
        }
        return KVNode(fallbackTitle, format(any))
    }

    private func format(_ v: Any) -> String {
        if let b = v as? Bool { return L(b ? "tak" : "nie") }
        if let s = v as? String {
            let map = ["spdisplays_yes": "tak", "spdisplays_no": "nie", "activation_lock_enabled": "włączona", "activation_lock_disabled": "wyłączona",
                       "spmemory_yes": "tak", "spmemory_no": "nie", "yes": "tak", "no": "nie", "spnetwork_yes": "tak", "spnetwork_no": "nie",
                       "TRUE": "tak", "FALSE": "nie", "spusb_yes": "tak", "spusb_no": "nie"]
            return map[s].map { L($0) } ?? s
        }
        return "\(v)"
    }

    private func keyOrder(_ a: String, _ b: String) -> Bool {
        let priority = ["machine_name", "chip_type", "machine_model", "model_number", "number_processors", "physical_memory", "os_version", "kernel_version", "boot_volume", "uptime", "user_name", "_items"]
        let ia = priority.firstIndex(of: a) ?? 999, ib = priority.firstIndex(of: b) ?? 999
        return ia != ib ? ia < ib : a < b
    }

    private static let translations: [String: String] = [
        "machine_name": "Nazwa modelu", "machine_model": "Identyfikator modelu", "model_number": "Numer modelu", "chip_type": "Układ",
        "number_processors": "Rdzenie (P:E)", "physical_memory": "Pamięć", "serial_number": "Numer seryjny", "platform_UUID": "UUID sprzętu",
        "provisioning_UDID": "UDID", "boot_rom_version": "Wersja firmware", "os_loader_version": "Wersja OS Loader", "activation_lock_status": "Blokada aktywacji",
        "os_version": "Wersja systemu", "kernel_version": "Wersja jądra", "boot_volume": "Wolumin startowy", "boot_mode": "Tryb startu", "uptime": "Czas pracy",
        "user_name": "Użytkownik", "local_host_name": "Nazwa komputera", "secure_vm": "Bezpieczna pamięć wirtualna", "system_integrity": "Integralność systemu (SIP)",
        "_items": "Elementy", "dimm_manufacturer": "Producent", "dimm_type": "Typ", "SPMemoryDataType": "Pamięć", "spdisplays_vendor": "Producent",
        "sppci_model": "Model", "spdisplays_ndrvs": "Ekrany", "spdisplays_resolution": "Rozdzielczość", "spdisplays_main": "Ekran główny",
        "spdisplays_mirror": "Klonowanie", "spdisplays_online": "Aktywny", "spdisplays_pixelresolution": "Rozdzielczość pikseli", "spdisplays_display_type": "Typ ekranu",
        "spdisplays_connection_type": "Połączenie", "sppci_cores": "Rdzenie", "sppci_bus": "Magistrala", "sppci_device_type": "Typ urządzenia", "spdisplays_mtlgpufamilysupport": "Metal",
        "device_manufacturer": "Producent", "device_model": "Model", "device_revision": "Rewizja", "device_serial": "Numer seryjny", "size": "Rozmiar", "free_space": "Wolne",
        "mount_point": "Punkt montowania", "file_system": "System plików", "writable": "Zapisywalny", "bsd_name": "Nazwa BSD", "volume_uuid": "UUID woluminu",
        "spnvme_trim_support": "TRIM", "spnvme_smart_status": "Stan S.M.A.R.T.", "detachable_drive": "Odłączalny", "removable_media": "Nośnik wymienny",
        "physical_drive": "Dysk fizyczny", "medium_type": "Rodzaj nośnika", "protocol": "Protokół", "internal": "Wewnętrzny", "partition_map_type": "Tablica partycji",
        "sppower_battery_health_info": "Kondycja baterii", "sppower_battery_charge_info": "Ładowanie", "sppower_battery_model_info": "Model baterii",
        "sppower_battery_cycle_count": "Cykle ładowania", "sppower_battery_health": "Kondycja", "sppower_battery_health_maximum_capacity": "Maks. pojemność",
        "sppower_battery_state_of_charge": "Poziom", "sppower_battery_is_charging": "Ładowanie", "sppower_battery_fully_charged": "Naładowana",
        "sppower_battery_at_warn_level": "Poziom ostrzegawczy", "sppower_battery_serial_number": "Numer seryjny", "sppower_battery_device_name": "Nazwa urządzenia",
        "sppower_battery_firmware_version": "Firmware", "sppower_battery_hardware_revision": "Rewizja sprzętu", "sppower_battery_cell_revision": "Rewizja ogniw",
        "sppower_ac_charger_information": "Zasilacz", "sppower_ac_charger_watts": "Moc (W)", "sppower_ac_charger_name": "Nazwa", "sppower_ac_charger_manufacturer": "Producent",
        "sppower_ac_charger_serial_number": "Numer seryjny", "sppower_battery_charger_connected": "Podłączony", "sppower_battery_is_charging_status": "Status ładowania",
        "sppower_current_power_source": "Bieżące źródło zasilania", "sppower_ups_installed": "UPS", "sppower_system_power_settings": "Ustawienia zasilania",
        "coreaudio_device_input": "Wejścia", "coreaudio_device_output": "Wyjścia", "coreaudio_device_manufacturer": "Producent", "coreaudio_device_srate": "Częstotliwość próbkowania",
        "coreaudio_device_transport": "Transport", "coreaudio_default_audio_input_device": "Domyślne wejście", "coreaudio_default_audio_output_device": "Domyślne wyjście",
        "coreaudio_default_audio_system_device": "Domyślne systemowe", "coreaudio_output_source": "Źródło wyjścia", "coreaudio_input_source": "Źródło wejścia",
        "spcamera_model-id": "Identyfikator modelu", "spcamera_unique-id": "Unikalny identyfikator", "controller_properties": "Właściwości kontrolera", "device_title": "Urządzenia",
        "spusb_host_controller": "Kontroler", "vendor_id": "ID producenta", "product_id": "ID produktu", "manufacturer": "Producent", "location_id": "ID lokalizacji",
        "bcd_device": "Wersja", "serial_num": "Numer seryjny", "spairport_software_information": "Oprogramowanie", "spairport_airport_interfaces": "Interfejsy Wi‑Fi",
        "spairport_status_information": "Status", "spairport_current_network_information": "Bieżąca sieć", "spairport_supported_channels": "Obsługiwane kanały",
        "spairport_wireless_mac_address": "Adres MAC", "spairport_network_type": "Typ sieci", "spairport_network_phymode": "Tryb PHY", "spairport_signal_noise": "Sygnał / szum",
        "spairport_network_channel": "Kanał", "spairport_security_mode": "Zabezpieczenia", "spairport_network_country_code": "Kraj", "spairport_network_rate": "Prędkość",
        "spethernet_mac_address": "Adres MAC", "spethernet_BSD_Device_Name": "Nazwa BSD", "hardware": "Sprzęt", "interface": "Interfejs", "type": "Typ", "ip_address": "Adres IP",
        "IPv4": "IPv4", "IPv6": "IPv6", "DNS": "DNS", "Ethernet": "Ethernet", "Proxies": "Proxy", "spnetwork_service_order": "Kolejność usług", "dhcp": "DHCP",
        "spfirewall_globalstate": "Stan zapory", "spfirewall_loggingenabled": "Logowanie", "spfirewall_stealthenabled": "Tryb ukryty", "spfirewall_applications": "Aplikacje",
        "version": "Wersja", "lastModified": "Ostatnia modyfikacja", "obtained_from": "Pochodzenie", "path": "Ścieżka", "signed_by": "Podpisane przez", "arch_kind": "Architektura",
        "info": "Informacje", "spext_bundleid": "Identyfikator pakietu", "spext_loaded": "Załadowane", "spext_path": "Ścieżka", "spext_version": "Wersja", "spext_obtained_from": "Pochodzenie",
        "spext_architectures": "Architektury", "spext_signed_by": "Podpisane przez", "spext_lastModified": "Ostatnia modyfikacja", "spext_notarized": "Notaryzacja",
        "install_date": "Data instalacji", "install_version": "Wersja", "package_source": "Źródło", "spdiags_lastrun": "Ostatni test", "spdiags_result": "Wynik",
        "user_locale": "Lokalizacja użytkownika", "user_languages": "Języki", "user_country": "Kraj", "spdevtools_version": "Wersja", "spdevtools_path": "Ścieżka", "spdevtools_apps": "Aplikacje", "spdevtools_sdks": "SDK",
    ]

    private func translate(_ key: String) -> String {
        if let t = Self.translations[key] { return L(t) }
        return prettify(key)
    }

    private func prettify(_ s: String) -> String {
        var k = s
        for prefix in ["spdisplays_", "sppower_", "spairport_", "spethernet_", "spnetwork_", "spusb_", "spnvme_", "spext_", "spcamera_", "coreaudio_", "sppci_", "spmemory_", "spfirewall_", "spdiags_", "spdevtools_"] {
            if k.hasPrefix(prefix) { k.removeFirst(prefix.count); break }
        }
        k = k.replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "-", with: " ")
        return k.prefix(1).uppercased() + k.dropFirst()
    }

    @objc private func reloadCurrent() {
        if let t = categories[selectedCategory].type { cache.removeValue(forKey: t); select(selectedCategory) }
    }

    @objc private func copyCurrent() {
        var out = "\(categories[selectedCategory].title)\n\n"
        func dump(_ n: KVNode, _ depth: Int) {
            out += String(repeating: "  ", count: depth) + n.key + (n.value.isEmpty ? "" : ": " + n.value) + "\n"
            for c in n.children { dump(c, depth + 1) }
        }
        for n in current { dump(n, 0) }
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(out, forType: .string)
    }

    // MARK: lewa lista
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool { rows[row] is String }
    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { rows[row] is Int }
    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat { rows[row] is String ? 28 : 24 }
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { let r = ThemedRowView(); r.inset = 4; return r }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = NSTableCellView()
        if let s = rows[row] as? String {
            let l = Label.make(s, size: 11, weight: .semibold, dim: true)
            l.pin(to: cell, insets: NSEdgeInsets(top: 8, left: 10, bottom: 0, right: 4))
            return cell
        }
        let c = categories[rows[row] as! Int]
        let icon = symbol(c.icon, size: 13, weight: .regular, color: P.gpu)
        icon.size(width: 20)
        let l = Label.make(L(c.title), size: 12)
        hstack([icon, l], spacing: 8).pinCentered(to: cell, leading: 12, trailing: 4)
        return cell
    }
    func tableViewSelectionDidChange(_ notification: Notification) {
        guard list.selectedRow >= 0, let i = rows[list.selectedRow] as? Int else { return }
        select(i)
    }

    // MARK: drzewo klucz/wartość
    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if item == nil { return current.count }
        return (item as? KVNode)?.children.count ?? 0
    }
    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if item == nil { return current[index] }
        return (item as! KVNode).children[index]
    }
    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool { !((item as? KVNode)?.children.isEmpty ?? true) }
    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? { let r = ThemedRowView(); r.inset = 0; r.zebra = outlineView.row(forItem: item) % 2 == 1; return r }
    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let n = item as? KVNode, let col = tableColumn else { return nil }
        let cell = NSTableCellView()
        let isKey = col.identifier.rawValue == "k"
        let l = Label.make(isKey ? n.key : n.value, size: 12, weight: isKey && !n.children.isEmpty ? .semibold : .regular, dim: isKey && n.children.isEmpty)
        l.isSelectable = !isKey
        l.pinCentered(to: cell, leading: 2, trailing: 2)
        return cell
    }
}

extension KVNode {
    convenience init(_ k: String, _ v: String, children: [KVNode]) { self.init(k, v); self.children = children }
}
