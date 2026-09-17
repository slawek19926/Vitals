// GraphView.swift - wykres historii na warstwach Core Animation: płynne przewijanie między próbkami (60 fps),
// poświata jako szerokie półprzezroczyste obrysy (bez kosztownych cieni CoreGraphics)
import AppKit
import QuartzCore

final class GraphView: ThemedView {
    var seriesCount: Int
    var history: Int { didSet { trim(); rebuild(animated: false) } }
    var accents: [Subsystem] { didSet { applyTheme() } }
    /// Kolory serii ustawiane przez stronę; po przypisaniu trzeba odświeżyć warstwy,
    /// bo pierwsze kolorowanie dzieje się jeszcze w konstruktorze
    var colorProvider: ((Int, Palette) -> NSColor)? { didSet { applyTheme() } }
    var maxValue: Double = 100 { didSet { needsRebuild = true } }
    var minValue: Double = 0
    var autoScale = false            // skala 0..ładne maksimum
    var autoRange = false            // zakres min..max historii (jak pamięć w TMOG)
    var compact = false { didSet { updateFonts() } }
    var showPercentAxis = false
    var title = "" { didSet { titleLabel.stringValue = L(title) } }
    var topLeft = "" { didSet { tlLabel.stringValue = L(topLeft) } }
    var topRight = "" { didSet { trLabel.stringValue = L(topRight) } }
    var bottomLeft = "" { didSet { blLabel.stringValue = L(bottomLeft) } }
    var bottomRight = "" { didSet { brLabel.stringValue = L(bottomRight) } }
    var formatter: ((Double) -> String)?
    var fillAlpha: CGFloat = 0.10
    /// Zakres czasu pokazywany na wykresie w sekundach (0 = wyznacz z kroku w pikselach)
    var timeSpan: Double = 0 { didSet { needsLayout = true } }
    /// Szerokość odniesienia dla `timeSpan`; wykres dwa razy szerszy pokazuje dwa razy dłuższy czas
    var referenceWidth: CGFloat = 320 { didSet { needsLayout = true } }
    var borderAccent: Subsystem?

    private var data: [[Double]]
    private let gridLayer = CAShapeLayer()
    private let borderLayer = CAShapeLayer()
    private let clipLayer = CALayer()
    private let scrollLayer = CALayer()
    private var fillLayers: [CAShapeLayer] = []
    private var glowLayers: [CAShapeLayer] = []
    private var lineLayers: [CAShapeLayer] = []
    private var markerLayers: [CAShapeLayer] = []
    private let titleLabel = NSTextField(labelWithString: "")
    private let tlLabel = NSTextField(labelWithString: ""), trLabel = NSTextField(labelWithString: "")
    private let blLabel = NSTextField(labelWithString: ""), brLabel = NSTextField(labelWithString: "")
    private let axisLabels = [NSTextField(labelWithString: "100%"), NSTextField(labelWithString: "50%"), NSTextField(labelWithString: "0%")]
    private var plot = CGRect.zero
    private var needsRebuild = false
    private var lastPush = CACurrentMediaTime()
    private var pushInterval: CFTimeInterval = 0.5
    private var phase: Double = 0          // przeniesienie fazy między próbkami (ciągły ruch)
    private var prevLast: [Double] = []
    private var curLast: [Double] = []
    private var stepXCache: CGFloat = 1
    private var lo = 0.0, hi = 1.0

    // MARK: przeglądanie historii (kursor czasu)
    /// true = można klikać i przeciągać po wykresie, żeby wybrać moment lub zakres
    var scrubbable = false {
        didSet { window?.acceptsMouseMovedEvents = window?.acceptsMouseMovedEvents ?? false || scrubbable; updateTrackingAreas() }
    }
    /// Zgłasza wybrany zakres próbek liczony od prawej (0 = najnowsza); nil = powrót do bieżących.
    /// Drugi argument: true = użytkownik przypiął wybór klikiem, false = podgląd spod kursora myszy
    var onScrub: ((ClosedRange<Int>?, Bool) -> Void)?
    /// true = wybór został przypięty klikiem i nie znika po zjechaniu myszą
    private(set) var pinned = false
    /// true = tryb przeglądania historii włączony klikiem; dopiero wtedy kursor podąża za myszą
    private var scrubActive = false
    private var hovering = false
    private var trackingArea: NSTrackingArea?
    /// Bieżący zakres kursora w indeksach od prawej (from >= to)
    private(set) var scrubFrom: Int?
    private(set) var scrubTo: Int?
    private var dragging = false
    private var dragAnchor: Int?
    private var currentPhase: CGFloat = 1
    private let cursorLayer = CAShapeLayer()
    private let rangeLayer = CAShapeLayer()

