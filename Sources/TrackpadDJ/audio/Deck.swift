import AVFoundation

/// A single playback deck wrapping AVAudioPlayerNode.
/// Supports load, play/pause toggle, cue, and seek-based scrubbing.
final class Deck: DeckProtocol {

    let player = AVAudioPlayerNode()

    private(set) var isPlaying = false

    /// Output volume [0, 1]. Set by crossfader or deck fader.
    var volume: Float {
        get { player.volume }
        set { player.volume = newValue }
    }
    private var file: AVAudioFile?
    private var isScheduled = false
    private(set) var currentFrame: AVAudioFramePosition = 0

    // MARK: - Transport

    func load(url: URL) throws {
        player.stop()
        file = try AVAudioFile(forReading: url)
        currentFrame = 0
        isScheduled = false
        isPlaying = false
    }

    func togglePlayPause() {
        guard let file = file else { return }
        if isPlaying {
            player.pause()
            isPlaying = false
        } else {
            if !isScheduled {
                scheduleFromCurrentFrame(file)
            }
            player.play()
            isPlaying = true
        }
    }

    /// Stop and return to the beginning of the track.
    func cue() {
        guard let file = file else { return }
        player.stop()
        currentFrame = 0
        scheduleFromCurrentFrame(file)
        isPlaying = false
    }

    // MARK: - Scrubbing

    /// Seek by a normalized delta [-1, 1] relative to the full track length.
    /// Positive = forward, negative = backward.
    func scrub(normalizedDelta: Double) {
        guard let file = file else { return }
        let sampleRate = file.fileFormat.sampleRate
        // 15 seconds per full trackpad width
        let frameDelta = AVAudioFramePosition(normalizedDelta * 15.0 * sampleRate)
        let newFrame = max(0, min(file.length - 1, currentFrame + frameDelta))
        guard newFrame != currentFrame else { return }
        currentFrame = newFrame

        let wasPlaying = isPlaying
        player.stop()
        scheduleFromCurrentFrame(file)
        if wasPlaying {
            player.play()
        }
    }

    // MARK: - Info

    var trackName: String? {
        file?.url.deletingPathExtension().lastPathComponent
    }

    var processingFormat: AVAudioFormat? {
        file?.processingFormat
    }

    // MARK: - Private

    private func scheduleFromCurrentFrame(_ file: AVAudioFile) {
        let remaining = AVAudioFrameCount(file.length - currentFrame)
        guard remaining > 0 else { return }
        player.scheduleSegment(file, startingFrame: currentFrame, frameCount: remaining, at: nil)
        isScheduled = true
    }
}
