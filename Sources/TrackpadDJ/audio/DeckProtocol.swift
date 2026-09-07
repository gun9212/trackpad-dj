import Foundation

/// Common interface for a single DJ deck.
///
/// Current implementation: `Deck` (AVAudioSourceNode-based)
/// Future implementation: `SuperpoweredDeck` (if key-lock / BPM analysis needed)
@MainActor
protocol DeckProtocol: AnyObject {

    /// Whether the deck is currently playing.
    var isPlaying: Bool { get }

    /// Display name of the loaded track, nil if no track loaded.
    var trackName: String? { get }

    /// Output volume [0.0, 1.0]. Controlled externally by crossfader or deck fader.
    var volume: Float { get set }

    // MARK: - Transport

    func install(_ track: LoadedTrack)
    func togglePlayPause()
    func cue()
    var hotCues: [Double?] { get }
    func applyHotCues(_ positions: [Double?])
    @discardableResult func activateHotCue(_ slot: HotCueSlot) -> Bool
    @discardableResult func clearHotCue(_ slot: HotCueSlot) -> Bool

    // MARK: - Jog / Scrub

    /// Scrub forward (positive) or backward (negative) by a normalized delta.
    /// Full trackpad width (1.0) corresponds to a fixed number of seconds.
    func scrub(normalizedDelta: Double)

    // MARK: - Realtime Controls

    func setScratch(rate: Double)
    func endScratch()
    func setPitchBendPercent(_ value: Double)
    func endPitchBend()
    func setTempoPercent(_ value: Double)
    func adjustTempoPercent(by delta: Double)
    func resetTempo()
    var tempoPercent: Double { get }
    var pitchBendPercent: Double { get }

    // MARK: - Beat Grid

    var beatGrid: BeatGrid? { get }
    var automaticBeatGrid: BeatGrid? { get }
    func applyBeatGrid(_ beatGrid: BeatGrid?)
    func restoreAutomaticBeatGrid()

    // MARK: - Waveform

    /// Peak-amplitude waveform data, downsampled on load. Empty until a track is loaded.
    var waveformSamples: [Float] { get }

    /// Playback position normalized to [0, 1].
    var playbackProgress: Double { get }

    /// Pre-roll 포함 진행도. 음수 = 프리롤 구간, 0~1 = 실제 트랙.
    var extendedProgress: Double { get }

    /// Total track duration in seconds. 0 if no track loaded.
    var duration: Double { get }
}
