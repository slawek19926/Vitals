// SettingsViewController.swift - strona „Ustawienia” (jak w TMOG): sekcje z wierszami etykieta + kontrolka
import AppKit
import ServiceManagement
import HelperKit

final class SettingsViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, PageRefreshable {
    /// Kategorie ustawień: tytuł, ikona i karty pokazywane po prawej
    private var categories: [(title: String, icon: String, cards: [NSView])] = []
    private let catTable = NSTableView()
    private let detailScroll = NSScrollView()
    private let detailColumn = vstack([], spacing: 12)
    private let prefs = Prefs.shared
    private var themePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private var displayPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private var fontPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private var tempPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private var refreshPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private var historyPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private var pixelsPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private var exitedPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private var startPagePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let smoothSwitch = NSSwitch(), statusSwitch = NSSwitch(), flashSwitch = NSSwitch()
    private let crossfadeSwitch = NSSwitch(), fpsSwitch = NSSwitch()
    private let stylePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let langPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let updateSwitch = NSSwitch()
    private let loginSwitch = NSSwitch()
    private let menuBarStylePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let menuBarSpanPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private var menuBarPopups: [WidgetKind: NSPopUpButton] = [:]
    private let backgroundSwitch = NSSwitch()
    private let onTopSwitch = NSSwitch()
    private let opacitySlider = NSSlider()
    private var widgetSwitches: [WidgetKind: NSSwitch] = [:]
    private let loginStatus = Label.make("", size: 10.5, dim: true)
    private let alertsSwitch = NSSwitch(), notifySwitch = NSSwitch(), soundSwitch = NSSwitch()
    private let tempField = NSTextField(), cpuField = NSTextField(), swapField = NSTextField()
    private let spaceField = NSTextField(), batteryField = NSTextField(), procField = NSTextField()
    private let spanPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let exitedSwitch = NSSwitch(), askAdminSwitch = NSSwitch(), rememberSwitch = NSSwitch(), alwaysAdminSwitch = NSSwitch()
    private let helperStatus = Label.make("", size: 11, dim: true)
    private var helperButton: NSButton?

