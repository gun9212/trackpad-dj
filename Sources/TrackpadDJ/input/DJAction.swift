import Foundation

enum DeckID: Equatable, Hashable, Sendable {
    case a
    case b

    var other: DeckID {
        self == .a ? .b : .a
    }

    var displayName: String {
        self == .a ? "A" : "B"
    }
}

enum JogMode: Equatable, Sendable {
    case scratch
    case pitchBend
}

/// Input translated into operations meaningful to the DJ domain.
enum DJAction: Equatable, Sendable {
    case selectActiveDeck(DeckID)
    case stepCrossfader(Int)
    case load(DeckID)
    case togglePlay(DeckID)
    case cue(DeckID)
    case activateHotCue(DeckID, HotCueSlot)
    case clearHotCue(DeckID, HotCueSlot)
    case nudge(DeckID, Float)
    case adjustFilter(DeckID, Float)
    case adjustVolume(DeckID, Float)
    case adjustTempo(DeckID, Double)
    case resetTempo(DeckID)
    case toggleMonitor(DeckID)
    case toggleOutputMode
    case setScratch(DeckID, Double)
    case endScratch(DeckID)
    case setPitchBend(DeckID, Double)
    case endPitchBend(DeckID)
    case tapBPM(DeckID)
    case restoreAutomaticBPM(DeckID)
    case syncTempo(DeckID)
    case toggleCursorLock
    case cancelJogAndUnlock
}
