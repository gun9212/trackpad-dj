import AVFoundation

/// Owns the AVAudioEngine and both decks.
/// Crossfader is applied as a linear volume split across the two player nodes.
final class AudioEngine {

    enum DeckID { case a, b }

    let deckA = Deck()
    let deckB = Deck()

    private let engine = AVAudioEngine()

    init() {
        setup()
    }

    // MARK: - Setup

    private func setup() {
        engine.attach(deckA.player)
        engine.attach(deckB.player)

        let main = engine.mainMixerNode
        engine.connect(deckA.player, to: main, format: nil)
        engine.connect(deckB.player, to: main, format: nil)

        do {
            try engine.start()
        } catch {
            print("AudioEngine: failed to start — \(error)")
        }
    }

    // MARK: - Crossfader

    /// Linear crossfade: value 0 = full A, 1 = full B.
    func applyCrossfader(_ state: CrossfaderState) {
        deckA.player.volume = 1.0 - state.value
        deckB.player.volume = state.value
    }

    // MARK: - Track Loading

    func loadTrack(url: URL, deck: DeckID) throws {
        switch deck {
        case .a: try deckA.load(url: url)
        case .b: try deckB.load(url: url)
        }
    }

    // MARK: - Transport

    func togglePlayPause(deck: DeckID) {
        switch deck {
        case .a: deckA.togglePlayPause()
        case .b: deckB.togglePlayPause()
        }
    }

    func cue(deck: DeckID) {
        switch deck {
        case .a: deckA.cue()
        case .b: deckB.cue()
        }
    }
}
