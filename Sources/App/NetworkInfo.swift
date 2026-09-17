// NetworkInfo.swift - rozpoznawanie rodzaju połączenia (Wi-Fi, Ethernet, Bluetooth PAN, hotspot, VPN…)
// oraz szczegóły Wi-Fi z CoreWLAN
import AppKit
import Foundation
import IOKit
import SystemConfiguration
import CoreWLAN
import CoreLocation

/// Rodzaj interfejsu sieciowego wraz z nazwą widoczną w Ustawieniach systemowych
struct InterfaceKind {
    let bsd: String
    let display: String     // np. „Wi-Fi”, „iPhone USB”, „Thunderbolt Bridge”
    let type: String        // np. „Wi-Fi”, „Ethernet”, „Bluetooth PAN”
    let icon: String
}

/// Stan połączenia Wi-Fi
struct WiFiStatus {
    var interface = ""
    var ssid: String?
    var bssid: String?
    var rssi = 0
    var noise = 0
    var txRateMbps: Double = 0
    var phyMode = ""
    var channel = 0
    var band = ""
    var security = ""
    var isHotspot = false
    var powerOn = true
    /// Jakość sygnału 0..1 z RSSI (-100 dBm = 0, -40 dBm = 1)
    var quality: Double { max(0, min(1, (Double(rssi) + 100) / 60)) }
}

/// Zgoda na lokalizację jest wymagana przez macOS, żeby aplikacja mogła odczytać nazwę sieci Wi-Fi
final class LocationAccess: NSObject, CLLocationManagerDelegate {
    static let shared = LocationAccess()
    private let manager = CLLocationManager()
    var onChange: (() -> Void)?

    override init() {
        super.init()
        manager.delegate = self
    }

    var status: CLAuthorizationStatus { manager.authorizationStatus }
    var granted: Bool { status == .authorizedAlways || status == .authorized }

    /// Pyta o zgodę; gdy użytkownik wcześniej odmówił, otwiera odpowiedni panel Ustawień systemowych
    func request() {
        switch status {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .denied, .restricted:
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices") {
                NSWorkspace.shared.open(url)
            }
        default:
            onChange?()
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        DispatchQueue.main.async { [weak self] in self?.onChange?() }
    }
}

/// Konfiguracja IP interfejsu czytana z SCDynamicStore
struct IPConfig {
    var router: String?
    var dns: [String] = []
    var searchDomains: [String] = []
    var dhcpServer: String?
    var leaseHours: Double?
    var isPrimary = false
    var serviceName: String?
}

/// Usługa VPN skonfigurowana w systemie
struct VPNService {
    let id: String
    let name: String
    let kind: String        // np. „WireGuard”, „DrayTek SmartVPN”, „IKEv2”
    let connected: Bool
    var interfaceName: String?
}

enum NetInfo {
    private static var vpnCache: [VPNService] = []
    private static var vpnAt = Date.distantPast
    private static var vpnPending = false

    /// Usługi VPN z `scutil --nc list`; odczyt idzie w tle, bo uruchamia proces
    static func vpnServices() -> [VPNService] {
        if !vpnPending, Date().timeIntervalSince(vpnAt) > 5 {
            vpnPending = true
            DispatchQueue.global(qos: .utility).async {
                let out = Shell.run("/usr/sbin/scutil", ["--nc", "list"], timeout: 6)
                var list: [VPNService] = []
                for line in out.split(separator: "\n").dropFirst() {
                    let l = String(line)
                    guard let statusRange = l.range(of: "("), let statusEnd = l.range(of: ")") else { continue }
                    let status = String(l[statusRange.upperBound..<statusEnd.lowerBound]).trimmingCharacters(in: .whitespaces)
                    let rest = String(l[statusEnd.upperBound...]).trimmingCharacters(in: .whitespaces)
                    let parts = rest.split(separator: " ", maxSplits: 1).map(String.init)
                    guard let id = parts.first else { continue }
                    let name = l.components(separatedBy: "\"").count > 1 ? l.components(separatedBy: "\"")[1] : id
                    var kind = "VPN"
                    if l.contains("com.wireguard") { kind = "WireGuard" }
                    else if l.contains("SmartVPN") { kind = "DrayTek SmartVPN" }
                    else if l.contains("IPSec") { kind = "IPsec" }
                    else if l.contains("PPP") { kind = "PPP/L2TP" }
                    var svc = VPNService(id: id, name: name, kind: kind, connected: status == "Connected", interfaceName: nil)
                    if svc.connected { svc.interfaceName = interfaceOfService(id) }
                    list.append(svc)
                }
                DispatchQueue.main.async {
                    vpnCache = list
                    vpnAt = Date()
                    vpnPending = false
                }
            }
        }
        return vpnCache
    }

