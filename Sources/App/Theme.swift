// Theme.swift - kolorystyka w stylu TMOG: motyw aplikacji (jasny/ciemny), tryb wyświetlacza (kolor/fosfor),
// nasycenie całej palety, siła poświaty (bloom) i rozszerzony zakres dynamiki (HDR).
import AppKit

/// Motyw okna: podąża za systemem albo wymusza jasny/ciemny
enum AppTheme: Int, CaseIterable {
    case system, light, dark
    var title: String { L(["Ustawienia systemowe", "Jasny", "Ciemny"][rawValue]) }
}

/// Tryb wyświetlacza: pełny kolor albo monochromatyczny fosfor (jak monitory CRT)
enum DisplayMode: Int, CaseIterable {
    case color, mono, green, amber, blue
    var title: String { L(["Kolor", "Mono", "Zielony", "Bursztynowy", "Niebieski"][rawValue]) }
    /// Barwa fosforu; nil dla trybu kolorowego
    var hue: NSColor? {
        switch self {
        case .color: return nil
        case .mono: return NSColor(white: 0.88, alpha: 1)
        case .green: return NSColor(srgbRed: 0.43, green: 1.0, blue: 0.39, alpha: 1)
        case .amber: return NSColor(srgbRed: 1.0, green: 0.69, blue: 0.12, alpha: 1)
        case .blue: return NSColor(srgbRed: 0.35, green: 0.69, blue: 1.0, alpha: 1)
        }
    }
}

/// Kolor napisów na wyświetlaczach segmentowych (nagłówki VFD w Podsumowaniu)
enum VFDText: Int, CaseIterable {
    case automatic, cyan, green, amber, white, magenta
    var title: String { L(["Automatyczny", "Cyjan", "Zielony", "Bursztynowy", "Biały", "Magenta"][rawValue]) }
    var color: NSColor? {
        switch self {
        case .automatic: return nil
        case .cyan: return NSColor(srgbRed: 0.35, green: 0.95, blue: 1.0, alpha: 1)
        case .green: return NSColor(srgbRed: 0.45, green: 1.0, blue: 0.45, alpha: 1)
        case .amber: return NSColor(srgbRed: 1.0, green: 0.72, blue: 0.20, alpha: 1)
        case .white: return NSColor(white: 0.96, alpha: 1)
        case .magenta: return NSColor(srgbRed: 1.0, green: 0.45, blue: 0.85, alpha: 1)
        }
    }
}

enum Subsystem { case cpu, memory, gpu, npu, disk, network, energy, thermal }

struct Palette {
    var isDark: Bool
    var isPhosphor: Bool
    var windowBg, sidebarBg, panelBg, graphBg, border, text, textDim, selection, hover: NSColor
    var cpu, cpuKernel, memory, gpu, disk, network, energy, good, warn, bad: NSColor
    /// Współczynnik nasycenia zastosowany do palety (1 = neutralny)
    var satFactor: CGFloat = 1

    /// Kolor wartości liczbowych przy paskach LED (cyjan jak w TMOG)
    var valueColor: NSColor {
        if let forced = ThemeManager.shared.vfdText.color { return forced.saturated(satFactor) }
        if isPhosphor { return text }
        if Prefs.shared.modernUI { return text }
        return (isDark ? NSColor(srgbRed: 0.35, green: 0.95, blue: 1, alpha: 1) : NSColor(srgbRed: 0, green: 0.55, blue: 0.7, alpha: 1)).saturated(satFactor)
    }
    var npu: NSColor { isPhosphor ? energy : NSColor(srgbRed: 1.0, green: 0.62, blue: 0.16, alpha: 1).saturated(satFactor) }
    var thermal: NSColor { isPhosphor ? energy : NSColor(srgbRed: 1.0, green: 0.45, blue: 0.30, alpha: 1).saturated(satFactor) }

    func accent(_ s: Subsystem) -> NSColor {
        switch s {
        case .cpu: return cpu
        case .memory: return memory
        case .gpu: return gpu
        case .disk: return disk
        case .network: return network
        case .energy: return energy
        case .npu: return npu
        case .thermal: return thermal
        }
    }

