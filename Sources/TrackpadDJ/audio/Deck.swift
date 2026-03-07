import AVFoundation

enum DeckError: Error {
    case bufferAllocationFailed
}

/// AVAudioSourceNode-based deck.
/// Loads the entire file into a PCM buffer and controls playback
/// position directly in the render callback — no stop/restart for scrubbing.
final class Deck: DeckProtocol {

    // MARK: - Audio Nodes

    /// Stable mixer node used for volume control.
    /// Always connected to the engine; survives file changes.
    let mixerNode = AVAudioMixerNode()

    /// Recreated on each file load. Managed by AudioEngine.
    private(set) var sourceNode: AVAudioSourceNode?

    // MARK: - State

    private(set) var isPlaying: Bool = false
    private(set) var trackName: String?
    private(set) var processingFormat: AVAudioFormat?

    var volume: Float {
        get { mixerNode.outputVolume }
        set { mixerNode.outputVolume = newValue }
    }

    // Accessed from both main thread and audio render thread.
    // Double/Bool reads on 64-bit ARM/x86 are effectively atomic — acceptable for prototype.
    private var buffer: AVAudioPCMBuffer?
    private var readPosition: Double = 0.0

    // MARK: - DeckProtocol

    func load(url: URL) throws {
        isPlaying = false  // stop before swapping buffer

        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let frameCount = AVAudioFrameCount(file.length)

        guard let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            throw DeckError.bufferAllocationFailed
        }
        try file.read(into: buf)

        trackName = file.url.deletingPathExtension().lastPathComponent
        processingFormat = format
        readPosition = 0.0
        buffer = buf

        sourceNode = AVAudioSourceNode(format: format) { [weak self] isSilence, _, frameCount, audioBufferList -> OSStatus in
            guard let self, self.isPlaying, let buf = self.buffer else {
                isSilence.pointee = true
                return noErr
            }
            self.render(into: audioBufferList, frameCount: frameCount, buffer: buf)
            return noErr
        }
    }

    func togglePlayPause() {
        guard buffer != nil else { return }
        isPlaying.toggle()
    }

    func cue() {
        isPlaying = false
        readPosition = 0.0
    }

    func scrub(normalizedDelta: Double) {
        guard let buf = buffer else { return }
        // 15 seconds per full trackpad width
        let frameDelta = normalizedDelta * 15.0 * buf.format.sampleRate
        readPosition = max(0, min(Double(buf.frameLength) - 1, readPosition + frameDelta))
    }

    // MARK: - Render Callback (audio thread)

    private func render(
        into audioBufferList: UnsafeMutablePointer<AudioBufferList>,
        frameCount: AVAudioFrameCount,
        buffer: AVAudioPCMBuffer
    ) {
        let abl = UnsafeMutableAudioBufferListPointer(audioBufferList)
        guard let channelData = buffer.floatChannelData else { return }

        let channelCount = min(Int(buffer.format.channelCount), abl.count)
        let totalFrames = Int(buffer.frameLength)

        for frame in 0..<Int(frameCount) {
            let srcInt = Int(readPosition)

            if srcInt >= totalFrames {
                for ch in 0..<channelCount {
                    abl[ch].mData?.assumingMemoryBound(to: Float.self)[frame] = 0
                }
                continue
            }

            // Linear interpolation for sub-frame accuracy
            let frac = Float(readPosition - Double(srcInt))
            let nextInt = min(srcInt + 1, totalFrames - 1)

            for ch in 0..<channelCount {
                let s = channelData[ch][srcInt] * (1 - frac) + channelData[ch][nextInt] * frac
                abl[ch].mData?.assumingMemoryBound(to: Float.self)[frame] = s
            }

            readPosition += 1.0
        }
    }
}
