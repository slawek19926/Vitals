// DiskDetails.swift - szczegóły i SMART dysków czytane z `diskutil info -plist` (bez roota),
// odświeżane rzadko i trzymane w pamięci, bo to uruchomienie procesu
import Foundation

/// Szczegóły pojedynczego dysku wraz z atrybutami SMART (NVMe wystawia je przez diskutil)
struct DiskDetail {
    var smartStatus = ""
    var busProtocol = ""
    var mediaName = ""
    var content = ""
    var volumeName = ""
    var blockSize = 0
    var solidState: Bool? = nil
    var ejectable = false
    var virtualOrPhysical = ""
    var smart: [String: Int] = [:]

    var hasSMART: Bool { !smart.isEmpty }

    /// Temperatura kontrolera w °C (SMART podaje kelwiny)
    var temperatureC: Double? {
        guard let k = smart["TEMPERATURE"], k > 100 else { return nil }
        return Double(k) - 273.15
    }
    var powerOnHours: Int? { smart["POWER_ON_HOURS_0"] }
    var powerCycles: Int? { smart["POWER_CYCLES_0"] }
    var percentageUsed: Int? { smart["PERCENTAGE_USED"] }
    var availableSpare: Int? { smart["AVAILABLE_SPARE"] }
    var unsafeShutdowns: Int? { smart["UNSAFE_SHUTDOWNS_0"] }
    var mediaErrors: Int? { smart["MEDIA_ERRORS_0"] }
    /// NVMe liczy w jednostkach 512 000 bajtów
    var dataRead: UInt64? { smart["DATA_UNITS_READ_0"].map { UInt64($0) * 512_000 } }
    var dataWritten: UInt64? { smart["DATA_UNITS_WRITTEN_0"].map { UInt64($0) * 512_000 } }
}

/// Cache szczegółów dysków; odczyt idzie w tle, a wynik trafia do słownika po nazwie BSD
final class DiskDetails {
    static let shared = DiskDetails()
    private var cache: [String: DiskDetail] = [:]
    private var pending = Set<String>()
    private var fetchedAt: [String: Date] = [:]
    private let ttl: TimeInterval = 60

    /// Zwraca znane szczegóły i w razie potrzeby zleca odświeżenie w tle
    func detail(for bsd: String) -> DiskDetail? {
        guard !bsd.isEmpty else { return nil }
        let fresh = fetchedAt[bsd].map { Date().timeIntervalSince($0) < ttl } ?? false
        if !fresh, !pending.contains(bsd) {
            pending.insert(bsd)
            DispatchQueue.global(qos: .utility).async { [weak self] in
                let d = Self.load(bsd)
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.pending.remove(bsd)
                    self.fetchedAt[bsd] = Date()
                    if let d { self.cache[bsd] = d }
                }
            }
        }
        return cache[bsd]
    }

    private static func load(_ bsd: String) -> DiskDetail? {
        let out = Shell.run("/usr/sbin/diskutil", ["info", "-plist", bsd], timeout: 8)
        guard let data = out.data(using: .utf8),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return nil }
        var d = DiskDetail()
        d.smartStatus = plist["SMARTStatus"] as? String ?? ""
        d.busProtocol = plist["BusProtocol"] as? String ?? ""
        d.mediaName = plist["MediaName"] as? String ?? ""
        d.content = plist["Content"] as? String ?? ""
        d.volumeName = plist["VolumeName"] as? String ?? ""
        d.blockSize = plist["DeviceBlockSize"] as? Int ?? 0
        d.solidState = plist["SolidState"] as? Bool
        d.ejectable = plist["Ejectable"] as? Bool ?? false
        d.virtualOrPhysical = plist["VirtualOrPhysical"] as? String ?? ""
        if let s = plist["SMARTDeviceSpecificKeysMayVaryNotGuaranteed"] as? [String: Any] {
            for (k, v) in s { if let n = v as? Int { d.smart[k] = n } }
        }
        return d
    }
}