    /// Kopia palety z przeskalowanym nasyceniem wszystkich barw
    func saturated(_ f: CGFloat) -> Palette {
        guard abs(f - 1) > 0.001 else { var p = self; p.satFactor = 1; return p }
        var p = self
        p.satFactor = f
        p.windowBg = windowBg.saturated(f); p.sidebarBg = sidebarBg.saturated(f); p.panelBg = panelBg.saturated(f)
        p.graphBg = graphBg.saturated(f); p.border = border.saturated(f); p.text = text.saturated(f)
        p.textDim = textDim.saturated(f); p.selection = selection.saturated(f); p.hover = hover.saturated(f)
        p.cpu = cpu.saturated(f); p.cpuKernel = cpuKernel.saturated(f); p.memory = memory.saturated(f)
        p.gpu = gpu.saturated(f); p.disk = disk.saturated(f); p.network = network.saturated(f)
        p.energy = energy.saturated(f); p.good = good.saturated(f); p.warn = warn.saturated(f); p.bad = bad.saturated(f)
        return p
    }

    static let dark = Palette(
        isDark: true, isPhosphor: false,
        windowBg: NSColor(srgbRed: 0.094, green: 0.094, blue: 0.106, alpha: 1),
        sidebarBg: NSColor(srgbRed: 0.118, green: 0.118, blue: 0.133, alpha: 1),
        panelBg: NSColor(srgbRed: 0.129, green: 0.129, blue: 0.149, alpha: 1),
        graphBg: NSColor(srgbRed: 0.078, green: 0.078, blue: 0.090, alpha: 1),
        border: NSColor(srgbRed: 0.243, green: 0.243, blue: 0.275, alpha: 1),
        text: NSColor(srgbRed: 0.925, green: 0.925, blue: 0.941, alpha: 1),
        textDim: NSColor(srgbRed: 0.588, green: 0.588, blue: 0.635, alpha: 1),
        selection: NSColor(srgbRed: 0.188, green: 0.259, blue: 0.463, alpha: 1),
        hover: NSColor(white: 1, alpha: 0.06),
        cpu: NSColor(srgbRed: 0.573, green: 0.902, blue: 0.290, alpha: 1),
        cpuKernel: NSColor(srgbRed: 1.0, green: 0.361, blue: 0.282, alpha: 1),
        memory: NSColor(srgbRed: 0.808, green: 0.345, blue: 0.980, alpha: 1),
        gpu: NSColor(srgbRed: 0.290, green: 0.588, blue: 1.0, alpha: 1),
        disk: NSColor(srgbRed: 0.275, green: 0.824, blue: 0.510, alpha: 1),
        network: NSColor(srgbRed: 0.259, green: 0.549, blue: 1.0, alpha: 1),
        energy: NSColor(srgbRed: 0.961, green: 0.784, blue: 0.235, alpha: 1),
        good: NSColor(srgbRed: 0.314, green: 0.824, blue: 0.392, alpha: 1),
        warn: NSColor(srgbRed: 0.961, green: 0.706, blue: 0.157, alpha: 1),
        bad: NSColor(srgbRed: 1.0, green: 0.314, blue: 0.275, alpha: 1))

    static let light = Palette(
        isDark: false, isPhosphor: false,
        windowBg: NSColor(srgbRed: 0.965, green: 0.965, blue: 0.973, alpha: 1),
        sidebarBg: NSColor(srgbRed: 0.925, green: 0.925, blue: 0.941, alpha: 1),
        panelBg: .white,
        graphBg: NSColor(srgbRed: 0.980, green: 0.980, blue: 0.988, alpha: 1),
        border: NSColor(srgbRed: 0.839, green: 0.839, blue: 0.871, alpha: 1),
        text: NSColor(srgbRed: 0.110, green: 0.110, blue: 0.125, alpha: 1),
        textDim: NSColor(srgbRed: 0.439, green: 0.439, blue: 0.486, alpha: 1),
        selection: NSColor(srgbRed: 0.816, green: 0.871, blue: 0.980, alpha: 1),
        hover: NSColor(black: 0.05),
        cpu: NSColor(srgbRed: 0.298, green: 0.686, blue: 0.157, alpha: 1),
        cpuKernel: NSColor(srgbRed: 0.902, green: 0.275, blue: 0.196, alpha: 1),
        memory: NSColor(srgbRed: 0.667, green: 0.235, blue: 0.863, alpha: 1),
        gpu: NSColor(srgbRed: 0.157, green: 0.431, blue: 0.902, alpha: 1),
        disk: NSColor(srgbRed: 0.157, green: 0.667, blue: 0.392, alpha: 1),
        network: NSColor(srgbRed: 0.118, green: 0.431, blue: 0.902, alpha: 1),
        energy: NSColor(srgbRed: 0.843, green: 0.647, blue: 0.078, alpha: 1),
        good: NSColor(srgbRed: 0.196, green: 0.667, blue: 0.314, alpha: 1),
        warn: NSColor(srgbRed: 0.863, green: 0.588, blue: 0.078, alpha: 1),
        bad: NSColor(srgbRed: 0.863, green: 0.196, blue: 0.157, alpha: 1))