    /// Interfejs przypisany do usługi (np. utun4) czytany z SCDynamicStore
    private static func interfaceOfService(_ id: String) -> String? {
        guard let store = SCDynamicStoreCreate(nil, "online.equishow.vitals" as CFString, nil, nil) else { return nil }
        for proto in ["IPv4", "IPv6"] {
            let key = "State:/Network/Service/\(id)/\(proto)" as CFString
            if let d = SCDynamicStoreCopyValue(store, key) as? [String: Any],
               let name = d["InterfaceName"] as? String { return name }
        }
        return nil
    }

    /// Usługa VPN korzystająca z danego interfejsu.
    /// Tunele oparte na NetworkExtension (np. Cloudflare WARP, Tailscale) nie pojawiają się
    /// w `scutil --nc list`, więc dodatkowo przeszukujemy SCDynamicStore i uruchomione procesy.
    static func vpn(for bsd: String) -> VPNService? {
        // tylko interfejsy tunelowe – zwykłe karty mają własne usługi w konfiguracji i nie są VPN-em
        let tunnel = bsd.hasPrefix("utun") || bsd.hasPrefix("ipsec") || bsd.hasPrefix("ppp") || bsd.hasPrefix("tap")
        guard tunnel else { return nil }
        if let s = vpnServices().first(where: { $0.interfaceName == bsd && $0.connected }) { return s }
        if let s = serviceFromStore(bsd) { return s }
        if let app = runningVPNApp() {
            return VPNService(id: bsd, name: app, kind: "NetworkExtension", connected: true, interfaceName: bsd)
        }
        return nil
    }

    /// Szuka w SCDynamicStore usługi przypisanej do interfejsu i jej nazwy użytkownika
    private static func serviceFromStore(_ bsd: String) -> VPNService? {
        guard let store = SCDynamicStoreCreate(nil, "online.equishow.vitals.vpn" as CFString, nil, nil),
              let keys = SCDynamicStoreCopyKeyList(store, "State:/Network/Service/.*/IPv[46]" as CFString) as? [String]
        else { return nil }
        for key in keys {
            guard let v = SCDynamicStoreCopyValue(store, key as CFString) as? [String: Any],
                  (v["InterfaceName"] as? String) == bsd else { continue }
            let parts = key.split(separator: "/")
            guard parts.count >= 4 else { continue }
            let id = String(parts[2])
            var name = id
            if let setup = SCDynamicStoreCopyValue(store, "Setup:/Network/Service/\(id)" as CFString) as? [String: Any],
               let n = setup["UserDefinedName"] as? String, n != "Service" { name = n }
            else if let n = vpnServices().first(where: { $0.id == id })?.name { name = n }
            else if let app = runningVPNApp() { name = app }
            return VPNService(id: id, name: name, kind: L("Tunel systemowy"), connected: true, interfaceName: bsd)
        }
        return nil
    }

