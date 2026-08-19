import AppKit

private enum ConsolePalette {
    static let background = NSColor(srgbRed: 0.043, green: 0.051, blue: 0.063, alpha: 1)
    static let surface = NSColor(srgbRed: 0.071, green: 0.086, blue: 0.106, alpha: 1)
    static let raised = NSColor(srgbRed: 0.102, green: 0.122, blue: 0.145, alpha: 1)
    static let divider = NSColor(srgbRed: 0.149, green: 0.173, blue: 0.204, alpha: 1)
    static let primaryText = NSColor(srgbRed: 0.957, green: 0.969, blue: 0.980, alpha: 1)
    static let secondaryText = NSColor(srgbRed: 0.541, green: 0.576, blue: 0.620, alpha: 1)
    static let deckA = NSColor(srgbRed: 0.224, green: 0.655, blue: 1, alpha: 1)
    static let deckB = NSColor(srgbRed: 1, green: 0.541, blue: 0.239, alpha: 1)
    static let warning = NSColor(srgbRed: 0.965, green: 0.784, blue: 0.373, alpha: 1)
    static let error = NSColor(srgbRed: 1, green: 0.278, blue: 0.333, alpha: 1)
}

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
    private var controlTouchIDs: Set<TouchID> = []
    private var isControlTouchSequence = false
    private var nextTouchID: UInt64 = 1
    private var inputTimer: Timer?
    private weak var observedWindow: NSWindow?
    private var pointerTrackingArea: NSTrackingArea?
    private var hoveredControl: PerformanceControl?
    private var pressedControl: PerformanceControl?
    private var displayedPeakA: Float = 0
    private var displayedPeakB: Float = 0
    private var lastMeterUpdate = CACurrentMediaTime()
    private var activeDeckTransitionStartedAt: TimeInterval?

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
    override var isOpaque: Bool { true }

    private func configureTouchInput() {
        allowedTouchTypes = [.indirect]
        wantsRestingTouches = false
        wantsLayer = true
    }

    func apply(
        deckA: DeckSnapshot,
        deckB: DeckSnapshot,
        mixer: MixerSnapshot
    ) {
        let now = CACurrentMediaTime()
        let elapsed = min(0.25, max(0, now - lastMeterUpdate))
        let decay = Float(exp(-elapsed / 0.28))
        displayedPeakA = max(deckA.preFaderPeak, displayedPeakA * decay)
        displayedPeakB = max(deckB.preFaderPeak, displayedPeakB * decay)
        lastMeterUpdate = now
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
            window.acceptsMouseMovedEvents = true
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

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let pointerTrackingArea {
            removeTrackingArea(pointerTrackingArea)
        }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.activeInKeyWindow, .inVisibleRect, .mouseMoved, .mouseEnteredAndExited],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        pointerTrackingArea = area
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
        let sequenceWasEmpty = touchIDs.isEmpty
        let points = sortedTouches(event.touches(matching: .began, in: self)).compactMap {
            touchPoint(for: $0, timestamp: event.timestamp, createIdentity: true)
        }
        if TouchRoutingPolicy.reservesSequenceForControl(
            sequenceWasEmpty: sequenceWasEmpty,
            cursorLocked: isCursorLocked,
            controlUnderPointer: PerformanceLayout(bounds: bounds).control(at: cursorPointInView())
        ) {
            isControlTouchSequence = true
        }
        if isControlTouchSequence {
            controlTouchIDs.formUnion(points.map(\.identity))
            needsDisplay = true
            return
        }
        let mode: JogMode = event.modifierFlags.contains(.shift) ? .pitchBend : .scratch
        emit(gestureStateMachine.process(
            .began(points, deck: keyboardStateMachine.activeDeck, mode: mode)
        ))
        syncSession()
    }

    override func touchesMoved(with event: NSEvent) {
        guard !isControlTouchSequence else { return }
        let points = sortedTouches(event.touches(matching: .moved, in: self)).compactMap {
            touchPoint(for: $0, timestamp: event.timestamp, createIdentity: false)
        }
        emit(gestureStateMachine.process(.moved(points)))
        syncSession()
    }

    override func touchesEnded(with event: NSEvent) {
        let endedTouches = sortedTouches(event.touches(matching: .ended, in: self))
        let identities = endedTouches.compactMap { touchID(for: $0, create: false) }
        if isControlTouchSequence {
            controlTouchIDs.subtract(identities)
        } else {
            emit(gestureStateMachine.process(.ended(identities)))
        }
        for touch in endedTouches {
            touchIDs.removeValue(forKey: touch.identity as! NSObject)
        }
        if isControlTouchSequence, controlTouchIDs.isEmpty {
            isControlTouchSequence = false
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
        controlTouchIDs.removeAll(keepingCapacity: true)
        isControlTouchSequence = false
        hoveredControl = nil
        pressedControl = nil
        syncSession()
        restoreCursor()
    }

    private func cancelJogAndUnlock() {
        emit(gestureStateMachine.process(.cancelled))
        touchIDs.removeAll(keepingCapacity: true)
        controlTouchIDs.removeAll(keepingCapacity: true)
        isControlTouchSequence = false
        hoveredControl = nil
        pressedControl = nil
        syncSession()
        restoreCursor()
    }

    private func emit(_ actions: [DJAction]) {
        for action in actions {
            switch action {
            case .selectActiveDeck:
                activeDeckTransitionStartedAt = CACurrentMediaTime()
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
            case .stepCrossfader, .togglePlay, .cue, .nudge,
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
            hoveredControl = nil
            pressedControl = nil
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

    // MARK: - Pointer Controls

    override func mouseMoved(with event: NSEvent) {
        updateHoveredControl(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        hoveredControl = nil
        pressedControl = nil
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        guard !isCursorLocked, gestureStateMachine.session.count == 0 else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard let control = PerformanceLayout(bounds: bounds).control(at: point),
              isControlEnabled(control) else {
            return
        }
        pressedControl = control
        hoveredControl = control
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard pressedControl != nil else { return }
        updateHoveredControl(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseUp(with event: NSEvent) {
        guard let pressedControl else { return }
        let point = convert(event.locationInWindow, from: nil)
        let releasedControl = PerformanceLayout(bounds: bounds).control(at: point)
        self.pressedControl = nil
        hoveredControl = releasedControl
        if releasedControl == pressedControl, isControlEnabled(pressedControl) {
            activate(pressedControl)
        }
        needsDisplay = true
    }

    private func updateHoveredControl(at point: NSPoint) {
        let next = isCursorLocked ? nil : PerformanceLayout(bounds: bounds).control(at: point)
        guard next != hoveredControl else { return }
        hoveredControl = next
        needsDisplay = true
    }

    private func isControlEnabled(_ control: PerformanceControl) -> Bool {
        PerformanceControlPolicy.isEnabled(
            control,
            deckA: deckASnapshot,
            deckB: deckBSnapshot
        )
    }

    private func activate(_ control: PerformanceControl) {
        emit(keyboardStateMachine.activate(control))
    }

    private func cursorPointInView() -> NSPoint {
        guard let window else { return .zero }
        return convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
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
        let layout = PerformanceLayout(bounds: bounds)
        drawTopBar(layout)
        drawWaveformStage(layout)
        drawDeckConsole(snapshot: deckASnapshot, in: layout.deckAConsole, layout: layout)
        drawDeckConsole(snapshot: deckBSnapshot, in: layout.deckBConsole, layout: layout)
        drawPlatter(in: layout.platter)
        drawCrossfader(in: layout.crossfader)
        drawBottomRail(layout.bottomRail)
    }

    private func drawBackground() {
        ConsolePalette.background.setFill()
        bounds.fill()
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

    private func drawTopBar(_ layout: PerformanceLayout) {
        let separator = NSBezierPath()
        separator.move(to: NSPoint(x: layout.topBar.minX, y: layout.topBar.minY))
        separator.line(to: NSPoint(x: layout.topBar.maxX, y: layout.topBar.minY))
        separator.lineWidth = 1
        ConsolePalette.divider.setStroke()
        separator.stroke()

        drawText(
            "TRACKPAD / DJ",
            in: NSRect(
                x: layout.topBar.minX + 76,
                y: layout.topBar.midY - 10,
                width: 190,
                height: 24
            ),
            font: .systemFont(ofSize: 17, weight: .heavy),
            color: ConsolePalette.primaryText
        )

        let displayedDeck = jogDeck ?? activeDeck
        let mode = jogMode == .pitchBend ? "BEND" : "SCRATCH"
        var status = "JOG \(displayedDeck.displayName)  /  \(mode)"
        if jogDeck != nil, displayedDeck != activeDeck {
            status += "  /  NEXT \(activeDeck.displayName)"
        }
        if isCursorLocked {
            status += "  /  CURSOR LOCKED"
        }
        drawText(
            status,
            in: NSRect(
                x: layout.topBar.minX + 260,
                y: layout.topBar.midY - 9,
                width: max(0, layout.topBar.width - 430),
                height: 22
            ),
            font: .monospacedSystemFont(ofSize: 13, weight: .bold),
            color: deckColor(for: activeDeck),
            alignment: .center
        )

        if let region = layout.region(for: .toggleOutputMode) {
            let title = mixerSnapshot.outputMode == .splitCue ? "SPLIT CUE" : "STEREO MASTER"
            drawControlButton(
                .toggleOutputMode,
                in: region.frame,
                accent: mixerSnapshot.outputMode == .splitCue
                    ? ConsolePalette.warning
                    : ConsolePalette.primaryText,
                isActive: mixerSnapshot.outputMode == .splitCue,
                titleOverride: title,
                keyHintOverride: mixerSnapshot.outputMode == .splitCue
                    ? "L:MASTER / R:CUE  ·  M"
                    : nil
            )
        }

        if let routingError = mixerSnapshot.routingErrorMessage {
            ConsolePalette.error.setFill()
            NSRect(x: layout.topBar.minX, y: layout.topBar.minY, width: layout.topBar.width, height: 2).fill()
            drawText(
                "AUDIO STOPPED  /  \(routingError)",
                in: NSRect(
                    x: layout.topBar.minX + 260,
                    y: layout.topBar.minY + 3,
                    width: max(0, layout.topBar.width - 430),
                    height: 13
                ),
                font: .monospacedSystemFont(ofSize: 9, weight: .bold),
                color: ConsolePalette.error,
                alignment: .center
            )
        }
    }

    private func drawWaveformStage(_ layout: PerformanceLayout) {
        drawWaveformBand(snapshot: deckASnapshot, in: layout.deckAWaveform, compact: layout.isCompact)
        drawWaveformBand(snapshot: deckBSnapshot, in: layout.deckBWaveform, compact: layout.isCompact)
    }

    private func drawWaveformBand(
        snapshot: DeckSnapshot,
        in rect: NSRect,
        compact: Bool
    ) {
        let color = deckColor(for: snapshot.deck)
        ConsolePalette.surface.setFill()
        NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6).fill()

        if activeDeck == snapshot.deck {
            color.withAlphaComponent(0.95).setFill()
            NSRect(x: rect.minX, y: rect.minY + 4, width: 3, height: rect.height - 8).fill()
        }
        if jogDeck == snapshot.deck {
            color.withAlphaComponent(0.07).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6).fill()
        }

        let badge = NSRect(x: rect.minX + 14, y: rect.maxY - 39, width: 28, height: 28)
        let badgePath = NSBezierPath(roundedRect: badge, xRadius: 5, yRadius: 5)
        if activeDeck == snapshot.deck {
            color.setFill()
            badgePath.fill()
        } else {
            color.withAlphaComponent(0.8).setStroke()
            badgePath.lineWidth = 1.5
            badgePath.stroke()
        }
        drawText(
            snapshot.deck.displayName,
            in: NSRect(x: badge.minX, y: badge.minY + 4, width: badge.width, height: 20),
            font: .monospacedSystemFont(ofSize: 15, weight: .heavy),
            color: activeDeck == snapshot.deck ? ConsolePalette.background : color,
            alignment: .center
        )

        let transport = snapshot.duration <= 0
            ? "EMPTY"
            : (snapshot.isPlaying ? "PLAYING" : "READY")
        drawText(
            transport,
            in: NSRect(x: rect.minX + 52, y: rect.maxY - 25, width: 70, height: 14),
            font: .monospacedSystemFont(ofSize: 9, weight: .bold),
            color: snapshot.isPlaying ? color : ConsolePalette.secondaryText
        )
        drawText(
            snapshot.trackName ?? "NO TRACK LOADED",
            in: NSRect(
                x: rect.minX + 118,
                y: rect.maxY - 28,
                width: max(0, rect.width - 330),
                height: 18
            ),
            font: .systemFont(ofSize: 13, weight: .semibold),
            color: snapshot.trackName == nil
                ? ConsolePalette.secondaryText
                : ConsolePalette.primaryText
        )

        let bpmText = snapshot.bpm.map { String(format: "%.1f", $0) } ?? "---.-"
        drawText(
            bpmText,
            in: NSRect(x: rect.maxX - 150, y: rect.maxY - 41, width: 136, height: 31),
            font: .monospacedSystemFont(ofSize: 24, weight: .bold),
            color: snapshot.bpm == nil ? ConsolePalette.secondaryText : color,
            alignment: .right
        )
        let source = snapshot.beatGridSource == .tap ? "TAP" : "AUTO"
        let confidence = Int(((snapshot.beatConfidence ?? 0) * 100).rounded())
        let bpmDetail: String
        if snapshot.bpm == nil {
            bpmDetail = "BPM"
        } else if compact {
            bpmDetail = "BPM  /  \(source)"
        } else {
            bpmDetail = "BPM  /  \(source) \(confidence)%"
        }
        drawText(
            bpmDetail,
            in: NSRect(x: rect.maxX - 150, y: rect.maxY - 53, width: 136, height: 13),
            font: .monospacedSystemFont(ofSize: 8, weight: .medium),
            color: ConsolePalette.secondaryText,
            alignment: .right
        )

        let waveRect = NSRect(
            x: rect.minX + 52,
            y: rect.minY + 12,
            width: max(0, rect.width - 220),
            height: max(0, rect.height - 56)
        )
        drawWaveform(snapshot: snapshot, in: waveRect, color: color)

        let timeText: String
        if snapshot.duration > 0 {
            let remaining = snapshot.duration * (1 - snapshot.playbackProgress)
            timeText = "-\(formatTime(remaining))\n\(formatTime(snapshot.duration))"
        } else {
            timeText = "--:--\n--:--"
        }
        drawText(
            timeText,
            in: NSRect(x: rect.maxX - 150, y: rect.minY + 15, width: 136, height: 34),
            font: .monospacedSystemFont(ofSize: 10, weight: .medium),
            color: ConsolePalette.secondaryText,
            alignment: .right
        )
    }

    private func drawWaveform(snapshot: DeckSnapshot, in rect: NSRect, color: NSColor) {
        let baseline = NSBezierPath()
        baseline.move(to: NSPoint(x: rect.minX, y: rect.midY))
        baseline.line(to: NSPoint(x: rect.maxX, y: rect.midY))
        baseline.lineWidth = 1
        ConsolePalette.divider.withAlphaComponent(0.8).setStroke()
        baseline.stroke()

        let samples = snapshot.waveformSamples
        guard samples.count > 1 else {
            drawText(
                "LOAD DECK \(snapshot.deck.displayName)  /  Q",
                in: NSRect(x: rect.minX, y: rect.midY - 8, width: rect.width, height: 18),
                font: .monospacedSystemFont(ofSize: 10, weight: .semibold),
                color: color.withAlphaComponent(0.62),
                alignment: .center
            )
            return
        }

        let visibleHalf = 150
        let center = Int(snapshot.extendedProgress * Double(samples.count))
        drawBeatGrid(
            snapshot: snapshot,
            center: center,
            visibleHalf: visibleHalf,
            samplesCount: samples.count,
            in: rect
        )

        let columns = max(80, Int(rect.width / 2.5))
        let played = NSBezierPath()
        let upcoming = NSBezierPath()
        for column in 0...columns {
            let progress = Double(column) / Double(columns)
            let offset = Int((progress * Double(visibleHalf * 2)).rounded()) - visibleHalf
            let index = center + offset
            let amplitude = samples.indices.contains(index)
                ? min(1, max(0, CGFloat(samples[index])))
                : 0
            let x = rect.minX + CGFloat(progress) * rect.width
            let halfHeight = max(1, amplitude * rect.height * 0.43)
            let path = column <= columns / 2 ? played : upcoming
            path.move(to: NSPoint(x: x, y: rect.midY - halfHeight))
            path.line(to: NSPoint(x: x, y: rect.midY + halfHeight))
        }
        played.lineWidth = 1.35
        color.withAlphaComponent(0.88).setStroke()
        played.stroke()
        upcoming.lineWidth = 1.2
        color.withAlphaComponent(0.32).setStroke()
        upcoming.stroke()

        let playhead = NSBezierPath()
        playhead.move(to: NSPoint(x: rect.midX, y: rect.minY))
        playhead.line(to: NSPoint(x: rect.midX, y: rect.maxY))
        playhead.lineWidth = jogDeck == snapshot.deck ? 2.5 : 1.5
        (jogDeck == snapshot.deck ? ConsolePalette.warning : ConsolePalette.primaryText).setStroke()
        playhead.stroke()

        let marker = NSBezierPath()
        marker.move(to: NSPoint(x: rect.midX - 5, y: rect.maxY))
        marker.line(to: NSPoint(x: rect.midX + 5, y: rect.maxY))
        marker.line(to: NSPoint(x: rect.midX, y: rect.maxY - 7))
        marker.close()
        ConsolePalette.primaryText.setFill()
        marker.fill()
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

        let interval = 60 * Double(samplesCount) / (bpm * snapshot.duration)
        guard interval.isFinite, interval > 0 else { return }
        let firstBeatSample = firstBeatTime / snapshot.duration * Double(samplesCount)
        var beatIndex = Int(floor((Double(center - visibleHalf) - firstBeatSample) / interval))
        var beat = firstBeatSample + Double(beatIndex) * interval
        while beat <= Double(center + visibleHalf) {
            let offset = beat - Double(center - visibleHalf)
            let x = rect.minX + CGFloat(offset / Double(visibleHalf * 2)) * rect.width
            let downbeat = ((beatIndex % 4) + 4) % 4 == 0
            let line = NSBezierPath()
            line.move(to: NSPoint(x: x, y: rect.minY))
            line.line(to: NSPoint(x: x, y: rect.maxY))
            line.lineWidth = downbeat ? 1.2 : 0.7
            ConsolePalette.primaryText.withAlphaComponent(downbeat ? 0.22 : 0.09).setStroke()
            line.stroke()
            beatIndex += 1
            beat += interval
        }
    }

    private func drawDeckConsole(
        snapshot: DeckSnapshot,
        in rect: NSRect,
        layout: PerformanceLayout
    ) {
        ConsolePalette.surface.withAlphaComponent(0.72).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 7, yRadius: 7).fill()
        let color = deckColor(for: snapshot.deck)

        if let selector = layout.region(for: .selectDeck(snapshot.deck)) {
            drawDeckSelector(snapshot: snapshot, in: selector.frame, color: color)
        }

        let buttonControls: [PerformanceControl] = [
            .load(snapshot.deck), .cue(snapshot.deck), .togglePlay(snapshot.deck),
            .sync(snapshot.deck), .monitor(snapshot.deck),
        ]
        for control in buttonControls {
            guard let region = layout.region(for: control) else { continue }
            let active: Bool
            switch control {
            case .togglePlay: active = snapshot.isPlaying
            case .monitor: active = snapshot.monitorEnabled
            default: active = false
            }
            let titleOverride = control == .togglePlay(snapshot.deck) && snapshot.isPlaying
                ? "PAUSE"
                : nil
            drawControlButton(
                control,
                in: region.frame,
                accent: color,
                isActive: active,
                titleOverride: titleOverride
            )
        }

        let buttonsTop = buttonControls.compactMap { layout.region(for: $0)?.frame.maxY }.max()
            ?? rect.minY + 56
        let metricsRect = NSRect(
            x: rect.minX + 14,
            y: buttonsTop + 8,
            width: max(0, rect.width - 28),
            height: max(0, rect.maxY - 48 - buttonsTop - 12)
        )
        drawDeckMetrics(snapshot: snapshot, in: metricsRect, color: color)
    }

    private func drawDeckSelector(snapshot: DeckSnapshot, in rect: NSRect, color: NSColor) {
        if activeDeck == snapshot.deck {
            color.withAlphaComponent(0.14).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6).fill()
            color.setFill()
            NSRect(x: rect.minX, y: rect.maxY - 3, width: rect.width, height: 3).fill()
        }
        drawText(
            "DECK \(snapshot.deck.displayName)",
            in: NSRect(x: rect.minX + 12, y: rect.midY - 10, width: 105, height: 22),
            font: .systemFont(ofSize: 16, weight: .heavy),
            color: activeDeck == snapshot.deck ? color : ConsolePalette.primaryText
        )
        let state = activeDeck == snapshot.deck ? "ACTIVE  /  TAB" : "SELECT  /  TAB"
        drawText(
            state,
            in: NSRect(x: rect.maxX - 126, y: rect.midY - 7, width: 114, height: 16),
            font: .monospacedSystemFont(ofSize: 8, weight: .semibold),
            color: activeDeck == snapshot.deck ? color : ConsolePalette.secondaryText,
            alignment: .right
        )
    }

    private func drawDeckMetrics(snapshot: DeckSnapshot, in rect: NSRect, color: NSColor) {
        let meterOnRight = snapshot.deck == .a
        let meterRect = NSRect(
            x: meterOnRight ? rect.maxX - 16 : rect.minX,
            y: rect.minY,
            width: 16,
            height: rect.height
        )
        let dialRect = NSRect(
            x: meterOnRight ? rect.minX : rect.minX + 28,
            y: rect.minY,
            width: max(0, rect.width - 28),
            height: rect.height
        )
        let peak = snapshot.deck == .a ? displayedPeakA : displayedPeakB
        drawChannelMeter(peak: peak, in: meterRect, color: color)

        let values: [(String, Float, String)] = [
            ("VOL", snapshot.faderLevel, String(format: "%d%%", Int((snapshot.faderLevel * 100).rounded()))),
            ("FILTER", snapshot.filterLevel, String(format: "%d%%", Int((snapshot.filterLevel * 100).rounded()))),
            (
                abs(snapshot.pitchBendPercent) > 0.005 ? "BEND" : "TEMPO",
                Float(min(1, max(0, (snapshot.tempoPercent + snapshot.pitchBendPercent + 8) / 16))),
                String(format: "%+.2f%%", snapshot.tempoPercent + snapshot.pitchBendPercent)
            ),
        ]
        let cellWidth = dialRect.width / CGFloat(values.count)
        for (index, value) in values.enumerated() {
            drawParameterDial(
                label: value.0,
                level: value.1,
                value: value.2,
                in: NSRect(
                    x: dialRect.minX + CGFloat(index) * cellWidth,
                    y: dialRect.minY,
                    width: cellWidth,
                    height: dialRect.height
                ),
                color: color
            )
        }
    }

    private func drawParameterDial(
        label: String,
        level: Float,
        value: String,
        in rect: NSRect,
        color: NSColor
    ) {
        let diameter = min(58, rect.width - 12, rect.height - 36)
        let center = NSPoint(x: rect.midX, y: rect.midY + 5)
        let radius = max(12, diameter / 2)
        let segments = 22
        for index in 0..<segments {
            let progress = CGFloat(index) / CGFloat(segments - 1)
            let angle = (225 - 270 * progress) * .pi / 180
            let inner = radius - 5
            let outer = radius
            let path = NSBezierPath()
            path.move(to: NSPoint(
                x: center.x + cos(angle) * inner,
                y: center.y + sin(angle) * inner
            ))
            path.line(to: NSPoint(
                x: center.x + cos(angle) * outer,
                y: center.y + sin(angle) * outer
            ))
            path.lineWidth = progress <= CGFloat(level) ? 1.8 : 1
            (progress <= CGFloat(level)
                ? color.withAlphaComponent(0.85)
                : ConsolePalette.divider.withAlphaComponent(0.8)).setStroke()
            path.stroke()
        }

        ConsolePalette.raised.setFill()
        NSBezierPath(ovalIn: NSRect(
            x: center.x - radius + 9,
            y: center.y - radius + 9,
            width: (radius - 9) * 2,
            height: (radius - 9) * 2
        )).fill()
        let indicatorAngle = (225 - 270 * CGFloat(level)) * .pi / 180
        let indicator = NSBezierPath()
        indicator.move(to: center)
        indicator.line(to: NSPoint(
            x: center.x + cos(indicatorAngle) * (radius - 11),
            y: center.y + sin(indicatorAngle) * (radius - 11)
        ))
        indicator.lineWidth = 2
        color.setStroke()
        indicator.stroke()

        drawText(
            label,
            in: NSRect(x: rect.minX, y: rect.maxY - 12, width: rect.width, height: 12),
            font: .monospacedSystemFont(ofSize: 7, weight: .semibold),
            color: ConsolePalette.secondaryText,
            alignment: .center
        )
        drawText(
            value,
            in: NSRect(x: rect.minX, y: rect.minY, width: rect.width, height: 14),
            font: .monospacedSystemFont(ofSize: 8, weight: .medium),
            color: ConsolePalette.primaryText,
            alignment: .center
        )
    }

    private func drawChannelMeter(peak: Float, in rect: NSRect, color: NSColor) {
        drawText(
            "PFL",
            in: NSRect(x: rect.minX - 3, y: rect.maxY - 10, width: rect.width + 6, height: 10),
            font: .monospacedSystemFont(ofSize: 6, weight: .bold),
            color: ConsolePalette.secondaryText,
            alignment: .center
        )
        let finitePeak = peak.isFinite ? max(0.000_004, peak) : 0.000_004
        let decibels = 20 * log10(finitePeak)
        let normalized = min(1, max(0, (decibels + 48) / 48))
        let segments = 14
        let gap: CGFloat = 2
        let height = max(0, rect.height - 18)
        let segmentHeight = max(1, (height - gap * CGFloat(segments - 1)) / CGFloat(segments))
        for index in 0..<segments {
            let threshold = Float(index + 1) / Float(segments)
            let segment = NSRect(
                x: rect.midX - 4,
                y: rect.minY + CGFloat(index) * (segmentHeight + gap),
                width: 8,
                height: segmentHeight
            )
            let segmentColor: NSColor
            if threshold > 0.93 {
                segmentColor = ConsolePalette.error
            } else if threshold > 0.78 {
                segmentColor = ConsolePalette.warning
            } else {
                segmentColor = color
            }
            segmentColor.withAlphaComponent(threshold <= normalized ? 0.95 : 0.12).setFill()
            NSBezierPath(roundedRect: segment, xRadius: 1, yRadius: 1).fill()
        }
    }

    private func drawControlButton(
        _ control: PerformanceControl,
        in rect: NSRect,
        accent: NSColor,
        isActive: Bool,
        titleOverride: String? = nil,
        keyHintOverride: String? = nil
    ) {
        let enabled = isControlEnabled(control)
        let hovered = enabled && hoveredControl == control
        let pressed = enabled && pressedControl == control
        let fill: NSColor
        if !enabled {
            fill = ConsolePalette.raised.withAlphaComponent(0.32)
        } else if pressed {
            fill = accent.withAlphaComponent(0.38)
        } else if isActive {
            fill = accent.withAlphaComponent(0.24)
        } else if hovered {
            fill = ConsolePalette.raised.withAlphaComponent(0.95)
        } else {
            fill = ConsolePalette.raised.withAlphaComponent(0.62)
        }
        fill.setFill()
        let path = NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5)
        path.fill()
        (isActive || hovered ? accent : ConsolePalette.divider)
            .withAlphaComponent(enabled ? 0.85 : 0.32)
            .setStroke()
        path.lineWidth = isActive ? 1.5 : 1
        path.stroke()

        drawText(
            titleOverride ?? control.title,
            in: NSRect(x: rect.minX + 4, y: rect.midY - 2, width: rect.width - 8, height: 15),
            font: .systemFont(ofSize: control == .toggleOutputMode ? 10 : 9, weight: .bold),
            color: enabled ? ConsolePalette.primaryText : ConsolePalette.secondaryText.withAlphaComponent(0.45),
            alignment: .center
        )
        if let keyHint = keyHintOverride ?? control.keyHint {
            drawText(
                keyHint,
                in: NSRect(x: rect.minX + 4, y: rect.minY + 5, width: rect.width - 8, height: 10),
                font: .monospacedSystemFont(ofSize: 6.5, weight: .medium),
                color: enabled ? accent.withAlphaComponent(0.72) : ConsolePalette.secondaryText.withAlphaComponent(0.3),
                alignment: .center
            )
        }
    }

    private func drawPlatter(in rect: NSRect) {
        let snapshot = activeDeck == .a ? deckASnapshot : deckBSnapshot
        let color = deckColor(for: activeDeck)
        let outer = NSBezierPath(ovalIn: rect)
        ConsolePalette.surface.setFill()
        outer.fill()
        ConsolePalette.divider.setStroke()
        outer.lineWidth = 1
        outer.stroke()

        if let started = activeDeckTransitionStartedAt {
            if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                activeDeckTransitionStartedAt = nil
            } else {
                let progress = (CACurrentMediaTime() - started) / 0.16
                if progress < 1 {
                    color.withAlphaComponent(CGFloat(0.18 * (1 - progress))).setFill()
                    NSBezierPath(ovalIn: rect.insetBy(dx: -8, dy: -8)).fill()
                } else {
                    activeDeckTransitionStartedAt = nil
                }
            }
        }

        let center = NSPoint(x: rect.midX, y: rect.midY)
        let radius = rect.width / 2
        for index in 0..<48 {
            let angle = CGFloat(index) / 48 * .pi * 2
            let inner = radius - (index % 4 == 0 ? 10 : 6)
            let outerRadius = radius - 3
            let tick = NSBezierPath()
            tick.move(to: NSPoint(
                x: center.x + cos(angle) * inner,
                y: center.y + sin(angle) * inner
            ))
            tick.line(to: NSPoint(
                x: center.x + cos(angle) * outerRadius,
                y: center.y + sin(angle) * outerRadius
            ))
            tick.lineWidth = index % 4 == 0 ? 1.5 : 0.8
            (index % 4 == 0 ? color : ConsolePalette.divider)
                .withAlphaComponent(index % 4 == 0 ? 0.8 : 0.7)
                .setStroke()
            tick.stroke()
        }

        let innerRect = rect.insetBy(dx: rect.width * 0.18, dy: rect.height * 0.18)
        ConsolePalette.raised.withAlphaComponent(0.8).setFill()
        NSBezierPath(ovalIn: innerRect).fill()

        let playbackTime = max(0, snapshot.extendedProgress * snapshot.duration)
        let shouldAnimate = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion || jogDeck != nil
        let turns = shouldAnimate ? playbackTime * (33.333 / 60) : 0
        let angle = CGFloat(turns.truncatingRemainder(dividingBy: 1)) * .pi * 2
        let marker = NSBezierPath()
        marker.move(to: center)
        marker.line(to: NSPoint(
            x: center.x + cos(angle) * (radius - 17),
            y: center.y + sin(angle) * (radius - 17)
        ))
        marker.lineWidth = 2.5
        color.setStroke()
        marker.stroke()

        let mode = jogMode == .pitchBend ? "BEND" : "SCRATCH"
        drawText(
            activeDeck.displayName,
            in: NSRect(x: innerRect.minX, y: center.y - 12, width: innerRect.width, height: 34),
            font: .systemFont(ofSize: 28, weight: .heavy),
            color: color,
            alignment: .center
        )
        drawText(
            mode,
            in: NSRect(x: innerRect.minX, y: center.y - 29, width: innerRect.width, height: 14),
            font: .monospacedSystemFont(ofSize: 8, weight: .bold),
            color: jogMode == .pitchBend ? ConsolePalette.warning : ConsolePalette.secondaryText,
            alignment: .center
        )
        if jogDeck != nil {
            let suffix = jogMode == .pitchBend ? "%" : "×"
            drawText(
                String(format: "%+.2f%@", jogValue, suffix),
                in: NSRect(x: innerRect.minX, y: center.y - 44, width: innerRect.width, height: 13),
                font: .monospacedSystemFont(ofSize: 8, weight: .medium),
                color: ConsolePalette.primaryText,
                alignment: .center
            )
        }

        let controllingID = session.activeTouches.keys.min()
        for touch in session.activeTouches.values {
            let touchCenter = NSPoint(
                x: innerRect.minX + touch.position.x * innerRect.width,
                y: innerRect.minY + touch.position.y * innerRect.height
            )
            let controlling = touch.identity == controllingID
            drawCircle(
                center: touchCenter,
                radius: controlling ? 10 : 6,
                fill: color.withAlphaComponent(controlling ? 0.24 : 0.10)
            )
            drawCircle(
                center: touchCenter,
                radius: controlling ? 3 : 2,
                fill: controlling ? color : ConsolePalette.secondaryText
            )
        }

        if isCursorLocked {
            drawText(
                "LOCKED",
                in: NSRect(x: rect.minX, y: rect.minY + 12, width: rect.width, height: 13),
                font: .monospacedSystemFont(ofSize: 8, weight: .bold),
                color: ConsolePalette.primaryText,
                alignment: .center
            )
        }
    }

    private func drawCrossfader(in rect: NSRect) {
        drawText(
            "CROSSFADER · GATE",
            in: NSRect(x: rect.minX, y: rect.maxY - 11, width: rect.width, height: 10),
            font: .monospacedSystemFont(ofSize: 7, weight: .bold),
            color: ConsolePalette.secondaryText,
            alignment: .center
        )
        let selected = CrossfaderState(rawValue: mixerSnapshot.crossfaderValue) ?? .both
        let labels = ["A ON", "A+B ON", "B ON"]
        let colors = [ConsolePalette.deckA, ConsolePalette.primaryText, ConsolePalette.deckB]
        let gap: CGFloat = 3
        let segmentWidth = (rect.width - gap * 2) / 3

        for (index, state) in CrossfaderState.allCases.enumerated() {
            let segment = NSRect(
                x: rect.minX + CGFloat(index) * (segmentWidth + gap),
                y: rect.minY + 2,
                width: segmentWidth,
                height: 22
            )
            let isSelected = state == selected
            let color = colors[index]
            let path = NSBezierPath(roundedRect: segment, xRadius: 4, yRadius: 4)
            (isSelected ? color.withAlphaComponent(0.28) : ConsolePalette.raised.withAlphaComponent(0.45)).setFill()
            path.fill()
            (isSelected ? color : ConsolePalette.divider).setStroke()
            path.lineWidth = 1
            path.stroke()
            drawText(
                labels[index],
                in: segment.insetBy(dx: 2, dy: 5),
                font: .monospacedSystemFont(ofSize: 8, weight: .bold),
                color: isSelected ? color : ConsolePalette.secondaryText,
                alignment: .center
            )
        }
    }

    private func drawBottomRail(_ rect: NSRect) {
        let line = NSBezierPath()
        line.move(to: NSPoint(x: rect.minX, y: rect.maxY))
        line.line(to: NSPoint(x: rect.maxX, y: rect.maxY))
        line.lineWidth = 1
        ConsolePalette.divider.withAlphaComponent(0.65).setStroke()
        line.stroke()

        drawText(
            "TAB  SWITCH     ⇧ + TOUCH  BEND     P  CURSOR     ESC  RELEASE",
            in: NSRect(x: rect.minX, y: rect.minY + 9, width: rect.width * 0.58, height: 13),
            font: .monospacedSystemFont(ofSize: 8, weight: .medium),
            color: ConsolePalette.secondaryText
        )
        let status = cursorStatusMessage
            ?? statusMessage
            ?? "TRACKPAD = JOG  /  BUTTON HOVER = CLICK"
        drawText(
            status,
            in: NSRect(
                x: rect.minX + rect.width * 0.55,
                y: rect.minY + 9,
                width: rect.width * 0.45,
                height: 13
            ),
            font: .monospacedSystemFont(ofSize: 8, weight: .medium),
            color: cursorStatusMessage == nil ? ConsolePalette.secondaryText : ConsolePalette.error,
            alignment: .right
        )
    }

    private func drawText(
        _ string: String,
        in rect: NSRect,
        font: NSFont,
        color: NSColor,
        alignment: NSTextAlignment = .left
    ) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment
        paragraph.lineBreakMode = .byTruncatingTail
        (string as NSString).draw(
            in: rect,
            withAttributes: [
                .font: font,
                .foregroundColor: color,
                .paragraphStyle: paragraph,
            ]
        )
    }

    private func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "--:--" }
        let value = Int(seconds)
        return String(format: "%d:%02d", value / 60, value % 60)
    }

    private func deckColor(for deck: DeckID) -> NSColor {
        switch deck {
        case .a: return ConsolePalette.deckA
        case .b: return ConsolePalette.deckB
        }
    }
}
