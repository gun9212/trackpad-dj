import CoreGraphics
import Foundation

enum GestureInputEvent: Equatable, Sendable {
    case frame([TouchPoint], deck: DeckID, mode: JogMode)
    case began([TouchPoint], deck: DeckID, mode: JogMode)
    case moved([TouchPoint])
    case ended([TouchID])
    case cancelled
    case tick(TimeInterval)
}

struct GestureStateMachine {

    struct Configuration: Equatable, Sendable {
        var scratchSensitivity: Double = 3.3
        var scratchRange: ClosedRange<Double> = -8.0...8.0
        var bendSensitivity: Double = 8.0
        var bendRange: ClosedRange<Double> = -8.0...8.0
        var stationaryTimeout: TimeInterval = 0.020

        static let `default` = Configuration()
    }

    private struct ControlState {
        var lastPoints: [TouchID: TouchPoint]
        let deck: DeckID
        let mode: JogMode
        var lastMovement: TimeInterval?
        var targetIsZero = true
    }

    let configuration: Configuration
    private(set) var session: TouchSession = .empty
    private var control: ControlState?

    init(configuration: Configuration = .default) {
        self.configuration = configuration
    }

    mutating func process(_ event: GestureInputEvent) -> [DJAction] {
        switch event {
        case .frame(let touches, let deck, let mode):
            // Reconcile the complete touching set so a missed end cannot retain a ghost controller.
            let present = Set(touches.map(\.identity))
            var actions = touchesEnded(session.activeTouches.keys.filter { !present.contains($0) })
            let newTouches = touches.filter { session.activeTouches[$0.identity] == nil }
            actions += touchesBegan(newTouches, deck: deck, mode: mode)
            actions += touchesMoved(touches)
            return actions
        case .began(let touches, let deck, let mode):
            return touchesBegan(touches, deck: deck, mode: mode)
        case .moved(let touches):
            return touchesMoved(touches)
        case .ended(let identities):
            return touchesEnded(identities)
        case .cancelled:
            return cancelAll()
        case .tick(let timestamp):
            return advanceTime(to: timestamp)
        }
    }

    private mutating func touchesBegan(
        _ touches: [TouchPoint],
        deck: DeckID,
        mode: JogMode
    ) -> [DJAction] {
        let sorted = touches.sorted(by: Self.touchOrder)
        let previousCount = session.count
        for touch in sorted {
            session = session.adding(touch)
        }

        guard previousCount < 2, session.count >= 2, control == nil,
              let activationTime = sorted.last?.timestamp else { return [] }

        let pair = session.activeTouches.values.sorted(by: Self.touchOrder).prefix(2)
        control = ControlState(
            lastPoints: Dictionary(uniqueKeysWithValues: pair.map {
                ($0.identity, TouchPoint(identity: $0.identity, position: $0.position,
                                        timestamp: activationTime))
            }),
            deck: deck,
            mode: mode
        )
        return [startAction(deck: deck, mode: mode)]
    }

    private mutating func touchesMoved(_ touches: [TouchPoint]) -> [DJAction] {
        var current = control
        var velocities: [Double] = []
        var lastMovement: TimeInterval?

        for touch in touches.sorted(by: Self.touchOrder) {
            guard session.activeTouches[touch.identity] != nil else { continue }
            session = session.updating(touch)
            guard let previous = current?.lastPoints[touch.identity] else { continue }

            let deltaY = touch.position.y - previous.position.y
            let elapsed = touch.timestamp - previous.timestamp
            if elapsed > 0 {
                velocities.append(Double(deltaY) / elapsed)
                if deltaY != 0 {
                    lastMovement = max(lastMovement ?? touch.timestamp, touch.timestamp)
                }
            }
            current?.lastPoints[touch.identity] = touch
        }

        control = current
        guard var current, !velocities.isEmpty else { return [] }
        // Fixed pair denominator: tiny motion of the resting finger must not halve the rate.
        let target = targetValue(velocity: velocities.reduce(0, +) / Double(current.lastPoints.count),
                                 mode: current.mode)
        if target == 0, current.targetIsZero { return [] }
        current.lastMovement = lastMovement
        current.targetIsZero = target == 0
        control = current
        return [updateAction(deck: current.deck, mode: current.mode, value: target)]
    }

    private mutating func touchesEnded(_ identities: [TouchID]) -> [DJAction] {
        var actions: [DJAction] = []

        for identity in identities.sorted() {
            session = session.removing(identity: identity)
            if let current = control, current.lastPoints[identity] != nil {
                actions.append(endAction(deck: current.deck, mode: current.mode))
                control = nil
            }
        }

        if session.count < 2, let current = control {
            actions.append(endAction(deck: current.deck, mode: current.mode))
            control = nil
        }
        return actions
    }

    private mutating func cancelAll() -> [DJAction] {
        let actions = control.map { [endAction(deck: $0.deck, mode: $0.mode)] } ?? []
        session = .empty
        control = nil
        return actions
    }

    private mutating func advanceTime(to timestamp: TimeInterval) -> [DJAction] {
        guard var current = control,
              !current.targetIsZero,
              let lastMovement = current.lastMovement,
              timestamp - lastMovement >= configuration.stationaryTimeout else {
            return []
        }

        current.targetIsZero = true
        control = current
        return [updateAction(deck: current.deck, mode: current.mode, value: 0)]
    }

    private func targetValue(velocity: Double, mode: JogMode) -> Double {
        switch mode {
        case .scratch:
            return clamp(
                velocity * configuration.scratchSensitivity,
                to: configuration.scratchRange
            )
        case .pitchBend:
            return clamp(
                velocity * configuration.bendSensitivity,
                to: configuration.bendRange
            )
        }
    }

    private func clamp(_ value: Double, to range: ClosedRange<Double>) -> Double {
        min(range.upperBound, max(range.lowerBound, value))
    }

    private func startAction(deck: DeckID, mode: JogMode) -> DJAction {
        updateAction(deck: deck, mode: mode, value: 0)
    }

    private func updateAction(deck: DeckID, mode: JogMode, value: Double) -> DJAction {
        switch mode {
        case .scratch: return .setScratch(deck, value)
        case .pitchBend: return .setPitchBend(deck, value)
        }
    }

    private func endAction(deck: DeckID, mode: JogMode) -> DJAction {
        switch mode {
        case .scratch: return .endScratch(deck)
        case .pitchBend: return .endPitchBend(deck)
        }
    }

    private static func touchOrder(_ lhs: TouchPoint, _ rhs: TouchPoint) -> Bool {
        if lhs.timestamp == rhs.timestamp {
            return lhs.identity < rhs.identity
        }
        return lhs.timestamp < rhs.timestamp
    }
}
