// DiskSpaceViewController.swift - „Miejsce na dysku”: skanowanie woluminu/katalogu, treemap, typy plików, największe foldery i pliki
import AppKit
import HelperKit

final class FSNode {
    let name: String
    let path: String
    let isDir: Bool
    var size: UInt64 = 0
    var children: [FSNode] = []
    var smallFiles: UInt64 = 0
    var smallCount = 0
    weak var parent: FSNode?
    init(name: String, path: String, isDir: Bool, parent: FSNode?) { self.name = name; self.path = path; self.isDir = isDir; self.parent = parent }
}

enum FileCategory: Int, CaseIterable {
    case media, documents, code, archives, apps, system, other
    var title: String { ["Multimedia", "Dokumenty", "Kod", "Archiwa", "Aplikacje", "System", "Inne"][rawValue] }
    var color: NSColor {
        [NSColor(srgbRed: 0.98, green: 0.45, blue: 0.42, alpha: 1), NSColor(srgbRed: 0.35, green: 0.80, blue: 0.45, alpha: 1), NSColor(srgbRed: 0.35, green: 0.62, blue: 1.0, alpha: 1),
         NSColor(srgbRed: 0.98, green: 0.80, blue: 0.30, alpha: 1), NSColor(srgbRed: 0.75, green: 0.50, blue: 0.95, alpha: 1), NSColor(srgbRed: 0.55, green: 0.60, blue: 0.70, alpha: 1), NSColor(srgbRed: 0.45, green: 0.48, blue: 0.58, alpha: 1)][rawValue]
    }
    static let mediaExt: Set<String> = ["jpg","jpeg","png","heic","heif","gif","tif","tiff","bmp","webp","raw","cr2","cr3","arw","dng","nef","mov","mp4","m4v","mkv","avi","webm","mp3","m4a","aac","wav","flac","aiff","ogg","psd","ai","svg"]
    static let docsExt: Set<String> = ["pdf","doc","docx","xls","xlsx","ppt","pptx","txt","md","rtf","pages","numbers","key","epub","odt","ods","csv","tex"]
    static let codeExt: Set<String> = ["swift","c","cc","cpp","h","hpp","m","mm","py","js","ts","tsx","jsx","java","kt","go","rs","rb","php","json","xml","yml","yaml","toml","html","css","scss","sh","zsh","o","a","dylib","so","framework","pbxproj","plist","sql","ipynb","lock","gradle","cmake","make"]
    static let archivesExt: Set<String> = ["zip","dmg","tar","gz","tgz","xz","bz2","7z","rar","iso","pkg","xip","img","sparsebundle","sparseimage"]
    static func of(path: String, ext: String) -> FileCategory {
        if path.contains(".app/") { return .apps }
        let e = ext.lowercased()
        if mediaExt.contains(e) { return .media }
        if docsExt.contains(e) { return .documents }
        if codeExt.contains(e) { return .code }
        if archivesExt.contains(e) { return .archives }
        if path.hasPrefix("/System") || path.hasPrefix("/Library") || path.hasPrefix("/usr") || path.hasPrefix("/private") || path.contains("/Library/") { return .system }
        return .other
    }
}

final class ScanResult {
    let root: FSNode
    var categories: [FileCategory: UInt64] = [:]
    var files = 0
    var dirs: [FSNode] = []
    var largestFiles: [(String, UInt64)] = []
    var deniedDirs = 0
    init(root: FSNode) { self.root = root }
}

