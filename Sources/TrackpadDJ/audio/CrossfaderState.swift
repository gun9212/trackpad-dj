/// Crossfader position model.
/// value: 0.0 = full Deck A, 1.0 = full Deck B
struct CrossfaderState {
    let value: Float

    static let center = CrossfaderState(value: 0.5)
    static let step: Float = 0.02

    init(value: Float) {
        self.value = max(0, min(1, value))
    }

    func nudged(by delta: Float) -> CrossfaderState {
        CrossfaderState(value: value + delta)
    }

    func stepped(toward direction: Int) -> CrossfaderState {
        guard direction != 0 else { return self }
        if direction < 0 {
            return CrossfaderState(value: value > 0.5 ? 0.5 : 0.0)
        }
        return CrossfaderState(value: value < 0.5 ? 0.5 : 1.0)
    }

    func snapped(to end: End) -> CrossfaderState {
        CrossfaderState(value: end == .deckA ? 0.0 : 1.0)
    }

    enum End { case deckA, deckB }
}
