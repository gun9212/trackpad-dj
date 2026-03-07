import AppKit

/// Renders the Touch Lab: zone boundaries and live touch point visualization.
final class TouchLabView: NSView {

    var session: TouchSession = .empty {
        didSet { needsDisplay = true }
    }

    // MARK: - Init

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        // .indirect = trackpad touches (as opposed to direct stylus/screen touches)
        allowedTouchTypes = [.indirect]
        wantsRestingTouches = false
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        allowedTouchTypes = [.indirect]
        wantsRestingTouches = false
    }

    override var acceptsFirstResponder: Bool { true }

    // MARK: - Touch Events

    override func touchesBegan(with event: NSEvent) {
        var updated = session
        for touch in event.touches(matching: .began, in: self) {
            let tp = TouchPoint(
                identity: ObjectIdentifier(touch.identity as AnyObject),
                position: touch.normalizedPosition,
                timestamp: event.timestamp
            )
            updated = updated.adding(tp)
        }
        session = updated
    }

    override func touchesMoved(with event: NSEvent) {
        var updated = session
        for touch in event.touches(matching: .moved, in: self) {
            let tp = TouchPoint(
                identity: ObjectIdentifier(touch.identity as AnyObject),
                position: touch.normalizedPosition,
                timestamp: event.timestamp
            )
            updated = updated.updating(tp)
        }
        session = updated
    }

    override func touchesEnded(with event: NSEvent) {
        var updated = session
        for touch in event.touches(matching: .ended, in: self) {
            let id = ObjectIdentifier(touch.identity as AnyObject)
            updated = updated.removing(identity: id)
        }
        session = updated
    }

    override func touchesCancelled(with event: NSEvent) {
        session = .empty
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        drawBackground()
        drawZones()
        drawTouches()
        drawHUD()
    }

    // MARK: - Drawing Helpers

    private func drawBackground() {
        NSColor(white: 0.08, alpha: 1.0).setFill()
        bounds.fill()
    }

    private func drawZones() {
        for zone in ZoneLayout.all {
            let rect = viewRect(from: zone.rect)
            let color = zoneColor(for: zone.name)

            color.withAlphaComponent(0.12).setFill()
            NSBezierPath(rect: rect).fill()

            color.withAlphaComponent(0.45).setStroke()
            let border = NSBezierPath(rect: rect)
            border.lineWidth = 1.0
            border.stroke()

            drawLabel(zone.name.rawValue, in: rect, color: color)
        }
    }

    private func drawLabel(_ text: String, in rect: NSRect, color: NSColor) {
        let attrs: [NSAttributedString.Key: Any] = [
            .foregroundColor: color.withAlphaComponent(0.7),
            .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .medium),
        ]
        let str = NSAttributedString(string: text, attributes: attrs)
        let size = str.size()
        let point = NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2)
        str.draw(at: point)
    }

    private func drawTouches() {
        for (_, touch) in session.activeTouches {
            let center = viewPoint(from: touch.position)
            let zone = ZoneLayout.zone(for: touch.position)
            let color: NSColor = zone.map { zoneColor(for: $0.name) } ?? .white

            // Halo
            drawCircle(center: center, radius: 26, fill: color.withAlphaComponent(0.2), stroke: nil)
            // Dot
            drawCircle(center: center, radius: 6, fill: color, stroke: nil)

            // Coordinate readout
            let label = String(format: "%.2f, %.2f", touch.position.x, touch.position.y)
            let attrs: [NSAttributedString.Key: Any] = [
                .foregroundColor: NSColor.white.withAlphaComponent(0.65),
                .font: NSFont.monospacedSystemFont(ofSize: 9, weight: .regular),
            ]
            NSAttributedString(string: label, attributes: attrs)
                .draw(at: NSPoint(x: center.x + 30, y: center.y - 5))
        }
    }

    private func drawCircle(center: NSPoint, radius: CGFloat, fill: NSColor?, stroke: NSColor?) {
        let rect = NSRect(x: center.x - radius, y: center.y - radius,
                          width: radius * 2, height: radius * 2)
        let path = NSBezierPath(ovalIn: rect)
        if let fill { fill.setFill(); path.fill() }
        if let stroke { stroke.setStroke(); path.stroke() }
    }

    private func drawHUD() {
        let left = "Touch Lab"
        let right = "fingers: \(session.count)"
        let attrs: [NSAttributedString.Key: Any] = [
            .foregroundColor: NSColor.white.withAlphaComponent(0.35),
            .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .regular),
        ]
        NSAttributedString(string: left, attributes: attrs).draw(at: NSPoint(x: 8, y: bounds.height - 18))
        let rightStr = NSAttributedString(string: right, attributes: attrs)
        let rightX = bounds.width - rightStr.size().width - 8
        rightStr.draw(at: NSPoint(x: rightX, y: bounds.height - 18))
    }

    // MARK: - Coordinate Conversion

    /// Converts a normalized position (origin lower-left) to view points.
    private func viewPoint(from normalized: CGPoint) -> NSPoint {
        NSPoint(x: normalized.x * bounds.width, y: normalized.y * bounds.height)
    }

    private func viewRect(from normalizedRect: CGRect) -> NSRect {
        NSRect(
            x: normalizedRect.minX * bounds.width,
            y: normalizedRect.minY * bounds.height,
            width: normalizedRect.width * bounds.width,
            height: normalizedRect.height * bounds.height
        )
    }

    // MARK: - Zone Colors

    private func zoneColor(for name: Zone.Name) -> NSColor {
        switch name {
        case .topStrip:    return NSColor(red: 0.20, green: 0.80, blue: 0.90, alpha: 1)
        case .deckA:       return NSColor(red: 0.35, green: 0.65, blue: 1.00, alpha: 1)
        case .deckB:       return NSColor(red: 1.00, green: 0.55, blue: 0.25, alpha: 1)
        case .bottomStrip: return NSColor(red: 0.75, green: 0.35, blue: 0.95, alpha: 1)
        }
    }
}