    override func loadView() {
        view = NSView()
        let title = PageTitleView(L("Ustawienia"))

        let appearance = section("Wygląd", icon: "paintbrush")
        themePopup.addItems(withTitles: AppTheme.allCases.map { $0.title })
        themePopup.selectItem(at: ThemeManager.shared.appTheme.rawValue)
        themePopup.target = self; themePopup.action = #selector(themeChanged)
        row(appearance, "Motyw aplikacji", themePopup, hint: "Ustawienia systemowe podążają za trybem jasnym/ciemnym macOS.")
        displayPopup.addItems(withTitles: DisplayMode.allCases.map { $0.title })
        displayPopup.selectItem(at: ThemeManager.shared.display.rawValue)
        displayPopup.target = self; displayPopup.action = #selector(displayModeChanged)
        row(appearance, "Wyświetlacz", displayPopup, hint: "Tryby monochromatyczne odwzorowują monitory fosforowe.")
        let colorsBtn = NSButton(title: L("Otwórz panel kolorów…"), target: self, action: #selector(openColors))
        colorsBtn.bezelStyle = .rounded; colorsBtn.controlSize = .small; colorsBtn.font = Fonts.ui(11.5)
        row(appearance, "Nasycenie, poświata i HDR", colorsBtn, hint: "Suwaki nasycenia i poświaty oraz HDR są w panelu „Kolory” w pasku bocznym (⇧⌘K).")
        fontPopup.addItems(withTitles: ["Avenir Next (TMOG)", "Systemowa (SF Pro)"].map { L($0) })
        fontPopup.selectItem(at: prefs.systemTitleFont ? 1 : 0)
        fontPopup.target = self; fontPopup.action = #selector(fontChanged)
        row(appearance, "Czcionka tytułów", fontPopup)
        tempPopup.addItems(withTitles: [L("Celsjusz (°C)"), L("Fahrenheit (°F)")].map { L($0) })
        tempPopup.selectItem(at: prefs.fahrenheit ? 1 : 0)
        tempPopup.target = self; tempPopup.action = #selector(tempChanged)
        row(appearance, "Jednostka temperatury", tempPopup)

        langPopup.addItems(withTitles: AppLanguage.allCases.map { $0.title })
        langPopup.selectItem(at: prefs.language)
        langPopup.target = self; langPopup.action = #selector(languageChanged)
        row(appearance, "Język interfejsu", langPopup, hint: "Systemowy używa języka macOS. Zmiana działa od razu.")
        stylePopup.addItems(withTitles: ["Nowoczesny macOS", "Klasyczny (wyświetlacz VFD)"].map { L($0) })
        stylePopup.selectItem(at: prefs.uiStyle)
        stylePopup.target = self; stylePopup.action = #selector(styleChanged)
        row(appearance, "Styl interfejsu", stylePopup, hint: "Nowoczesny: karty z cieniem, jednolite paski, cienkie linie wykresów i akcent systemowy. Klasyczny: segmentowe paski LED, poświata i ramki w kolorach podsystemów. Część elementów przyjmuje nowy styl po ponownym uruchomieniu.")

        let charts = section("Wykresy i odświeżanie", icon: "waveform.path.ecg")
        refreshPopup.addItems(withTitles: ["Bardzo szybko — 10/s", "Szybko — 4/s", "Normalnie — 2/s", "Wolno — 1/s", "Oszczędnie — co 2 s"].map { L($0) })
        let ivs: [Double] = [0.1, 0.25, 0.5, 1, 2]
        refreshPopup.selectItem(at: ivs.firstIndex(where: { abs($0 - Monitor.shared.interval) < 0.01 }) ?? 1)
        pixelsPopup.addItems(withTitles: ["8 pikseli", "12 pikseli", "16 pikseli", "24 piksele"].map { L($0) })
        pixelsPopup.selectItem(at: [8, 12, 16, 24].firstIndex(of: prefs.pixelsPerUpdate) ?? 2)
        pixelsPopup.target = self; pixelsPopup.action = #selector(pixelsChanged)
        refreshPopup.target = self; refreshPopup.action = #selector(refreshChanged)
        row(charts, "Prędkość odświeżania", refreshPopup, hint: "Dotyczy tanich pomiarów (CPU, pamięć, dysk, sieć). Lista procesów odświeża się co ok. 2 s, a czujniki co ok. 1 s, niezależnie od tego ustawienia.")
        row(charts, "Krok wykresu na pomiar", pixelsPopup, hint: "Każdy pomiar przesuwa wykres o tyle pikseli. Większy krok daje czytelniejszy ruch, mniejszy mieści dłuższą historię.")
        smoothSwitch.state = prefs.smoothGraphs ? .on : .off
        smoothSwitch.target = self; smoothSwitch.action = #selector(smoothChanged)
        row(charts, "Płynne przewijanie wykresów (60 fps)", smoothSwitch, hint: "Wykresy przesuwają się płynnie między pomiarami. Wyłącz, aby przerysowywać tylko przy nowych danych.")
        spanPopup.addItems(withTitles: ["10 sekund", "20 sekund", "30 sekund", "1 minuta", "2 minuty", "5 minut"].map { L($0) })
        spanPopup.selectItem(at: [10, 20, 30, 60, 120, 300].firstIndex(of: prefs.graphSpanSeconds) ?? 2)
        spanPopup.target = self; spanPopup.action = #selector(spanChanged)
        row(charts, "Zakres czasu wykresów", spanPopup, hint: "Ile historii mieszczą wykresy w Podsumowaniu i Wydajności. Dłuższy zakres = gęstsze próbki i wolniejszy, drobniejszy ruch.")
        crossfadeSwitch.state = prefs.crossfadeValues ? .on : .off
        crossfadeSwitch.target = self; crossfadeSwitch.action = #selector(crossfadeChanged)
        row(charts, "Przenikanie zmienionych wartości", crossfadeSwitch, hint: "Stara wartość zanika, a nowa się wyłania. Domyślnie wyłączone — przy szybkim odświeżaniu bywa niespokojne.")
        fpsSwitch.state = prefs.highFPS ? .on : .off
        fpsSwitch.target = self; fpsSwitch.action = #selector(fpsChanged)
        row(charts, L("Animacje 60 kl./s"), fpsSwitch, hint: "Wyłączone = 30 kl./s. Niższa wartość zauważalnie zmniejsza obciążenie procesora.")
        historyPopup.addItems(withTitles: ["60 próbek", "120 próbek", "240 próbek", "600 próbek"].map { L($0) })
        historyPopup.selectItem(at: [60, 120, 240, 600].firstIndex(of: prefs.history) ?? 1)
        historyPopup.target = self; historyPopup.action = #selector(historyChanged)
        row(charts, "Długość historii wykresów", historyPopup, hint: "Dotyczy nowo tworzonych wykresów (po zmianie strony lub restarcie).")

        let alerts = section("Alerty i progi", icon: "bell.badge")
        alertsSwitch.state = prefs.alertsEnabled ? .on : .off
        alertsSwitch.target = self; alertsSwitch.action = #selector(alertsChanged)
        row(alerts, "Sprawdzaj progi", alertsSwitch, hint: "Aplikacja obserwuje temperaturę, obciążenie, pamięć, miejsce i baterię, a zdarzenia zapisuje w dzienniku na stronie Zdrowie systemu.")
        notifySwitch.state = prefs.alertNotifications ? .on : .off
        notifySwitch.target = self; notifySwitch.action = #selector(notifyChanged)
        row(alerts, "Powiadomienia systemowe", notifySwitch, hint: "Alert pojawia się jako powiadomienie macOS, nawet gdy okno jest schowane. Powtarzany nie częściej niż co 10 minut.")
        soundSwitch.state = prefs.alertSound ? .on : .off
        soundSwitch.target = self; soundSwitch.action = #selector(soundChanged)
        row(alerts, "Dźwięk powiadomienia", soundSwitch)
        for (field, value, label, hintText) in [
            (tempField, prefs.alertTempC, "Próg temperatury (°C)", "Najgorętszy czujnik powyżej tej wartości."),
            (cpuField, prefs.alertCPUPercent, "Próg obciążenia CPU (%)", "Łączne użycie procesora utrzymujące się powyżej progu przez 5 sekund."),
            (swapField, prefs.alertSwapGB, "Próg swapu (GB)", "Ilość danych w pliku wymiany."),
            (spaceField, prefs.alertFreeSpacePercent, "Próg wolnego miejsca (%)", "Wolne miejsce na dysku systemowym poniżej tej wartości."),
            (batteryField, prefs.alertBatteryPercent, "Próg baterii (%)", "Poziom naładowania przy pracy na baterii."),
            (procField, prefs.alertProcessCPU, "Próg dla procesu (%)", "Pojedynczy proces powyżej tej wartości. Zero wyłącza tę regułę."),
        ] {
            field.stringValue = "\(value)"
            field.alignment = .right
            field.size(width: 70)
            field.target = self
            field.action = #selector(thresholdChanged)
            row(alerts, label, field, hint: hintText)
        }

        let bars = section("Pasek menu i pasek stanu", icon: "menubar.rectangle")
        // każda metryka to osobna pozycja w pasku menu, jak w Stats
        for kind in WidgetKind.allCases {
            let popup = NSPopUpButton(frame: .zero, pullsDown: false)
            popup.addItems(withTitles: [L("Wyłączony"), L("Prosty"), L("Zaawansowany")])
            let enabled = prefs.menuBarModules.contains(kind.rawValue)
            popup.selectItem(at: enabled ? (prefs.menuBarDetailed.contains(kind.rawValue) ? 2 : 1) : 0)
            popup.tag = WidgetKind.allCases.firstIndex(of: kind) ?? 0
            popup.target = self; popup.action = #selector(menuBarModuleChanged(_:))
            menuBarPopups[kind] = popup
            row(bars, kind.title, popup)
        }
        menuBarStylePopup.addItems(withTitles: MenuBarStyle.allCases.map { $0.title })
        menuBarStylePopup.selectItem(at: min(prefs.menuBarStyle, MenuBarStyle.allCases.count - 1))
        menuBarStylePopup.target = self; menuBarStylePopup.action = #selector(menuBarStyleChanged)
        menuBarSpanPopup.addItems(withTitles: ["30 s", "1 min", "2 min", "5 min"])
        menuBarSpanPopup.selectItem(at: [30.0, 60, 120, 300].firstIndex(of: prefs.menuBarSpanSeconds) ?? 1)
        menuBarSpanPopup.target = self; menuBarSpanPopup.action = #selector(menuBarSpanChanged)
        row(bars, "Zakres czasu mini wykresów", menuBarSpanPopup,
            hint: "Ile historii mieści wykres przy pozycji w pasku menu.")
        row(bars, "Wygląd pozycji", menuBarStylePopup,
            hint: "Wartość, mini wykres albo oba naraz w samym pasku. Prosty panel pokazuje skrót metryki, zaawansowany pełne listy odczytów (rdzenie, czujniki, klucze SMC, interfejsy).")
        statusSwitch.state = prefs.showStatusBar ? .on : .off
        statusSwitch.target = self; statusSwitch.action = #selector(statusChanged)
        row(bars, "Pokaż pasek stanu", statusSwitch)

        let procs = section("Procesy i tabele", icon: "list.bullet.rectangle")
        flashSwitch.state = prefs.flashChanges ? .on : .off
        flashSwitch.target = self; flashSwitch.action = #selector(flashChanged)
        row(procs, "Podświetlaj zmienione wartości", flashSwitch)
        exitedSwitch.state = prefs.showExited ? .on : .off
        exitedSwitch.target = self; exitedSwitch.action = #selector(exitedChanged)
        row(procs, "Pokazuj zakończone procesy", exitedSwitch, hint: "Zakończone procesy pozostają na liście podświetlone na czerwono.")
        exitedPopup.addItems(withTitles: ["3 s", "8 s", "15 s", "30 s"].map { L($0) })
        exitedPopup.selectItem(at: [3, 8, 15, 30].firstIndex(of: prefs.keepExited) ?? 1)
        exitedPopup.target = self; exitedPopup.action = #selector(exitedTimeChanged)
        row(procs, "Czas wyświetlania zakończonych", exitedPopup)

        let perm = section("Uprawnienia", icon: "lock.shield")
        askAdminSwitch.state = prefs.askAdmin ? .on : .off
        askAdminSwitch.target = self; askAdminSwitch.action = #selector(askAdminChanged)
        alwaysAdminSwitch.state = prefs.alwaysAdmin ? .on : .off
        alwaysAdminSwitch.isEnabled = !HelperClient.shared.isEnabled
        alwaysAdminSwitch.target = self; alwaysAdminSwitch.action = #selector(alwaysAdminChanged)
        row(perm, "Uruchamiaj jako administrator przy każdym starcie (z hasłem)", alwaysAdminSwitch, hint: "Alternatywa dla pomocnika: przy każdym starcie systemowe okno hasła i przełączenie całej aplikacji w tryb administratora.")
        row(perm, "Pytaj o uprawnienia administratora przy starcie", askAdminSwitch)
        let adminBtn = NSButton(title: Monitor.isRoot ? L("Działa jako administrator") : L("Uruchom ponownie jako administrator…"), target: nil, action: #selector(AppDelegate.runAsAdmin(_:)))
        adminBtn.bezelStyle = .rounded; adminBtn.controlSize = .small; adminBtn.font = Fonts.ui(11.5); adminBtn.isEnabled = !Monitor.isRoot
        row(perm, "Pełne dane procesów i liczniki energii", adminBtn, hint: "macOS udostępnia CPU i pamięć procesów innych użytkowników oraz liczniki energii CPU / GPU / ANE tylko procesom z uprawnieniami administratora.")

        let helper = section("Pomocnik uprzywilejowany (zalecane)", icon: "shield.checkered")
        helperStatus.stringValue = L("Stan: ") + HelperClient.shared.statusText
        helperStatus.lineBreakMode = .byWordWrapping; helperStatus.maximumNumberOfLines = 2
        let hb = NSButton(title: HelperClient.shared.isEnabled ? (HelperClient.shared.outdated ? L("Zaktualizuj pomocnika…") : L("Wyłącz pomocnika")) : L("Włącz pomocnika…"), target: self, action: #selector(toggleHelper(_:)))
        hb.bezelStyle = .rounded; hb.controlSize = .small; hb.font = Fonts.ui(11.5)
        helperButton = hb
        row(helper, "Pełne dane procesów i liczniki energii bez hasła przy starcie", hb, hint: "Instaluje w systemie mały pomocnik (LaunchDaemon) z tego pakietu. macOS poprosi o jednorazowe zatwierdzenie w Ustawieniach systemowych → Ogólne → Elementy logowania i rozszerzenia. Pomocnik działa w tle jako administrator i przekazuje aplikacji przez XPC tylko listę procesów i odczyty mocy.")
        helper.add(helperStatus)
        let openLI = NSButton(title: L("Otwórz Elementy logowania…"), target: self, action: #selector(openLoginItems))
        openLI.bezelStyle = .rounded; openLI.controlSize = .small; openLI.font = Fonts.ui(11.5)
        row(helper, "Ustawienia systemowe", openLI)

        let start = section("Uruchamianie", icon: "power")
        rememberSwitch.state = prefs.rememberPage ? .on : .off
        rememberSwitch.target = self; rememberSwitch.action = #selector(rememberChanged)
        row(start, "Pamiętaj ostatnio otwartą stronę", rememberSwitch)
        startPagePopup.addItems(withTitles: ["Podsumowanie", "Wydajność", "Procesy", "Informacje o systemie", "Usługi", "Użytkownicy", "Zasilanie i czujniki", "Apple Silicon", "Połączenia", "Elementy startowe", "Zainstalowane aplikacje", "Sterowniki", "Miejsce na dysku", "Benchmarki"].map { L($0) })
        startPagePopup.selectItem(at: prefs.startPage)
        startPagePopup.target = self; startPagePopup.action = #selector(startPageChanged)
        row(start, "Strona startowa", startPagePopup)
        loginSwitch.state = LoginItem.isEnabled ? .on : .off
        loginSwitch.target = self; loginSwitch.action = #selector(loginItemChanged)
        row(start, "Uruchamiaj po zalogowaniu", loginSwitch,
            hint: "System uruchamia Vitals w tle po zalogowaniu. Pozycję można też cofnąć w Ustawieniach systemowych → Ogólne → Elementy logowania.")
        loginStatus.stringValue = L("Stan") + ": " + LoginItem.statusText
        start.add(loginStatus)
        backgroundSwitch.state = prefs.keepRunning ? .on : .off
        backgroundSwitch.target = self; backgroundSwitch.action = #selector(keepRunningChanged)
        row(start, "Działaj dalej po zamknięciu okna", backgroundSwitch,
            hint: "Zamknięcie okna zostawia aplikację w pasku menu i nie przerywa pomiarów. Bez okna próbkowanie zwalnia do jednego pomiaru na sekundę.")

        // --- panele na pulpicie
        let widgets = section("Panele na pulpicie", icon: "square.on.square")
        for kind in WidgetKind.allCases {
            let sw = NSSwitch()
            sw.state = WidgetManager.shared.isEnabled(kind) ? .on : .off
            sw.target = self; sw.action = #selector(widgetToggled(_:))
            sw.tag = WidgetKind.allCases.firstIndex(of: kind) ?? 0
            widgetSwitches[kind] = sw
            row(widgets, kind.title, sw)
        }
        onTopSwitch.state = prefs.widgetsOnTop ? .on : .off
        onTopSwitch.target = self; onTopSwitch.action = #selector(widgetPrefsChanged)
        row(widgets, "Zawsze na wierzchu", onTopSwitch,
            hint: "Panele leżą nad innymi oknami. Wyłączone – chowają się za aktywnym oknem.")
        opacitySlider.minValue = 0.35; opacitySlider.maxValue = 1
        opacitySlider.doubleValue = prefs.widgetOpacity
        opacitySlider.target = self; opacitySlider.action = #selector(widgetPrefsChanged)
        opacitySlider.controlSize = .small
        opacitySlider.widthAnchor.constraint(equalToConstant: 160).isActive = true
        row(widgets, "Przezroczystość", opacitySlider,
            hint: "Panel staje się w pełni widoczny, gdy najedziesz na niego kursorem. Przeciągasz go za tło, a zamykasz krzyżykiem w rogu.")

        let about = section("O programie", icon: "info.circle")
        let versionRow = KeyValueRow("Wersja", "\(AppVersion.full) (zbudowano \(AppVersion.buildDate))", keyWidth: 220)
        about.add(versionRow)
        updateSwitch.state = prefs.autoUpdateCheck ? .on : .off
        updateSwitch.target = self; updateSwitch.action = #selector(updateCheckChanged)
        row(about, "Sprawdzaj aktualizacje automatycznie", updateSwitch,
            hint: "Raz na dobę aplikacja pyta GitHuba o najnowsze wydanie. Pobranie i instalacja dopiero po Twojej zgodzie.")
        let checkBtn = NSButton(title: L("Sprawdź teraz"), target: self, action: #selector(checkUpdatesNow))
        checkBtn.bezelStyle = .rounded; checkBtn.controlSize = .small; checkBtn.font = Fonts.ui(11.5)
        row(about, "Aktualizacje", checkBtn, hint: L("Wydania pobierane są z repozytorium") + " \(Updater.repository).")

        let copyVersion = NSButton(title: L("Kopiuj informacje o wersji"), target: self, action: #selector(copyVersion))
        copyVersion.bezelStyle = .rounded; copyVersion.controlSize = .small; copyVersion.font = Fonts.ui(11.5)
        row(about, "Zgłaszanie problemów", copyVersion, hint: "Kopiuje wersję aplikacji, model komputera i wersję macOS.")

        // układ dwupanelowy: po lewej kategorie, po prawej zawartość wybranej kategorii
        categories = [
            ("Wygląd", "paintbrush", [appearance]),
            ("Wykresy i odświeżanie", "waveform.path.ecg", [charts]),
            ("Alerty i progi", "bell.badge", [alerts]),
            ("Pasek menu", "menubar.rectangle", [bars]),
            ("Procesy i tabele", "list.bullet.rectangle", [procs]),
            ("Pomocnik i uprawnienia", "lock.shield", [helper, perm]),
            ("Panele na pulpicie", "square.on.square", [widgets]),
            ("Uruchamianie", "power", [start]),
            ("O programie", "info.circle", [about]),
        ]

        catTable.addTableColumn(NSTableColumn(identifier: .init("cat")))
        catTable.headerView = nil
        catTable.rowHeight = 30
        catTable.backgroundColor = .clear
        catTable.style = .plain
        catTable.focusRingType = .none
        catTable.dataSource = self
        catTable.delegate = self
        let catScroll = NSScrollView()
        catScroll.documentView = catTable
        catScroll.drawsBackground = false
        catScroll.hasVerticalScroller = true; catScroll.scrollerStyle = .overlay; catScroll.autohidesScrollers = true
        catScroll.widthAnchor.constraint(equalToConstant: 220).isActive = true

        detailScroll.drawsBackground = false
        detailScroll.hasVerticalScroller = true; detailScroll.scrollerStyle = .overlay; detailScroll.autohidesScrollers = true
        let doc = FlippedView()
        detailScroll.documentView = doc
        detailColumn.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(detailColumn)
        doc.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            detailColumn.topAnchor.constraint(equalTo: doc.topAnchor, constant: 4),
            detailColumn.leadingAnchor.constraint(equalTo: doc.leadingAnchor),
            detailColumn.trailingAnchor.constraint(equalTo: doc.trailingAnchor),
            detailColumn.bottomAnchor.constraint(lessThanOrEqualTo: doc.bottomAnchor, constant: -20),
            doc.widthAnchor.constraint(equalTo: detailScroll.contentView.widthAnchor),
        ])

        let body = hstack([catScroll, detailScroll], spacing: 16, alignment: .top)
        let root = vstack([title, body], spacing: 6)
        for v in [title, body] { v.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true }
        body.setContentHuggingPriority(.init(1), for: .vertical)
        for v in [catScroll, detailScroll] { v.heightAnchor.constraint(equalTo: body.heightAnchor).isActive = true }
        root.pin(to: view, insets: NSEdgeInsets(top: 2, left: 18, bottom: 10, right: 18))
        catTable.reloadData()
        catTable.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        showCategory(0)
        NotificationCenter.default.addObserver(forName: .themeChanged, object: nil, queue: .main) { [weak self] _ in
            self?.themePopup.selectItem(at: ThemeManager.shared.appTheme.rawValue)
            self?.displayPopup.selectItem(at: ThemeManager.shared.display.rawValue)
        }
    }

    func pageDidAppear() {}

    /// Pokazuje karty wybranej kategorii
    private func showCategory(_ index: Int) {
        guard index >= 0, index < categories.count else { return }
        for v in detailColumn.arrangedSubviews { detailColumn.removeArrangedSubview(v); v.removeFromSuperview() }
        for card in categories[index].cards {
            detailColumn.addArrangedSubview(card)
            card.widthAnchor.constraint(equalTo: detailColumn.widthAnchor).isActive = true
        }
    }

    // MARK: lista kategorii
    func numberOfRows(in tableView: NSTableView) -> Int { categories.count }
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let r = ThemedRowView(); r.inset = 2; return r
    }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < categories.count else { return nil }
        let c = categories[row]
        let selected = catTable.selectedRow == row
        let fg = (Prefs.shared.modernUI && selected) ? NSColor.white : P.text
        let cell = NSTableCellView()
        let icon = symbol(c.icon, size: 13, weight: .regular, color: fg)
        icon.widthAnchor.constraint(equalToConstant: 20).isActive = true
        let label = Label.make(L(c.title), size: 12.5, weight: selected ? .medium : .regular)
        label.textColor = fg
        let h = hstack([icon, label], spacing: 8)
        h.pinCentered(to: cell, leading: 10, trailing: 6)
        return cell
    }
    private var lastCategoryRow = 0

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard notification.object as? NSTableView === catTable else { return }
        let row = catTable.selectedRow
        showCategory(row)
        // odświeżamy tylko poprzedni i nowy wiersz, żeby nie gubić zaznaczenia
        var idx = IndexSet()
        if lastCategoryRow >= 0, lastCategoryRow < categories.count { idx.insert(lastCategoryRow) }
        if row >= 0 { idx.insert(row) }
        lastCategoryRow = row
        DispatchQueue.main.async { [weak self] in
            self?.catTable.reloadData(forRowIndexes: idx, columnIndexes: IndexSet(integer: 0))
        }
    }

    private func section(_ title: String, icon: String) -> SectionCard { SectionCard(title: title, icon: icon) }

    private func row(_ card: SectionCard, _ label: String, _ control: NSView, hint: String? = nil) {
        let l = Label.make(L(label), size: 12)
        if let c = control as? NSControl { c.controlSize = .small; (c as? NSPopUpButton)?.font = Fonts.ui(11.5) }
        let h = hstack([l, spacer(), control], spacing: 12)
        card.add(h)
        if let hint {
            let hl = Label.make(L(hint), size: 10.5, dim: true)
            hl.lineBreakMode = .byWordWrapping; hl.maximumNumberOfLines = 2
            card.add(hl)
            card.stack.setCustomSpacing(2, after: h)
        }
    }

    @objc private func themeChanged() { ThemeManager.shared.setAppTheme(AppTheme(rawValue: themePopup.indexOfSelectedItem) ?? .system) }
    @objc private func displayModeChanged() { ThemeManager.shared.setDisplay(DisplayMode(rawValue: displayPopup.indexOfSelectedItem) ?? .color) }
    @objc private func openColors() { (NSApp.delegate as? AppDelegate)?.showColorsPanel(nil) }
    @objc private func fontChanged() { prefs.systemTitleFont = fontPopup.indexOfSelectedItem == 1 }
    @objc private func tempChanged() { prefs.fahrenheit = tempPopup.indexOfSelectedItem == 1 }
    @objc private func refreshChanged() { Monitor.shared.interval = [0.1, 0.25, 0.5, 1, 2][refreshPopup.indexOfSelectedItem] }
    @objc private func pixelsChanged() { prefs.pixelsPerUpdate = [8, 12, 16, 24][pixelsPopup.indexOfSelectedItem] }
    @objc private func smoothChanged() { prefs.smoothGraphs = smoothSwitch.state == .on }
    @objc private func updateCheckChanged() {
        prefs.autoUpdateCheck = updateSwitch.state == .on
        if updateSwitch.state == .on { prefs.skippedUpdate = "" }
    }

    @objc private func checkUpdatesNow() { Updater.shared.check(userInitiated: true) }

    /// Wyłączony / prosty panel / rozbudowany panel z pełnymi listami odczytów
    @objc private func menuBarModuleChanged(_ sender: NSPopUpButton) {
        let kinds = WidgetKind.allCases
        guard sender.tag < kinds.count else { return }
        let id = kinds[sender.tag].rawValue
        let mode = sender.indexOfSelectedItem
        // kolejność listy = kolejność pozycji w pasku menu
        var list = prefs.menuBarModules.filter { $0 != id }
        if mode > 0 { list = kinds.map { $0.rawValue }.filter { list.contains($0) || $0 == id } }
        prefs.menuBarModules = list
        var detailed = Set(prefs.menuBarDetailed)
        if mode == 2 { detailed.insert(id) } else { detailed.remove(id) }
        prefs.menuBarDetailed = detailed.sorted()
        NotificationCenter.default.post(name: .prefsChanged, object: nil)
    }

    @objc private func menuBarSpanChanged() {
        prefs.menuBarSpanSeconds = [30.0, 60, 120, 300][min(menuBarSpanPopup.indexOfSelectedItem, 3)]
        NotificationCenter.default.post(name: .prefsChanged, object: nil)
    }

    @objc private func menuBarStyleChanged() {
        prefs.menuBarStyle = menuBarStylePopup.indexOfSelectedItem
        NotificationCenter.default.post(name: .prefsChanged, object: nil)
    }

    @objc private func widgetToggled(_ sender: NSSwitch) {
        let kinds = WidgetKind.allCases
        guard sender.tag < kinds.count else { return }
        WidgetManager.shared.setEnabled(kinds[sender.tag], sender.state == .on)
    }

    @objc private func widgetPrefsChanged() {
        prefs.widgetsOnTop = onTopSwitch.state == .on
        prefs.widgetOpacity = opacitySlider.doubleValue
        WidgetManager.shared.applyPrefs()
    }

    @objc private func keepRunningChanged() { prefs.keepRunning = backgroundSwitch.state == .on }

    @objc private func loginItemChanged() {
        if let error = LoginItem.set(loginSwitch.state == .on) {
            let a = NSAlert()
            a.messageText = L("Nie udało się zmienić uruchamiania po zalogowaniu")
            a.informativeText = error
            a.addButton(withTitle: "OK")
            a.runModal()
        }
        loginSwitch.state = LoginItem.isEnabled ? .on : .off
        loginStatus.stringValue = L("Stan") + ": " + LoginItem.statusText
        if LoginItem.needsApproval { LoginItem.openSystemSettings() }
    }

    @objc private func languageChanged() {
        guard prefs.language != langPopup.indexOfSelectedItem else { return }
        prefs.language = langPopup.indexOfSelectedItem
        NotificationCenter.default.post(name: .languageChanged, object: nil)
    }

    @objc private func styleChanged() {
        prefs.uiStyle = stylePopup.indexOfSelectedItem
        NotificationCenter.default.post(name: .themeChanged, object: nil)
    }

    @objc private func alertsChanged() {
        prefs.alertsEnabled = alertsSwitch.state == .on
        if prefs.alertsEnabled { AlertCenter.shared.requestAuthorizationIfNeeded() }
    }
    @objc private func notifyChanged() {
        prefs.alertNotifications = notifySwitch.state == .on
        if prefs.alertNotifications { AlertCenter.shared.requestAuthorizationIfNeeded() }
    }
    @objc private func soundChanged() { prefs.alertSound = soundSwitch.state == .on }

    /// Zapisuje wszystkie progi po edycji dowolnego pola
    @objc private func thresholdChanged() {
        func value(_ f: NSTextField, _ fallback: Int, max maxV: Int) -> Int {
            let v = Int(f.stringValue.trimmingCharacters(in: .whitespaces)) ?? fallback
            return min(maxV, Swift.max(0, v))
        }
        prefs.alertTempC = value(tempField, prefs.alertTempC, max: 130)
        prefs.alertCPUPercent = value(cpuField, prefs.alertCPUPercent, max: 100)
        prefs.alertSwapGB = value(swapField, prefs.alertSwapGB, max: 256)
        prefs.alertFreeSpacePercent = value(spaceField, prefs.alertFreeSpacePercent, max: 90)
        prefs.alertBatteryPercent = value(batteryField, prefs.alertBatteryPercent, max: 100)
        prefs.alertProcessCPU = value(procField, prefs.alertProcessCPU, max: 1000)
        tempField.stringValue = "\(prefs.alertTempC)"
        cpuField.stringValue = "\(prefs.alertCPUPercent)"
        swapField.stringValue = "\(prefs.alertSwapGB)"
        spaceField.stringValue = "\(prefs.alertFreeSpacePercent)"
        batteryField.stringValue = "\(prefs.alertBatteryPercent)"
        procField.stringValue = "\(prefs.alertProcessCPU)"
    }

    @objc private func fpsChanged() { prefs.highFPS = fpsSwitch.state == .on }
    @objc private func spanChanged() { prefs.graphSpanSeconds = [10, 20, 30, 60, 120, 300][spanPopup.indexOfSelectedItem] }
    @objc private func crossfadeChanged() { prefs.crossfadeValues = crossfadeSwitch.state == .on }
    @objc private func historyChanged() { prefs.history = [60, 120, 240, 600][historyPopup.indexOfSelectedItem] }
    @objc private func statusChanged() { prefs.showStatusBar = statusSwitch.state == .on }
    @objc private func flashChanged() { prefs.flashChanges = flashSwitch.state == .on }
    @objc private func exitedChanged() { prefs.showExited = exitedSwitch.state == .on }
    @objc private func exitedTimeChanged() { prefs.keepExited = [3, 8, 15, 30][exitedPopup.indexOfSelectedItem] }
    @objc private func askAdminChanged() { prefs.askAdmin = askAdminSwitch.state == .on }
    @objc private func alwaysAdminChanged() { prefs.alwaysAdmin = alwaysAdminSwitch.state == .on }
    @objc private func toggleHelper(_ sender: NSButton) {
        do {
            // nieaktualny pomocnik instalujemy ponownie zamiast wyłączać
            if HelperClient.shared.isEnabled && !HelperClient.shared.outdated { try HelperClient.shared.unregister() }
            else { try HelperClient.shared.register() }
        } catch {
            let a = NSAlert(); a.messageText = L("Nie udało się zarejestrować pomocnika")
            a.informativeText = error.localizedDescription + "\n\nRejestracja LaunchDaemon przez SMAppService wymaga poprawnie podpisanej aplikacji (podpis Developer ID). Alternatywa: Uruchom ponownie jako administrator."
            a.runModal()
        }
        refreshHelperStatus()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.refreshHelperStatus() }
    }
    @objc private func openLoginItems() { SMAppService.openSystemSettingsLoginItems() }
    @objc private func copyVersion() {
        let hw = Monitor.shared.hardware
        let text = """
        Vitals \(AppVersion.full) (zbudowano \(AppVersion.buildDate))
        \(hw.marketingName) \(hw.model) · \(hw.cpuBrand) · \(Fmt.bytes(hw.memTotal, precision: 0))
        macOS \(hw.osVersion) (\(hw.osBuild)) · \(hw.kernel)
        Pomocnik: \(HelperClient.shared.statusText)
        """
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
    }

    @objc private func openFullDiskAccess() { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!) }
    private func refreshHelperStatus() {
        helperStatus.stringValue = L("Stan: ") + HelperClient.shared.statusText
        helperButton?.title = HelperClient.shared.isEnabled
            ? (HelperClient.shared.outdated ? L("Zaktualizuj pomocnika…") : L("Wyłącz pomocnika"))
            : L("Włącz pomocnika…")
    }
    @objc private func rememberChanged() { prefs.rememberPage = rememberSwitch.state == .on }
    @objc private func startPageChanged() { prefs.startPage = startPagePopup.indexOfSelectedItem }
}

extension NSLayoutConstraint {
    func withPriority(_ p: NSLayoutConstraint.Priority) -> NSLayoutConstraint { priority = p; return self }
}