    init(series: Int = 1, history: Int = 120, accents: [Subsystem] = [.cpu]) {
        seriesCount = max(1, series)
        self.history = max(2, history)
        self.accents = accents
        data = Array(repeating: [], count: seriesCount)
        super.init(frame: .zero)
        layerContentsRedrawPolicy = .never
        layer?.cornerRadius = 4
        layer?.masksToBounds = true
        guard let root = layer else { return }
        gridLayer.fillColor = nil
        gridLayer.lineWidth = 1
        borderLayer.fillColor = nil
        borderLayer.lineWidth = 1
        clipLayer.masksToBounds = true
        clipLayer.addSublayer(scrollLayer)
        root.addSublayer(gridLayer)
        root.addSublayer(clipLayer)
        root.addSublayer(borderLayer)
        for _ in 0..<seriesCount {
            let f = CAShapeLayer(); f.strokeColor = nil
            let g = CAShapeLayer(); g.fillColor = nil; g.lineJoin = .round; g.lineCap = .round
            let l = CAShapeLayer(); l.fillColor = nil; l.lineJoin = .round; l.lineCap = .round
            let m = CAShapeLayer()
            fillLayers.append(f); glowLayers.append(g); lineLayers.append(l); markerLayers.append(m)
            scrollLayer.addSublayer(f)
        }
        for g in glowLayers { scrollLayer.addSublayer(g) }
        for l in lineLayers { scrollLayer.addSublayer(l) }
        for m in markerLayers { root.addSublayer(m) }
        rangeLayer.fillColor = nil
        rangeLayer.strokeColor = nil
        cursorLayer.fillColor = nil
        cursorLayer.lineWidth = 1
        cursorLayer.lineDashPattern = [4, 3]
        root.addSublayer(rangeLayer)
        root.addSublayer(cursorLayer)
        for l in [titleLabel, tlLabel, trLabel, blLabel, brLabel] + axisLabels {
            l.isEditable = false; l.isBordered = false; l.drawsBackground = false
            addSubview(l)
        }
        updateFonts()
        applyTheme()
        NotificationCenter.default.addObserver(forName: .prefsChanged, object: nil, queue: .main) { [weak self] _ in self?.applyTheme() }
        GraphTicker.shared.register(self)
    }

    /// Klatka animacji: przesunięcie proporcjonalne do czasu od ostatniej próbki
    fileprivate func frame(now: CFTimeInterval) {
        guard window != nil, !isHiddenOrHasHiddenAncestor, plot.width > 1, data.first?.count ?? 0 >= 1 else { return }
        // t rośnie liniowo z czasem; przy nowej próbce faza jest przenoszona (t - 1), więc ruch nie zatrzymuje się
        // Przewijanie trwa nieco dłużej niż odstęp próbek, więc najnowszy punkt jest zawsze
        // tuż za prawą krawędzią i linia dochodzi do samego brzegu. Faza nigdy nie przekracza 1,
        // przez co spóźniony pomiar tylko zatrzymuje ruch zamiast zostawiać pustą krawędź.
        // Przejazd o jeden krok trwa nieco krócej niż odstęp próbek, więc najnowszy punkt zawsze
        // zdąży dojechać do prawej krawędzi. Po dojechaniu ruch chwilę stoi, a nowa próbka
        // przedłuża ścieżkę dokładnie o ten jeden krok – dzięki temu podmiana jest niewidoczna.
        let span = max(0.04, pushInterval * 0.88)
        var t = Prefs.shared.smoothGraphs ? (now - lastPush) / span : 1.0
        t = min(1.0, max(0.0, t))
        currentPhase = CGFloat(t)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        scrollLayer.transform = CATransform3DMakeTranslation(-stepXCache * CGFloat(t), 0, 0)
        for s in 0..<seriesCount where s < curLast.count {
            let a = s < prevLast.count ? prevLast[s] : curLast[s]
            let v = a + (curLast[s] - a) * min(1, max(0, t))
            let y = 2 + CGFloat(min(1, max(0, (v - lo) / (hi - lo)))) * (plot.height - 3)
            markerLayers[s].position = CGPoint(x: plot.maxX, y: plot.minY + y)
        }
        CATransaction.commit()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func updateFonts() {
        let f = Fonts.ui(compact ? 9 : 10.5)
        for l in [titleLabel, tlLabel, trLabel, blLabel, brLabel] + axisLabels { l.font = f }
        needsLayout = true
    }

    override var isFlipped: Bool { false }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { GraphTicker.shared.start(from: self) }
        if scrubbable { window?.acceptsMouseMovedEvents = true }
        updateTrackingAreas()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = trackingArea { removeTrackingArea(t) }
        guard scrubbable else { return }
        let t = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(t)
        trackingArea = t
    }

