import AppKit

/// Renders the Touch Lab: zone boundaries and live touch point visualization.
final class TouchLabView: NSView {

    var session: TouchSession = .empty {
        didSet { needsDisplay = true }
    }

    private var crossfader = CrossfaderState.center

    // MARK: - Audio Callbacks (set by ViewController)

    var onCrossfaderChanged: ((CrossfaderState) -> Void)?
    var onLoadDeck: ((AudioEngine.DeckID) -> Void)?
    var onTogglePlay: ((AudioEngine.DeckID) -> Void)?
    var onCue: ((AudioEngine.DeckID) -> Void)?
    /// deltaX: normalized horizontal movement per event (positive = right)
    var onNudge: ((AudioEngine.DeckID, Float) -> Void)?
    var onNudgeEnd: ((AudioEngine.DeckID) -> Void)?
    /// deltaY: normalized vertical movement per event (positive = up = open filter)
    var onFilter: ((AudioEngine.DeckID, Float) -> Void)?

    // MARK: - Deck Status (updated by ViewController)

    var deckALabel: String = "A: —" { didSet { needsDisplay = true } }
    var deckBLabel: String = "B: —" { didSet { needsDisplay = true } }

    // MARK: - Waveform Data (updated by ViewController)

    var waveformA: [Float] = [] { didSet { needsDisplay = true } }
    var waveformB: [Float] = [] { didSet { needsDisplay = true } }
    var progressA: Double = 0 { didSet { needsDisplay = true } }
    var progressB: Double = 0 { didSet { needsDisplay = true } }

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

    // MARK: - Keyboard Events

    override func keyDown(with event: NSEvent) {
        let cmd = event.modifierFlags.contains(.command)
        switch event.keyCode {
        case 123: // ←
            crossfader = cmd ? crossfader.snapped(to: .deckA)
                             : crossfader.nudged(by: -CrossfaderState.step)
            needsDisplay = true
            onCrossfaderChanged?(crossfader)
        case 124: // →
            crossfader = cmd ? crossfader.snapped(to: .deckB)
                             : crossfader.nudged(by: +CrossfaderState.step)
            needsDisplay = true
            onCrossfaderChanged?(crossfader)
        case 12: onLoadDeck?(.a)    // Q → load Deck A
        case 13: onLoadDeck?(.b)    // W → load Deck B
        case 0:  onTogglePlay?(.a)  // A → play/pause Deck A
        case 1:  onTogglePlay?(.b)  // S → play/pause Deck B
        case 6:  onCue?(.a)         // Z → cue Deck A
        case 7:  onCue?(.b)         // X → cue Deck B
        default:
            super.keyDown(with: event)
        }
    }

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

        // Count all active touches per deck zone to distinguish 1-finger (jog) from 2-finger (filter).
        let touchesInA = session.activeTouches.values.filter { ZoneLayout.zone(for: $0.position)?.name == .deckA }.count
        let touchesInB = session.activeTouches.values.filter { ZoneLayout.zone(for: $0.position)?.name == .deckB }.count

