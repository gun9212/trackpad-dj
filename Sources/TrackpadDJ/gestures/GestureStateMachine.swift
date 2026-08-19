import CoreGraphics
import Foundation

enum GestureInputEvent: Equatable, Sendable {
    case began([TouchPoint])
    case moved([TouchPoint])
    case ended([TouchID])
    case cancelled
    case tick(TimeInterval)
}

struct GestureStateMachine {

    struct Configuration: Equatable, Sendable {
        var axisLockDistance: CGFloat = 0.006
        var dominanceRatio: CGFloat = 1.25
        var scratchSensitivity: Double = 3.3
        var scratchRange: ClosedRange<Double> = -8.0...8.0
        var stationaryTimeout: TimeInterval = 0.050

        static let `default` = Configuration()
    }

    private enum Axis {
        case horizontal
        case vertical
    }

    private struct ControlState {
        let zone: Zone.Name
        let origin: TouchPoint
        let volumeDeck: DeckID?
        var lastPoint: TouchPoint
        var axis: Axis?
        var lastScratchMovement: TimeInterval?
        var scratchTargetIsZero = true
    }

    let configuration: Configuration
    private(set) var session: TouchSession = .empty

    private var controllingTouchByZone: [Zone.Name: TouchID] = [:]
    private var controls: [TouchID: ControlState] = [:]

    init(configuration: Configuration = .default) {
        self.configuration = configuration
    }

    mutating func process(_ event: GestureInputEvent) -> [DJAction] {
        switch event {
        case .began(let touches):
            return touchesBegan(touches)
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

    private mutating func touchesBegan(_ touches: [TouchPoint]) -> [DJAction] {
        var actions: [DJAction] = []

        for touch in touches.sorted(by: Self.touchOrder) {
            session = session.adding(touch)
            guard let zone = ZoneLayout.zone(for: touch.position)?.name,
                  controllingTouchByZone[zone] == nil else { continue }

            controllingTouchByZone[zone] = touch.identity
            let volumeDeck: DeckID? = zone == .topStrip ? (touch.position.x < 0.5 ? .a : .b) : nil
            controls[touch.identity] = ControlState(
                zone: zone,
                origin: touch,
                volumeDeck: volumeDeck,
                lastPoint: touch
            )

            if let deck = Self.deck(for: zone) {
                actions.append(.setScratch(deck, 0))
            }
        }

        return actions
    }

    private mutating func touchesMoved(_ touches: [TouchPoint]) -> [DJAction] {
        var actions: [DJAction] = []

        for touch in touches.sorted(by: Self.touchOrder) {
            guard session.activeTouches[touch.identity] != nil else { continue }
            session = session.updating(touch)
            guard var control = controls[touch.identity] else { continue }

            let deltaX = touch.position.x - control.lastPoint.position.x
            let deltaY = touch.position.y - control.lastPoint.position.y

            switch control.zone {
            case .topStrip:
                if let deck = control.volumeDeck, deltaY != 0 {
                    actions.append(.adjustVolume(deck, Float(deltaY)))
                }
            case .bottomStrip:
                if deltaX != 0 {
                    actions.append(.adjustCrossfader(Float(deltaX)))
                }
            case .deckA, .deckB:
                guard let deck = Self.deck(for: control.zone) else { break }
                if control.axis == nil {
                    control.axis = lockedAxis(
                        from: control.origin.position,
                        to: touch.position
                    )
                }

                switch control.axis {
                case .horizontal:
                    if deltaX != 0 {
                        actions.append(.adjustFilter(deck, Float(deltaX)))
                    }
                case .vertical:
                    let elapsed = touch.timestamp - control.lastPoint.timestamp
                    if elapsed > 0, deltaY != 0 {
                        let velocity = Double(deltaY) / elapsed
                        let unclampedRate = velocity * configuration.scratchSensitivity
                        let rate = min(
                            configuration.scratchRange.upperBound,
                            max(configuration.scratchRange.lowerBound, unclampedRate)
                        )
                        actions.append(.setScratch(deck, rate))
                        control.lastScratchMovement = touch.timestamp
                        control.scratchTargetIsZero = rate == 0
                    }
                case nil:
                    break
                }
            }

            control.lastPoint = touch
            controls[touch.identity] = control
        }

        return actions
    }

    private mutating func touchesEnded(_ identities: [TouchID]) -> [DJAction] {
        var actions: [DJAction] = []

        for identity in identities.sorted() {
            session = session.removing(identity: identity)
            guard let control = controls.removeValue(forKey: identity) else { continue }
            controllingTouchByZone.removeValue(forKey: control.zone)
            if let deck = Self.deck(for: control.zone) {
                actions.append(.endScratch(deck))
            }
        }

        return actions
    }

    private mutating func cancelAll() -> [DJAction] {
        let actions = controls
            .sorted { $0.key < $1.key }
            .compactMap { Self.deck(for: $0.value.zone).map(DJAction.endScratch) }
        session = .empty
        controls.removeAll(keepingCapacity: true)
        controllingTouchByZone.removeAll(keepingCapacity: true)
        return actions
    }

    private mutating func advanceTime(to timestamp: TimeInterval) -> [DJAction] {
        var actions: [DJAction] = []

        for identity in controls.keys.sorted() {
            guard var control = controls[identity],
                  control.axis == .vertical,
                  !control.scratchTargetIsZero,
                  let lastMovement = control.lastScratchMovement,
                  timestamp - lastMovement >= configuration.stationaryTimeout,
                  let deck = Self.deck(for: control.zone) else { continue }

            control.scratchTargetIsZero = true
            controls[identity] = control
            actions.append(.setScratch(deck, 0))
        }

        return actions
    }

    private func lockedAxis(from origin: CGPoint, to current: CGPoint) -> Axis? {
        let deltaX = abs(current.x - origin.x)
        let deltaY = abs(current.y - origin.y)
        guard max(deltaX, deltaY) >= configuration.axisLockDistance else { return nil }

        if deltaX >= deltaY * configuration.dominanceRatio {
            return .horizontal
        }
        if deltaY >= deltaX * configuration.dominanceRatio {
            return .vertical
        }
        return nil
    }

    private static func deck(for zone: Zone.Name) -> DeckID? {
        switch zone {
        case .deckA: return .a
        case .deckB: return .b
        case .topStrip, .bottomStrip: return nil
        }
    }

    private static func touchOrder(_ lhs: TouchPoint, _ rhs: TouchPoint) -> Bool {
        if lhs.timestamp == rhs.timestamp {
            return lhs.identity < rhs.identity
        }
        return lhs.timestamp < rhs.timestamp
    }
}
