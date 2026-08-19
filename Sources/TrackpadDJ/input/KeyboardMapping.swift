import Foundation

enum KeyboardMapping {

    static func oneShotAction(for keyCode: UInt16, shift: Bool) -> DJAction? {
        switch keyCode {
        case 123: return .stepCrossfader(-1) // Left arrow
        case 124: return .stepCrossfader(1)  // Right arrow
        case 12: return .load(.a)            // Q
        case 13: return .load(.b)            // W
        case 0: return .togglePlay(.a)       // A
        case 1: return .togglePlay(.b)       // S
        case 6: return .cue(.a)              // Z
        case 7: return .cue(.b)              // X
        case 11: return .tapBPM(.a)          // B
        case 45: return .tapBPM(.b)          // N
        case 18, 19, 20, 21:                 // 1, 2, 3, 4
            let index = Int(keyCode) - 18
            return shift ? .setHotCue(.a, index) : .jumpToHotCue(.a, index)
        case 26, 28, 25, 29:                 // 7, 8, 9, 0
            let indexByKey: [UInt16: Int] = [26: 0, 28: 1, 25: 2, 29: 3]
            guard let index = indexByKey[keyCode] else { return nil }
            return shift ? .setHotCue(.b, index) : .jumpToHotCue(.b, index)
        default:
            return nil
        }
    }

    static func isHeldKey(_ keyCode: UInt16) -> Bool {
        heldKeyCodes.contains(keyCode)
    }

    static func handles(_ keyCode: UInt16, shift: Bool) -> Bool {
        oneShotAction(for: keyCode, shift: shift) != nil || isHeldKey(keyCode)
    }

    private static let heldKeyCodes: Set<UInt16> = [
        14, 2, 15, 3,       // Volume: E/D, R/F
        17, 5, 16, 4,       // Filter: T/G, Y/H
        126, 125, 34, 40,   // Nudge: Up/Down, I/K
    ]
}

struct KeyboardStateMachine {

    private(set) var pressedKeys: Set<UInt16> = []

    mutating func keyDown(keyCode: UInt16, isRepeat: Bool, shift: Bool) -> [DJAction] {
        let oneShot = KeyboardMapping.oneShotAction(for: keyCode, shift: shift)
        guard oneShot != nil || KeyboardMapping.isHeldKey(keyCode) else { return [] }

        let inserted = pressedKeys.insert(keyCode).inserted
        guard inserted, !isRepeat, let oneShot else { return [] }
        return [oneShot]
    }

    mutating func keyUp(keyCode: UInt16) {
        pressedKeys.remove(keyCode)
    }

    mutating func focusLost() {
        pressedKeys.removeAll(keepingCapacity: true)
    }

    func heldActions() -> [DJAction] {
        var actions: [DJAction] = []
        appendHeldAction(
            positiveKey: 14, negativeKey: 2,
            scale: 0.008,
            makeAction: { .adjustVolume(.a, $0) },
            to: &actions
        )
        appendHeldAction(
            positiveKey: 15, negativeKey: 3,
            scale: 0.008,
            makeAction: { .adjustVolume(.b, $0) },
            to: &actions
        )
        appendHeldAction(
            positiveKey: 17, negativeKey: 5,
            scale: 0.003,
            makeAction: { .adjustFilter(.a, $0) },
            to: &actions
        )
        appendHeldAction(
            positiveKey: 16, negativeKey: 4,
            scale: 0.003,
            makeAction: { .adjustFilter(.b, $0) },
            to: &actions
        )
        appendHeldAction(
            positiveKey: 126, negativeKey: 125,
            scale: 0.001,
            makeAction: { .nudge(.a, $0) },
            to: &actions
        )
        appendHeldAction(
            positiveKey: 34, negativeKey: 40,
            scale: 0.001,
            makeAction: { .nudge(.b, $0) },
            to: &actions
        )
        return actions
    }

    private func appendHeldAction(
        positiveKey: UInt16,
        negativeKey: UInt16,
        scale: Float,
        makeAction: (Float) -> DJAction,
        to actions: inout [DJAction]
    ) {
        let positive: Float = pressedKeys.contains(positiveKey) ? 1 : 0
        let negative: Float = pressedKeys.contains(negativeKey) ? 1 : 0
        let direction = positive - negative
        if direction != 0 {
            actions.append(makeAction(direction * scale))
        }
    }
}
