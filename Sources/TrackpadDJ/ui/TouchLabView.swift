import AppKit

/// Renders the Touch Lab: zone boundaries and live touch point visualization.
@MainActor
final class TouchLabView: NSView {

    private(set) var session: TouchSession = .empty {
        didSet { needsDisplay = true }
    }

    private var gestureStateMachine = GestureStateMachine()
    private var keyboardStateMachine = KeyboardStateMachine()
    private var touchIDs: [NSObject: TouchID] = [:]
    private var nextTouchID: UInt64 = 1
    private var inputTimer: Timer?
    private weak var observedWindow: NSWindow?

    private var crossfader = CrossfaderState.center
    private let crossfaderModeValues: [Float] = [0.0, 0.5, 1.0]

    // MARK: - Action Callback (set by ViewController)

    var onAction: ((DJAction) -> Void)?

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
    var hotCuesA: [Double?] = Array(repeating: nil, count: 4) { didSet { needsDisplay = true } }
    var hotCuesB: [Double?] = Array(repeating: nil, count: 4) { didSet { needsDisplay = true } }
    var durationA: Double = 0 { didSet { needsDisplay = true } }
    var durationB: Double = 0 { didSet { needsDisplay = true } }
    var faderA: Float = 1.0 { didSet { needsDisplay = true } }
    var faderB: Float = 1.0 { didSet { needsDisplay = true } }

    // Accumulated filter level [0, 1]. 1.0 = fully open (default).
    private var filterLevelA: Float = 1.0
    private var filterLevelB: Float = 1.0

