import Foundation

enum CrossfaderCurve {

    /// Constant-power blend: each deck is -3 dB at the center position.
    static func equalPowerGains(at value: Float) -> (deckA: Float, deckB: Float) {
        let clamped = max(0, min(1, value))
        if clamped == 0 { return (1, 0) }
        if clamped == 1 { return (0, 1) }
        let angle = Double(clamped) * .pi / 2
        return (Float(cos(angle)), Float(sin(angle)))
    }
}