    override func layout() {
        super.layout()
        let W = bounds.width, H = bounds.height
        let leftPad: CGFloat = (showPercentAxis && !compact) ? 34 : 0
        plot = CGRect(x: leftPad + 1, y: 1, width: max(1, W - leftPad - 2), height: max(1, H - 2))
        // stały krok w pikselach na pomiar – ruch jest czytelniejszy niż przy ściskaniu setek próbek
        if timeSpan > 0 {
            // Szerszy wykres dostaje proporcjonalnie dłuższe okno czasu, żeby odstęp między próbkami
            // był wszędzie podobny (inaczej duże wykresy miały grube kroki i widoczne przeskoki)
            let span = timeSpan * max(1, plot.width / referenceWidth)
            let wanted = max(12, min(Int(plot.width), Int((span / max(0.05, pushInterval)).rounded())))
            if wanted != history { history = wanted; clearScrub(notify: false) }
        } else {
            let px = CGFloat(Prefs.shared.pixelsPerUpdate)
            if px > 0 {
                let wanted = max(12, Int((plot.width / px).rounded()))
                if wanted != history { history = wanted; clearScrub(notify: false) }
            }
        }
        clipLayer.frame = plot
        scrollLayer.frame = clipLayer.bounds

        // siatka
        let grid = CGMutablePath()
        let cols = compact ? 4 : 12, rows = compact ? 3 : 8
        for c in 1..<cols {
            let x = plot.minX + plot.width * CGFloat(c) / CGFloat(cols)
            grid.move(to: CGPoint(x: x, y: plot.minY)); grid.addLine(to: CGPoint(x: x, y: plot.maxY))
        }
        for r in 1..<rows { let y = plot.minY + plot.height * CGFloat(r) / CGFloat(rows); grid.move(to: CGPoint(x: plot.minX, y: y)); grid.addLine(to: CGPoint(x: plot.maxX, y: y)) }
        gridLayer.path = grid
        borderLayer.path = CGPath(rect: CGRect(x: leftPad + 0.5, y: 0.5, width: W - leftPad - 1, height: H - 1), transform: nil)

        // podpisy
        let lh: CGFloat = compact ? 12 : 14
        titleLabel.frame = CGRect(x: plot.minX + 4, y: H - lh - 2, width: plot.width - 8, height: lh)
        tlLabel.frame = CGRect(x: plot.minX + 6, y: H - lh - 3, width: plot.width * 0.6, height: lh)
        trLabel.frame = CGRect(x: plot.maxX - 6 - plot.width * 0.4, y: H - lh - 3, width: plot.width * 0.4, height: lh)
        trLabel.alignment = .right
        blLabel.frame = CGRect(x: plot.minX + 6, y: 3, width: plot.width * 0.6, height: lh)
        brLabel.frame = CGRect(x: plot.maxX - 6 - plot.width * 0.4, y: 3, width: plot.width * 0.4, height: lh)
        brLabel.alignment = .right
        let showAxis = showPercentAxis && !compact
        for (i, l) in axisLabels.enumerated() {
            l.isHidden = !showAxis
            l.alignment = .right
            let y = plot.minY + plot.height * CGFloat(2 - i) / 2
            l.frame = CGRect(x: 0, y: min(max(y - lh / 2, 1), H - lh - 1), width: leftPad - 4, height: lh)
        }
        titleLabel.isHidden = !compact
        for l in [tlLabel, trLabel, blLabel, brLabel] { l.isHidden = compact }
        rebuild(animated: false)
        updateCursorLayers()
        window?.invalidateCursorRects(for: self)
        updateTrackingAreas()
    }

