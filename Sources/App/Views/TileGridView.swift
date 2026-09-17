// TileGridView.swift - responsywna siatka kart z trybem edycji: przeciąganie i zmiana rozmiaru kafelków
import AppKit

final class TileGridView: NSView {
    struct Item {
        let id: String
        let title: String
        let view: NSView
        /// domyślna liczba zajmowanych kolumn
        let span: Int
        /// domyślna wysokość
        let height: CGFloat
    }

    var items: [Item] = [] { didSet { syncOrder(); rebuild() } }
    var hiddenIDs: Set<String> = [] { didSet { rebuild() } }
    var spacing: CGFloat = 14
    var minColumnWidth: CGFloat = 330
    private(set) var contentHeight: CGFloat = 0
    var onHeightChange: ((CGFloat) -> Void)?
    /// Wywoływane po każdej zmianie układu przez użytkownika (kolejność, rozpiętość, wysokość)
    var onLayoutChange: (() -> Void)?

    /// Tryb edycji: kafelki dostają uchwyty, a zwykłe kliknięcia w ich treść są wstrzymane
    var editing = false {
        didSet {
            rebuildOverlays()
            needsLayout = true
        }
    }

    private(set) var order: [String] = []
    private var spans: [String: Int] = [:]
    private var heights: [String: CGFloat] = [:]
    private var overlays: [String: TileOverlay] = [:]
    private var columns = 1
    private var columnWidth: CGFloat = 0

    override var isFlipped: Bool { true }

    // MARK: układ zapisany
    func applyLayout(order savedOrder: [String], spans savedSpans: [String: Int], heights savedHeights: [String: Double]) {
        if !savedOrder.isEmpty { order = savedOrder.filter { id in items.contains { $0.id == id } } }
        syncOrder()
        spans = savedSpans
        heights = savedHeights.mapValues { CGFloat($0) }
        needsLayout = true
    }

    var savedSpans: [String: Int] { spans }
    var savedHeights: [String: Double] { heights.mapValues { Double($0) } }

    private func syncOrder() {
        for item in items where !order.contains(item.id) { order.append(item.id) }
        order = order.filter { id in items.contains { $0.id == id } }
    }

    private func item(_ id: String) -> Item? { items.first { $0.id == id } }
    private func span(_ id: String) -> Int { spans[id] ?? item(id)?.span ?? 1 }
    private func height(_ id: String) -> CGFloat { heights[id] ?? item(id)?.height ?? 160 }

    private func rebuild() {
        for v in subviews where !(v is TileOverlay) { v.removeFromSuperview() }
        for id in order where !hiddenIDs.contains(id) {
            if let v = item(id)?.view { addSubview(v) }
        }
        rebuildOverlays()
        needsLayout = true
    }

    private func rebuildOverlays() {
        for o in overlays.values { o.removeFromSuperview() }
        overlays.removeAll()
        guard editing else { return }
        for id in order where !hiddenIDs.contains(id) {
            let o = TileOverlay(id: id, title: item(id)?.title ?? id)
            o.grid = self
            addSubview(o)
            overlays[id] = o
        }
    }

