// AppDelegate.swift - start aplikacji, menu, akcje globalne
import AppKit
import Security
import HelperKit

@main
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    private var windowController: MainWindowController!
    private var statusItem: StatusItemController!

    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        ThemeManager.shared.setAppTheme(ThemeManager.shared.appTheme)   // ustawia NSAppearance zgodnie z zapisanym motywem
        buildMenu()
        windowController = MainWindowController()
        windowController.showWindow(nil)
        statusItem = StatusItemController()
        NotificationCenter.default.addObserver(self, selector: #selector(rebuildForLanguage), name: .languageChanged, object: nil)
        Monitor.shared.start()
        NSApp.activate(ignoringOtherApps: true)
        if CommandLine.arguments.contains("-registerHelper") {
            do { try HelperClient.shared.register(); NSLog("helper register OK, status=%@", HelperClient.shared.statusText) }
            catch { NSLog("helper register FAILED: %@", error.localizedDescription) }
        }
        if CommandLine.arguments.contains("-helperStatus") { NSLog("helper status=%@", HelperClient.shared.statusText) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in self?.maybeAskForAdmin() }
        // sprawdzenie aktualizacji dopiero po ustabilizowaniu okna, żeby start nie czekał na sieć
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { Updater.shared.checkOnLaunch() }
    }

    /// Zmiana języka w locie: menu, ikona w pasku menu i całe okno budowane są od nowa,
    /// bo etykiety są ustawiane przy tworzeniu widoków. Strona i ramka okna zostają te same.
    @objc private func rebuildForLanguage() {
        let page = windowController?.content.current ?? 0
        let wasVisible = windowController?.window?.isVisible ?? true
        buildMenu()
        statusItem = StatusItemController()
        let old = windowController
        let fresh = MainWindowController()
        windowController = fresh
        if wasVisible { fresh.showWindow(nil) }
        fresh.selectPage(max(0, page))
        old?.close()
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Przy pierwszym uruchomieniu pytamy, czy działać z uprawnieniami administratora
    private func maybeAskForAdmin() {
        guard !Monitor.isRoot else { return }
        // Zainstalowany pomocnik uprzywilejowany daje pełne dane – żadnych monitów o hasło
        if HelperClient.shared.isEnabled { Prefs.shared.alwaysAdmin = false; return }
        if Prefs.shared.alwaysAdmin { relaunchAsAdmin(); return }
        guard !UserDefaults.standard.bool(forKey: "adminAsked") else { return }
        let alert = NSAlert()
        alert.messageText = L("Uruchomić z uprawnieniami administratora?")
        alert.informativeText = "macOS udostępnia CPU, pamięć i wątki procesów innych użytkowników oraz liczniki energii CPU / GPU / Neural Engine tylko procesom z uprawnieniami administratora. Bez nich te pola pokażą „Brak dostępu”.\n\nPo kliknięciu „Uruchom jako administrator” system poprosi o hasło w standardowym oknie macOS i aplikacja uruchomi się ponownie."
        alert.alertStyle = .informational
        alert.addButton(withTitle: L("Uruchom jako administrator"))
        alert.addButton(withTitle: L("Kontynuuj bez uprawnień"))
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = L("Nie pytaj ponownie (zmiana w Ustawieniach)")
        let resp = alert.runModal()
        if alert.suppressionButton?.state == .on { UserDefaults.standard.set(true, forKey: "adminAsked") }
        if resp == .alertFirstButtonReturn { relaunchAsAdmin() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { Prefs.shared.menuBarItem == 0 }

    // MARK: menu
    private func buildMenu() {
        let bar = NSMenu()

        let appMenu = NSMenu()
        appMenu.addItem(withTitle: L("O programie Vitals"), action: #selector(showAbout), keyEquivalent: "")
        appMenu.addItem(withTitle: L("Sprawdź aktualizacje…"), action: #selector(checkForUpdates), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: L("Ustawienia…"), action: #selector(openSettings), keyEquivalent: ",")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: L("Ukryj Vitals"), action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: L("Zakończ Vitals"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let appItem = NSMenuItem(); appItem.submenu = appMenu; bar.addItem(appItem)

        let proc = NSMenu(title: L("Proces"))
        proc.addItem(withTitle: L("Zakończ proces"), action: #selector(endProcess), keyEquivalent: "\u{8}")
        let force = proc.addItem(withTitle: L("Wymuś zakończenie procesu"), action: #selector(forceEndProcess), keyEquivalent: "\u{8}")
        force.keyEquivalentModifierMask = [.command, .option]
        proc.addItem(.separator())
        let reveal = proc.addItem(withTitle: L("Pokaż w Finderze"), action: #selector(revealProcess), keyEquivalent: "r")
        reveal.keyEquivalentModifierMask = [.command, .shift]
        proc.addItem(withTitle: L("Kopiuj ścieżkę"), action: #selector(copyProcessPath), keyEquivalent: "")
        let procItem = NSMenuItem(); procItem.submenu = proc; bar.addItem(procItem)

        let view = NSMenu(title: L("Widok"))
        for (i, t) in ["Podsumowanie", "Wydajność", "Procesy", "Informacje o systemie", "Usługi", "Użytkownicy", "Zasilanie i czujniki", "Apple Silicon", "Połączenia", "Elementy startowe", "Zainstalowane aplikacje", "Sterowniki", "Miejsce na dysku", "Benchmarki"].enumerated() {
            let it = view.addItem(withTitle: t, action: #selector(selectPage(_:)), keyEquivalent: i < 9 ? "\(i + 1)" : (i == 9 ? "0" : ""))
            it.tag = i
        }
        let settingsItem = view.addItem(withTitle: L("Ustawienia"), action: #selector(selectPage(_:)), keyEquivalent: ",")
        settingsItem.tag = -1   // -1 = strona ustawień, jej numer zna okno
        view.addItem(.separator())
        let find = view.addItem(withTitle: L("Szukaj…"), action: #selector(focusSearch), keyEquivalent: "f")
        find.keyEquivalentModifierMask = [.command]
        let side = view.addItem(withTitle: L("Pokaż/ukryj pasek boczny"), action: #selector(toggleSidebar), keyEquivalent: "s")
        side.keyEquivalentModifierMask = [.command, .control]
        view.addItem(.separator())
        view.addItem(withTitle: L("Odśwież teraz"), action: #selector(refreshNow(_:)), keyEquivalent: "r")
        let interval = NSMenu(title: L("Częstotliwość odświeżania"))
        for (t, ms) in [(L("Bardzo szybko — 10/s"), 100), (L("Szybko — 4/s"), 250), (L("Normalnie — 2/s"), 500), (L("Wolno — 1/s"), 1000), ("Oszczędnie — co 2 s", 2000)] {
            let it = interval.addItem(withTitle: t, action: #selector(setInterval(_:)), keyEquivalent: ""); it.tag = ms
        }
        let intervalItem = view.addItem(withTitle: L("Częstotliwość odświeżania"), action: nil, keyEquivalent: ""); intervalItem.submenu = interval
        let theme = NSMenu(title: L("Motyw aplikacji"))
        for k in AppTheme.allCases {
            let it = theme.addItem(withTitle: k.title, action: #selector(setAppTheme(_:)), keyEquivalent: ""); it.tag = k.rawValue
        }
        let themeItem = view.addItem(withTitle: L("Motyw aplikacji"), action: nil, keyEquivalent: ""); themeItem.submenu = theme
        let disp = NSMenu(title: L("Wyświetlacz"))
        for m in DisplayMode.allCases {
            let it = disp.addItem(withTitle: m.title, action: #selector(setDisplayMode(_:)), keyEquivalent: ""); it.tag = m.rawValue
        }
        let dispItem = view.addItem(withTitle: L("Wyświetlacz"), action: nil, keyEquivalent: ""); dispItem.submenu = disp
        let colorsItem = view.addItem(withTitle: L("Kolory…"), action: #selector(showColorsPanel(_:)), keyEquivalent: "k")
        colorsItem.keyEquivalentModifierMask = [.command, .shift]
        view.addItem(.separator())
        view.addItem(withTitle: L("Uruchom ponownie jako administrator…"), action: #selector(runAsAdmin(_:)), keyEquivalent: "")
        let viewItem = NSMenuItem(); viewItem.submenu = view; bar.addItem(viewItem)

        let window = NSMenu(title: L("Okno"))
        window.addItem(withTitle: L("Minimalizuj"), action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        window.addItem(withTitle: L("Powiększ"), action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        let windowItem = NSMenuItem(); windowItem.submenu = window; bar.addItem(windowItem)
        NSApp.windowsMenu = window

        NSApp.mainMenu = bar
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(setAppTheme(_:)):
            item.state = ThemeManager.shared.appTheme.rawValue == item.tag ? .on : .off
        case #selector(setDisplayMode(_:)):
            item.state = ThemeManager.shared.display.rawValue == item.tag ? .on : .off
        case #selector(setInterval(_:)):
            item.state = Int(Monitor.shared.interval * 1000) == item.tag ? .on : .off
        case #selector(runAsAdmin(_:)):
            return !Monitor.isRoot
        case #selector(selectPage(_:)):
            item.state = windowController?.content.current == item.tag ? .on : .off
        default: break
        }
        return true
    }

    // MARK: akcje
    @objc func selectPage(_ sender: NSMenuItem) {
        windowController.selectPage(sender.tag < 0 ? windowController.settingsPage : sender.tag)
    }
    @objc func checkForUpdates() { Updater.shared.check(userInitiated: true) }

    @objc func openSettings() { windowController.selectPage(windowController.settingsPage) }
    @objc func showMainWindow(_ sender: Any?) { windowController.showWindow(nil); NSApp.activate(ignoringOtherApps: true) }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showMainWindow(nil); return true }
    @objc func toggleSidebar() { windowController.toggleSidebar() }
    @objc func focusSearch() { windowController.showWindow(nil); windowController.focusSearch() }
    @objc func setAppTheme(_ sender: NSMenuItem) { if let k = AppTheme(rawValue: sender.tag) { ThemeManager.shared.setAppTheme(k) } }
    @objc func setDisplayMode(_ sender: NSMenuItem) { if let m = DisplayMode(rawValue: sender.tag) { ThemeManager.shared.setDisplay(m) } }
    @objc func showColorsPanel(_ sender: Any?) { windowController.sidebar.presentColorsPopover() }
    @objc func setInterval(_ sender: NSMenuItem) { Monitor.shared.interval = Double(sender.tag) / 1000 }
    @objc func refreshNow(_ sender: Any?) { Monitor.shared.sampleNow() }
    @objc func toggleAskAdmin(_ sender: Any?) { Prefs.shared.askAdmin.toggle() }
    @objc func endProcess() { windowController.selectPage(2); windowController.content.processes.endProcess() }
    @objc func forceEndProcess() { windowController.selectPage(2); windowController.content.processes.forceEndProcess() }
    @objc func revealProcess() { windowController.content.processes.revealInFinder() }
    @objc func copyProcessPath() { windowController.content.processes.copyPath() }

    @objc func showAbout() {
        let hw = Monitor.shared.hardware
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "Vitals",
            .applicationVersion: AppVersion.short,
            .version: "\(AppVersion.build)",
            .credits: NSAttributedString(string: "Monitor procesów i sprzętu dla macOS.\nSwift + AppKit, pomiary: libproc, Mach, sysctl, IOKit, SMC, IOReport.\nWersja \(AppVersion.full) · zbudowano \(AppVersion.buildDate)\n\(hw.model) · macOS \(hw.osVersion)"),
        ])
    }

    @objc func runAsAdmin(_ sender: Any?) {
        let alert = NSAlert()
        alert.messageText = L("Uruchomić ponownie jako administrator?")
        alert.informativeText = "Aplikacja zostanie uruchomiona z uprawnieniami administratora, dzięki czemu pokaże CPU i pamięć wszystkich procesów oraz pozwoli je kończyć. System poprosi o hasło w standardowym oknie macOS."
        alert.addButton(withTitle: L("Kontynuuj"))
        alert.addButton(withTitle: L("Anuluj"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        relaunchAsAdmin()
    }

    private var prefsArgs: [String] {
        let plist = NSHomeDirectory() + "/Library/Preferences/" + (Bundle.main.bundleIdentifier ?? "online.equishow.vitals") + ".plist"
        return ["-userPrefs", plist, "-userUID", "\(getuid())"]
    }

    /// Próba przez Authorization Services: systemowy dialog uprawnień (może zaoferować Touch ID); zwraca true gdy uruchomiono
    private func relaunchWithAuthorization(exe: String, args: [String]) -> Bool {
        var authRef: AuthorizationRef?
        guard AuthorizationCreate(nil, nil, [], &authRef) == errAuthorizationSuccess, let auth = authRef else { return false }
        defer { AuthorizationFree(auth, [.destroyRights]) }
        var item = kAuthorizationRightExecute.withCString { AuthorizationItem(name: $0, valueLength: 0, value: nil, flags: 0) }
        var rights = AuthorizationRights(count: 1, items: &item)
        let flags: AuthorizationFlags = [.interactionAllowed, .preAuthorize, .extendRights]
        guard AuthorizationCopyRights(auth, &rights, nil, flags, nil) == errAuthorizationSuccess else { return false }
        // AuthorizationExecuteWithPrivileges jest przestarzałe, ale nadal dostępne – ładujemy dynamicznie
        typealias ExecFn = @convention(c) (AuthorizationRef, UnsafePointer<CChar>, AuthorizationFlags, UnsafePointer<UnsafeMutablePointer<CChar>?>, UnsafeMutablePointer<UnsafeMutablePointer<FILE>?>?) -> OSStatus
        guard let h = dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_LAZY), let sym = dlsym(h, "AuthorizationExecuteWithPrivileges") else { return false }
        let fn = unsafeBitCast(sym, to: ExecFn.self)
        var cargs: [UnsafeMutablePointer<CChar>?] = args.map { strdup($0) } + [nil]
        defer { for c in cargs { free(c) } }
        let status = cargs.withUnsafeBufferPointer { buf in exe.withCString { fn(auth, $0, [], buf.baseAddress!, nil) } }
        return status == errAuthorizationSuccess
    }

    private func relaunchAsAdmin() {
        guard let exe = Bundle.main.executablePath else { return }
        UserDefaults.standard.synchronize()
        if relaunchWithAuthorization(exe: exe, args: prefsArgs) { NSApp.terminate(nil); return }
        // Instancja administratora ma własne preferencje (w katalogu roota) – kopiujemy bieżące ustawienia użytkownika
        let plist = NSHomeDirectory() + "/Library/Preferences/" + (Bundle.main.bundleIdentifier ?? "online.equishow.vitals") + ".plist"
        func esc(_ s: String) -> String { s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") }
        let shell = "mkdir -p /var/root/Library/Preferences; cp -f \\\"\(esc(plist))\\\" /var/root/Library/Preferences/ 2>/dev/null; \\\"\(esc(exe))\\\" >/dev/null 2>&1 &"
        let script = "do shell script \"\(shell)\" with administrator privileges"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", script]
        let err = Pipe(); p.standardError = err
        do {
            try p.run(); p.waitUntilExit()
            if p.terminationStatus == 0 {
                NSApp.terminate(nil)
            } else {
                let msg = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                if !msg.contains("-128") {   // -128 = anulowano
                    let e = NSAlert(); e.messageText = L("Nie udało się uruchomić jako administrator"); e.informativeText = msg; e.runModal()
                }
            }
        } catch {
            let e = NSAlert(); e.messageText = L("Nie udało się uruchomić osascript"); e.informativeText = error.localizedDescription; e.runModal()
        }
    }
}
