import Foundation

enum DeckID: Equatable, Hashable, Sendable {
    case a
    case b
}

/// Input translated into operations meaningful to the DJ domain.
enum DJAction: Equatable, Sendable {
    case adjustCrossfader(Float)
    case stepCrossfader(Int)
    case load(DeckID)
    case togglePlay(DeckID)
    case cue(DeckID)
    case nudge(DeckID, Float)
    case adjustFilter(DeckID, Float)
    case adjustVolume(DeckID, Float)
    case adjustTempo(DeckID, Double)
    case resetTempo(DeckID)
    case toggleMonitor(DeckID)
    case toggleOutputMode
    case setScratch(DeckID, Double)
    case endScratch(DeckID)
    case tapBPM(DeckID)
    case setHotCue(DeckID, Int)
    case jumpToHotCue(DeckID, Int)
}