    /// Znane klienty VPN rozpoznawane po nazwie procesu
    private static let vpnApps: [(match: String, name: String)] = [
        ("CloudflareWARP", "Cloudflare WARP"), ("warp-svc", "Cloudflare WARP"),
        ("Tailscale", "Tailscale"), ("tailscaled", "Tailscale"),
        ("WireGuard", "WireGuard"), ("wg-quick", "WireGuard"),
        ("openvpn", "OpenVPN"), ("Mullvad", "Mullvad"), ("mullvad-daemon", "Mullvad"),
        ("NordVPN", "NordVPN"), ("ProtonVPN", "Proton VPN"), ("Surfshark", "Surfshark"),
        ("ExpressVPN", "ExpressVPN"), ("ZeroTier", "ZeroTier"), ("Cisco Secure Client", "Cisco Secure Client"),
        ("vpnagentd", "Cisco Secure Client"), ("GlobalProtect", "GlobalProtect"), ("SmartVPN", "DrayTek SmartVPN"),
    ]

    private static func runningVPNApp() -> String? {
        let names = Monitor.shared.latest.processes.map(\.name)
        for app in vpnApps where names.contains(where: { $0.localizedCaseInsensitiveContains(app.match) }) {
            return app.name
        }
        return nil
    }

    private static var dhcpCache: [String: (server: String?, leaseHours: Double?)] = [:]
    private static var dhcpAt: [String: Date] = [:]
    private static var dhcpPending = Set<String>()

    /// Dane DHCP z `ipconfig` (czytane w tle, odświeżane co minutę)
    private static func dhcp(for bsd: String) -> (server: String?, leaseHours: Double?)? {
        let fresh = dhcpAt[bsd].map { Date().timeIntervalSince($0) < 60 } ?? false
        if !fresh, !dhcpPending.contains(bsd) {
            dhcpPending.insert(bsd)
            DispatchQueue.global(qos: .utility).async {
                let server = Shell.run("/usr/sbin/ipconfig", ["getoption", bsd, "server_identifier"], timeout: 5)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let lease = Shell.run("/usr/sbin/ipconfig", ["getoption", bsd, "lease_time"], timeout: 5)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                DispatchQueue.main.async {
                    dhcpPending.remove(bsd)
                    dhcpAt[bsd] = Date()
                    dhcpCache[bsd] = (server.isEmpty || server == "0.0.0.0" ? nil : server,
                                      Double(lease).map { $0 / 3600 })
                }
            }
        }
        return dhcpCache[bsd]
    }

