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

    // Deck channel faders [0, 1]. Combined with crossfader for final volume.
    private(set) var faderA: Float = 1.0
    private(set) var faderB: Float = 1.0
    private var crossfaderValue: Float = 0.5

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
        crossfaderValue = state.value
        applyVolumes()
    }

    // MARK: - Channel Faders

    /// Adjust channel fader by vertical touch delta. Full height = full range.
    func setFader(deck: DeckID, deltaY: Float) {
        switch deck {
        case .a: faderA = max(0, min(1, faderA + deltaY))
        case .b: faderB = max(0, min(1, faderB + deltaY))
        }
        applyVolumes()
    }

    private func applyVolumes() {
        // Scratch crossfader curve: one deck is always at full gain.
        // 0.0→0.5: A=full, B fades in.  0.5: both full.  0.5→1.0: B=full, A fades out.
        let v = crossfaderValue
        let aGain: Float = v <= 0.5 ? 1.0 : Float(1.0 - (v - 0.5) * 2.0)
        let bGain: Float = v >= 0.5 ? 1.0 : Float(v * 2.0)
        _deckA.volume = faderA * aGain
        _deckB.volume = faderB * bGain
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

    // MARK: - Scratch

    /// Called on each touchesMoved in a deck zone (1-finger).
    /// rate: 0 = freeze, 1.0 = normal speed, negative = reverse.
    func setScratch(deck: DeckID, rate: Double) {
        let d = deck == .a ? _deckA : _deckB
        d.scratchRate = rate
        d.isScratchActive = true
    }

    /// Called when the finger lifts from a deck zone.
    func endScratch(deck: DeckID) {
        let d = deck == .a ? _deckA : _deckB
        d.isScratchActive = false
        d.scratchRate = 1.0
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