    // BPM tap state — purely local, no audio-side dependency.
    private var bpmTapA = BPMTapState()
    private var bpmTapB = BPMTapState()
    private var bpmA: Double { bpmTapA.bpm }
    private var bpmB: Double { bpmTapB.bpm }
    private var beatOffsetA: Double { bpmTapA.beatOffset }
    private var beatOffsetB: Double { bpmTapB.beatOffset }

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
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        allowedTouchTypes = [.indirect]
        wantsRestingTouches = false
    }

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()

        if let observedWindow {
            NotificationCenter.default.removeObserver(
                self,
                name: NSWindow.didResignKeyNotification,
                object: observedWindow
            )
        }

        observedWindow = window
        if let window {
            if inputTimer == nil {
                startInputTimer()
            }
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(windowDidResignKey(_:)),
                name: NSWindow.didResignKeyNotification,
                object: window
            )
        } else {
            inputTimer?.invalidate()
            inputTimer = nil
        }
    }

    override func resignFirstResponder() -> Bool {
        keyboardStateMachine.focusLost()
        return super.resignFirstResponder()
    }

    @objc private func windowDidResignKey(_ notification: Notification) {
        cancelActiveInput()
    }

    // MARK: - Keyboard Events

    override func keyDown(with event: NSEvent) {
        let shift = event.modifierFlags.contains(.shift)
        guard KeyboardMapping.handles(event.keyCode, shift: shift) else {
            super.keyDown(with: event)
            return
        }
        emit(keyboardStateMachine.keyDown(
            keyCode: event.keyCode,
            isRepeat: event.isARepeat,
            shift: shift
        ))
    }

    override func keyUp(with event: NSEvent) {
        if KeyboardMapping.handles(
            event.keyCode,
            shift: event.modifierFlags.contains(.shift)
        ) {
            keyboardStateMachine.keyUp(keyCode: event.keyCode)
        } else {
            super.keyUp(with: event)
        }
    }

    // MARK: - BPM Tap

    private func handleBpmTap(deck: DeckID) {
        let now = CACurrentMediaTime()
        switch deck {
        case .a:
            bpmTapA.tap(at: now, progress: extendedProgressA)
        case .b:
            bpmTapB.tap(at: now, progress: extendedProgressB)
        }
        needsDisplay = true
    }

    // MARK: - Input Timer

    private func startInputTimer() {
        inputTimer = Timer.scheduledTimer(
            timeInterval: 1.0 / 60.0,
            target: self,
            selector: #selector(inputTimerFired(_:)),
            userInfo: nil,
            repeats: true
        )
    }

    @objc private func inputTimerFired(_ timer: Timer) {
        emit(keyboardStateMachine.heldActions())
        emit(gestureStateMachine.process(.tick(CACurrentMediaTime())))
    }

    // MARK: - Touch Events

    override func touchesBegan(with event: NSEvent) {
        let points = sortedTouches(event.touches(matching: .began, in: self)).compactMap {
            touchPoint(for: $0, timestamp: event.timestamp, createIdentity: true)
        }
        emit(gestureStateMachine.process(.began(points)))
        syncSession()
    }

    override func touchesMoved(with event: NSEvent) {
        let points = sortedTouches(event.touches(matching: .moved, in: self)).compactMap {
            touchPoint(for: $0, timestamp: event.timestamp, createIdentity: false)
        }
        emit(gestureStateMachine.process(.moved(points)))
        syncSession()
    }

    override func touchesEnded(with event: NSEvent) {
        let endedTouches = sortedTouches(event.touches(matching: .ended, in: self))
        let identities = endedTouches.compactMap { touchID(for: $0, create: false) }
        emit(gestureStateMachine.process(.ended(identities)))
        for touch in endedTouches {
            touchIDs.removeValue(forKey: touch.identity as! NSObject)
        }
        syncSession()
    }

    override func touchesCancelled(with event: NSEvent) {
        cancelActiveInput()
    }

    private func sortedTouches(_ touches: Set<NSTouch>) -> [NSTouch] {
        touches.sorted {
            let lhs = $0.identity as! NSObject
            let rhs = $1.identity as! NSObject
            if lhs.hash == rhs.hash {
                if $0.normalizedPosition.x == $1.normalizedPosition.x {
                    return $0.normalizedPosition.y < $1.normalizedPosition.y
                }
                return $0.normalizedPosition.x < $1.normalizedPosition.x
            }
            return lhs.hash < rhs.hash
        }
    }

    private func touchPoint(
        for touch: NSTouch,
        timestamp: TimeInterval,
        createIdentity: Bool
    ) -> TouchPoint? {
        guard let identity = touchID(for: touch, create: createIdentity) else { return nil }
        return TouchPoint(
            identity: identity,
            position: touch.normalizedPosition,
            timestamp: timestamp
        )
    }

    private func touchID(for touch: NSTouch, create: Bool) -> TouchID? {
        let key = touch.identity as! NSObject
        if let existing = touchIDs[key] {
            return existing
        }
        guard create else { return nil }

        let identity = TouchID(rawValue: nextTouchID)
        nextTouchID &+= 1
        touchIDs[key] = identity
        return identity
    }

    private func syncSession() {
        session = gestureStateMachine.session
    }

    private func cancelActiveInput() {
        keyboardStateMachine.focusLost()
        emit(gestureStateMachine.process(.cancelled))
        touchIDs.removeAll(keepingCapacity: true)
        syncSession()
    }

    private func emit(_ actions: [DJAction]) {
        for action in actions {
            switch action {
            case .adjustCrossfader(let delta):
                crossfader = crossfader.nudged(by: delta)
                needsDisplay = true
            case .stepCrossfader(let direction):
                crossfader = crossfader.stepped(toward: direction)
                needsDisplay = true
            case .adjustFilter(.a, let delta):
                filterLevelA = max(0, min(1, filterLevelA + delta))
            case .adjustFilter(.b, let delta):
                filterLevelB = max(0, min(1, filterLevelB + delta))
            case .setScratch(.a, let rate):
                isScratchActiveA = true
                scratchRateA = rate
            case .setScratch(.b, let rate):
                isScratchActiveB = true
                scratchRateB = rate
            case .endScratch(.a):
                isScratchActiveA = false
                scratchRateA = 0
            case .endScratch(.b):
                isScratchActiveB = false
                scratchRateB = 0
            case .tapBPM(let deck):
                handleBpmTap(deck: deck)
            case .load, .togglePlay, .cue, .nudge, .adjustVolume, .setHotCue, .jumpToHotCue:
                break
            }
            onAction?(action)
        }
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
            drawWaveform(waveformA, progress: extendedProgressA, hotCues: hotCuesA,
                         bpm: bpmA, beatOffset: beatOffsetA, duration: durationA,
                         scratchRate: scratchRateA, isScratchActive: isScratchActiveA,
                         in: viewRect(from: zone.rect), color: zoneColor(for: .deckA))
        }
        if let zone = ZoneLayout.all.first(where: { $0.name == .deckB }) {
            drawWaveform(waveformB, progress: extendedProgressB, hotCues: hotCuesB,
                         bpm: bpmB, beatOffset: beatOffsetB, duration: durationB,
                         scratchRate: scratchRateB, isScratchActive: isScratchActiveB,
                         in: viewRect(from: zone.rect), color: zoneColor(for: .deckB))
        }
    }

    /// Scrolling waveform: playhead fixed at center, waveform scrolls with playback.
    private func drawWaveform(_ samples: [Float], progress: Double, hotCues: [Double?],
                               bpm: Double, beatOffset: Double, duration: Double,
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

        // Beat grid: white tick marks at BPM intervals.
        if bpm > 0 && duration > 0 {
            let beatIntervalSamples = 60.0 * Double(samples.count) / (bpm * duration)
            let beatOffsetSample = beatOffset * Double(samples.count)
            let firstN = Int(floor((Double(center - visibleHalf) - beatOffsetSample) / beatIntervalSamples))
            var beatPos = beatOffsetSample + Double(firstN) * beatIntervalSamples
            while beatPos <= Double(center + visibleHalf) {
                let offset = Int(beatPos.rounded()) - center
                if offset >= -visibleHalf && offset <= visibleHalf {
                    let x = xFor(offset: offset + visibleHalf)
                    let tick = NSBezierPath()
                    tick.move(to: NSPoint(x: x, y: waveRect.minY + 2))
                    tick.line(to: NSPoint(x: x, y: waveRect.minY + 10))
                    tick.lineWidth = 1.0
                    NSColor.white.withAlphaComponent(0.45).setStroke()
                    tick.stroke()
                }
                beatPos += beatIntervalSamples
            }
            let bpmStr = String(format: "%.1f BPM", bpm) as NSString
            bpmStr.draw(at: NSPoint(x: waveRect.minX + 4, y: waveRect.minY + 4),
                        withAttributes: [.foregroundColor: NSColor.white.withAlphaComponent(0.65),
                                         .font: NSFont.systemFont(ofSize: 10)])
        }

        // Hot cue markers: colored vertical lines on the waveform.
        let cueColors: [NSColor] = [.systemOrange, .systemCyan, .systemGreen, .systemPurple]
        for (i, cueProgress) in hotCues.enumerated() {
            guard let cue = cueProgress else { continue }
            let cueIdx = Int(cue * Double(samples.count))
            let offset = cueIdx - center
            guard offset >= -visibleHalf && offset <= visibleHalf else { continue }
            let x = xFor(offset: offset + visibleHalf)
            let cuePath = NSBezierPath()
            cuePath.move(to: NSPoint(x: x, y: waveRect.minY))
            cuePath.line(to: NSPoint(x: x, y: waveRect.maxY))
            cuePath.lineWidth = 1.5
            cueColors[i].withAlphaComponent(0.9).setStroke()
            cuePath.stroke()
            // 번호 레이블
            let label = "\(i + 1)" as NSString
            label.draw(at: NSPoint(x: x + 2, y: waveRect.maxY - 14),
                       withAttributes: [.foregroundColor: cueColors[i],
                                        .font: NSFont.systemFont(ofSize: 10, weight: .bold)])
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
        let crossfaderMode = crossfaderModeValues.enumerated().min {
            abs($0.element - crossfader.value) < abs($1.element - crossfader.value)
        }?.offset ?? 1
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
