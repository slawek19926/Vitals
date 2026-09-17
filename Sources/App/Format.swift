// Format.swift - formatowanie wartości do wyświetlenia
import Foundation

enum Fmt {
    static func bytes(_ b: Double, precision: Int = 1) -> String {
        let units = ["B", "KB", "MB", "GB", "TB", "PB"]
        var v = b, i = 0
        while v >= 1000, i < units.count - 1 { v /= 1024; i += 1 }
        return (i == 0 ? String(format: "%.0f", v) : String(format: "%.\(precision)f", v)) + " " + units[i]
    }
    static func bytes(_ b: UInt64, precision: Int = 1) -> String { bytes(Double(b), precision: precision) }
    static func rate(_ bps: Double) -> String { bytes(bps) + "/s" }
    static func percent(_ p: Double, precision: Int = 1) -> String { String(format: "%.\(precision)f%%", p) }

    static func duration(_ seconds: Double) -> String {
        var s = Int(seconds)
        let d = s / 86400; s %= 86400
        let h = s / 3600; s %= 3600
        let m = s / 60; s %= 60
        return d > 0 ? String(format: "%d d %02d:%02d:%02d", d, h, m, s) : String(format: "%02d:%02d:%02d", h, m, s)
    }

    static func cpuTime(_ ns: UInt64) -> String {
        var s = Double(ns) / 1e9
        let h = Int(s / 3600); s -= Double(h) * 3600
        let m = Int(s / 60); s -= Double(m) * 60
        return h > 0 ? String(format: "%d:%02d:%05.2f", h, m, s) : String(format: "%d:%05.2f", m, s)
    }

    static let dateTime: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm:ss"; return f
    }()
    static let time: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f
    }()

    static func temp(_ c: Double, precision: Int = 1) -> String {
        Prefs.shared.fahrenheit ? String(format: "%.\(precision)f °F", c * 9 / 5 + 32) : String(format: "%.\(precision)f °C", c)
    }
    static func watts(_ w: Double, precision: Int = 1) -> String { String(format: "%.\(precision)f W", w) }

    /// Częstotliwość z automatycznie dobraną jednostką: Hz → kHz → MHz → GHz
    static func frequency(_ hz: Double) -> String {
        let a = abs(hz)
        if a >= 1e9 { return String(format: "%.2f GHz", hz / 1e9) }
        if a >= 1e6 { return String(format: a >= 1e8 ? "%.0f MHz" : "%.1f MHz", hz / 1e6) }
        if a >= 1e3 { return String(format: "%.1f kHz", hz / 1e3) }
        return String(format: "%.0f Hz", hz)
    }
    /// Wygodny wariant dla wartości podanych w megahercach
    static func frequencyMHz(_ mhz: Double) -> String { frequency(mhz * 1e6) }
    static func number(_ n: UInt64) -> String {
        let f = NumberFormatter(); f.numberStyle = .decimal; f.groupingSeparator = " "; return f.string(from: NSNumber(value: n)) ?? "\(n)"
    }

    static func minutes(_ min: Int) -> String {
        min < 0 ? "obliczanie…" : String(format: "%d h %02d min", min / 60, min % 60)
    }
}
