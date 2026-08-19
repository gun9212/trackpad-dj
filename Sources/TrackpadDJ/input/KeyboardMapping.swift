import Foundation

enum KeyboardCommand: Equatable {
    case stepCrossfader(Int)
    case load(AudioEngine.DeckID)
    case togglePlay(AudioEngine.DeckID)
    case cue(AudioEngine.DeckID)
    case tapBPM(AudioEngine.DeckID)
    case setHotCue(AudioEngine.DeckID, Int)
    case jumpToHotCue(AudioEngine.DeckID, Int)
}

enum HeldKeyboardControl: Equatable {
    case volume(AudioEngine.DeckID, Float)
    case filter(AudioEngine.DeckID, Float)
    case nudge(AudioEngine.DeckID, Float)
}

enum KeyboardMapping {

    static func command(
        for keyCode: UInt16,
        isRepeat: Bool,
        shift: Bool
    ) -> KeyboardCommand? {
        guard !isRepeat else { return nil }

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

    static func heldControl(for keyCode: UInt16) -> HeldKeyboardControl? {
        switch keyCode {
        case 14: return .volume(.a, 1)  // E
        case 2: return .volume(.a, -1)  // D
        case 15: return .volume(.b, 1)  // R
        case 3: return .volume(.b, -1)  // F
        case 17: return .filter(.a, 1)  // T
        case 5: return .filter(.a, -1)  // G
        case 16: return .filter(.b, 1)  // Y
        case 4: return .filter(.b, -1)  // H
        case 126: return .nudge(.a, 1)  // Up arrow
        case 125: return .nudge(.a, -1) // Down arrow
        case 34: return .nudge(.b, 1)   // I
        case 40: return .nudge(.b, -1)  // K
        default: return nil
        }
    }
}