    /// Router, DNS, domeny i dzierżawa DHCP dla wskazanego interfejsu
    static func ipConfig(for bsd: String) -> IPConfig {
        var cfg = IPConfig()
        guard let store = SCDynamicStoreCreate(nil, "online.equishow.vitals.ip" as CFString, nil, nil) else { return cfg }
        if let global = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString) as? [String: Any] {
            cfg.isPrimary = (global["PrimaryInterface"] as? String) == bsd
            if cfg.isPrimary { cfg.router = global["Router"] as? String }
        }
        // router przypisany do konkretnego interfejsu (gdy nie jest podstawowy)
        if cfg.router == nil,
           let v4 = SCDynamicStoreCopyValue(store, "State:/Network/Interface/\(bsd)/IPv4" as CFString) as? [String: Any] {
            cfg.router = v4["Router"] as? String
        }
        if let dns = SCDynamicStoreCopyValue(store, "State:/Network/Global/DNS" as CFString) as? [String: Any], cfg.isPrimary {
            cfg.dns = dns["ServerAddresses"] as? [String] ?? []
            cfg.searchDomains = dns["SearchDomains"] as? [String] ?? []
        }
        if let d = dhcp(for: bsd) {
            cfg.dhcpServer = d.server
            cfg.leaseHours = d.leaseHours
        }
        return cfg
    }

    private static var kindCache: [String: InterfaceKind] = [:]
    private static var kindsAt = Date.distantPast

    /// Mapa interfejsów BSD → rodzaj; lista zmienia się rzadko, więc jest cache'owana
    static func kinds() -> [String: InterfaceKind] {
        if Date().timeIntervalSince(kindsAt) < 20, !kindCache.isEmpty { return kindCache }
        kindsAt = Date()
        var out: [String: InterfaceKind] = [:]
        for i in SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] ?? [] {
            guard let bsd = SCNetworkInterfaceGetBSDName(i) as String? else { continue }
            let display = SCNetworkInterfaceGetLocalizedDisplayName(i) as String? ?? bsd
            let raw = SCNetworkInterfaceGetInterfaceType(i) as String? ?? ""
            out[bsd] = InterfaceKind(bsd: bsd, display: display, type: friendly(raw, display: display), icon: icon(raw, display: display))
        }
        // interfejsy bez wpisu w SystemConfiguration (awdl, utun, loopback)
        for extra in ["lo0": "Pętla zwrotna", "awdl0": "AirDrop / AWDL", "llw0": "Low Latency WLAN"] where out[extra.key] == nil {
            out[extra.key] = InterfaceKind(bsd: extra.key, display: extra.value, type: extra.value, icon: "point.3.connected.trianglepath.dotted")
        }
        kindCache = out
        return out
    }

    /// Rodzaj pojedynczego interfejsu (z rozpoznaniem tuneli i udostępniania)
    static func kind(for bsd: String) -> InterfaceKind {
        if let k = kinds()[bsd] { return k }
        if bsd.hasPrefix("utun") || bsd.hasPrefix("ipsec") || bsd.hasPrefix("ppp") {
            return InterfaceKind(bsd: bsd, display: "Tunel VPN", type: "VPN", icon: "lock.shield")
        }
        if bsd.hasPrefix("bridge") { return InterfaceKind(bsd: bsd, display: "Mostek", type: "Mostek", icon: "arrow.triangle.branch") }
        if bsd.hasPrefix("anpi") || bsd.hasPrefix("ap") { return InterfaceKind(bsd: bsd, display: bsd, type: L("Wewnętrzny"), icon: "cable.connector") }
        if bsd.hasPrefix("lo") { return InterfaceKind(bsd: bsd, display: L("Pętla zwrotna"), type: L("Pętla zwrotna"), icon: "arrow.uturn.left") }
        return InterfaceKind(bsd: bsd, display: bsd, type: L("Nieznany"), icon: "network")
    }

    private static func friendly(_ raw: String, display: String) -> String {
        let d = display.lowercased()
        if d.contains("iphone") || d.contains("ipad") { return "Hotspot (USB)" }
        switch raw {
        case "IEEE80211": return "Wi-Fi"
        case "Ethernet": return d.contains("thunderbolt") ? "Thunderbolt" : (d.contains("bluetooth") ? "Bluetooth PAN" : "Ethernet")
        case "Bluetooth", "Bluetooth PAN": return "Bluetooth PAN"
        case "Bridge": return "Mostek"
        case "PPP", "PPPoE": return "PPP"
        case "IPSec", "VPN", "L2TP": return "VPN"
        case "Modem", "WWAN": return "Modem"
        default: return raw.isEmpty ? L("Nieznany") : raw
        }
    }

    private static func icon(_ raw: String, display: String) -> String {
        let d = display.lowercased()
        if d.contains("iphone") || d.contains("ipad") { return "iphone.gen3.radiowaves.left.and.right" }
        if d.contains("bluetooth") { return "antenna.radiowaves.left.and.right" }
        switch raw {
        case "IEEE80211": return "wifi"
        case "Ethernet": return d.contains("thunderbolt") ? "bolt.horizontal" : "cable.connector"
        case "Bridge": return "arrow.triangle.branch"
        case "IPSec", "VPN", "L2TP", "PPP": return "lock.shield"
        default: return "network"
        }
    }

    /// Nazwa usługi sieciowej z konfiguracji systemu (to, co widać w Ustawieniach sieci)
    static func serviceName(for bsd: String) -> String? {
        guard let prefs = SCPreferencesCreate(nil, "online.equishow.vitals" as CFString, nil),
              let set = SCNetworkSetCopyCurrent(prefs),
              let services = SCNetworkSetCopyServices(set) as? [SCNetworkService] else { return nil }
        for svc in services {
            guard let itf = SCNetworkServiceGetInterface(svc),
                  SCNetworkInterfaceGetBSDName(itf) as String? == bsd else { continue }
            return SCNetworkServiceGetName(svc) as String?
        }
        return nil
    }

    /// Model sprzętu karty sieciowej z IORegistry (np. nazwa produktu adaptera USB)
    static func hardwareModel(for bsd: String) -> String? {
        if let cached = modelCache[bsd] { return cached }
        var result: String? = nil
        let match = IOServiceMatching("IOEthernetInterface") as NSMutableDictionary
        match[kIOPropertyMatchKey] = ["BSD Name": bsd] as NSDictionary
        var it: io_iterator_t = 0
        if IOServiceGetMatchingServices(kIOMainPortDefault, match, &it) == KERN_SUCCESS {
            var svc = IOIteratorNext(it)
            while svc != 0 {
                var parent: io_object_t = 0
                if IORegistryEntryGetParentEntry(svc, kIOServicePlane, &parent) == KERN_SUCCESS {
                    for key in ["USB Product Name", "IOModel", "model", "IOName"] {
                        if let v = IORegistryEntrySearchCFProperty(parent, kIOServicePlane, key as CFString, kCFAllocatorDefault,
                                                                  IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents)) {
                            if let str = v as? String { result = str; break }
                            if let data = v as? Data, let str = String(data: data, encoding: .utf8) {
                                result = str.trimmingCharacters(in: CharacterSet(charactersIn: "\0")); break
                            }
                        }
                    }
                    IOObjectRelease(parent)
                }
                IOObjectRelease(svc)
                if result != nil { break }
                svc = IOIteratorNext(it)
            }
            IOObjectRelease(it)
        }
        modelCache[bsd] = result
        return result
    }

    private static var modelCache: [String: String?] = [:]

    /// Bieżący stan Wi-Fi; nazwa sieci bywa niedostępna bez zgody na lokalizację
    static func wifi() -> WiFiStatus? {
        guard let itf = CWWiFiClient.shared().interface() else { return nil }
        var w = WiFiStatus()
        w.interface = itf.interfaceName ?? "en0"
        w.powerOn = itf.powerOn()
        guard w.powerOn else { return w }
        w.ssid = itf.ssid()
        w.bssid = itf.bssid()
        w.rssi = itf.rssiValue()
        w.noise = itf.noiseMeasurement()
        w.txRateMbps = itf.transmitRate()
        w.isHotspot = itf.interfaceMode() == .hostAP
        switch itf.activePHYMode() {
        case .mode11a: w.phyMode = "802.11a"
        case .mode11b: w.phyMode = "802.11b"
        case .mode11g: w.phyMode = "802.11g"
        case .mode11n: w.phyMode = "802.11n"
        case .mode11ac: w.phyMode = "802.11ac"
        case .mode11ax: w.phyMode = "802.11ax (Wi-Fi 6/6E)"
        default: w.phyMode = "—"
        }
        if let ch = itf.wlanChannel() {
            w.channel = ch.channelNumber
            switch ch.channelBand {
            case .band2GHz: w.band = "2,4 GHz"
            case .band5GHz: w.band = "5 GHz"
            case .band6GHz: w.band = "6 GHz"
            default: w.band = "—"
            }
        }
        switch itf.security() {
        case .none: w.security = "Otwarta"
        case .wpaPersonal, .wpaPersonalMixed: w.security = "WPA"
        case .wpa2Personal: w.security = "WPA2"
        case .wpa3Personal: w.security = "WPA3"
        case .wpa3Transition: w.security = "WPA2/WPA3"
        case .wpa3Enterprise: w.security = "WPA3 Enterprise"
        case .wpaEnterprise, .wpa2Enterprise, .wpaEnterpriseMixed: w.security = "Enterprise"
        case .unknown: w.security = "—"
        default: w.security = "WEP / inne"
        }
        return w
    }
}