        for touch in event.touches(matching: .moved, in: self) {
            let id = ObjectIdentifier(touch.identity as AnyObject)
            let newPos = touch.normalizedPosition

            if let prevPos = session.activeTouches[id]?.position,
               let zone = ZoneLayout.zone(for: newPos) {
                let deltaX = Float(newPos.x - prevPos.x)
                let deltaY = Float(newPos.y - prevPos.y)
                switch zone.name {
                case .deckA:
                    if touchesInA >= 2 { onFilter?(.a, deltaY) }
                    else               { onNudge?(.a, deltaX) }
                case .deckB:
                    if touchesInB >= 2 { onFilter?(.b, deltaY) }
                    else               { onNudge?(.b, deltaX) }
                default: break
                }
            }

            let tp = TouchPoint(identity: id, position: newPos, timestamp: event.timestamp)
            updated = updated.updating(tp)
        }
        session = updated
    }

    override func touchesEnded(with event: NSEvent) {
        // Snapshot which deck zones had touches before rebuild.
        let hadA = session.activeTouches.values.contains { ZoneLayout.zone(for: $0.position)?.name == .deckA }
        let hadB = session.activeTouches.values.contains { ZoneLayout.zone(for: $0.position)?.name == .deckB }

        // Rebuild from still-active touches to avoid ObjectIdentifier
        // mismatches from existential re-boxing across events.
        var remaining: [ObjectIdentifier: TouchPoint] = [:]
        for touch in event.touches(matching: .touching, in: self) {
            let id = ObjectIdentifier(touch.identity as AnyObject)
            remaining[id] = TouchPoint(
                identity: id,
                position: touch.normalizedPosition,
                timestamp: event.timestamp
            )
        }
        session = TouchSession(activeTouches: remaining)

        // Reset nudge for decks that lost all their touches.
        let hasA = session.activeTouches.values.contains { ZoneLayout.zone(for: $0.position)?.name == .deckA }
        let hasB = session.activeTouches.values.contains { ZoneLayout.zone(for: $0.position)?.name == .deckB }
        if hadA && !hasA { onNudgeEnd?(.a) }
        if hadB && !hasB { onNudgeEnd?(.b) }
    }

    override func touchesCancelled(with event: NSEvent) {
        session = .empty
        onNudgeEnd?(.a)
        onNudgeEnd?(.b)
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        drawBackground()
        drawZones()
        drawWaveforms()
        drawCrossfaderIndicator()
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

    private func drawWaveforms() {
        if let zone = ZoneLayout.all.first(where: { $0.name == .deckA }) {
            drawWaveform(waveformA, progress: progressA, in: viewRect(from: zone.rect),
                         color: zoneColor(for: .deckA))
        }
        if let zone = ZoneLayout.all.first(where: { $0.name == .deckB }) {
            drawWaveform(waveformB, progress: progressB, in: viewRect(from: zone.rect),
                         color: zoneColor(for: .deckB))
        }
    }

    private func drawWaveform(_ samples: [Float], progress: Double, in rect: NSRect, color: NSColor) {
        guard samples.count > 1 else { return }

        let mid = rect.midY
        let halfH = rect.height * 0.4  // waveform uses 80% of zone height

        // Filled waveform shape
        let path = NSBezierPath()
        // Top half (forward pass)
        for (i, amp) in samples.enumerated() {
            let x = rect.minX + CGFloat(i) / CGFloat(samples.count) * rect.width
            let y = mid + CGFloat(amp) * halfH
            if i == 0 { path.move(to: NSPoint(x: x, y: y)) }
            else       { path.line(to: NSPoint(x: x, y: y)) }
        }
        // Bottom half (reverse pass)
        for i in stride(from: samples.count - 1, through: 0, by: -1) {
            let x = rect.minX + CGFloat(i) / CGFloat(samples.count) * rect.width
            let y = mid - CGFloat(samples[i]) * halfH
            path.line(to: NSPoint(x: x, y: y))
        }
        path.close()
        color.withAlphaComponent(0.25).setFill()
        path.fill()

        // Played region overlay (brighter)
        let playedWidth = rect.width * CGFloat(progress)
        let playedPath = NSBezierPath()
        for i in 0..<samples.count {
            let x = rect.minX + CGFloat(i) / CGFloat(samples.count) * rect.width
            guard x <= rect.minX + playedWidth else { break }
            let y = mid + CGFloat(samples[i]) * halfH
            if i == 0 { playedPath.move(to: NSPoint(x: x, y: y)) }
            else       { playedPath.line(to: NSPoint(x: x, y: y)) }
        }
        for i in stride(from: samples.count - 1, through: 0, by: -1) {
            let x = rect.minX + CGFloat(i) / CGFloat(samples.count) * rect.width
            guard x <= rect.minX + playedWidth else { continue }
            playedPath.line(to: NSPoint(x: x, y: mid - CGFloat(samples[i]) * halfH))
        }
        playedPath.close()
        color.withAlphaComponent(0.55).setFill()
        playedPath.fill()

        // Playhead vertical line
        let headX = rect.minX + CGFloat(progress) * rect.width
        let headPath = NSBezierPath()
        headPath.move(to: NSPoint(x: headX, y: rect.minY + 4))
        headPath.line(to: NSPoint(x: headX, y: rect.maxY - 4))
        headPath.lineWidth = 1.5
        NSColor.white.withAlphaComponent(0.9).setStroke()
        headPath.stroke()
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
        let attrs: [NSAttributedString.Key: Any] = [
            .foregroundColor: NSColor.white.withAlphaComponent(0.35),
            .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .regular),
        ]
        let top = bounds.height - 18
        NSAttributedString(string: "Touch Lab", attributes: attrs)
            .draw(at: NSPoint(x: 8, y: top))

        let fingerStr = NSAttributedString(string: "fingers: \(session.count)", attributes: attrs)
        let fingerX = bounds.width - fingerStr.size().width - 8
        fingerStr.draw(at: NSPoint(x: fingerX, y: top))

        // Deck status (bottom-left)
        let deckAttrs: [NSAttributedString.Key: Any] = [
            .foregroundColor: NSColor.white.withAlphaComponent(0.55),
            .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .regular),
        ]
        NSAttributedString(string: deckALabel, attributes: deckAttrs).draw(at: NSPoint(x: 8, y: 8))
        let bStr = NSAttributedString(string: deckBLabel, attributes: deckAttrs)
        let bX = bounds.width - bStr.size().width - 8
        bStr.draw(at: NSPoint(x: bX, y: 8))

        // Key hint (center bottom)
        let hint = "Q/W: load  A/S: play  Z/X: cue  ←/→: xfade"
        let hintAttrs: [NSAttributedString.Key: Any] = [
            .foregroundColor: NSColor.white.withAlphaComponent(0.2),
            .font: NSFont.monospacedSystemFont(ofSize: 9, weight: .regular),
        ]
        let hintStr = NSAttributedString(string: hint, attributes: hintAttrs)
        let hintX = (bounds.width - hintStr.size().width) / 2
        hintStr.draw(at: NSPoint(x: hintX, y: 8))
    }

    private func drawCrossfaderIndicator() {
        guard let stripZone = ZoneLayout.all.first(where: { $0.name == .bottomStrip }) else { return }
        let stripRect = viewRect(from: stripZone.rect)
        let xPos = stripRect.minX + CGFloat(crossfader.value) * stripRect.width

        // White vertical line at current crossfader position
        let line = NSBezierPath()
        line.move(to: NSPoint(x: xPos, y: stripRect.minY + 4))
        line.line(to: NSPoint(x: xPos, y: stripRect.maxY - 4))
        line.lineWidth = 2.0
        NSColor.white.withAlphaComponent(0.85).setStroke()
        line.stroke()

        // Value readout
        let label = String(format: "XF: %.2f", crossfader.value)
        let attrs: [NSAttributedString.Key: Any] = [
            .foregroundColor: NSColor.white.withAlphaComponent(0.6),
            .font: NSFont.monospacedSystemFont(ofSize: 9, weight: .regular),
        ]
        NSAttributedString(string: label, attributes: attrs)
            .draw(at: NSPoint(x: stripRect.minX + 6, y: stripRect.minY + 4))
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
