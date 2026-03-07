import AVFoundation

/// Owns the AVAudioEngine and both decks.
/// Signal chain: player → mainMixerNode (reconnected with file format on load)
final class AudioEngine {

    enum DeckID { case a, b }

    // Public protocol interface — ViewController and View depend only on this.
    var deckA: any DeckProtocol { _deckA }
    var deckB: any DeckProtocol { _deckB }

    // Private concrete types — needed for AVAudioEngine graph management.
    private let _deckA = Deck()
    private let _deckB = Deck()

    private let engine = AVAudioEngine()

    init() {
        setup()
    }

    // MARK: - Setup

    // Current lowpass cutoff per deck [200, 20_000] Hz.
    private var cutoffA: Float = 20_000
    private var cutoffB: Float = 20_000

    private func setup() {
        // Attach stable nodes — these persist across file loads.
        // Signal chain: sourceNode → mixerNode → eqNode → mainMixerNode
        engine.attach(_deckA.mixerNode)
        engine.attach(_deckA.eqNode)
        engine.attach(_deckB.mixerNode)
        engine.attach(_deckB.eqNode)

        let main = engine.mainMixerNode
        engine.connect(_deckA.mixerNode, to: _deckA.eqNode, format: nil)
        engine.connect(_deckA.eqNode, to: main, format: nil)
        engine.connect(_deckB.mixerNode, to: _deckB.eqNode, format: nil)
        engine.connect(_deckB.eqNode, to: main, format: nil)

        do {
            try engine.start()
        } catch {
            print("AudioEngine: failed to start — \(error)")
        }
    }

    // MARK: - Crossfader

    /// Linear crossfade: value 0 = full A, 1 = full B.
    func applyCrossfader(_ state: CrossfaderState) {
        _deckA.volume = 1.0 - state.value
        _deckB.volume = state.value
    }

    // MARK: - Track Loading

    func loadTrack(url: URL, deck: DeckID) throws {
        let d = deck == .a ? _deckA : _deckB

        // Detach old sourceNode before creating a new one.
        if let old = d.sourceNode {
            engine.detach(old)
        }

        try d.load(url: url)

        // Attach new sourceNode and wire it into the stable mixerNode.
        if let src = d.sourceNode, let format = d.processingFormat {
            engine.attach(src)
            engine.connect(src, to: d.mixerNode, format: format)
        }
    }

    // MARK: - Transport

    func togglePlayPause(deck: DeckID) {
        switch deck {
        case .a: _deckA.togglePlayPause()
        case .b: _deckB.togglePlayPause()
        }
    }

    func cue(deck: DeckID) {
        switch deck {
        case .a: _deckA.cue()
        case .b: _deckB.cue()
        }
    }

    // MARK: - Scrubbing

    /// Called on each touchesMoved event in a deck zone.
    /// deltaX is normalized trackpad delta (positive = forward in track).
    func scrub(deck: DeckID, deltaX: Float) {
        switch deck {
        case .a: _deckA.scrub(normalizedDelta: Double(deltaX))
        case .b: _deckB.scrub(normalizedDelta: Double(deltaX))
        }
    }

    // MARK: - Filter

    /// Adjust lowpass cutoff via 2-finger vertical gesture.
    /// deltaY is normalized trackpad delta: positive = up = open filter.
    /// Full height (1.0) spans ~2 decades (200 Hz → 20 kHz).
    func setFilter(deck: DeckID, deltaY: Float) {
        let d = deck == .a ? _deckA : _deckB
        var cutoff = deck == .a ? cutoffA : cutoffB

        // Logarithmic scaling: Δ1.0 → ×100 in frequency.
        cutoff *= pow(10, deltaY * 2.0)
        cutoff = max(200, min(20_000, cutoff))

        if deck == .a { cutoffA = cutoff } else { cutoffB = cutoff }
        d.eqNode.bands[0].frequency = cutoff
    }
}