    override func layout() {
        super.layout()
        guard bounds.width > 1 else { return }
        columns = max(1, Int((bounds.width + spacing) / (minColumnWidth + spacing)))
        columnWidth = (bounds.width - spacing * CGFloat(columns - 1)) / CGFloat(columns)
        var col = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        for id in order where !hiddenIDs.contains(id) {
            guard let view = item(id)?.view else { continue }
            let s = min(max(1, span(id)), columns)
            if col + s > columns {
                col = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            let w = columnWidth * CGFloat(s) + spacing * CGFloat(s - 1)
            let frame = CGRect(x: CGFloat(col) * (columnWidth + spacing), y: y, width: w, height: height(id))
            view.frame = frame
            overlays[id]?.frame = frame
            rowHeight = max(rowHeight, height(id))
            col += s
            if col >= columns {
                col = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
        }
        let h = y + rowHeight
        if abs(h - contentHeight) > 0.5 {
            contentHeight = h
            onHeightChange?(h)
        }
    }

    // MARK: operacje edycji
    /// Przenosi kafelek pod wskazany punkt
    fileprivate func moveTile(_ id: String, to point: NSPoint) {
        let visible = order.filter { !hiddenIDs.contains($0) }
        guard let from = visible.firstIndex(of: id) else { return }
        var target = visible.count - 1
        for (i, other) in visible.enumerated() where other != id {
            if let f = item(other)?.view.frame, f.contains(point) { target = i; break }
        }
        guard target != from, let globalFrom = order.firstIndex(of: id) else { return }
        let movedID = order.remove(at: globalFrom)
        let targetID = visible[target]
        if let globalTarget = order.firstIndex(of: targetID) {
            order.insert(movedID, at: target > from ? globalTarget + 1 : globalTarget)
        } else {
            order.append(movedID)
        }
        needsLayout = true
        layoutSubtreeIfNeeded()
    }

    fileprivate func setSpan(_ id: String, width: CGFloat) {
        let raw = (width + spacing) / (columnWidth + spacing)
        spans[id] = min(max(1, Int(raw.rounded())), columns)
        needsLayout = true
        layoutSubtreeIfNeeded()
    }

    fileprivate func setHeight(_ id: String, _ h: CGFloat) {
        heights[id] = min(max(80, h), 720)
        needsLayout = true
        layoutSubtreeIfNeeded()
    }

    fileprivate func frameOf(_ id: String) -> CGRect { item(id)?.view.frame ?? .zero }
    fileprivate func finishEdit() { onLayoutChange?() }

    /// Przywraca układ domyślny
    func resetLayout() {
        spans.removeAll()
        heights.removeAll()
        order = items.map(\.id)
        needsLayout = true
        onLayoutChange?()
    }

    /// Menu z przełącznikami widoczności kart
    func visibilityMenu(target: AnyObject, action: Selector) -> NSMenu {
        let menu = NSMenu()
        for id in order {
            guard let item = item(id) else { continue }
            let mi = NSMenuItem(title: item.title, action: action, keyEquivalent: "")
            mi.state = hiddenIDs.contains(item.id) ? .off : .on
            mi.representedObject = item.id
            mi.target = target
            menu.addItem(mi)
        }
        return menu
    }
}

/// Warstwa edycji nad kafelkiem: przeciąganie za środek, zmiana rozmiaru za prawą i dolną krawędź
private final class TileOverlay: NSView {
    private enum Mode { case move, resizeWidth, resizeHeight, resizeBoth }
    weak var grid: TileGridView?
    private let id: String
    private let title: String
    private var mode: Mode = .move
    private var startPoint: NSPoint = .zero
    private var startFrame: CGRect = .zero
    private let edge: CGFloat = 16

    init(id: String, title: String) {
        self.id = id
        self.title = title
        super.init(frame: .zero)
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 1, dy: 1)
        P.accent(.cpu).alpha(0.10).setFill()
        NSBezierPath(roundedRect: r, xRadius: 12, yRadius: 12).fill()
        let path = NSBezierPath(roundedRect: r, xRadius: 12, yRadius: 12)
        path.lineWidth = 1.5
        path.setLineDash([6, 4], count: 2, phase: 0)
        P.accent(.cpu).alpha(0.9).setStroke()
        path.stroke()
        // uchwyt w prawym dolnym rogu
        let grip = NSRect(x: bounds.maxX - 18, y: bounds.maxY - 18, width: 12, height: 12)
        P.accent(.cpu).alpha(0.95).setFill()
        NSBezierPath(roundedRect: grip, xRadius: 3, yRadius: 3).fill()
        let label = NSAttributedString(string: title, attributes: [
            .font: Fonts.ui(11, .semibold), .foregroundColor: P.text,
        ])
        label.draw(at: NSPoint(x: bounds.minX + 12, y: bounds.minY + 10))
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
        addCursorRect(NSRect(x: bounds.maxX - edge, y: 0, width: edge, height: bounds.height), cursor: .resizeLeftRight)
        addCursorRect(NSRect(x: 0, y: bounds.maxY - edge, width: bounds.width, height: edge), cursor: .resizeUpDown)
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        startPoint = convert(event.locationInWindow, from: nil)
        startFrame = frame
        let nearRight = p.x > bounds.width - edge
        let nearBottom = p.y > bounds.height - edge
        mode = nearRight && nearBottom ? .resizeBoth : (nearRight ? .resizeWidth : (nearBottom ? .resizeHeight : .move))
    }

    override func mouseDragged(with event: NSEvent) {
        guard let grid else { return }
        let inGrid = grid.convert(event.locationInWindow, from: nil)
        switch mode {
        case .move:
            grid.moveTile(id, to: inGrid)
        case .resizeWidth:
            grid.setSpan(id, width: inGrid.x - startFrame.minX)
        case .resizeHeight:
            grid.setHeight(id, inGrid.y - startFrame.minY)
        case .resizeBoth:
            grid.setSpan(id, width: inGrid.x - startFrame.minX)
            grid.setHeight(id, inGrid.y - startFrame.minY)
        }
    }

    override func mouseUp(with event: NSEvent) { grid?.finishEdit() }
}
