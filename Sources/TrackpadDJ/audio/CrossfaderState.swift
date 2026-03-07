/// Crossfader position model.
/// value: 0.0 = full Deck A, 1.0 = full Deck B
struct CrossfaderState {
    let value: Float

    static let center = CrossfaderState(value: 0.5)
    static let step: Float = 0.02

    func nudged(by delta: Float) -> CrossfaderState {
        CrossfaderState(value: max(0.0, min(1.0, value + delta)))
    }

    func snapped(to end: End) -> CrossfaderState {
        CrossfaderState(value: end == .deckA ? 0.0 : 1.0)
    }

    enum End { case deckA, deckB }
}
