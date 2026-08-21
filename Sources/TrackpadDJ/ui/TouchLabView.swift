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
        let reducesMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let renderState = PerformanceConsoleRenderState(
            bounds: bounds,
            deckA: deckASnapshot,
            deckB: deckBSnapshot,
            mixer: mixerSnapshot,
            activeDeck: activeDeck,
            jogDeck: jogDeck,
            jogMode: jogMode,
            jogValue: jogValue,
            touchSession: session,
            isCursorLocked: isCursorLocked,
            hoveredControl: hoveredControl,
            pressedControl: pressedControl,
            displayedPeakA: displayedPeakA,
            displayedPeakB: displayedPeakB,
            activeDeckTransitionProgress: activeDeckTransitionProgress(reducesMotion: reducesMotion),
            reducesMotion: reducesMotion,
            statusMessage: statusMessage,
            cursorStatusMessage: cursorStatusMessage
        )
        PerformanceConsoleRenderer(state: renderState).draw()
    }

    private func activeDeckTransitionProgress(reducesMotion: Bool) -> Double? {
        guard let started = activeDeckTransitionStartedAt else { return nil }
        if reducesMotion {
            activeDeckTransitionStartedAt = nil
            return nil
        }

        let progress = (CACurrentMediaTime() - started) / 0.16
        guard progress < 1 else {
            activeDeckTransitionStartedAt = nil
            return nil
        }
        return progress
    }
}
