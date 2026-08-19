/// Three-position output selector. Enabled decks always keep unity crossfader gain.
enum CrossfaderState: Float, CaseIterable, Equatable, Sendable {
    case deckAOnly = 0
    case both = 0.5
    case deckBOnly = 1

    static let center = CrossfaderState.both

    var value: Float { rawValue }

    func stepped(toward direction: Int) -> CrossfaderState {
        guard direction != 0 else { return self }
        switch (self, direction < 0) {
        case (.deckBOnly, true), (.deckAOnly, false):
            return .both
        case (.both, true):
            return .deckAOnly
        case (.both, false):
            return .deckBOnly
        default:
            return self
        }
    }
}
