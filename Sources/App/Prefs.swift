// Prefs.swift - ustawienia aplikacji (UserDefaults) + powiadomienie o zmianie
import AppKit
import Foundation

extension Notification.Name { static let prefsChanged = Notification.Name("PrefsChanged") }

final class Prefs {
    static let shared = Prefs()
    private let d = UserDefaults.standard
    private init() {
        migrateFromOldBundleIfNeeded()
        removeUnusedKeys()
    }

    /// Kasuje ustawienia, które przestały być używane, i przenosi to, co da się przenieść
    private func removeUnusedKeys() {
        // układ kafelków Podsumowania – funkcja usunięta
        for key in ["summaryTileOrder", "summaryTileSpans", "summaryTileHeights", "summaryHiddenTiles"]
        where d.object(forKey: key) != nil {
            d.removeObject(forKey: key)
        }
        // ramka okna: stary zapis AppKit zastąpiony własnym kluczem
        let legacyFrame = "NSWindow Frame MainWindow"
        if let old = d.string(forKey: legacyFrame) {
            if d.string(forKey: "windowFrame") == nil {
                let parts = old.split(separator: " ").compactMap { Double($0) }
                if parts.count >= 4 {
                    let rect = NSRect(x: parts[0], y: parts[1], width: parts[2], height: parts[3])
                    d.set(NSStringFromRect(rect), forKey: "windowFrame")
                }
            }
            d.removeObject(forKey: legacyFrame)
        }
        // stary klucz motywu jest już przeniesiony do appTheme
        if d.object(forKey: "appTheme") != nil, d.object(forKey: "theme") != nil {
            d.removeObject(forKey: "theme")
        }
    }

    /// Jednorazowe przeniesienie ustawień ze starego identyfikatora pakietu (pl.kimla.taskmanager)
    private func migrateFromOldBundleIfNeeded() {
        guard !d.bool(forKey: "migratedFromKimla") else { return }
        d.set(true, forKey: "migratedFromKimla")
        let oldPath = NSHomeDirectory() + "/Library/Preferences/pl.kimla.taskmanager.plist"
        guard let old = NSDictionary(contentsOfFile: oldPath) as? [String: Any], !old.isEmpty else { return }
        for (key, value) in old where d.object(forKey: key) == nil {
            d.set(value, forKey: key)
        }
    }

    private func set<T>(_ key: String, _ v: T) { d.set(v, forKey: key); NotificationCenter.default.post(name: .prefsChanged, object: key) }

    /// Jednostka temperatury: 0 = °C, 1 = °F
    var fahrenheit: Bool { get { d.bool(forKey: "fahrenheit") } set { set("fahrenheit", newValue) } }
    /// Czcionka tytułów: 0 = Avenir Next, 1 = systemowa
    var systemTitleFont: Bool { get { d.bool(forKey: "systemTitleFont") } set { set("systemTitleFont", newValue) } }
    /// Płynne przewijanie wykresów między próbkami (60 fps)
    var smoothGraphs: Bool { get { d.object(forKey: "smoothGraphs") == nil ? true : d.bool(forKey: "smoothGraphs") } set { set("smoothGraphs", newValue) } }
    var showStatusBar: Bool { get { d.object(forKey: "showStatusBar") == nil ? true : d.bool(forKey: "showStatusBar") } set { set("showStatusBar", newValue) } }
    /// Ikona w pasku menu: 0 = brak, 1 = CPU, 2 = CPU + RAM, 3 = CPU + RAM + temperatura
    var menuBarItem: Int { get { d.integer(forKey: "menuBarItem") } set { set("menuBarItem", newValue) } }
    /// Ile sekund pokazywać zakończone procesy
    var keepExited: Int { get { d.object(forKey: "keepExited") == nil ? 8 : d.integer(forKey: "keepExited") } set { set("keepExited", newValue) } }
    var alwaysAdmin: Bool { get { d.bool(forKey: "alwaysAdmin") } set { set("alwaysAdmin", newValue) } }
    var askAdmin: Bool { get { !d.bool(forKey: "adminAsked") } set { set("adminAsked", !newValue) } }
    /// Ile pikseli przesuwa się wykres przy każdym pomiarze (0 = dopasuj historię do szerokości)
    var pixelsPerUpdate: Int { get { d.object(forKey: "pixelsPerUpdate") == nil ? 16 : d.integer(forKey: "pixelsPerUpdate") } set { set("pixelsPerUpdate", newValue) } }
    /// Animacje w 60 fps zamiast 30 fps (jak „High Frequency Visuals” w TMOG)
    var highFPS: Bool { get { d.bool(forKey: "highFPS") } set { set("highFPS", newValue) } }
    /// Język interfejsu: 0 = systemowy, 1 = polski, 2 = angielski
    var language: Int { get { d.integer(forKey: "language") } set { set("language", newValue) } }

    /// 0 = nowoczesny macOS, 1 = klasyczny (VFD/retro)
    var uiStyle: Int { get { d.integer(forKey: "uiStyle") } set { set("uiStyle", newValue) } }
    var modernUI: Bool { uiStyle == 0 }

