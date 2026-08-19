import Foundation

enum KeyboardMapping {

    static func oneShotAction(
        for keyCode: UInt16,
        shift: Bool,
        activeDeck: DeckID
    ) -> DJAction? {
        switch keyCode {
        case 48: return .selectActiveDeck(activeDeck.other) // Tab
        case 123: return .stepCrossfader(-1)                // Left arrow
        case 124: return .stepCrossfader(1)                 // Right arrow
        case 12: return .load(activeDeck)                    // Q
        case 49: return .togglePlay(activeDeck)              // Space
        case 8: return .cue(activeDeck)                      // C
        case 1: return .syncTempo(activeDeck)                // S
        case 23: return .resetTempo(activeDeck)              // 5
        case 11:                                             // B / Shift+B
            return shift ? .restoreAutomaticBPM(activeDeck) : .tapBPM(activeDeck)
        case 9: return .toggleMonitor(activeDeck)            // V
        case 46: return .toggleOutputMode                    // M
        case 35: return .toggleCursorLock                    // P
        case 53: return .cancelJogAndUnlock                  // Escape
        default:
            return nil
        }
    }

    static func isHeldKey(_ keyCode: UInt16) -> Bool {
        heldKeyCodes.contains(keyCode)
    }

    static func handles(
        _ keyCode: UInt16,
        shift: Bool,
        hasSystemModifier: Bool = false
    ) -> Bool {
        guard !hasSystemModifier else { return false }
        return oneShotAction(for: keyCode, shift: shift, activeDeck: .a) != nil
            || isHeldKey(keyCode)
    }

    private static let heldKeyCodes: Set<UInt16> = [
        14, 2,       // Volume: E/D
        15, 3,       // Filter: R/F
        17, 5,       // Tempo: T/G
        126, 125,    // Nudge: Up/Down
    ]
}

struct KeyboardStateMachine {

    private(set) var activeDeck: DeckID = .a
    private(set) var pressedKeys: Set<UInt16> = []
    private var heldDeckByKey: [UInt16: DeckID] = [:]

    mutating func selectActiveDeck(_ deck: DeckID) -> DJAction? {
        guard activeDeck != deck else { return nil }
        activeDeck = deck
        return .selectActiveDeck(deck)
    }

    mutating func keyDown(keyCode: UInt16, isRepeat: Bool, shift: Bool) -> [DJAction] {
        let oneShot = KeyboardMapping.oneShotAction(
            for: keyCode,
            shift: shift,
            activeDeck: activeDeck
        )
        guard oneShot != nil || KeyboardMapping.isHeldKey(keyCode) else { return [] }

        let inserted = pressedKeys.insert(keyCode).inserted
        guard inserted, !isRepeat else { return [] }

        if KeyboardMapping.isHeldKey(keyCode) {
            heldDeckByKey[keyCode] = activeDeck
            return []
        }

        guard let oneShot else { return [] }
        if case .selectActiveDeck(let deck) = oneShot {
            _ = selectActiveDeck(deck)
        }
        return [oneShot]
    }

    mutating func keyUp(keyCode: UInt16) {
        pressedKeys.remove(keyCode)
        heldDeckByKey.removeValue(forKey: keyCode)
    }

    mutating func focusLost() {
        pressedKeys.removeAll(keepingCapacity: true)
        heldDeckByKey.removeAll(keepingCapacity: true)
    }

    func heldActions() -> [DJAction] {
        var actions: [DJAction] = []
        for deck in [DeckID.a, .b] {
            appendHeldAction(
                positiveKey: 14, negativeKey: 2,
                deck: deck,
                scale: 0.008,
                makeAction: DJAction.adjustVolume,
                to: &actions
            )
            appendHeldAction(
                positiveKey: 15, negativeKey: 3,
                deck: deck,
                scale: 0.003,
                makeAction: DJAction.adjustFilter,
                to: &actions
            )
            appendHeldAction(
                positiveKey: 126, negativeKey: 125,
                deck: deck,
                scale: 0.001,
                makeAction: DJAction.nudge,
                to: &actions
            )
            let tempoDirection = heldDirection(
                positiveKey: 17,
                negativeKey: 5,
                deck: deck
            )
            if tempoDirection != 0 {
                actions.append(.adjustTempo(deck, Double(tempoDirection) * 0.05))
            }
        }
        return actions
    }

    private func heldDirection(
        positiveKey: UInt16,
        negativeKey: UInt16,
        deck: DeckID
    ) -> Float {
        let positive: Float = heldDeckByKey[positiveKey] == deck ? 1 : 0
        let negative: Float = heldDeckByKey[negativeKey] == deck ? 1 : 0
        return positive - negative
    }

    private func appendHeldAction(
        positiveKey: UInt16,
        negativeKey: UInt16,
        deck: DeckID,
        scale: Float,
        makeAction: (DeckID, Float) -> DJAction,
        to actions: inout [DJAction]
    ) {
        let direction = heldDirection(
            positiveKey: positiveKey,
            negativeKey: negativeKey,
            deck: deck
        )
        if direction != 0 {
            actions.append(makeAction(deck, direction * scale))
        }
    }
}
