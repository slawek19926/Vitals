// ChartViews.swift - pierścień i pasek warstwowy używane w prezentacji miejsca na dysku
import AppKit

/// Wykres pierścieniowy z podświetlaniem segmentu pod kursorem
final class DonutChartView: NSView {
    struct Segment {
        let title: String
        let value: Double
        let color: NSColor
    }

    var segments: [Segment] = [] { didSet { needsDisplay = true } }
    /// Tekst w środku, gdy kursor jest poza wykresem
    var centerTitle = ""
    var centerSubtitle = ""
    private var hoverIndex: Int? { didSet { needsDisplay = true } }
    private var tracking: NSTrackingArea?

    override var isFlipped: Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                               owner: self, userInfo: nil)
        addTrackingArea(t)
        tracking = t
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let total = segments.reduce(0) { $0 + $1.value }
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let radius = min(bounds.width, bounds.height) / 2 - 4
        let inner = radius * 0.62
        guard total > 0, radius > 10 else { return }

        var start = -CGFloat.pi / 2
        for (i, seg) in segments.enumerated() {
            let angle = CGFloat(seg.value / total) * .pi * 2
            let highlighted = hoverIndex == i
            let r = highlighted ? radius : radius - 3
            ctx.beginPath()
            ctx.addArc(center: center, radius: r, startAngle: start, endAngle: start + angle, clockwise: false)
            ctx.addArc(center: center, radius: inner, startAngle: start + angle, endAngle: start, clockwise: true)
            ctx.closePath()
            ctx.setFillColor(seg.color.alpha(highlighted ? 1 : 0.85).cgColor)
            ctx.fillPath()
            start += angle
        }

        // opis w środku
        let title: String
        let subtitle: String
        if let i = hoverIndex, i < segments.count {
            title = Fmt.bytes(UInt64(max(0, segments[i].value)))
            subtitle = segments[i].title
        } else {
            title = centerTitle
            subtitle = centerSubtitle
        }
        let t = title as NSString
        let tAttrs: [NSAttributedString.Key: Any] = [.font: Fonts.ui(15, .semibold), .foregroundColor: P.text]
        let tSize = t.size(withAttributes: tAttrs)
        t.draw(at: NSPoint(x: center.x - tSize.width / 2, y: center.y - tSize.height / 2 - 7), withAttributes: tAttrs)
        let s = subtitle as NSString
        let sAttrs: [NSAttributedString.Key: Any] = [.font: Fonts.ui(10.5), .foregroundColor: P.textDim]
        let sSize = s.size(withAttributes: sAttrs)
        s.draw(at: NSPoint(x: center.x - sSize.width / 2, y: center.y + tSize.height / 2 - 6), withAttributes: sAttrs)
    }

    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let dx = p.x - center.x, dy = p.y - center.y
        let dist = sqrt(dx * dx + dy * dy)
        let radius = min(bounds.width, bounds.height) / 2 - 4
        guard dist < radius, dist > radius * 0.62 else { hoverIndex = nil; return }
        var angle = atan2(dy, dx) + .pi / 2
        if angle < 0 { angle += .pi * 2 }
        let total = segments.reduce(0) { $0 + $1.value }
        guard total > 0 else { return }
        var acc = 0.0
        for (i, seg) in segments.enumerated() {
            acc += seg.value
            if angle <= CGFloat(acc / total) * .pi * 2 { hoverIndex = i; return }
        }
        hoverIndex = segments.isEmpty ? nil : segments.count - 1
    }

    override func mouseExited(with event: NSEvent) { hoverIndex = nil }
}

/// Poziomy pasek złożony z kolorowych części (np. udział kategorii plików)
final class StackedBarView: NSView {
    var segments: [(color: NSColor, value: Double)] = [] { didSet { needsDisplay = true } }
    var trackColor: NSColor?

    override func draw(_ dirtyRect: NSRect) {
        let radius = min(6, bounds.height / 2)
        let total = segments.reduce(0) { $0 + $1.value }
        (trackColor ?? P.border.alpha(P.isDark ? 0.35 : 0.5)).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()
        guard total > 0 else { return }
        NSGraphicsContext.current?.saveGraphicsState()
        NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).addClip()
        var x: CGFloat = 0
        for seg in segments {
            let w = bounds.width * CGFloat(seg.value / total)
            seg.color.setFill()
            NSRect(x: x, y: 0, width: max(1, w), height: bounds.height).fill()
            x += w
        }
        NSGraphicsContext.current?.restoreGraphicsState()
    }
}