    /// Monochromatyczna paleta fosforowa na ciemnym tle
    static func phosphor(_ hue: NSColor) -> Palette {
        let black = NSColor.black
        return Palette(
            isDark: true, isPhosphor: true,
            windowBg: .mix(black, hue, 0.05), sidebarBg: .mix(black, hue, 0.08), panelBg: .mix(black, hue, 0.09),
            graphBg: .mix(black, hue, 0.04), border: .mix(black, hue, 0.38), text: .mix(hue, .white, 0.35),
            textDim: .mix(black, hue, 0.62), selection: .mix(black, hue, 0.28), hover: hue.withAlphaComponent(0.1),
            cpu: hue, cpuKernel: .mix(hue, .white, 0.55), memory: hue, gpu: hue, disk: hue, network: hue, energy: hue,
            good: hue, warn: hue, bad: .mix(hue, .white, 0.7))
    }

    /// Jasne tło z monochromatycznymi akcentami (tryb fosforowy przy jasnym motywie)
    static func phosphorLight(_ hue: NSColor) -> Palette {
        var p = Palette.light
        p.isPhosphor = true
        let ink = NSColor.mix(hue, .black, 0.55)
        p.cpu = ink; p.cpuKernel = .mix(ink, .black, 0.35); p.memory = ink; p.gpu = ink
        p.disk = ink; p.network = ink; p.energy = ink; p.good = ink; p.warn = ink; p.bad = .mix(ink, .black, 0.3)
        return p
    }
}

extension NSColor {
    convenience init(black alpha: CGFloat) { self.init(white: 0, alpha: alpha) }

    static func mix(_ a: NSColor, _ b: NSColor, _ t: CGFloat) -> NSColor {
        let a = a.usingColorSpace(.sRGB)!, b = b.usingColorSpace(.sRGB)!
        return NSColor(srgbRed: a.redComponent + (b.redComponent - a.redComponent) * t,
                       green: a.greenComponent + (b.greenComponent - a.greenComponent) * t,
                       blue: a.blueComponent + (b.blueComponent - a.blueComponent) * t, alpha: 1)
    }

    func alpha(_ a: CGFloat) -> NSColor { withAlphaComponent(a) }

    /// Skaluje nasycenie (0 = odcienie szarości, 1 = bez zmian, >1 = wzmocnienie)
    func saturated(_ f: CGFloat) -> NSColor {
        guard abs(f - 1) > 0.001, let c = usingColorSpace(.sRGB) else { return self }
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        c.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        return NSColor(hue: h, saturation: min(1, s * f), brightness: b, alpha: a)
    }

    /// CGColor rozjaśniony poza zakres SDR — na ekranach z EDR daje realny „bloom”.
    /// Kolory są cache'owane: tworzenie CGColor w pętli rysowania kosztowało krocie
    /// (ColorSync sprawdzał profil przy każdym porównaniu kolorów).
    func edr(_ boost: CGFloat) -> CGColor {
        guard let c = usingColorSpace(.sRGB) else { return cgColor }
        return CGColorCache.shared.color(c.redComponent, c.greenComponent, c.blueComponent,
                                         c.alphaComponent, boost > 1.001 ? boost : 1)
    }

    /// CGColor z cache (bez EDR) — tańszy zamiennik `cgColor` w pętlach rysowania
    var cachedCG: CGColor { edr(1) }
}

/// Cache CGColor-ów kluczowany skwantowanymi składowymi; zwracanie tych samych instancji
/// sprawia, że CoreGraphics porównuje kolory wskaźnikiem zamiast przez ColorSync
final class CGColorCache {
    static let shared = CGColorCache()
    private var map: [UInt64: CGColor] = [:]
    private let sdr = CGColorSpaceCreateDeviceRGB()
    private let hdr = CGColorSpace(name: CGColorSpace.extendedSRGB)

    func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat, _ boost: CGFloat) -> CGColor {
        func q(_ v: CGFloat, _ scale: CGFloat) -> UInt64 { UInt64(max(0, min(1023, (v * scale).rounded()))) }
        let key = q(r, 255) | q(g, 255) << 10 | q(b, 255) << 20 | q(a, 255) << 30 | q(boost, 64) << 40
        if let c = map[key] { return c }
        let made: CGColor
        if boost > 1.001, let hdr {
            made = CGColor(colorSpace: hdr, components: [r * boost, g * boost, b * boost, a])
                ?? CGColor(colorSpace: sdr, components: [r, g, b, a])!
        } else {
            made = CGColor(colorSpace: sdr, components: [r, g, b, a])!
        }
        if map.count > 4096 { map.removeAll(keepingCapacity: true) }
        map[key] = made
        return made
    }
}

