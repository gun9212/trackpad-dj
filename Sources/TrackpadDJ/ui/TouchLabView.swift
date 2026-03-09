import AppKit

/// Renders the Touch Lab: zone boundaries and live touch point visualization.
final class TouchLabView: NSView {

    var session: TouchSession = .empty {
        didSet { needsDisplay = true }
    }

    private var crossfader = CrossfaderState.center
    private var crossfaderMode: Int = 1                          // 0=A, 1=both, 2=B
    private let crossfaderModeValues: [Float] = [0.0, 0.5, 1.0]

    // Key hold directions: -1, 0, +1  (driven by 60fps timer)
    private var volumeKeyA: Float = 0
    private var volumeKeyB: Float = 0
    private var filterKeyA: Float = 0
    private var filterKeyB: Float = 0
    private var nudgeKeyA:  Float = 0
    private var nudgeKeyB:  Float = 0

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
    /// deltaY: normalized vertical movement per event (positive = up = louder)
    var onVolume: ((AudioEngine.DeckID, Float) -> Void)?
    /// rate: playback rate (1.0 = normal, negative = reverse, 0 = freeze). Called on 1-finger touch in deck zone.
    var onScratch: ((AudioEngine.DeckID, Double) -> Void)?
    /// Called when all fingers lift from a deck zone.
    var onScratchEnd: ((AudioEngine.DeckID) -> Void)?

    // MARK: - Deck Status (updated by ViewController)

    var deckALabel: String = "A: —" { didSet { needsDisplay = true } }
    var deckBLabel: String = "B: —" { didSet { needsDisplay = true } }

    // MARK: - Waveform Data (updated by ViewController)

    var waveformA: [Float] = [] { didSet { needsDisplay = true } }
    var waveformB: [Float] = [] { didSet { needsDisplay = true } }
    var progressA: Double = 0 { didSet { needsDisplay = true } }
    var progressB: Double = 0 { didSet { needsDisplay = true } }
    var extendedProgressA: Double = 0 { didSet { needsDisplay = true } }
    var extendedProgressB: Double = 0 { didSet { needsDisplay = true } }
    var durationA: Double = 0 { didSet { needsDisplay = true } }
    var durationB: Double = 0 { didSet { needsDisplay = true } }
    var faderA: Float = 1.0 { didSet { needsDisplay = true } }
    var faderB: Float = 1.0 { didSet { needsDisplay = true } }

    // Accumulated filter level [0, 1]. 1.0 = fully open (default).
    private var filterLevelA: Float = 1.0
    private var filterLevelB: Float = 1.0

    // Scratch state — tracked locally for visual feedback.
    private var scratchRateA: Double = 0
    private var scratchRateB: Double = 0
    private var isScratchActiveA: Bool = false
    private var isScratchActiveB: Bool = false

