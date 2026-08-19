import AppKit

/// Renders two deck waveforms and translates keyboard / trackpad input into DJ actions.
@MainActor
final class TouchLabView: NSView {

    private(set) var session: TouchSession = .empty {
        didSet { needsDisplay = true }
    }

    private var gestureStateMachine = GestureStateMachine()
    private var keyboardStateMachine = KeyboardStateMachine()
    private let cursorLockController = CursorLockController()
    private var touchIDs: [NSObject: TouchID] = [:]
    private var nextTouchID: UInt64 = 1
    private var inputTimer: Timer?
    private weak var observedWindow: NSWindow?

    private let crossfaderModeValues: [Float] = [0, 0.5, 1]

    var onAction: ((DJAction) -> Void)?

    private(set) var deckASnapshot = DeckSnapshot.empty(deck: .a)
    private(set) var deckBSnapshot = DeckSnapshot.empty(deck: .b)
    private(set) var mixerSnapshot = MixerSnapshot.initial
    var statusMessage: String? { didSet { needsDisplay = true } }
    private var cursorStatusMessage: String?

    private var jogDeck: DeckID?
    private var jogMode: JogMode?
    private var jogValue: Double = 0

    var activeDeck: DeckID { keyboardStateMachine.activeDeck }
    var isCursorLocked: Bool { cursorLockController.isLocked }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureTouchInput()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureTouchInput()
    }

    override var acceptsFirstResponder: Bool { true }

    private func configureTouchInput() {
        allowedTouchTypes = [.indirect]
        wantsRestingTouches = false
    }

    func apply(
        deckA: DeckSnapshot,
        deckB: DeckSnapshot,
        mixer: MixerSnapshot
    ) {
        deckASnapshot = deckA
        deckBSnapshot = deckB
        mixerSnapshot = mixer
        needsDisplay = true
    }

    func resetTransientState(for deck: DeckID) {
        guard jogDeck == deck else { return }
        jogDeck = nil
        jogMode = nil
        jogValue = 0
        needsDisplay = true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stopObservingWindow()

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
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(windowWillClose(_:)),
                name: NSWindow.willCloseNotification,
                object: window
            )
        } else {
            inputTimer?.invalidate()
            inputTimer = nil
            cancelActiveInput()
        }
    }

    override func resignFirstResponder() -> Bool {
        cancelActiveInput()
        return super.resignFirstResponder()
    }

    @objc private func windowDidResignKey(_ notification: Notification) {
        cancelActiveInput()
    }

    @objc private func windowWillClose(_ notification: Notification) {
        cancelActiveInput()
    }

    func shutdown() {
        inputTimer?.invalidate()
        inputTimer = nil
        stopObservingWindow()
        cancelActiveInput()
    }

    private func stopObservingWindow() {
        guard let observedWindow else { return }
        NotificationCenter.default.removeObserver(
            self,
            name: NSWindow.didResignKeyNotification,
            object: observedWindow
        )
        NotificationCenter.default.removeObserver(
            self,
            name: NSWindow.willCloseNotification,
            object: observedWindow
        )
    }

    // MARK: - Keyboard Events

    override func keyDown(with event: NSEvent) {
        let shift = event.modifierFlags.contains(.shift)
        let systemModifiers: NSEvent.ModifierFlags = [.command, .control, .option]
        let hasSystemModifier = !event.modifierFlags.intersection(systemModifiers).isEmpty
        guard KeyboardMapping.handles(
            event.keyCode,
            shift: shift,
            hasSystemModifier: hasSystemModifier
        ) else {
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
        if keyboardStateMachine.pressedKeys.contains(event.keyCode)
            || KeyboardMapping.handles(
                event.keyCode,
                shift: event.modifierFlags.contains(.shift)
            ) {
            keyboardStateMachine.keyUp(keyCode: event.keyCode)
        } else {
            super.keyUp(with: event)
        }
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
        let mode: JogMode = event.modifierFlags.contains(.shift) ? .pitchBend : .scratch
        emit(gestureStateMachine.process(
            .began(points, deck: keyboardStateMachine.activeDeck, mode: mode)
        ))
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
        restoreCursor()
    }

    private func cancelJogAndUnlock() {
        emit(gestureStateMachine.process(.cancelled))
        touchIDs.removeAll(keepingCapacity: true)
        syncSession()
        restoreCursor()
    }

    private func emit(_ actions: [DJAction]) {
        for action in actions {
            switch action {
            case .selectActiveDeck:
                needsDisplay = true
            case .setScratch(let deck, let rate):
                jogDeck = deck
                jogMode = .scratch
                jogValue = rate
                needsDisplay = true
            case .endScratch:
                jogDeck = nil
                jogMode = nil
                jogValue = 0
                needsDisplay = true
            case .setPitchBend(let deck, let percent):
                jogDeck = deck
                jogMode = .pitchBend
                jogValue = percent
                needsDisplay = true
            case .endPitchBend:
                jogDeck = nil
                jogMode = nil
                jogValue = 0
                needsDisplay = true
            case .toggleCursorLock:
                toggleCursorLock()
            case .cancelJogAndUnlock:
                cancelJogAndUnlock()
            case .load:
                restoreCursor()
            case .adjustCrossfader, .stepCrossfader, .togglePlay, .cue, .nudge,
                 .adjustFilter, .adjustVolume, .adjustTempo, .resetTempo,
                 .toggleMonitor, .toggleOutputMode, .tapBPM,
                 .restoreAutomaticBPM, .syncTempo:
                break
            }
            onAction?(action)
        }
    }

    // MARK: - Cursor Lock

    private func toggleCursorLock() {
        if cursorLockController.isLocked {
            restoreCursor()
            return
        }

        do {
            try cursorLockController.lock(
                windowIsKey: window?.isKeyWindow == true,
                cursorInsideContent: isCursorInsideContent()
            )
            cursorStatusMessage = nil
        } catch {
            cursorStatusMessage = error.localizedDescription
        }
        needsDisplay = true
    }

    private func restoreCursor() {
        do {
            try cursorLockController.unlock()
            cursorStatusMessage = nil
        } catch {
            cursorStatusMessage = error.localizedDescription
        }
        needsDisplay = true
    }

    private func isCursorInsideContent() -> Bool {
        guard let window, let contentView = window.contentView else { return false }
        let pointInWindow = window.convertPoint(fromScreen: NSEvent.mouseLocation)
        let pointInContent = contentView.convert(pointInWindow, from: nil)
        return contentView.bounds.contains(pointInContent)
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        drawBackground()
        drawDeckPanels()
        drawWaveforms()
        drawDeckHeaders()
        drawLevelIndicators()
        drawCrossfaderIndicator()
        drawTouches()
        drawHUD()
    }

    private func drawBackground() {
        NSColor(white: 0.08, alpha: 1).setFill()
        bounds.fill()
    }

    private func deckRect(for deck: DeckID) -> NSRect {
        let margin: CGFloat = 16
        let gap: CGFloat = 10
        let bottom: CGFloat = 58
        let top: CGFloat = 52
        let availableWidth = bounds.width - margin * 2 - gap
        let width = availableWidth / 2
        let x = deck == .a ? margin : margin + width + gap
        return NSRect(
            x: x,
            y: bottom,
            width: width,
            height: max(0, bounds.height - bottom - top)
        )
    }

    private func drawDeckPanels() {
        for deck in [DeckID.a, .b] {
            let rect = deckRect(for: deck)
            let color = deckColor(for: deck)
            color.withAlphaComponent(activeDeck == deck ? 0.13 : 0.07).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8).fill()

            color.withAlphaComponent(activeDeck == deck ? 0.95 : 0.28).setStroke()
            let border = NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8)
            border.lineWidth = activeDeck == deck ? 3 : 1
            border.stroke()
        }
    }

    private func drawWaveforms() {
        drawWaveform(snapshot: deckASnapshot, in: deckRect(for: .a), color: deckColor(for: .a))
        drawWaveform(snapshot: deckBSnapshot, in: deckRect(for: .b), color: deckColor(for: .b))
    }

    private func drawWaveform(snapshot: DeckSnapshot, in rect: NSRect, color: NSColor) {
        let samples = snapshot.waveformSamples
        guard samples.count > 1 else { return }

        let waveRect = NSRect(
            x: rect.minX + 12,
            y: rect.minY + 20,
            width: rect.width - 24,
            height: rect.height - 52
        )
        let mode = jogDeck == snapshot.deck ? jogMode : nil
        if mode != nil {
            color.withAlphaComponent(0.08).setFill()
            NSBezierPath(rect: waveRect).fill()
        }

        let visibleHalf = 150
        let total = visibleHalf * 2
        let center = Int(snapshot.extendedProgress * Double(samples.count))
        let mid = waveRect.midY
        let halfHeight = waveRect.height * 0.38

        func amplitude(at index: Int) -> CGFloat {
            guard samples.indices.contains(index) else { return 0 }
            return CGFloat(samples[index])
        }

        func xPosition(for offset: Int) -> CGFloat {
            waveRect.minX + CGFloat(offset) / CGFloat(total) * waveRect.width
        }

        let played = NSBezierPath()
        for offset in 0...visibleHalf {
            let point = NSPoint(
                x: xPosition(for: offset),
                y: mid + amplitude(at: center - visibleHalf + offset) * halfHeight
            )
            offset == 0 ? played.move(to: point) : played.line(to: point)
        }
        for offset in stride(from: visibleHalf, through: 0, by: -1) {
            played.line(to: NSPoint(
                x: xPosition(for: offset),
                y: mid - amplitude(at: center - visibleHalf + offset) * halfHeight
            ))
        }
        played.close()
        color.withAlphaComponent(0.6).setFill()
        played.fill()

        let upcoming = NSBezierPath()
        for offset in visibleHalf...total {
            let point = NSPoint(
                x: xPosition(for: offset),
                y: mid + amplitude(at: center - visibleHalf + offset) * halfHeight
            )
            offset == visibleHalf ? upcoming.move(to: point) : upcoming.line(to: point)
        }
        for offset in stride(from: total, through: visibleHalf, by: -1) {
            upcoming.line(to: NSPoint(
                x: xPosition(for: offset),
                y: mid - amplitude(at: center - visibleHalf + offset) * halfHeight
            ))
        }
        upcoming.close()
        color.withAlphaComponent(0.25).setFill()
        upcoming.fill()

        drawBeatGrid(snapshot: snapshot, center: center, visibleHalf: visibleHalf,
                     samplesCount: samples.count, in: waveRect)

        let playhead = NSBezierPath()
        playhead.move(to: NSPoint(x: waveRect.midX, y: waveRect.minY + 4))
        playhead.line(to: NSPoint(x: waveRect.midX, y: waveRect.maxY - 4))
        playhead.lineWidth = mode == nil ? 1.5 : 2
        (mode == nil ? NSColor.white : NSColor.systemYellow).setStroke()
        playhead.stroke()

        if mode != nil, abs(jogValue) > 0.05 {
            drawJogArrow(
                value: jogValue,
                at: NSPoint(x: waveRect.midX, y: waveRect.minY + 10),
                color: color
            )
        }
    }

    private func drawBeatGrid(
        snapshot: DeckSnapshot,
        center: Int,
        visibleHalf: Int,
        samplesCount: Int,
        in rect: NSRect
    ) {
        guard let bpm = snapshot.bpm,
              let firstBeatTime = snapshot.firstBeatTime,
              bpm > 0,
              snapshot.duration > 0 else { return }

        let beatInterval = 60 * Double(samplesCount) / (bpm * snapshot.duration)
        let firstBeatSample = firstBeatTime / snapshot.duration * Double(samplesCount)
        let firstVisibleBeat = Int(floor((Double(center - visibleHalf) - firstBeatSample) / beatInterval))
        var beat = firstBeatSample + Double(firstVisibleBeat) * beatInterval
        while beat <= Double(center + visibleHalf) {
            let offset = Int(beat.rounded()) - center
            if (-visibleHalf...visibleHalf).contains(offset) {
                let x = rect.minX
                    + CGFloat(offset + visibleHalf) / CGFloat(visibleHalf * 2) * rect.width
                let tick = NSBezierPath()
                tick.move(to: NSPoint(x: x, y: rect.minY + 2))
                tick.line(to: NSPoint(x: x, y: rect.minY + 10))
                tick.lineWidth = 1
                NSColor.white.withAlphaComponent(0.4).setStroke()
                tick.stroke()
            }
            beat += beatInterval
        }
    }

    private func drawJogArrow(value: Double, at center: NSPoint, color: NSColor) {
        let size = min(14, CGFloat(abs(value)) * 2)
        let direction: CGFloat = value > 0 ? 1 : -1
        let arrow = NSBezierPath()
        arrow.move(to: NSPoint(x: center.x + direction * size, y: center.y))
        arrow.line(to: NSPoint(x: center.x - direction * size * 0.5, y: center.y + size * 0.5))
        arrow.line(to: NSPoint(x: center.x - direction * size * 0.5, y: center.y - size * 0.5))
        arrow.close()
        color.withAlphaComponent(0.85).setFill()
        arrow.fill()
    }

    private func drawDeckHeaders() {
        drawDeckHeader(snapshot: deckASnapshot, in: deckRect(for: .a), color: deckColor(for: .a))
        drawDeckHeader(snapshot: deckBSnapshot, in: deckRect(for: .b), color: deckColor(for: .b))
    }

    private func drawDeckHeader(snapshot: DeckSnapshot, in rect: NSRect, color: NSColor) {
        let bend = abs(snapshot.pitchBendPercent) > 0.005
            ? String(format: "  BEND %+.2f%%", snapshot.pitchBendPercent)
            : ""
        let monitor = snapshot.monitorEnabled ? "  MON" : ""
        let title = "\(snapshot.deck.displayName): \(snapshot.trackName ?? "—")  \(snapshot.isPlaying ? "▶" : "■")  \(String(format: "%+.2f%%", snapshot.tempoPercent))\(bend)\(monitor)"
        NSAttributedString(
            string: title,
            attributes: [
                .foregroundColor: color.withAlphaComponent(0.95),
                .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .medium),
            ]
        ).draw(at: NSPoint(x: rect.minX + 10, y: rect.maxY - 20))

        if let bpm = snapshot.bpm {
            let source = snapshot.beatGridSource == .tap ? "TAP" : "AUTO"
            let confidence = Int(((snapshot.beatConfidence ?? 0) * 100).rounded())
            let bpmText = String(format: "%.1f BPM  %@ %d%%", bpm, source, confidence)
            NSAttributedString(
                string: bpmText,
                attributes: [
                    .foregroundColor: NSColor.white.withAlphaComponent(0.58),
                    .font: NSFont.monospacedSystemFont(ofSize: 9, weight: .regular),
                ]
            ).draw(at: NSPoint(x: rect.minX + 10, y: rect.maxY - 34))
        }

        guard snapshot.duration > 0 else { return }
        let remaining = snapshot.duration * (1 - snapshot.playbackProgress)
        let time = "-\(formatTime(remaining)) / \(formatTime(snapshot.duration))"
        let attributed = NSAttributedString(
            string: time,
            attributes: [
                .foregroundColor: color.withAlphaComponent(0.58),
                .font: NSFont.monospacedSystemFont(ofSize: 9, weight: .regular),
            ]
        )
        attributed.draw(at: NSPoint(x: rect.maxX - attributed.size().width - 10, y: rect.maxY - 34))
    }

    private func drawLevelIndicators() {
        for (snapshot, deck) in [(deckASnapshot, DeckID.a), (deckBSnapshot, .b)] {
            let rect = deckRect(for: deck)
            drawLevelBar(
                level: snapshot.faderLevel,
                label: "VOL",
                x: rect.minX + 5,
                in: rect,
                color: deckColor(for: deck)
            )
            drawLevelBar(
                level: snapshot.filterLevel,
                label: "FLT",
                x: rect.maxX - 9,
                in: rect,
                color: deckColor(for: deck)
            )
        }
    }

    private func drawLevelBar(
        level: Float,
        label: String,
        x: CGFloat,
        in rect: NSRect,
        color: NSColor
    ) {
        let bar = NSRect(x: x, y: rect.minY + 8, width: 4, height: rect.height - 50)
        color.withAlphaComponent(0.12).setFill()
        NSBezierPath(rect: bar).fill()
        let fill = NSRect(
            x: bar.minX,
            y: bar.minY,
            width: bar.width,
            height: bar.height * CGFloat(level)
        )
        color.withAlphaComponent(0.65).setFill()
        NSBezierPath(rect: fill).fill()
        (label as NSString).draw(
            at: NSPoint(x: x - 2, y: rect.minY + 2),
            withAttributes: [
                .foregroundColor: color.withAlphaComponent(0.5),
                .font: NSFont.monospacedSystemFont(ofSize: 6, weight: .regular),
            ]
        )
    }

    private func drawCrossfaderIndicator() {
        let rect = NSRect(x: bounds.midX - 90, y: 31, width: 180, height: 16)
        let labels = ["A", "A+B", "B"]
        let activeMode = crossfaderModeValues.enumerated().min {
            abs($0.element - mixerSnapshot.crossfaderValue)
                < abs($1.element - mixerSnapshot.crossfaderValue)
        }?.offset ?? 1
        for index in labels.indices {
            let segment = NSRect(
                x: rect.minX + CGFloat(index) * rect.width / 3,
                y: rect.minY,
                width: rect.width / 3,
                height: rect.height
            )
            let active = index == activeMode
            if active {
                NSColor.systemPurple.withAlphaComponent(0.25).setFill()
                NSBezierPath(roundedRect: segment, xRadius: 3, yRadius: 3).fill()
            }
            let text = NSAttributedString(
                string: labels[index],
                attributes: [
                    .foregroundColor: NSColor.systemPurple.withAlphaComponent(active ? 0.95 : 0.35),
                    .font: NSFont.monospacedSystemFont(ofSize: 9, weight: active ? .bold : .regular),
                ]
            )
            text.draw(at: NSPoint(
                x: segment.midX - text.size().width / 2,
                y: segment.midY - text.size().height / 2
            ))
        }
    }

    private func drawTouches() {
        let color = deckColor(for: jogDeck ?? activeDeck)
        for touch in session.activeTouches.values {
            let center = NSPoint(
                x: touch.position.x * bounds.width,
                y: touch.position.y * bounds.height
            )
            drawCircle(center: center, radius: 26, fill: color.withAlphaComponent(0.2))
            drawCircle(center: center, radius: 6, fill: color)
        }
    }

    private func drawCircle(center: NSPoint, radius: CGFloat, fill: NSColor) {
        fill.setFill()
        NSBezierPath(ovalIn: NSRect(
            x: center.x - radius,
            y: center.y - radius,
            width: radius * 2,
            height: radius * 2
        )).fill()
    }

    private func drawHUD() {
        let displayedJogDeck = jogDeck ?? activeDeck
        let mode = jogMode == .pitchBend ? "BEND" : "SCRATCH"
        var jogStatus = "JOG \(displayedJogDeck.displayName) · \(mode)"
        if jogDeck != nil, displayedJogDeck != activeDeck {
            jogStatus += " · NEXT \(activeDeck.displayName)"
        }
        if isCursorLocked {
            jogStatus += " · CURSOR LOCKED"
        }
        NSAttributedString(
            string: jogStatus,
            attributes: [
                .foregroundColor: deckColor(for: activeDeck),
                .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .bold),
            ]
        ).draw(at: NSPoint(x: 16, y: bounds.height - 27))

        let hints = [
            "Tab:deck  Q:load  Space:play  C:cue  S:sync  E/D:vol  R/F:filter  T/G:tempo  5:reset",
            "B:tap  ⇧B:auto BPM  V:MON  ↑/↓:nudge  ←/→:xfade  M:split  P:cursor  Esc:release",
        ]
        for (index, hint) in hints.enumerated() {
            let text = NSAttributedString(
                string: hint,
                attributes: [
                    .foregroundColor: NSColor.white.withAlphaComponent(0.25),
                    .font: NSFont.monospacedSystemFont(ofSize: 8, weight: .regular),
                ]
            )
            text.draw(at: NSPoint(
                x: (bounds.width - text.size().width) / 2,
                y: 5 + CGFloat(index) * 11
            ))
        }

        if let status = cursorStatusMessage ?? statusMessage {
            let text = NSAttributedString(
                string: status,
                attributes: [
                    .foregroundColor: NSColor.white.withAlphaComponent(0.78),
                    .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .medium),
                ]
            )
            text.draw(at: NSPoint(
                x: (bounds.width - text.size().width) / 2,
                y: bounds.height - 43
            ))
        }

        let warning: (String, NSColor)?
        if let routingError = mixerSnapshot.routingErrorMessage {
            warning = ("AUDIO STOPPED — \(routingError)", .systemRed)
        } else if mixerSnapshot.outputMode == .splitCue {
            warning = ("SPLIT CUE — L: MASTER / R: CUE", .systemYellow)
        } else {
            warning = nil
        }
        if let (message, color) = warning {
            let text = NSAttributedString(
                string: message,
                attributes: [
                    .foregroundColor: color.withAlphaComponent(0.95),
                    .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .bold),
                ]
            )
            text.draw(at: NSPoint(x: bounds.maxX - text.size().width - 16, y: bounds.height - 26))
        }
    }

    private func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "--:--" }
        let value = Int(seconds)
        return String(format: "%d:%02d", value / 60, value % 60)
    }

    private func deckColor(for deck: DeckID) -> NSColor {
        switch deck {
        case .a: return NSColor(red: 0.35, green: 0.65, blue: 1, alpha: 1)
        case .b: return NSColor(red: 1, green: 0.55, blue: 0.25, alpha: 1)
        }
    }
}