    override func applyTheme() {
        let pal = P
        layer?.backgroundColor = pal.graphBg.cgColor
        let border = borderAccent.map { pal.accent($0) } ?? color(0)
        gridLayer.strokeColor = border.alpha(Prefs.shared.modernUI ? (pal.isDark ? 0.08 : 0.12) : (pal.isDark ? 0.13 : 0.18)).cgColor
        // nowoczesny styl: brak kolorowej ramki wokół wykresu, tylko delikatna linia dolna/boczna
        borderLayer.strokeColor = Prefs.shared.modernUI ? pal.border.alpha(pal.isDark ? 0.35 : 0.55).cgColor
                                                        : border.alpha(0.75).cgColor
        let tm = ThemeManager.shared
        let bloom = tm.bloomFactor          // 0 = brak poświaty, 1 = domyślna, ~1.4 = maksymalna
        let boost = tm.edrBoost             // > 1 tylko przy HDR na ekranie z EDR
        if #available(macOS 14.0, *) { layer?.wantsExtendedDynamicRangeContent = boost > 1.001 }
        let modern = Prefs.shared.modernUI
        for i in 0..<seriesCount {
            let c = color(i)
            if modern {
                // wypełnienie mocniejsze, poświata wyłączona, linia cieńsza – bliżej natywnych aplikacji
                fillLayers[i].fillColor = c.alpha(pal.isDark ? 0.16 : 0.12).cgColor
                glowLayers[i].strokeColor = NSColor.clear.cgColor
                glowLayers[i].lineWidth = 0
                lineLayers[i].strokeColor = c.cgColor
                lineLayers[i].lineWidth = compact ? 1.2 : 1.6
                markerLayers[i].fillColor = c.cgColor
            } else {
                fillLayers[i].fillColor = c.alpha(fillAlpha * min(1.6, max(0.5, bloom))).cgColor
                glowLayers[i].strokeColor = bloom > 0.01 ? c.alpha(min(0.6, 0.28 * bloom)).edr(boost) : NSColor.clear.cgColor
                glowLayers[i].lineWidth = (compact ? 5 : 8) * max(0.35, min(1.8, bloom))
                lineLayers[i].strokeColor = c.edr(boost)
                lineLayers[i].lineWidth = compact ? 1.4 : (i == 0 ? 2.0 : 1.8)
                markerLayers[i].fillColor = (pal.isDark ? NSColor.white : NSColor.black).alpha(0.85).cgColor
            }
            lineLayers[i].lineJoin = .round
            lineLayers[i].lineCap = .round
        }
        updateCursorColors()
        for l in [tlLabel, trLabel, blLabel, brLabel, titleLabel] { l.textColor = pal.textDim }
        for l in axisLabels { l.textColor = border }
    }

    private func color(_ i: Int) -> NSColor {
        if let cp = colorProvider { return cp(i, P) }
        let s = i < accents.count ? accents[i] : accents.last ?? .cpu
        return P.accent(s)
    }

    private func trim() { for i in 0..<seriesCount where data[i].count > history { data[i].removeFirst(data[i].count - history) } }

