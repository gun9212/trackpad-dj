import AVFoundation

/// Immutable PCM data captured by exactly one source-node renderer.
final class DeckAudioData: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer
    let format: AVAudioFormat
    let preRollFrames: Double

    init(buffer: AVAudioPCMBuffer, format: AVAudioFormat, preRollFrames: Double) {
        self.buffer = buffer
        self.format = format
        self.preRollFrames = preRollFrames
    }

    var frameLength: Double {
        Double(buffer.frameLength)
    }
}

/// Owns the mutable playhead. Only the AVAudioSourceNode render callback calls `render`.
final class DeckRenderer: @unchecked Sendable {
    private let audio: DeckAudioData
    private let state: DeckRealtimeState
    private var readPosition: Double
    private var consumedSeekGeneration: UInt64
    private var smoothedRate: Double = 1

    init(audio: DeckAudioData, state: DeckRealtimeState) {
        self.audio = audio
        self.state = state
        readPosition = -audio.preRollFrames
        consumedSeekGeneration = state.currentSeekGeneration
        state.publish(readPosition: readPosition)
    }

    func render(
        isSilence: UnsafeMutablePointer<ObjCBool>,
        frameCount: AVAudioFrameCount,
        audioBufferList: UnsafeMutablePointer<AudioBufferList>
    ) -> OSStatus {
        let output = UnsafeMutableAudioBufferListPointer(audioBufferList)
        clear(output)

        if let command = state.seekCommand(after: consumedSeekGeneration) {
            consumedSeekGeneration = command.generation
            readPosition = clampPosition(command.targetFrame)
        }

        let isPlaying = state.isPlaying
        let isScratchActive = state.isScratchActive
        guard isPlaying || isScratchActive,
              let channelData = audio.buffer.floatChannelData else {
            isSilence.pointee = true
            state.publish(readPosition: readPosition)
            return noErr
        }

        isSilence.pointee = false
        let normalRate = 1 + state.tempoPercent / 100
        let alpha = 0.3
        if isScratchActive {
            smoothedRate = smoothedRate * (1 - alpha) + state.targetScratchRate * alpha
        } else {
            smoothedRate = normalRate
        }
        let advance = isScratchActive ? smoothedRate : normalRate

        let sourceChannelCount = Int(audio.format.channelCount)
        let channelCount = min(sourceChannelCount, output.count)
        let totalFrames = Int(audio.buffer.frameLength)

        for frame in 0..<Int(frameCount) {
            let sourceIndex = Int(floor(readPosition))

            if sourceIndex < 0 {
                readPosition = max(-audio.preRollFrames, readPosition + advance)
                continue
            }

            if sourceIndex >= totalFrames {
                if advance < 0 {
                    readPosition = max(-audio.preRollFrames, readPosition + advance)
                } else {
                    readPosition = Double(totalFrames)
                    state.setPlaying(false)
                }
                continue
            }

            let fraction = Float(readPosition - Double(sourceIndex))
            for channel in 0..<channelCount {
                let samples = output[channel].mData?.assumingMemoryBound(to: Float.self)
                samples?[frame] = Self.cubicHermite(
                    channelData[channel],
                    at: sourceIndex,
                    fraction: fraction,
                    totalFrames: totalFrames
                )
            }

            readPosition = clampPosition(readPosition + advance)
        }

        state.publish(readPosition: readPosition)
        return noErr
    }

    private func clear(_ output: UnsafeMutableAudioBufferListPointer) {
        for buffer in output {
            guard let data = buffer.mData else { continue }
            data.initializeMemory(
                as: UInt8.self,
                repeating: 0,
                count: Int(buffer.mDataByteSize)
            )
        }
    }

    private func clampPosition(_ value: Double) -> Double {
        min(audio.frameLength, max(-audio.preRollFrames, value))
    }

    @inline(__always)
    private static func cubicHermite(
        _ data: UnsafePointer<Float>,
        at index: Int,
        fraction: Float,
        totalFrames: Int
    ) -> Float {
        let p0 = data[max(0, index - 1)]
        let p1 = data[index]
        let p2 = data[min(totalFrames - 1, index + 1)]
        let p3 = data[min(totalFrames - 1, index + 2)]

        let a = -0.5 * p0 + 1.5 * p1 - 1.5 * p2 + 0.5 * p3
        let b = p0 - 2.5 * p1 + 2.0 * p2 - 0.5 * p3
        let c = -0.5 * p0 + 0.5 * p2
        return ((a * fraction + b) * fraction + c) * fraction + p1
    }
}

/// Main-actor graph facade. Render-time mutation lives exclusively in `DeckRenderer`.
@MainActor
final class Deck: DeckProtocol {

    let mixerNode = AVAudioMixerNode()

    let eqNode: AVAudioUnitEQ = {
        let eq = AVAudioUnitEQ(numberOfBands: 1)
        eq.bands[0].filterType = .lowPass
        eq.bands[0].frequency = 20_000
        eq.bands[0].bypass = false
        return eq
    }()

    private(set) var sourceNode: AVAudioSourceNode?
    private(set) var processingFormat: AVAudioFormat?
    private(set) var trackName: String?
    private(set) var waveformSamples: [Float] = []

    private var realtimeState = DeckRealtimeState()
    private var audioData: DeckAudioData?
    private var renderer: DeckRenderer?

    var isPlaying: Bool {
        realtimeState.isPlaying
    }

    var volume: Float {
        get { mixerNode.outputVolume }
        set { mixerNode.outputVolume = newValue }
    }

    var playbackProgress: Double {
        guard let audioData, audioData.frameLength > 0 else { return 0 }
        return min(max(realtimeState.publicReadPosition, 0) / audioData.frameLength, 1)
    }

    var extendedProgress: Double {
        guard let audioData, audioData.frameLength > 0 else { return 0 }
        return realtimeState.publicReadPosition / audioData.frameLength
    }

    var duration: Double {
        guard let audioData else { return 0 }
        return audioData.frameLength / audioData.format.sampleRate
    }

    var tempoPercent: Double {
        realtimeState.tempoPercent
    }

    func install(_ track: LoadedTrack) {
        let state = DeckRealtimeState()
        state.reset(initialPosition: -track.audio.preRollFrames)
        let renderer = DeckRenderer(audio: track.audio, state: state)

        realtimeState = state
        trackName = track.name
        processingFormat = track.audio.format
        waveformSamples = track.waveformSamples
        audioData = track.audio
        self.renderer = renderer
        sourceNode = AVAudioSourceNode(format: track.audio.format) { isSilence, _, frameCount, buffers in
            renderer.render(
                isSilence: isSilence,
                frameCount: frameCount,
                audioBufferList: buffers
            )
        }
    }

    func togglePlayPause() {
        guard audioData != nil else { return }
        realtimeState.togglePlaying()
    }

    func cue() {
        guard let audioData else { return }
        realtimeState.setPlaying(false)
        realtimeState.requestSeek(to: -audioData.preRollFrames)
    }

    func scrub(normalizedDelta: Double) {
        guard let audioData else { return }
        let frameDelta = normalizedDelta * 15 * audioData.format.sampleRate
        let target = min(
            audioData.frameLength,
            max(-audioData.preRollFrames, realtimeState.publicReadPosition + frameDelta)
        )
        realtimeState.requestSeek(to: target)
    }

    func setScratch(rate: Double) {
        realtimeState.setScratch(active: true, rate: rate)
    }

    func endScratch() {
        realtimeState.setScratch(active: false, rate: 0)
    }

    func setTempoPercent(_ value: Double) {
        realtimeState.setTempoPercent(value)
    }

}
