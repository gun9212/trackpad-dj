import AVFoundation

/// A single playback deck wrapping AVAudioPlayerNode.
/// Supports load, play/pause toggle, and cue (return to start).
final class Deck {

    let player = AVAudioPlayerNode()

    private(set) var isPlaying = false
    private var file: AVAudioFile?
    private var isScheduled = false

    // MARK: - Transport

    func load(url: URL) throws {
        player.stop()
        file = try AVAudioFile(forReading: url)
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
                player.scheduleFile(file, at: nil)
                isScheduled = true
            }
            player.play()
            isPlaying = true
        }
    }

    /// Stop and return to the beginning of the track.
    func cue() {
        guard let file = file else { return }
        player.stop()
        player.scheduleFile(file, at: nil)
        isScheduled = true
        isPlaying = false
    }

    var trackName: String? {
        file?.url.deletingPathExtension().lastPathComponent
    }

    /// The processing format of the loaded file, used to reconnect the player node.
    var processingFormat: AVAudioFormat? {
        file?.processingFormat
    }
}