    // MARK: - Init

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        allowedTouchTypes = [.indirect]
        wantsRestingTouches = false
        startKeyHoldTimer()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        allowedTouchTypes = [.indirect]
        wantsRestingTouches = false
        startKeyHoldTimer()
    }

    override var acceptsFirstResponder: Bool { true }

    // MARK: - Keyboard Events

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        // Crossfader: 3-mode snap (A=0 / both=0.5 / B=1). One-shot, no repeat.
        case 123: // ←
            if !event.isARepeat {
                crossfaderMode = max(0, crossfaderMode - 1)
                crossfader = CrossfaderState(value: crossfaderModeValues[crossfaderMode])
                needsDisplay = true
                onCrossfaderChanged?(crossfader)
            }
        case 124: // →
            if !event.isARepeat {
                crossfaderMode = min(2, crossfaderMode + 1)
                crossfader = CrossfaderState(value: crossfaderModeValues[crossfaderMode])
                needsDisplay = true
                onCrossfaderChanged?(crossfader)
            }
        // One-shot transport
        case 12: if !event.isARepeat { onLoadDeck?(.a) }   // Q
        case 13: if !event.isARepeat { onLoadDeck?(.b) }   // W
        case 0:  if !event.isARepeat { onTogglePlay?(.a) } // A
        case 1:  if !event.isARepeat { onTogglePlay?(.b) } // S
        case 6:  if !event.isARepeat { onCue?(.a) }        // Z
        case 7:  if !event.isARepeat { onCue?(.b) }        // X
        // Hold keys: set direction, 60fps timer drives the callbacks
        case 14: volumeKeyA = +1  // E
        case 2:  volumeKeyA = -1  // D
        case 15: volumeKeyB = +1  // R
        case 3:  volumeKeyB = -1  // F
        case 17: filterKeyA = +1  // T
        case 5:  filterKeyA = -1  // G
        case 16: filterKeyB = +1  // Y
        case 4:  filterKeyB = -1  // H
        case 126: nudgeKeyA = +1  // up arrow
        case 125: nudgeKeyA = -1  // down arrow
        case 34:  nudgeKeyB = +1  // I
        case 40:  nudgeKeyB = -1  // K
        default:
            super.keyDown(with: event)
        }
    }

    override func keyUp(with event: NSEvent) {
        switch event.keyCode {
        case 14, 2:    volumeKeyA = 0
        case 15, 3:    volumeKeyB = 0
        case 17, 5:    filterKeyA = 0
        case 16, 4:    filterKeyB = 0
        case 126, 125: nudgeKeyA = 0
        case 34, 40:   nudgeKeyB = 0
        default: super.keyUp(with: event)
        }
    }

    // MARK: - Key Hold Timer

    private func startKeyHoldTimer() {
        Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            self?.applyHeldKeys()
        }
    }

    private func applyHeldKeys() {
        if volumeKeyA != 0 { onVolume?(.a, volumeKeyA * 0.008) }
        if volumeKeyB != 0 { onVolume?(.b, volumeKeyB * 0.008) }
        if filterKeyA != 0 {
            filterLevelA = max(0, min(1, filterLevelA + filterKeyA * 0.003))
            onFilter?(.a, filterKeyA * 0.003)
        }
        if filterKeyB != 0 {
            filterLevelB = max(0, min(1, filterLevelB + filterKeyB * 0.003))
            onFilter?(.b, filterKeyB * 0.003)
        }
        if nudgeKeyA != 0 { onNudge?(.a, nudgeKeyA * 0.001) }
        if nudgeKeyB != 0 { onNudge?(.b, nudgeKeyB * 0.001) }
    }

    // MARK: - Touch Events

    override func touchesBegan(with event: NSEvent) {
        var updated = session
        for touch in event.touches(matching: .began, in: self) {
            let pos = touch.normalizedPosition
            let tp = TouchPoint(
                identity: ObjectIdentifier(touch.identity as AnyObject),
                position: pos,
                timestamp: event.timestamp
            )
            // Freeze deck on first contact — like putting a hand on a record.
            if let zone = ZoneLayout.zone(for: pos) {
                let isFirstInZone = !session.activeTouches.values.contains {
                    ZoneLayout.zone(for: $0.position)?.name == zone.name
                }
                if isFirstInZone {
                    switch zone.name {
                    case .deckA:
                        isScratchActiveA = true; scratchRateA = 0
                        onScratch?(.a, 0)
                    case .deckB:
                        isScratchActiveB = true; scratchRateB = 0
                        onScratch?(.b, 0)
                    default: break
                    }
                }
            }
            updated = updated.adding(tp)
        }
        session = updated
    }

    override func touchesMoved(with event: NSEvent) {
        var updated = session

        for touch in event.touches(matching: .moved, in: self) {
            let id = ObjectIdentifier(touch.identity as AnyObject)
            let newPos = touch.normalizedPosition

            if let prevPos = session.activeTouches[id]?.position,
               let zone = ZoneLayout.zone(for: newPos) {
                let deltaX = Float(newPos.x - prevPos.x)
                let deltaY = Float(newPos.y - prevPos.y)
                switch zone.name {
                case .deckA:
                    // 우세 축만 적용 — 대각선 움직임 시 양쪽 동시 발동 방지.
                    if abs(deltaY) >= abs(deltaX) {
                        let rate = Double(deltaY) * 200.0
                        scratchRateA = rate
                        isScratchActiveA = true
                        onScratch?(.a, rate)
                    } else {
                        filterLevelA = max(0, min(1, filterLevelA + deltaX))
                        onFilter?(.a, deltaX)
                    }
                case .deckB:
                    if abs(deltaY) >= abs(deltaX) {
                        let rate = Double(deltaY) * 200.0
                        scratchRateB = rate
                        isScratchActiveB = true
                        onScratch?(.b, rate)
                    } else {
                        filterLevelB = max(0, min(1, filterLevelB + deltaX))
                        onFilter?(.b, deltaX)
                    }
                case .topStrip:
                    let deck: AudioEngine.DeckID = newPos.x < 0.5 ? .a : .b
                    onVolume?(deck, deltaY)
                case .bottomStrip:
                    crossfader = crossfader.nudged(by: deltaX)
                    needsDisplay = true
                    onCrossfaderChanged?(crossfader)
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

        // Reset nudge/scratch for decks that lost all their touches.
        let hasA = session.activeTouches.values.contains { ZoneLayout.zone(for: $0.position)?.name == .deckA }
        let hasB = session.activeTouches.values.contains { ZoneLayout.zone(for: $0.position)?.name == .deckB }
        if hadA && !hasA {
            isScratchActiveA = false; scratchRateA = 0
            onNudgeEnd?(.a); onScratchEnd?(.a)
        }
        if hadB && !hasB {
            isScratchActiveB = false; scratchRateB = 0
            onNudgeEnd?(.b); onScratchEnd?(.b)
        }
    }

    override func touchesCancelled(with event: NSEvent) {
        session = .empty
        isScratchActiveA = false; isScratchActiveB = false
        scratchRateA = 0; scratchRateB = 0
        onNudgeEnd?(.a); onNudgeEnd?(.b)
        onScratchEnd?(.a); onScratchEnd?(.b)
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        drawBackground()
        drawZones()
        drawWaveforms()
        drawDeckHeaders()
        drawFilterIndicators()
        drawFaders()
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
            drawWaveform(waveformA, progress: extendedProgressA,
                         scratchRate: scratchRateA, isScratchActive: isScratchActiveA,
                         in: viewRect(from: zone.rect), color: zoneColor(for: .deckA))
        }
        if let zone = ZoneLayout.all.first(where: { $0.name == .deckB }) {
            drawWaveform(waveformB, progress: extendedProgressB,
                         scratchRate: scratchRateB, isScratchActive: isScratchActiveB,
                         in: viewRect(from: zone.rect), color: zoneColor(for: .deckB))
        }
    }

    /// Scrolling waveform: playhead fixed at center, waveform scrolls with playback.
    private func drawWaveform(_ samples: [Float], progress: Double,
                               scratchRate: Double, isScratchActive: Bool,
                               in rect: NSRect, color: NSColor) {
        guard samples.count > 1 else { return }

        // Leave room for deck header (top 22px) and filter bar (right 15px).
        let waveRect = NSRect(x: rect.minX, y: rect.minY,
                              width: rect.width - 15, height: rect.height - 22)
        let mid = waveRect.midY
        let halfH = waveRect.height * 0.38

        // Subtle background highlight when scratch is active.
        if isScratchActive {
            color.withAlphaComponent(0.07).setFill()
            NSBezierPath(rect: waveRect).fill()
        }

        let visibleHalf = 150          // samples visible on each side of center
        let total = visibleHalf * 2
        let center = Int(progress * Double(samples.count))

        func amp(at idx: Int) -> CGFloat {
            guard idx >= 0 && idx < samples.count else { return 0 }
            return CGFloat(samples[idx])
        }
        func xFor(offset: Int) -> CGFloat {
            waveRect.minX + CGFloat(offset) / CGFloat(total) * waveRect.width
        }

        // Played region (left half — brighter).
        let playedPath = NSBezierPath()
        for off in 0...visibleHalf {
            let x = xFor(offset: off)
            let y = mid + amp(at: center - visibleHalf + off) * halfH
            if off == 0 { playedPath.move(to: NSPoint(x: x, y: y)) }
            else         { playedPath.line(to: NSPoint(x: x, y: y)) }
        }
        for off in stride(from: visibleHalf, through: 0, by: -1) {
            let x = xFor(offset: off)
            playedPath.line(to: NSPoint(x: x, y: mid - amp(at: center - visibleHalf + off) * halfH))
        }
        playedPath.close()
        color.withAlphaComponent(0.60).setFill()
        playedPath.fill()

        // Upcoming region (right half — dimmer).
        let upcomingPath = NSBezierPath()
        for off in visibleHalf...total {
            let x = xFor(offset: off)
            let y = mid + amp(at: center - visibleHalf + off) * halfH
            if off == visibleHalf { upcomingPath.move(to: NSPoint(x: x, y: y)) }
            else                  { upcomingPath.line(to: NSPoint(x: x, y: y)) }
        }
        for off in stride(from: total, through: visibleHalf, by: -1) {
            let x = xFor(offset: off)
            upcomingPath.line(to: NSPoint(x: x, y: mid - amp(at: center - visibleHalf + off) * halfH))
        }
        upcomingPath.close()
        color.withAlphaComponent(0.25).setFill()
        upcomingPath.fill()

        // Center playhead — yellow when scratching, white when playing normally.
        let headColor: NSColor = isScratchActive ? .systemYellow : .white
        let headPath = NSBezierPath()
        headPath.move(to: NSPoint(x: waveRect.midX, y: waveRect.minY + 4))
        headPath.line(to: NSPoint(x: waveRect.midX, y: waveRect.maxY - 4))
        headPath.lineWidth = isScratchActive ? 2.0 : 1.5
        headColor.withAlphaComponent(0.9).setStroke()
        headPath.stroke()

        // Scratch rate arrow below playhead.
        if isScratchActive && abs(scratchRate) > 0.05 {
            drawScratchArrow(rate: scratchRate,
                             at: NSPoint(x: waveRect.midX, y: waveRect.minY + 10),
                             color: color)
        }
    }

    private func drawScratchArrow(rate: Double, at center: NSPoint, color: NSColor) {
        let size = min(14, CGFloat(abs(rate)) * 5)
        let dir: CGFloat = rate > 0 ? 1 : -1
        let arrow = NSBezierPath()
        arrow.move(to: NSPoint(x: center.x + dir * size, y: center.y))
        arrow.line(to: NSPoint(x: center.x - dir * size * 0.5, y: center.y + size * 0.5))
        arrow.line(to: NSPoint(x: center.x - dir * size * 0.5, y: center.y - size * 0.5))
        arrow.close()
        color.withAlphaComponent(0.85).setFill()
        arrow.fill()
    }

    private func drawTouches() {
        for (_, touch) in session.activeTouches {
            let center = viewPoint(from: touch.position)
            let zone = ZoneLayout.zone(for: touch.position)
            let color: NSColor = zone.map { zoneColor(for: $0.name) } ?? .white
            drawCircle(center: center, radius: 26, fill: color.withAlphaComponent(0.2), stroke: nil)
            drawCircle(center: center, radius: 6, fill: color, stroke: nil)
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
        // Key hint at bottom center
        let hint = "Q/W:load  A/S:play  Z/X:cue  E·D/R·F:vol  T·G/Y·H:filter  ↑·↓/I·K:nudge  ←/→:xfade"
        let hintAttrs: [NSAttributedString.Key: Any] = [
            .foregroundColor: NSColor.white.withAlphaComponent(0.2),
            .font: NSFont.monospacedSystemFont(ofSize: 9, weight: .regular),
        ]
        let hintStr = NSAttributedString(string: hint, attributes: hintAttrs)
        let hintX = (bounds.width - hintStr.size().width) / 2
        hintStr.draw(at: NSPoint(x: hintX, y: 8))
    }

    private func drawFaders() {
        guard let strip = ZoneLayout.all.first(where: { $0.name == .topStrip }) else { return }
        let rect = viewRect(from: strip.rect)
        let midX = rect.midX

        // Deck A fader — left half
        let aRect = NSRect(x: rect.minX + 4, y: rect.minY + 4,
                           width: rect.width / 2 - 8, height: rect.height - 8)
        drawFaderBar(in: aRect, level: CGFloat(faderA), color: zoneColor(for: .deckA), label: "VOL A")

        // Deck B fader — right half
        let bRect = NSRect(x: midX + 4, y: rect.minY + 4,
                           width: rect.width / 2 - 8, height: rect.height - 8)
        drawFaderBar(in: bRect, level: CGFloat(faderB), color: zoneColor(for: .deckB), label: "VOL B")
    }

    private func drawFaderBar(in rect: NSRect, level: CGFloat, color: NSColor, label: String) {
        // Track background
        color.withAlphaComponent(0.1).setFill()
        NSBezierPath(rect: rect).fill()

        // Filled level bar
        let fillH = rect.height * level
        let fillRect = NSRect(x: rect.minX, y: rect.minY, width: rect.width, height: fillH)
        color.withAlphaComponent(0.5).setFill()
        NSBezierPath(rect: fillRect).fill()

        // Label + value
        let text = String(format: "%@ %.0f%%", label, level * 100)
        let attrs: [NSAttributedString.Key: Any] = [
            .foregroundColor: color.withAlphaComponent(0.8),
            .font: NSFont.monospacedSystemFont(ofSize: 9, weight: .regular),
        ]
        let str = NSAttributedString(string: text, attributes: attrs)
        let pt = NSPoint(x: rect.minX + 3, y: rect.midY - str.size().height / 2)
        str.draw(at: pt)
    }

    private func drawCrossfaderIndicator() {
        guard let stripZone = ZoneLayout.all.first(where: { $0.name == .bottomStrip }) else { return }
        let stripRect = viewRect(from: stripZone.rect)
        let color = zoneColor(for: .bottomStrip)

        // A / A+B / B mode labels — highlight active mode
        let modeLabels = ["A", "A+B", "B"]
        let segW = stripRect.width / 3
        for (i, label) in modeLabels.enumerated() {
            let segRect = NSRect(x: stripRect.minX + CGFloat(i) * segW,
                                 y: stripRect.minY, width: segW, height: stripRect.height)
            let isActive = i == crossfaderMode
            if isActive {
                color.withAlphaComponent(0.25).setFill()
                NSBezierPath(rect: segRect).fill()
            }
            let alpha: CGFloat = isActive ? 0.95 : 0.35
            let attrs: [NSAttributedString.Key: Any] = [
                .foregroundColor: color.withAlphaComponent(alpha),
                .font: NSFont.monospacedSystemFont(ofSize: isActive ? 12 : 10,
                                                    weight: isActive ? .bold : .regular),
            ]
            let str = NSAttributedString(string: label, attributes: attrs)
            let pt = NSPoint(x: segRect.midX - str.size().width / 2,
                             y: segRect.midY - str.size().height / 2)
            str.draw(at: pt)
        }

        // Playhead line at exact crossfader position
        let xPos = stripRect.minX + CGFloat(crossfader.value) * stripRect.width
        let line = NSBezierPath()
        line.move(to: NSPoint(x: xPos, y: stripRect.minY + 2))
        line.line(to: NSPoint(x: xPos, y: stripRect.maxY - 2))
        line.lineWidth = 2.0
        NSColor.white.withAlphaComponent(0.7).setStroke()
        line.stroke()
    }

    // MARK: - Deck Headers

    private func drawDeckHeaders() {
        if let zone = ZoneLayout.all.first(where: { $0.name == .deckA }) {
            drawDeckHeader(label: deckALabel, progress: progressA, duration: durationA,
                           in: viewRect(from: zone.rect), color: zoneColor(for: .deckA))
        }
        if let zone = ZoneLayout.all.first(where: { $0.name == .deckB }) {
            drawDeckHeader(label: deckBLabel, progress: progressB, duration: durationB,
                           in: viewRect(from: zone.rect), color: zoneColor(for: .deckB))
        }
    }

    private func drawDeckHeader(label: String, progress: Double, duration: Double,
                                 in rect: NSRect, color: NSColor) {
        let headerH: CGFloat = 20
        let headerRect = NSRect(x: rect.minX, y: rect.maxY - headerH,
                                width: rect.width, height: headerH)

        // Track name + play state (left side)
        let nameAttrs: [NSAttributedString.Key: Any] = [
            .foregroundColor: color.withAlphaComponent(0.9),
            .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .medium),
        ]
        NSAttributedString(string: label, attributes: nameAttrs)
            .draw(at: NSPoint(x: headerRect.minX + 6, y: headerRect.minY + 3))

        // Time display (right side): elapsed / total
        guard duration > 0 else { return }
        let elapsed = progress * duration
        let remaining = duration - elapsed
        let timeStr = "-\(formatTime(remaining))  /  \(formatTime(duration))"
        let timeAttrs: [NSAttributedString.Key: Any] = [
            .foregroundColor: color.withAlphaComponent(0.6),
            .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .regular),
        ]
        let timeStrAttr = NSAttributedString(string: timeStr, attributes: timeAttrs)
        let timeX = headerRect.maxX - timeStrAttr.size().width - 6
        timeStrAttr.draw(at: NSPoint(x: timeX, y: headerRect.minY + 4))
    }

    private func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "--:--" }
        let s = Int(seconds)
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    // MARK: - Filter Indicators

    private func drawFilterIndicators() {
        if let zone = ZoneLayout.all.first(where: { $0.name == .deckA }) {
            drawFilterBar(level: filterLevelA, in: viewRect(from: zone.rect),
                          color: zoneColor(for: .deckA))
        }
        if let zone = ZoneLayout.all.first(where: { $0.name == .deckB }) {
            drawFilterBar(level: filterLevelB, in: viewRect(from: zone.rect),
                          color: zoneColor(for: .deckB))
        }
    }

    private func drawFilterBar(level: Float, in rect: NSRect, color: NSColor) {
        let barW: CGFloat = 6
        let barX = rect.maxX - barW - 3
        let barRect = NSRect(x: barX, y: rect.minY + 4, width: barW, height: rect.height - 8)

        // Track
        color.withAlphaComponent(0.1).setFill()
        NSBezierPath(rect: barRect).fill()

        // Fill
        let fillH = barRect.height * CGFloat(level)
        let fillRect = NSRect(x: barRect.minX, y: barRect.minY, width: barW, height: fillH)
        color.withAlphaComponent(0.5).setFill()
        NSBezierPath(rect: fillRect).fill()

        // Label
        let attrs: [NSAttributedString.Key: Any] = [
            .foregroundColor: color.withAlphaComponent(0.5),
            .font: NSFont.monospacedSystemFont(ofSize: 7, weight: .regular),
        ]
        NSAttributedString(string: "F", attributes: attrs)
            .draw(at: NSPoint(x: barX + 1, y: barRect.maxY + 2))
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
