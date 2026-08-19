import Foundation

enum CrossfaderCurve {

    /// Existing scratch-style curve: one deck stays at unity while the other fades.
    static func scratchStyleGains(at value: Float) -> (deckA: Float, deckB: Float) {
        let clamped = max(0, min(1, value))
        let deckA: Float = clamped <= 0.5 ? 1.0 : 1.0 - (clamped - 0.5) * 2.0
        let deckB: Float = clamped >= 0.5 ? 1.0 : clamped * 2.0
        return (deckA, deckB)
    }
}