/// Treemap (squarified) rysowany na CoreGraphics; klik = wejście do katalogu
final class TreemapView: NSView {
    var node: FSNode? { didSet { zoom = 1; pan = .zero; rects.removeAll(); needsDisplay = true; onZoomChange?(1) } }
    /// Powiększenie mapy i przesunięcie widocznego wycinka
    private(set) var zoom: CGFloat = 1
    private var pan: CGPoint = .zero
    private var dragOrigin: CGPoint?
    private var didPan = false
    private var pressed: FSNode?
    private var dragStartPan: CGPoint = .zero
    var onZoomChange: ((CGFloat) -> Void)?
    var onOpen: ((FSNode) -> Void)?
    var onSelect: ((FSNode?) -> Void)?
    private var rects: [(CGRect, FSNode)] = []
    /// Kafle podkatalogów rysowane wewnątrz kafli głównych (jeden poziom w głąb)
    private var subRects: [(rect: CGRect, node: FSNode, parent: Int)] = []
    private var hover: FSNode?
    private var tracking: NSTrackingArea?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        tracking = NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeInKeyWindow, .mouseEnteredAndExited], owner: self, userInfo: nil)
        addTrackingArea(tracking!)
    }

    /// Barwa kafla: każda gałąź dostaje własny odcień, rozsuwany złotym kątem
    private func tileColor(_ index: Int, depth: Int) -> NSColor {
        let hue = CGFloat((0.07 + 0.61803398875 * Double(index)).truncatingRemainder(dividingBy: 1))
        let sat: CGFloat = depth == 0 ? 0.42 : 0.30
        let bri: CGFloat = P.isDark ? (depth == 0 ? 0.62 : 0.78) : (depth == 0 ? 0.80 : 0.92)
        return NSColor(hue: hue, saturation: sat, brightness: bri, alpha: 1)
    }

    private func layoutRects() {
        rects.removeAll()
        subRects.removeAll()
        guard let n = node else { return }
        var items = n.children.sorted { $0.size > $1.size }
        if n.smallFiles > 0 { let s = FSNode(name: L("Małe pliki") + " (\(n.smallCount))", path: n.path, isDir: false, parent: n); s.size = n.smallFiles; items.append(s) }
        items = Array(items.prefix(80))
        let total = Double(items.reduce(0) { $0 + $1.size })
        guard total > 0 else { return }
        let area = CGRect(x: -pan.x + 2, y: -pan.y + 2,
                          width: bounds.width * zoom - 4, height: bounds.height * zoom - 4)
        squarify(items, rect: area, total: total)
        layoutChildren()
    }

    /// Układa zawartość każdego dużego kafla, żeby mapa pokazywała też jeden poziom niżej
    private func layoutChildren() {
        for (i, entry) in rects.enumerated() {
            let (rect, parent) = entry
            guard parent.isDir, !parent.children.isEmpty else { continue }
            let inner = rect.insetBy(dx: 6, dy: 6)
            let body = CGRect(x: inner.minX, y: inner.minY + headerHeight, width: inner.width, height: max(0, inner.height - headerHeight))
            guard body.width > 46, body.height > 34 else { continue }
            var kids = parent.children.sorted { $0.size > $1.size }
            if parent.smallFiles > 0 {
                let s = FSNode(name: L("Małe pliki") + " (\(parent.smallCount))", path: parent.path, isDir: false, parent: parent)
                s.size = parent.smallFiles
                kids.append(s)
            }
            kids = Array(kids.prefix(24))
            let total = Double(kids.reduce(0) { $0 + $1.size })
            guard total > 0 else { continue }
            let saved = rects
            rects = []
            squarify(kids, rect: body, total: total)
            for (r, k) in rects where r.width > 3 && r.height > 3 {
                subRects.append((r, k, i))
            }
            rects = saved
        }
    }

    private let headerHeight: CGFloat = 18

    private func squarify(_ items: [FSNode], rect: CGRect, total: Double) {
        var rest = items
        var r = rect
        var remaining = total
        while !rest.isEmpty, r.width > 1, r.height > 1 {
            let horizontal = r.width >= r.height
            let side = horizontal ? r.height : r.width
            var row: [FSNode] = []
            var rowSum = 0.0
            var bestRatio = Double.infinity
            for item in rest {
                let trial = rowSum + Double(item.size)
                let rowLen = trial / remaining * (horizontal ? Double(r.width) : Double(r.height))
                var worst = 0.0
                for x in row + [item] {
                    let len = Double(x.size) / trial * Double(side)
                    if len > 0, rowLen > 0 { worst = max(worst, max(rowLen / len, len / rowLen)) }
                }
                if worst <= bestRatio || row.isEmpty { row.append(item); rowSum = trial; bestRatio = worst } else { break }
            }
            let rowLen = CGFloat(rowSum / remaining) * (horizontal ? r.width : r.height)
            var offset: CGFloat = 0
            for x in row {
                let len = CGFloat(Double(x.size) / rowSum) * side
                let cell = horizontal ? CGRect(x: r.minX, y: r.maxY - offset - len, width: rowLen, height: len)
                                      : CGRect(x: r.minX + offset, y: r.maxY - rowLen, width: len, height: rowLen)
                rects.append((cell, x))
                offset += len
            }
            if horizontal { r.origin.x += rowLen; r.size.width -= rowLen } else { r.size.height -= rowLen }
            rest.removeFirst(row.count)
            remaining -= rowSum
        }
    }

    override func layout() { super.layout(); rects.removeAll(); needsDisplay = true }

    /// Ustawia powiększenie tak, aby punkt pod kursorem został w miejscu
    func setZoom(_ newZoom: CGFloat, anchor: CGPoint? = nil) {
        let z = min(max(1, newZoom), 12)
        guard abs(z - zoom) > 0.001 else { return }
        let a = anchor ?? CGPoint(x: bounds.midX, y: bounds.midY)
        let factor = z / zoom
        pan = CGPoint(x: (pan.x + a.x) * factor - a.x, y: (pan.y + a.y) * factor - a.y)
        zoom = z
        clampPan()
        rects.removeAll()
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
        onZoomChange?(zoom)
    }

    func resetZoom() { zoom = 1; pan = .zero; rects.removeAll(); needsDisplay = true; window?.invalidateCursorRects(for: self); onZoomChange?(zoom) }

    private func clampPan() {
        let maxX = max(0, bounds.width * zoom - bounds.width)
        let maxY = max(0, bounds.height * zoom - bounds.height)
        pan.x = min(max(0, pan.x), maxX)
        pan.y = min(max(0, pan.y), maxY)
    }

    override func magnify(with event: NSEvent) {
        setZoom(zoom * (1 + event.magnification), anchor: convert(event.locationInWindow, from: nil))
    }

    /// Rolka i gest przewijania zmieniają powiększenie; z Shiftem przesuwają powiększoną mapę
    override func scrollWheel(with event: NSEvent) {
        let dx = event.scrollingDeltaX, dy = event.scrollingDeltaY
        if event.modifierFlags.contains(.shift), zoom > 1 {
            pan.x -= dx == 0 ? dy : dx
            clampPan(); rects.removeAll(); needsDisplay = true
            return
        }
        guard dy != 0 || dx != 0 else { return }
        let raw = dy != 0 ? dy : dx
        let step = event.hasPreciseScrollingDeltas ? raw / 40 : raw / 6
        setZoom(zoom * (1 + max(-0.5, min(0.5, step))), anchor: convert(event.locationInWindow, from: nil))
    }


    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.setFillColor(P.graphBg.cachedCG)
        ctx.fill(bounds)
        if rects.isEmpty { layoutRects() }

        guard !rects.isEmpty else {
            let txt = NSAttributedString(string: L("Uruchom skanowanie, aby zobaczyć mapę"),
                                         attributes: [.font: Fonts.ui(12), .foregroundColor: P.textDim])
            txt.draw(at: CGPoint(x: bounds.midX - txt.size().width / 2, y: bounds.midY - 8))
            return
        }

        ctx.saveGState()
        ctx.clip(to: bounds)

        // kafle główne
        for (i, entry) in rects.enumerated() {
            let (rect, n) = entry
            guard rect.intersects(bounds), rect.width > 1, rect.height > 1 else { continue }
            let base = tileColor(i, depth: 0)
            drawTile(rect, color: base, radius: min(6, min(rect.width, rect.height) / 4), highlighted: n === hover)
            drawTileLabel(rect, node: n, color: base, hasChildren: subRects.contains { $0.parent == i })
        }

        // kafle zagnieżdżone
        for sub in subRects {
            guard sub.rect.intersects(bounds), sub.rect.width > 2, sub.rect.height > 2 else { continue }
            let c = tileColor(sub.parent * 7 + 3, depth: 1)
            drawTile(sub.rect, color: c, radius: min(3, min(sub.rect.width, sub.rect.height) / 4), highlighted: sub.node === hover)
            if sub.rect.width > 52, sub.rect.height > 20 {
                let a: [NSAttributedString.Key: Any] = [.font: Fonts.ui(9.5), .foregroundColor: NSColor.black.withAlphaComponent(0.72)]
                let t = NSAttributedString(string: sub.node.name, attributes: a)
                t.draw(with: CGRect(x: sub.rect.minX + 3, y: sub.rect.minY + 2, width: sub.rect.width - 6, height: 12),
                       options: [.truncatesLastVisibleLine, .usesLineFragmentOrigin])
                if sub.rect.height > 32 {
                    let sz = NSAttributedString(string: Fmt.bytes(sub.node.size),
                                               attributes: [.font: Fonts.ui(9), .foregroundColor: NSColor.black.withAlphaComponent(0.55)])
                    sz.draw(at: CGPoint(x: sub.rect.minX + 3, y: sub.rect.minY + 15))
                }
            }
        }
        ctx.restoreGState()
    }

    /// Kafel z pionowym gradientem, zaokrągleniem i ciemną krawędzią
    private func drawTile(_ rect: CGRect, color: NSColor, radius: CGFloat, highlighted: Bool) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let r = rect.insetBy(dx: 0.5, dy: 0.5)
        guard r.width > 0, r.height > 0 else { return }
        let path = CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil)
        ctx.saveGState()
        ctx.addPath(path)
        ctx.clip()
        let top = (highlighted ? color.blended(withFraction: 0.25, of: .white) ?? color : color)
        let bottom = top.blended(withFraction: P.isDark ? 0.22 : 0.16, of: .black) ?? top
        if let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                 colors: [top.cachedCG, bottom.cachedCG] as CFArray, locations: [0, 1]) {
            ctx.drawLinearGradient(grad, start: CGPoint(x: r.minX, y: r.maxY), end: CGPoint(x: r.minX, y: r.minY), options: [])
        } else {
            ctx.setFillColor(top.cachedCG); ctx.fill(r)
        }
        ctx.restoreGState()
        ctx.addPath(path)
        ctx.setStrokeColor(NSColor.black.withAlphaComponent(highlighted ? 0.75 : 0.45).cachedCG)
        ctx.setLineWidth(highlighted ? 1.6 : 1)
        ctx.strokePath()
    }

    /// Pasek nagłówka z nazwą i rozmiarem dla dużych kafli, dwuwierszowy podpis dla mniejszych
    private func drawTileLabel(_ rect: CGRect, node n: FSNode, color: NSColor, hasChildren: Bool) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let ink = NSColor.black.withAlphaComponent(0.85)
        if hasChildren, rect.width > 60, rect.height > 40 {
            let head = CGRect(x: rect.minX + 1, y: rect.minY + 1, width: rect.width - 2, height: headerHeight)
            ctx.setFillColor(NSColor.black.withAlphaComponent(0.16).cachedCG)
            ctx.fill(head)
            let size = NSAttributedString(string: Fmt.bytes(n.size),
                                          attributes: [.font: Fonts.ui(10), .foregroundColor: NSColor.black.withAlphaComponent(0.65)])
            let sw = min(size.size().width, head.width - 12)
            size.draw(at: CGPoint(x: head.maxX - sw - 4, y: head.minY + 4))
            let name = NSAttributedString(string: n.name, attributes: [.font: Fonts.ui(10.5, .semibold), .foregroundColor: ink])
            name.draw(with: CGRect(x: head.minX + 5, y: head.minY + 2, width: max(0, head.width - sw - 14), height: headerHeight - 3),
                      options: [.truncatesLastVisibleLine, .usesLineFragmentOrigin])
        } else if rect.width > 46, rect.height > 26 {
            let name = NSAttributedString(string: n.name, attributes: [.font: Fonts.ui(10.5, .semibold), .foregroundColor: ink])
            name.draw(with: CGRect(x: rect.minX + 4, y: rect.minY + 3, width: rect.width - 8, height: 13),
                      options: [.truncatesLastVisibleLine, .usesLineFragmentOrigin])
            if rect.height > 38 {
                let size = NSAttributedString(string: Fmt.bytes(n.size),
                                              attributes: [.font: Fonts.ui(9.5), .foregroundColor: NSColor.black.withAlphaComponent(0.6)])
                size.draw(at: CGPoint(x: rect.minX + 4, y: rect.minY + 17))
            }
        }
    }

    private func hit(_ e: NSEvent) -> FSNode? {
        let p = convert(e.locationInWindow, from: nil)
        if let sub = subRects.first(where: { $0.rect.contains(p) }) { return sub.node }
        return rects.first { $0.0.contains(p) }?.1
    }
    override func mouseMoved(with event: NSEvent) {
        let h = hit(event)
        if h !== hover { hover = h; toolTip = h.map { "\($0.path)\n\(Fmt.bytes($0.size))" }; needsDisplay = true; onSelect?(h) }
    }
    override func mouseExited(with event: NSEvent) { hover = nil; needsDisplay = true }
    override func resetCursorRects() {
        super.resetCursorRects()
        if zoom > 1 { addCursorRect(bounds, cursor: .openHand) }
    }
    override func mouseDragged(with event: NSEvent) {
        guard let o = dragOrigin else { return }
        let p = convert(event.locationInWindow, from: nil)
        if hypot(p.x - o.x, p.y - o.y) > 3 { didPan = true }
        guard zoom > 1, didPan else { return }
        pan = CGPoint(x: dragStartPan.x - (p.x - o.x), y: dragStartPan.y - (p.y - o.y))
        clampPan()
        rects.removeAll()
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        dragOrigin = convert(event.locationInWindow, from: nil)
        dragStartPan = pan
        didPan = false
        pressed = hit(event)
        if zoom > 1 { NSCursor.closedHand.push() }
    }

    /// Otwarcie katalogu dopiero przy puszczeniu przycisku – inaczej nie dałoby się przeciągać mapy
    override func mouseUp(with event: NSEvent) {
        if zoom > 1 { NSCursor.pop() }
        defer { dragOrigin = nil; pressed = nil; didPan = false }
        guard !didPan, let h = pressed, hit(event) === h else { return }
        if event.clickCount == 2 { NSWorkspace.shared.selectFile(h.path, inFileViewerRootedAtPath: "") }
        else if h.isDir, !h.children.isEmpty || h.smallFiles > 0 { onOpen?(h) }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let h = hit(event) else { return nil }
        let m = NSMenu()
        m.addItem(withTitle: L("Pokaż w Finderze"), action: #selector(revealHit(_:)), keyEquivalent: "").representedObject = h
        m.addItem(withTitle: L("Przenieś do Kosza…"), action: #selector(trashHit(_:)), keyEquivalent: "").representedObject = h
        m.addItem(withTitle: L("Kopiuj ścieżkę"), action: #selector(copyHit(_:)), keyEquivalent: "").representedObject = h
        for it in m.items { it.target = self }
        return m
    }
    @objc private func revealHit(_ s: NSMenuItem) { if let n = s.representedObject as? FSNode { NSWorkspace.shared.selectFile(n.path, inFileViewerRootedAtPath: "") } }
    @objc private func copyHit(_ s: NSMenuItem) { if let n = s.representedObject as? FSNode { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(n.path, forType: .string) } }
    @objc private func trashHit(_ s: NSMenuItem) {
        guard let n = s.representedObject as? FSNode else { return }
        let a = NSAlert(); a.messageText = L("Przenieść „") + "\(n.name)” (\(Fmt.bytes(n.size))) " + L("do Kosza?"); a.alertStyle = .warning
        a.addButton(withTitle: L("Przenieś do Kosza")); a.addButton(withTitle: L("Anuluj"))
        guard a.runModal() == .alertFirstButtonReturn else { return }
        NSWorkspace.shared.recycle([URL(fileURLWithPath: n.path)]) { _, err in if let err { NSAlert(error: err).runModal() } }
    }
}

final class DiskSpaceViewController: NSViewController, PageRefreshable {
    private let volumePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let scopePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let scanButton = NSButton(title: L("Skanuj"), target: nil, action: nil)
    private let progress = LEDBarView()
    private let progressLabel = Label.make("", size: 11, dim: true)
    private let breadcrumb = Label.make("", size: 12, dim: true)
    private let backButton = NSButton(title: L("Wstecz"), target: nil, action: nil)
    private let treemap = TreemapView()
    private let hoverLabel = Label.make("", size: 11, dim: true)
    private let zoomOutButton = NSButton(title: "−", target: nil, action: nil)
    private let zoomInButton = NSButton(title: "+", target: nil, action: nil)
    private let zoomResetButton = NSButton(title: "1:1", target: nil, action: nil)
    private let zoomLabel = Label.make("100%", size: 11, dim: true)
    private let volTitle = Label.make("", size: 14, weight: .semibold)
    private let volSize = Label.make("", size: 12, dim: true)
    private let volBar = LEDBarView()
    private let volUsed = Label.make("", size: 11, dim: true), volFree = Label.make("", size: 11, dim: true)
    private let typesStack = vstack([], spacing: 4)
    private let donut = DonutChartView()
    private let categoryBar = StackedBarView()
    private let foldersStack = vstack([], spacing: 3)
    private let filesStack = vstack([], spacing: 3)
    private var volumes: [Volume] = []
    private var result: ScanResult?
    private var current: FSNode?
    private var scanning = false
    private let cancellation = Locked(false)
    private var cancelFlag: Bool {
        get { cancellation.withValue { $0 } }
        set { cancellation.withValue { $0 = newValue } }
    }

    override func loadView() {
        view = NSView()
        let title = PageTitleView(L("Miejsce na dysku"))
        volumePopup.font = Fonts.ui(11.5); volumePopup.controlSize = .small
        scopePopup.addItems(withTitles: ["Katalog domowy", "Cały wolumin", "Wybierz folder…"].map { L($0) }); scopePopup.font = Fonts.ui(11.5); scopePopup.controlSize = .small
        scanButton.bezelStyle = .rounded; scanButton.controlSize = .small; scanButton.font = Fonts.ui(11.5); scanButton.keyEquivalent = "\r"
        scanButton.target = self; scanButton.action = #selector(scan)
        title.accessory = hstack([volumePopup, scopePopup, scanButton], spacing: 8)

        backButton.bezelStyle = .rounded; backButton.controlSize = .small; backButton.font = Fonts.ui(11.5); backButton.target = self; backButton.action = #selector(goBack); backButton.isEnabled = false
        for b in [zoomOutButton, zoomInButton, zoomResetButton] {
            b.bezelStyle = .rounded; b.controlSize = .small; b.font = Fonts.ui(11.5); b.target = self
        }
        zoomOutButton.action = #selector(zoomOut); zoomInButton.action = #selector(zoomIn); zoomResetButton.action = #selector(zoomReset)
        zoomOutButton.toolTip = L("Pomniejsz mapę")
        zoomInButton.toolTip = L("Powiększ mapę (⌘ + scroll lub gest szczypania)")
        zoomResetButton.toolTip = L("Powrót do pełnego widoku")
        zoomLabel.alignment = .right
        zoomLabel.widthAnchor.constraint(equalToConstant: 38).isActive = true
        let crumbRow = hstack([backButton, breadcrumb, spacer(), hoverLabel,
                               zoomOutButton, zoomLabel, zoomInButton, zoomResetButton], spacing: 6)
        treemap.setContentHuggingPriority(.init(1), for: .vertical)
        progress.accent = .disk; progress.segmentThickness = 9; progress.gap = 3
        progress.heightAnchor.constraint(equalToConstant: 12).isActive = true
        let progRow = hstack([progress, progressLabel], spacing: 10)
        progressLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        let left = vstack([crumbRow, treemap, progRow], spacing: 8)
        for v in [crumbRow, treemap, progRow] { v.widthAnchor.constraint(equalTo: left.widthAnchor).isActive = true }

        // prawy panel
        let volCard = SectionCard(title: "Wolumin", icon: "internaldrive", accent: .disk)
        volBar.accent = .disk; volBar.segmentThickness = 8; volBar.gap = 2; volBar.heightAnchor.constraint(equalToConstant: 10).isActive = true
        volCard.add(hstack([volTitle, spacer(), volSize]))
        volCard.add(volBar)
        categoryBar.heightAnchor.constraint(equalToConstant: 10).isActive = true
        volCard.add(categoryBar)
        volCard.add(hstack([volUsed, spacer(), volFree]))
        let typesCard = SectionCard(title: "Typ pliku", icon: "doc.on.doc", accent: .memory)
        donut.heightAnchor.constraint(equalToConstant: 150).isActive = true
        typesCard.add(donut)
        typesCard.add(typesStack)
        let foldersCard = SectionCard(title: "Największe foldery", icon: "folder", accent: .network)
        foldersCard.add(foldersStack)
        let filesCard = SectionCard(title: "Największe pliki", icon: "doc", accent: .energy)
        filesCard.add(filesStack)
        let right = vstack([volCard, typesCard, foldersCard, filesCard], spacing: 10)
        for c in right.arrangedSubviews { c.widthAnchor.constraint(equalTo: right.widthAnchor).isActive = true }
        let rScroll = NSScrollView(); rScroll.drawsBackground = false; rScroll.hasVerticalScroller = true; rScroll.scrollerStyle = .overlay; rScroll.autohidesScrollers = true
        let doc = FlippedView(); rScroll.documentView = doc
        right.pin(to: doc, insets: NSEdgeInsets(top: 0, left: 0, bottom: 10, right: 0))
        doc.translatesAutoresizingMaskIntoConstraints = false
        doc.widthAnchor.constraint(equalTo: rScroll.contentView.widthAnchor).isActive = true
        rScroll.size(width: 340)

        let body = hstack([left, rScroll], spacing: 14, alignment: .top)
        for v in [left, rScroll] { v.heightAnchor.constraint(equalTo: body.heightAnchor).isActive = true }
        body.setContentHuggingPriority(.init(1), for: .vertical)
        let root = vstack([title, body], spacing: 6)
        for v in [title, body] { v.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true }
        root.pin(to: view, insets: NSEdgeInsets(top: 2, left: 18, bottom: 12, right: 18))

        treemap.onOpen = { [weak self] n in self?.show(n) }
        treemap.onZoomChange = { [weak self] z in self?.updateZoomUI(z) }
        updateZoomUI(1)
        treemap.onSelect = { [weak self] n in self?.hoverLabel.stringValue = n.map { "\($0.name) · \(Fmt.bytes($0.size))" } ?? "" }
        NotificationCenter.default.addObserver(forName: .themeChanged, object: nil, queue: .main) { [weak self] _ in self?.treemap.needsDisplay = true; self?.refreshPanels() }
        reloadVolumes()
    }

    func pageDidAppear() { reloadVolumes() }

    private func reloadVolumes() {
        volumes = Monitor.volumes()
        let sel = volumePopup.indexOfSelectedItem
        volumePopup.removeAllItems()
        volumePopup.addItems(withTitles: volumes.map { v in
            let name = v.mount == "/" ? "Macintosh HD" : ((v.mount as NSString).lastPathComponent.isEmpty ? v.mount : (v.mount as NSString).lastPathComponent)
            return "\(name) — \(Fmt.bytes(v.total, precision: 0))"
        })
        if sel >= 0, sel < volumes.count { volumePopup.selectItem(at: sel) }
        updateVolumeCard()
    }

    private func updateVolumeCard() {
        guard volumePopup.indexOfSelectedItem >= 0, volumePopup.indexOfSelectedItem < volumes.count else { return }
        let v = volumes[volumePopup.indexOfSelectedItem]
        volTitle.stringValue = (v.mount as NSString).lastPathComponent.isEmpty ? "Macintosh HD" : (v.mount as NSString).lastPathComponent
        volSize.stringValue = Fmt.bytes(v.total)
        volBar.value = v.total > 0 ? Double(v.used) / Double(v.total) : 0
        volUsed.stringValue = "\(Fmt.bytes(v.used)) " + L("zajęte"); volFree.stringValue = "\(Fmt.bytes(v.free)) " + L("wolne")
        volTitle.textColor = P.text
    }

    @objc private func scan() {
        if scanning { cancelFlag = true; return }
        guard volumePopup.indexOfSelectedItem >= 0 else { return }
        let vol = volumes[volumePopup.indexOfSelectedItem]
        var rootPath: String
        switch scopePopup.indexOfSelectedItem {
        case 1: rootPath = vol.mount
        case 2:
            let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
            guard panel.runModal() == .OK, let u = panel.url else { return }
            rootPath = u.path
        default: rootPath = vol.mount == "/" ? NSHomeDirectory() : vol.mount
        }
        // katalog domowy leży na woluminie systemowym; dla innych woluminów skanujemy ich korzeń
        if scopePopup.indexOfSelectedItem == 0, vol.mount != "/" { rootPath = vol.mount }
        updateVolumeCard()
        scanning = true; cancelFlag = false
        scanButton.title = L("Zatrzymaj")
        progressLabel.stringValue = L("skanowanie…")
        progress.value = 0
        let volUsedBytes = max(1, vol.used)
        let started = Date()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let res = FastScanner.scan(rootPath, shouldCancel: { self?.cancelFlag ?? true }) { files, bytes in
                DispatchQueue.main.async {
                    self?.progressLabel.stringValue = "\(Fmt.number(UInt64(files))) " + L("plików") + " · \(Fmt.bytes(bytes))"
                    self?.progress.value = min(0.98, Double(bytes) / Double(volUsedBytes))
                }
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.scanning = false
                self.scanButton.title = L("Skanuj")
                self.result = res
                self.progress.value = 1
                var msg = "\(Fmt.number(UInt64(res.files))) " + L("plików") + " · \(Fmt.bytes(res.root.size))"
                msg += self.cancelFlag ? " (" + L("przerwano") + ")" : String(format: " · %.1f s", Date().timeIntervalSince(started))
                if res.deniedDirs > 0 { msg += " · \(res.deniedDirs) " + L("katalogów bez dostępu") }
                self.progressLabel.stringValue = msg
                self.show(res.root)
                self.refreshPanels()
            }
        }
    }

    static func scan(_ rootPath: String, usedHint: UInt64, shouldCancel: @escaping () -> Bool, progress: @escaping (Int, UInt64) -> Void) -> ScanResult {
        let root = FSNode(name: (rootPath as NSString).lastPathComponent.isEmpty ? rootPath : (rootPath as NSString).lastPathComponent, path: rootPath, isDir: true, parent: nil)
        let res = ScanResult(root: root)
        var dirs: [String: FSNode] = [rootPath: root]
        var largest: [(String, UInt64)] = []
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey]
        let skip: Set<String> = ["/System/Volumes", "/Volumes", "/dev", "/private/var/vm", "/Library/Developer/CoreSimulator/Volumes"]
        guard let en = FileManager.default.enumerator(at: URL(fileURLWithPath: rootPath), includingPropertiesForKeys: keys, options: [], errorHandler: { _, _ in true }) else { return res }
        var files = 0
        var bytes: UInt64 = 0
        var lastReport = Date()
        for case let url as URL in en {
            if shouldCancel() { break }
            let path = url.path
            if skip.contains(where: { path.hasPrefix($0) && path != rootPath }) { en.skipDescendants(); continue }
            guard let v = try? url.resourceValues(forKeys: Set(keys)) else { continue }
            if v.isSymbolicLink == true { en.skipDescendants(); continue }
            let parentPath = url.deletingLastPathComponent().path
            let parent = dirs[parentPath] ?? root
            if v.isDirectory == true {
                let n = FSNode(name: url.lastPathComponent, path: path, isDir: true, parent: parent)
                parent.children.append(n)
                dirs[path] = n
            } else {
                let size = UInt64(v.totalFileAllocatedSize ?? v.fileAllocatedSize ?? 0)
                files += 1; bytes += size
                let cat = FileCategory.of(path: path, ext: url.pathExtension)
                res.categories[cat, default: 0] += size
                if size >= 1_000_000 {
                    let n = FSNode(name: url.lastPathComponent, path: path, isDir: false, parent: parent); n.size = size
                    parent.children.append(n)
                    if largest.count < 200 || size > largest.last!.1 {
                        largest.append((path, size)); largest.sort { $0.1 > $1.1 }; if largest.count > 200 { largest.removeLast() }
                    }
                } else { parent.smallFiles += size; parent.smallCount += 1 }
                if Date().timeIntervalSince(lastReport) > 0.4 { lastReport = Date(); progress(files, bytes) }
            }
        }
        // sumowanie rozmiarów katalogów
        func total(_ n: FSNode) -> UInt64 {
            if !n.isDir { return n.size }
            var s = n.smallFiles
            for c in n.children { s += total(c) }
            n.size = s
            return s
        }
        _ = total(root)
        res.files = files
        res.dirs = dirs.values.filter { $0 !== root }.sorted { $0.size > $1.size }
        res.largestFiles = Array(largest.prefix(25))
        return res
    }

    private func show(_ n: FSNode) {
        current = n
        treemap.node = n
        breadcrumb.stringValue = n.path.replacingOccurrences(of: NSHomeDirectory(), with: "~") + " · " + Fmt.bytes(n.size)
        backButton.isEnabled = n.parent != nil
    }

    @objc private func zoomIn() { treemap.setZoom(treemap.zoom * 1.5) }
    @objc private func zoomOut() { treemap.setZoom(treemap.zoom / 1.5) }
    @objc private func zoomReset() { treemap.resetZoom() }

    private func updateZoomUI(_ z: CGFloat) {
        zoomLabel.stringValue = "\(Int((z * 100).rounded()))%"
        zoomOutButton.isEnabled = z > 1.001
        zoomResetButton.isEnabled = z > 1.001
        zoomInButton.isEnabled = z < 11.9
    }

    @objc private func goBack() { if let p = current?.parent { show(p) } }

    private func refreshPanels() {
        updateVolumeCard()
        typesStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        foldersStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        filesStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        guard let res = result else {
            donut.segments = []
            categoryBar.segments = []
            typesStack.addArrangedSubview(Label.make(L("Brak danych. Uruchom skanowanie."), size: 11.5, dim: true)); return
        }
        // pierścień i legenda: tylko kategorie, które faktycznie coś zajmują, od największej
        let used = FileCategory.allCases
            .map { ($0, Double(res.categories[$0] ?? 0)) }
            .filter { $0.1 > 0 }
            .sorted { $0.1 > $1.1 }
        let totalScanned = used.reduce(0) { $0 + $1.1 }
        donut.segments = used.map { .init(title: L($0.0.title), value: $0.1, color: $0.0.color) }
        donut.centerTitle = Fmt.bytes(UInt64(max(0, totalScanned)))
        donut.centerSubtitle = "\(res.files) " + L("plików")
        donut.needsDisplay = true
        categoryBar.segments = used.map { (color: $0.0.color, value: $0.1) }
        for (c, value) in used {
            let dot = ThemedView(); dot.layer?.cornerRadius = 5; dot.size(width: 10, height: 10); dot.layer?.backgroundColor = c.color.cgColor
            let l = Label.make(L(c.title), size: 12)
            let percent = totalScanned > 0 ? value / totalScanned * 100 : 0
            let r = Label.make(String(format: "%@  %.0f%%", Fmt.bytes(UInt64(value)), percent), size: 12, dim: true, mono: true)
            let row = hstack([dot, l, spacer(), r], spacing: 8)
            typesStack.addArrangedSubview(row); row.widthAnchor.constraint(equalTo: typesStack.widthAnchor).isActive = true
        }
        // największe foldery: bez potomków już wymienionych (unikalne gałęzie)
        var chosen: [FSNode] = []
        for d in res.dirs where chosen.count < 10 {
            if chosen.contains(where: { d.path.hasPrefix($0.path + "/") || $0.path.hasPrefix(d.path + "/") }) { continue }
            chosen.append(d)
        }
        for d in chosen {
            let b = NSButton(title: d.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"), target: self, action: #selector(openFolder(_:)))
            b.isBordered = false; b.font = Fonts.ui(11.5); b.alignment = .left; b.contentTintColor = P.network
            b.setContentCompressionResistancePriority(.defaultLow, for: .horizontal); b.lineBreakMode = .byTruncatingMiddle
            b.cell?.representedObject = d
            let r = Label.make(Fmt.bytes(d.size), size: 11.5, dim: true, mono: true)
            let row = hstack([b, spacer(), r], spacing: 8)
            foldersStack.addArrangedSubview(row); row.widthAnchor.constraint(equalTo: foldersStack.widthAnchor).isActive = true
        }
        for (path, size) in res.largestFiles.prefix(20) {
            let l = Label.make(path.replacingOccurrences(of: NSHomeDirectory(), with: "~"), size: 11.5); l.lineBreakMode = .byTruncatingMiddle
            l.toolTip = path
            let r = Label.make(Fmt.bytes(size), size: 11.5, dim: true, mono: true)
            let row = hstack([l, spacer(), r], spacing: 8)
            filesStack.addArrangedSubview(row); row.widthAnchor.constraint(equalTo: filesStack.widthAnchor).isActive = true
        }
    }

    @objc private func openFolder(_ sender: NSButton) { if let n = sender.cell?.representedObject as? FSNode { show(n) } }
}