extension Notification.Name {
    static let themeChanged = Notification.Name("ThemeChanged")
    static let snapshotUpdated = Notification.Name("SnapshotUpdated")
    /// zmiana języka interfejsu – okno i menu są przebudowywane bez restartu
    static let languageChanged = Notification.Name("LanguageChanged")
}

final class ThemeManager {
    static let shared = ThemeManager()

    private let d = UserDefaults.standard
    private(set) var palette: Palette = .dark

    /// Suwaki mają 12 pozycji (0…11) jak w TMOG; 7 i 8 to wartości domyślne
    static let sliderMax = 11

    private(set) var appTheme: AppTheme = .system
    private(set) var display: DisplayMode = .color
    private(set) var vfdText: VFDText = .automatic
    private(set) var saturation: Int = 7
    private(set) var bloom: Int = 8
    private(set) var hdr: Bool = true

    private init() {
        // Migracja starego klucza „theme” (0 systemowy, 1 jasny, 2 ciemny, 3 zielony, 4 bursztyn, 5 niebieski, 6 mono)
        if d.object(forKey: "appTheme") == nil, let old = d.object(forKey: "theme") as? Int {
            let map: [(AppTheme, DisplayMode)] = [(.system, .color), (.light, .color), (.dark, .color),
                                                  (.dark, .green), (.dark, .amber), (.dark, .blue), (.dark, .mono)]
            let m = map[min(max(old, 0), map.count - 1)]
            d.set(m.0.rawValue, forKey: "appTheme"); d.set(m.1.rawValue, forKey: "displayMode")
        }
        appTheme = AppTheme(rawValue: d.object(forKey: "appTheme") as? Int ?? 0) ?? .system
        display = DisplayMode(rawValue: d.object(forKey: "displayMode") as? Int ?? 0) ?? .color
        vfdText = VFDText(rawValue: d.object(forKey: "vfdText") as? Int ?? 0) ?? .automatic
        saturation = d.object(forKey: "saturation") as? Int ?? 7
        bloom = d.object(forKey: "bloom") as? Int ?? 8
        hdr = d.object(forKey: "hdr") as? Bool ?? true
        resolve()
    }