    func push(_ values: [Double]) {
        for i in 0..<seriesCount {
            var v = i < values.count ? values[i] : 0
            if !v.isFinite { v = 0 }
            data[i].append(max(0, v))
        }
        trim()
        let now = CACurrentMediaTime()
        let dt = min(4.0, max(0.02, now - lastPush))
        // Odstęp próbek wygładzamy, ale pojedyncze odchyłki (spóźniony pomiar) pomijamy,
        // inaczej szacunek skacze i razem z nim cały wykres
        if pushInterval <= 0.02 { pushInterval = dt }
        else if dt > pushInterval * 0.45, dt < pushInterval * 2.2 { pushInterval = pushInterval * 0.82 + dt * 0.18 }
        phase = 0
        lastPush = now
        prevLast = curLast
        curLast = data.map { $0.last ?? 0 }
        // przy zadanym zakresie czasu dostrajamy liczbę próbek do realnego tempa pomiarów
        if timeSpan > 0 {
            let span = timeSpan * max(1, plot.width / referenceWidth)
            let wanted = max(12, min(Int(plot.width), Int((span / max(0.05, pushInterval)).rounded())))
            if abs(wanted - history) > max(3, history / 8) { needsLayout = true }
        }
        // kursor trzyma się swojej próbki, więc z każdym pomiarem przesuwa się w lewo
        if let f = scrubFrom, let t = scrubTo {
            // kursor trzyma się swojej próbki i wędruje razem z wykresem
            if f + 1 >= history { clearScrub() } else { scrubFrom = f + 1; scrubTo = t + 1 }
        }
        rebuild(animated: true)
    }
    func push(_ v: Double) { push([v]) }
    func clear() { data = Array(repeating: [], count: seriesCount); rebuild(animated: false) }
    var lastValue: Double { data.first?.last ?? 0 }

    // MARK: kursor czasu
    /// Ekranowe X dla próbki o indeksie liczonym od prawej (0 = najnowsza)
    private func x(forIndexFromRight i: Int) -> CGFloat {
        plot.maxX + stepXCache * (1 - currentPhase) - stepXCache * CGFloat(i)
    }

    /// Indeks próbki (od prawej) pod wskazanym punktem
    private func indexFromRight(at point: CGPoint) -> Int {
        let raw = (plot.maxX + stepXCache * (1 - currentPhase) - point.x) / max(1, stepXCache)
        let maxIndex = max(0, (data.first?.count ?? 1) - 1)
        return min(maxIndex, max(0, Int(raw.rounded())))
    }

    private func updateCursorColors() {
        let base = P.isDark ? NSColor.white : NSColor.black
        cursorLayer.strokeColor = base.alpha(pinned ? 0.85 : 0.45).cgColor
        cursorLayer.lineWidth = pinned ? 1.2 : 1
        rangeLayer.fillColor = base.alpha(pinned ? 0.12 : 0.06).cgColor
    }

    private func updateCursorLayers() {
        guard let from = scrubFrom, let to = scrubTo, plot.width > 1 else {
            cursorLayer.path = nil; rangeLayer.path = nil; return
        }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        let xFrom = x(forIndexFromRight: from), xTo = x(forIndexFromRight: to)
        let line = CGMutablePath()
        line.move(to: CGPoint(x: xTo, y: plot.minY)); line.addLine(to: CGPoint(x: xTo, y: plot.maxY))
        if from != to {
            line.move(to: CGPoint(x: xFrom, y: plot.minY)); line.addLine(to: CGPoint(x: xFrom, y: plot.maxY))
            rangeLayer.path = CGPath(rect: CGRect(x: min(xFrom, xTo), y: plot.minY,
                                                  width: abs(xTo - xFrom), height: plot.height), transform: nil)
        } else {
            rangeLayer.path = nil
        }
        cursorLayer.path = line
        updateCursorColors()
        CATransaction.commit()
    }

    /// Ustawia kursor z zewnątrz (synchronizacja kilku wykresów)
    func setScrub(from: Int?, to: Int?, pinned: Bool = false) {
        scrubFrom = from
        scrubTo = to
        self.pinned = pinned && from != nil
        scrubActive = from != nil
        updateCursorLayers()
    }

    func clearScrub(notify: Bool = true) {
        pinned = false
        scrubActive = false
        hovering = false
        scrubFrom = nil
        scrubTo = nil
        updateCursorLayers()
        if notify { onScrub?(nil, true) }
    }

