enum CrossfaderGate {

    /// A three-position output gate. Enabled decks keep their channel-fader gain.
    static func gains(for state: CrossfaderState) -> (deckA: Float, deckB: Float) {
        switch state {
        case .deckAOnly:
            return (1, 0)
        case .both:
            return (1, 1)
        case .deckBOnly:
            return (0, 1)
        }
    }
}