    // MARK: ustawienia
    func setAppTheme(_ t: AppTheme) {
        appTheme = t
        d.set(t.rawValue, forKey: "appTheme")
        switch t {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
        refresh()
    }
    func setDisplay(_ m: DisplayMode) { display = m; d.set(m.rawValue, forKey: "displayMode"); refresh() }
    func setVFDText(_ v: VFDText) { vfdText = v; d.set(v.rawValue, forKey: "vfdText"); refresh() }
    func setSaturation(_ v: Int) { saturation = min(Self.sliderMax, max(0, v)); d.set(saturation, forKey: "saturation"); refresh() }
    func setBloom(_ v: Int) { bloom = min(Self.sliderMax, max(0, v)); d.set(bloom, forKey: "bloom"); refresh() }
    func setHDR(_ on: Bool) { hdr = on; d.set(on, forKey: "hdr"); refresh() }

    /// Mnożnik nasycenia: 0 → szarość, 7 → bez zmian, 11 → mocne wzmocnienie
    var saturationFactor: CGFloat {
        saturation <= 7 ? CGFloat(saturation) / 7.0 : 1 + CGFloat(saturation - 7) / 4.0 * 0.7
    }
    /// Siła poświaty: 0 → brak, 8 → domyślna, 11 → maksymalna
    var bloomFactor: CGFloat { CGFloat(bloom) / 8.0 }
    /// Czy ekran obsługuje rozszerzony zakres dynamiki
    var edrAvailable: Bool { (NSScreen.main?.maximumPotentialExtendedDynamicRangeColorComponentValue ?? 1) > 1.05 }
    var edrHeadroom: CGFloat { NSScreen.main?.maximumPotentialExtendedDynamicRangeColorComponentValue ?? 1 }
    /// Mnożnik jasności dla kolorów poświaty (1 = SDR)
    var edrBoost: CGFloat {
        guard hdr, edrAvailable, palette.isDark else { return 1 }
        let head = min(edrHeadroom, 2.0)
        return 1 + (head - 1) * (0.35 + 0.65 * bloomFactor)
    }

    func resolve() {
        let systemDark = NSApp?.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let dark = appTheme == .dark || (appTheme == .system && systemDark)
        var base: Palette
        if let hue = display.hue {
            base = dark ? .phosphor(hue) : .phosphorLight(hue)
        } else {
            base = dark ? .dark : .light
        }
        palette = base.saturated(saturationFactor)
    }

    private func refresh() {
        resolve()
        NotificationCenter.default.post(name: .themeChanged, object: nil)
    }

    func systemAppearanceChanged() {
        guard appTheme == .system else { return }
        let wasDark = palette.isDark
        resolve()
        // Powiadamiaj tylko przy faktycznej zmianie jasny/ciemny (inaczej pętla: nowe widoki → zmiana wyglądu → nowe widoki)
        if palette.isDark != wasDark { NotificationCenter.default.post(name: .themeChanged, object: nil) }
    }
}

var P: Palette { ThemeManager.shared.palette }

/// Wspólna skala „ciepła” dla wartości liczbowych: 0 = spokojnie (zielony), 1 = maksimum (czerwony).
enum HeatScale {
    static func color(_ level: Double) -> NSColor {
        let t = CGFloat(min(1, max(0, level)))
        let p = P
        // w trybie fosforowym nie ma barw — różnicujemy jasność
        if p.isPhosphor { return .mix(p.textDim, p.bad, t) }
        let orange = NSColor(srgbRed: 1.0, green: 0.55, blue: 0.15, alpha: 1).saturated(p.satFactor)
        if t < 0.5 { return .mix(p.good, p.warn, t * 2) }
        if t < 0.78 { return .mix(p.warn, orange, (t - 0.5) / 0.28) }
        return .mix(orange, p.bad, (t - 0.78) / 0.22)
    }
}

/// Kolorowanie temperatur według progów typowych dla Apple Silicon.
enum ThermalScale {
    /// (spoczynek, ostrzeżenie, próg krytyczny) w °C dla danej klasy czujnika
    static func limits(for key: String) -> (cool: Double, warn: Double, hot: Double) {
        if key.hasPrefix("TB") { return (25, 38, 50) }                        // bateria
        if key.hasPrefix("TH") { return (30, 60, 85) }                        // SSD
        if key.hasPrefix("Tg") { return (35, 80, 100) }                       // GPU
        if key.hasPrefix("Tp") || key.hasPrefix("Te") { return (35, 85, 105) } // rdzenie CPU (throttling ~100 °C)
        if key.hasPrefix("TA") || key.hasPrefix("Ta") { return (20, 40, 55) }  // otoczenie
        if key.hasPrefix("TW") { return (30, 65, 85) }                        // moduł bezprzewodowy
        if key.hasPrefix("Tm") || key.hasPrefix("TM") { return (30, 70, 90) }  // pamięć
        return (30, 75, 95)                                                   // pozostałe czujniki SoC
    }

    /// Udział w zakresie 0…1; próg ostrzegawczy wypada dokładnie w połowie skali
    static func level(_ celsius: Double, key: String) -> Double {
        let l = limits(for: key)
        if celsius <= l.warn { return max(0, 0.5 * (celsius - l.cool) / max(1, l.warn - l.cool)) }
        return min(1, 0.5 + 0.5 * (celsius - l.warn) / max(1, l.hot - l.warn))
    }

    static func color(_ celsius: Double, key: String) -> NSColor { HeatScale.color(level(celsius, key: key)) }
}

enum Fonts {
    static func title(_ size: CGFloat) -> NSFont {
        if Prefs.shared.modernUI { return NSFont.systemFont(ofSize: size, weight: .bold) }
        if Prefs.shared.systemTitleFont { return NSFont.systemFont(ofSize: size, weight: .light) }
        return NSFont(name: "AvenirNext-UltraLight", size: size) ?? NSFont.systemFont(ofSize: size, weight: .ultraLight)
    }
    static func mono(_ size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight)
    }
    static func ui(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> NSFont {
        NSFont.systemFont(ofSize: size, weight: weight)
    }
    /// Nagłówki kart: w nowoczesnym stylu zwykły SF półgruby, w klasycznym monospace jak na wyświetlaczu
    static func display(_ size: CGFloat) -> NSFont {
        if Prefs.shared.modernUI { return NSFont.systemFont(ofSize: size, weight: .semibold) }
        return NSFont(name: "Menlo-Bold", size: size) ?? NSFont.monospacedSystemFont(ofSize: size, weight: .bold)
    }
}