    // MARK: mysz
    override func mouseMoved(with event: NSEvent) {
        // kursor podąża za myszą dopiero po włączeniu trybu historii klikiem
        guard scrubbable, scrubActive, !dragging else { super.mouseMoved(with: event); return }
        let p = convert(event.locationInWindow, from: nil)
        guard plot.contains(p) else { return }   // poza wykresem kursor zostaje tam, gdzie był
        hovering = true
        let i = indexFromRight(at: p)
        scrubFrom = i
        scrubTo = i
        updateCursorLayers()
        onScrub?(i...i, true)
    }

    override func mouseExited(with event: NSEvent) { }

    override func mouseDown(with event: NSEvent) {
        guard scrubbable else { super.mouseDown(with: event); return }
        let p = convert(event.locationInWindow, from: nil)
        guard plot.contains(p) else { super.mouseDown(with: event); return }
        if event.clickCount >= 2 { clearScrub(); return }
        let i = indexFromRight(at: p)
        dragging = true
        dragAnchor = i
        // pierwszy klik włącza tryb historii, kolejny w to samo miejsce go wyłącza
        if scrubActive, scrubFrom == i, scrubTo == i { clearScrub(); dragging = false; return }
        scrubActive = true
        pinned = true
        scrubFrom = i
        scrubTo = i
        updateCursorLayers()
        onScrub?(i...i, true)
    }

    override func mouseDragged(with event: NSEvent) {
        guard scrubbable, dragging, let anchor = dragAnchor else { super.mouseDragged(with: event); return }
        let i = indexFromRight(at: convert(event.locationInWindow, from: nil))
        pinned = true
        scrubFrom = max(anchor, i)   // starsza próbka ma większy indeks
        scrubTo = min(anchor, i)
        updateCursorLayers()
        onScrub?(scrubTo!...scrubFrom!, true)
    }

    override func mouseUp(with event: NSEvent) {
        dragging = false
        dragAnchor = nil
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        if scrubbable { addCursorRect(plot, cursor: .crosshair) }
    }

    /// Bieżący zakres osi Y
    private func range() -> (Double, Double) {
        if autoRange {
            let all = data.flatMap { $0 }
            guard let mn = all.min(), let mx = all.max() else { return (0, 1) }
            let span = max(mx - mn, max(mx, 1) * 0.02)
            let lo = max(0, mn - span * 0.25), hi = mx + span * 0.25
            return (lo, hi > lo ? hi : lo + 1)
        }
        var maxV = maxValue
        if autoScale {
            let m = data.flatMap { $0 }.max() ?? 0
            if m <= 0 { maxV = 1 } else {
                let p = pow(10.0, floor(log10(m))); let n = m / p
                maxV = (n <= 1 ? 1 : n <= 2 ? 2 : n <= 5 ? 5 : 10) * p
            }
        }
        return (minValue, maxV > minValue ? maxV : minValue + 1)
    }

