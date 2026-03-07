import Foundation

/// Common interface for a single DJ deck.
///
/// Current implementation: `Deck` (AVAudioSourceNode-based)
/// Future implementation: `SuperpoweredDeck` (if key-lock / BPM analysis needed)
protocol DeckProtocol: AnyObject {

    /// Whether the deck is currently playing.
    var isPlaying: Bool { get }

    /// Display name of the loaded track, nil if no track loaded.
    var trackName: String? { get }

    /// Output volume [0.0, 1.0]. Controlled externally by crossfader or deck fader.
    var volume: Float { get set }

    // MARK: - Transport

    func load(url: URL) throws
    func togglePlayPause()
    func cue()

    // MARK: - Jog / Scrub

    /// Scrub forward (positive) or backward (negative) by a normalized delta.
    /// Full trackpad width (1.0) corresponds to a fixed number of seconds.
    func scrub(normalizedDelta: Double)
}