    // --- alerty progowe
    var alertsEnabled: Bool { get { d.object(forKey: "alertsEnabled") == nil ? true : d.bool(forKey: "alertsEnabled") } set { set("alertsEnabled", newValue) } }
    var alertNotifications: Bool { get { d.object(forKey: "alertNotifications") == nil ? true : d.bool(forKey: "alertNotifications") } set { set("alertNotifications", newValue) } }
    var alertSound: Bool { get { d.bool(forKey: "alertSound") } set { set("alertSound", newValue) } }
    var alertTempC: Int { get { d.object(forKey: "alertTempC") == nil ? 95 : d.integer(forKey: "alertTempC") } set { set("alertTempC", newValue) } }
    var alertCPUPercent: Int { get { d.object(forKey: "alertCPUPercent") == nil ? 85 : d.integer(forKey: "alertCPUPercent") } set { set("alertCPUPercent", newValue) } }
    var alertSwapGB: Int { get { d.object(forKey: "alertSwapGB") == nil ? 8 : d.integer(forKey: "alertSwapGB") } set { set("alertSwapGB", newValue) } }
    var alertFreeSpacePercent: Int { get { d.object(forKey: "alertFreeSpacePercent") == nil ? 10 : d.integer(forKey: "alertFreeSpacePercent") } set { set("alertFreeSpacePercent", newValue) } }
    var alertBatteryPercent: Int { get { d.object(forKey: "alertBatteryPercent") == nil ? 15 : d.integer(forKey: "alertBatteryPercent") } set { set("alertBatteryPercent", newValue) } }
    var alertProcessCPU: Int { get { d.object(forKey: "alertProcessCPU") == nil ? 0 : d.integer(forKey: "alertProcessCPU") } set { set("alertProcessCPU", newValue) } }

    /// Ile sekund historii pokazują wykresy podsumowania
    var graphSpanSeconds: Int { get { d.object(forKey: "graphSpanSeconds") == nil ? 30 : d.integer(forKey: "graphSpanSeconds") } set { set("graphSpanSeconds", newValue) } }
    /// Płynne przenikanie zmienionych wartości w tabelach (zamiast skokowej podmiany)
    var crossfadeValues: Bool { get { d.bool(forKey: "crossfadeValues") } set { set("crossfadeValues", newValue) } }
    /// Długość historii wykresów w próbkach
    var history: Int { get { d.object(forKey: "history") == nil ? 120 : d.integer(forKey: "history") } set { set("history", newValue) } }
    /// Podświetlanie zmian wartości w tabelach
    var flashChanges: Bool { get { d.object(forKey: "flashChanges") == nil ? true : d.bool(forKey: "flashChanges") } set { set("flashChanges", newValue) } }
    var showExited: Bool { get { d.object(forKey: "showExited") == nil ? true : d.bool(forKey: "showExited") } set { set("showExited", newValue) } }
    var startPage: Int { get { d.integer(forKey: "startPage") } set { set("startPage", newValue) } }

    // --- moduły w pasku menu (jak w Stats: osobna pozycja na metrykę)
    var menuBarModules: [String] {
        get {
            if let list = d.stringArray(forKey: "menuBarModules") { return list }
            // migracja ze starego trybu 0…4
            switch d.integer(forKey: "menuBarItem") {
            case 1: return ["cpu"]
            case 2: return ["cpu", "memory"]
            case 3: return ["cpu", "memory", "temperature"]
            case 4: return ["power"]
            default: return []
            }
        }
        set { set("menuBarModules", newValue) }
    }
    /// moduły z rozbudowanym panelem (pełne listy odczytów zamiast skrótu)
    var menuBarDetailed: [String] { get { d.stringArray(forKey: "menuBarDetailed") ?? [] } set { set("menuBarDetailed", newValue) } }
    /// ile sekund historii mieści mini wykres w pasku menu
    var menuBarSpanSeconds: Double { get { d.object(forKey: "menuBarSpanSeconds") == nil ? 60 : d.double(forKey: "menuBarSpanSeconds") } set { set("menuBarSpanSeconds", newValue) } }
    /// 0 = wartość, 1 = wykres, 2 = wartość i wykres
    var menuBarStyle: Int { get { d.object(forKey: "menuBarStyle") == nil ? 2 : d.integer(forKey: "menuBarStyle") } set { set("menuBarStyle", newValue) } }

    // --- pływające panele na pulpicie
    var widgets: [String] { get { d.stringArray(forKey: "widgets") ?? [] } set { set("widgets", newValue) } }
    var widgetOpacity: Double { get { d.object(forKey: "widgetOpacity") == nil ? 0.92 : d.double(forKey: "widgetOpacity") } set { set("widgetOpacity", newValue) } }
    var widgetsOnTop: Bool { get { d.object(forKey: "widgetsOnTop") == nil ? true : d.bool(forKey: "widgetsOnTop") } set { set("widgetsOnTop", newValue) } }

    // --- praca w tle i uruchamianie
    /// zamknięcie okna nie kończy aplikacji – zostaje w pasku menu
    var keepRunning: Bool { get { d.object(forKey: "keepRunning") == nil ? true : d.bool(forKey: "keepRunning") } set { set("keepRunning", newValue) } }
    /// co ile sekund próbkować, gdy okno jest schowane (0 = bez zmiany)
    var backgroundInterval: Double { get { d.object(forKey: "backgroundInterval") == nil ? 1.0 : d.double(forKey: "backgroundInterval") } set { set("backgroundInterval", newValue) } }

    // --- aktualizacje z wydań GitHuba
    var autoUpdateCheck: Bool { get { d.object(forKey: "autoUpdateCheck") == nil ? true : d.bool(forKey: "autoUpdateCheck") } set { set("autoUpdateCheck", newValue) } }
    var lastUpdateCheck: Double { get { d.double(forKey: "lastUpdateCheck") } set { set("lastUpdateCheck", newValue) } }
    /// wersja pominięta przyciskiem „Pomiń tę wersję” – nie pytamy o nią przy starcie
    var skippedUpdate: String { get { d.string(forKey: "skippedUpdate") ?? "" } set { set("skippedUpdate", newValue) } }
    var rememberPage: Bool { get { d.object(forKey: "rememberPage") == nil ? true : d.bool(forKey: "rememberPage") } set { set("rememberPage", newValue) } }
}