    private func rebuild(animated: Bool) {
        guard plot.width > 1 else { return }
        let (lo, hi) = range()
        self.lo = lo; self.hi = hi
        let stepX = plot.width / CGFloat(max(2, history) - 1)
        stepXCache = stepX
        let pw = plot.width, ph = plot.height
        // poziom zerowy 2 px nad ramką, żeby niskie wartości (np. jądro 2–3%) nie zlewały się z krawędzią
        func y(_ v: Double) -> CGFloat { 2 + CGFloat(min(1, max(0, (v - lo) / (hi - lo)))) * (ph - 3) }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        scrollLayer.transform = CATransform3DIdentity
        for s in 0..<seriesCount {
            let d = data[s]
            guard d.count >= 1 else { fillLayers[s].path = nil; lineLayers[s].path = nil; glowLayers[s].path = nil; markerLayers[s].path = nil; continue }
            // najnowszy punkt ustawiamy o jeden krok za prawą krawędzią; animacja przesunie całość w lewo
            // zawsze rysujemy jeden krok za prawą krawędzią – przesunięcie warstwy decyduje,
            // ile z niego widać; inaczej po przebudowie bez animacji zostawał pusty pasek przy krawędzi
            let endX = pw + stepX
            let startX = endX - stepX * CGFloat(d.count - 1)
            let path = CGMutablePath()
            for (i, v) in d.enumerated() {
                let pt = CGPoint(x: startX + stepX * CGFloat(i), y: y(v))
                if i == 0 { path.move(to: pt) } else { path.addLine(to: pt) }
            }
            lineLayers[s].path = path
            glowLayers[s].path = path
            let fill = path.mutableCopy()!
            fill.addLine(to: CGPoint(x: endX, y: 0))
            fill.addLine(to: CGPoint(x: startX, y: 0))
            fill.closeSubpath()
            fillLayers[s].path = fill
            // znacznik na prawej krawędzi
            let sz: CGFloat = compact ? 5 : 7
            let tri = CGMutablePath()
            tri.move(to: CGPoint(x: 0, y: sz / 2 + 1)); tri.addLine(to: CGPoint(x: 0, y: -sz / 2 - 1)); tri.addLine(to: CGPoint(x: -sz, y: 0)); tri.closeSubpath()
            markerLayers[s].path = tri
            if !animated { markerLayers[s].position = CGPoint(x: plot.maxX, y: plot.minY + y(d.last!)) }
        }
        CATransaction.commit()

        // podpisy zakresu
        if autoRange, let f = formatter { tlLabel.stringValue = f(hi); blLabel.stringValue = f(lo) }
        else if autoScale, let f = formatter, topRight.isEmpty { trLabel.stringValue = "maks. " + f(hi) }

        if !animated {
            // statyczny układ (zmiana rozmiaru, nowa długość historii): stan końcowy, czyli faza 1
            CATransaction.begin(); CATransaction.setDisableActions(true)
            currentPhase = 1
            phase = 0
            lastPush = CACurrentMediaTime()
            scrollLayer.transform = CATransform3DMakeTranslation(-stepX, 0, 0)
            CATransaction.commit()
        } else {
            frame(now: CACurrentMediaTime())
        }
    }
}

/// Nadaje wszystkim wykresom w drzewie widoków wspólne okno czasu (skalowane szerokością),
/// żeby ruch i gęstość próbek były takie same na każdej stronie
enum GraphStyle {
    static func applyTimeSpan(_ root: NSView, seconds: Double = Double(Prefs.shared.graphSpanSeconds)) {
        if let g = root as? GraphView { g.timeSpan = seconds }
        for v in root.subviews { applyTimeSpan(v, seconds: seconds) }
    }
}

/// Wspólny zegar 60 fps dla wykresów
final class GraphTicker {
    static let shared = GraphTicker()
    private var views = NSHashTable<GraphView>.weakObjects()
    private var timer: Timer?
    /// Trzymane jako AnyObject, bo CADisplayLink na macOS jest dostępny dopiero od 14.0
    private var link: AnyObject?
    private var frames = 0
    private var fpsAt = CACurrentMediaTime()

    func register(_ v: GraphView) {
        views.add(v)
        start(from: v)
    }

    /// Animacja chodzi w rytm odświeżania ekranu; zwykły Timer gubił klatki, gdy wątek główny
    /// był zajęty odświeżaniem tabel, i wykres szarpał
    func start(from v: NSView) {
        if #available(macOS 14.0, *) {
            guard link == nil, let host = v.window?.contentView ?? NSApp.mainWindow?.contentView else { return }

            let l = host.displayLink(target: self, selector: #selector(step(_:)))
            let max = Float(Prefs.shared.highFPS ? 120 : 60)
            l.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: max, preferred: max)
            l.add(to: .main, forMode: .common)
            link = l as AnyObject
            timer?.invalidate(); timer = nil
            return
        }
        guard timer == nil else { return }
        let t = Timer(timeInterval: 1.0 / (Prefs.shared.highFPS ? 60.0 : 30.0), repeats: true) { [weak self] _ in
            self?.tick()
        }
        t.tolerance = 0.002
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    @available(macOS 14.0, *)
    @objc private func step(_ l: CADisplayLink) { tick() }

    private func tick() {
        let now = CACurrentMediaTime()
        for v in views.allObjects { v.frame(now: now) }
    }
}
