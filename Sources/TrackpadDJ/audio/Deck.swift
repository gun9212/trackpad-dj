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
    private var wasScratchActive = false
    private let rateSmoothing: Double
    private let gainSmoothing: Float
    private var outputGain: Float = 1
    private let scratchResampler = ScratchResampler()
    private var jumpOldPosition: Double = 0
    private var jumpOldRate: Double = 0
    private var jumpOldGain: Float = 0
    private var jumpFramesRemaining = 0
    private let jumpFrameCount: Int

    init(audio: DeckAudioData, state: DeckRealtimeState) {
        self.audio = audio
        self.state = state
        readPosition = -audio.preRollFrames
        consumedSeekGeneration = state.currentSeekGeneration
        rateSmoothing = 1 - exp(-1 / (0.002 * audio.format.sampleRate))
        gainSmoothing = Float(1 - exp(-1 / (0.001 * audio.format.sampleRate)))
        jumpFrameCount = max(1, Int(audio.format.sampleRate * 0.002))
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
            if command.startsPlayback {
                jumpOldPosition = readPosition
                jumpOldRate = wasScratchActive ? smoothedRate : state.normalPlaybackRate
                jumpOldGain = state.isPlaying || state.isScratchActive ? outputGain : 0
                jumpFramesRemaining = jumpFrameCount
                state.setPlaying(true)
            } else {
                jumpFramesRemaining = 0
            }
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
        let normalRate = state.normalPlaybackRate
        if isScratchActive, !wasScratchActive {
            smoothedRate = 0
        } else if !isScratchActive {
            smoothedRate = normalRate
        }
        wasScratchActive = isScratchActive
        let targetRate = isScratchActive ? state.targetScratchRate : normalRate

        let sourceChannelCount = Int(audio.format.channelCount)
        let channelCount = min(sourceChannelCount, output.count)
        let totalFrames = Int(audio.buffer.frameLength)
        var preFaderPeak: Float = 0

        for frame in 0..<Int(frameCount) {
            if isScratchActive {
                smoothedRate += (targetRate - smoothedRate) * rateSmoothing
                if targetRate == 0, abs(smoothedRate) < 0.000_01 { smoothedRate = 0 }
            }
            let advance = isScratchActive ? smoothedRate : normalRate
            // Fade near standstill rather than emitting a held (DC) sample indefinitely.
            let scratchGain = isScratchActive ? Float(min(1, abs(advance) / 0.03)) : 1
            outputGain += (scratchGain - outputGain) * gainSmoothing
            if scratchGain == 0, outputGain < 0.000_01 { outputGain = 0 }
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
                    // Scratching across the end must not clear transport intent.
                    if !isScratchActive {
                        state.setPlaying(false)
                    }
                }
                continue
            }

            let fraction = Float(readPosition - Double(sourceIndex))
            for channel in 0..<channelCount {
                let samples = output[channel].mData?.assumingMemoryBound(to: Float.self)
                let interpolated = Self.cubicHermite(
                    channelData[channel],
                    at: sourceIndex,
                    fraction: fraction,
                    totalFrames: totalFrames
                )
                let speed = abs(advance)
                let filtered = isScratchActive && speed > 1
                    ? scratchResampler.sample(channelData[channel], position: readPosition,
                                              speed: speed, frameCount: totalFrames)
                    : interpolated
                let wet = isScratchActive ? Float(min(1, max(0, (speed - 1) * 4))) : 0
                var sample = (interpolated + (filtered - interpolated) * wet) * outputGain
                if jumpFramesRemaining > 0 {
                    let oldIndex = Int(floor(jumpOldPosition))
                    let oldSample: Float = oldIndex >= 0 && oldIndex < totalFrames
                        ? Self.cubicHermite(channelData[channel], at: oldIndex,
                                            fraction: Float(jumpOldPosition - Double(oldIndex)),
                                            totalFrames: totalFrames) * jumpOldGain : 0
                    let oldWeight = Float(jumpFramesRemaining) / Float(jumpFrameCount)
                    sample = oldSample * oldWeight + sample * (1 - oldWeight)
                }
                samples?[frame] = sample
                preFaderPeak = max(preFaderPeak, abs(sample))
            }

            readPosition = clampPosition(readPosition + advance)
            if jumpFramesRemaining > 0 {
                jumpOldPosition = clampPosition(jumpOldPosition + jumpOldRate)
                jumpFramesRemaining -= 1
            }
        }

        state.publish(readPosition: readPosition)
        state.publish(preFaderPeak: preFaderPeak)
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

    /// Post-EQ master path. Channel fader and crossfader gains are applied here.
    let mixerNode = AVAudioMixerNode()

    /// Post-EQ, pre-fader monitor path. It is disconnected in stereo master mode.
    let cueMixerNode = AVAudioMixerNode()

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
    private(set) var beatGrid: BeatGrid?
    private(set) var automaticBeatGrid: BeatGrid?
    private(set) var trackID: TrackID?
    private(set) var hotCues: [Double?] = Array(repeating: nil, count: 4)

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

    var cueVolume: Float {
        get { cueMixerNode.outputVolume }
        set { cueMixerNode.outputVolume = newValue }
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

    var pitchBendPercent: Double {
        realtimeState.pitchBendPercent
    }

    func consumePreFaderPeak() -> Float {
        realtimeState.consumePreFaderPeak()
    }

    func install(_ track: LoadedTrack) {
        let state = DeckRealtimeState()
        state.reset(initialPosition: -track.audio.preRollFrames)
        let renderer = DeckRenderer(audio: track.audio, state: state)

        realtimeState = state
        trackName = track.name
        trackID = track.trackID
        hotCues = Array(repeating: nil, count: 4)
        processingFormat = track.audio.format
        waveformSamples = track.waveformSamples
        automaticBeatGrid = track.beatGrid
        beatGrid = track.beatGrid
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

    func applyHotCues(_ positions: [Double?]) {
        hotCues = HotCueSlot.allCases.map { slot in
            guard positions.indices.contains(slot.index), let time = positions[slot.index],
                  time.isFinite, time >= 0, time < duration else { return nil }
            return time
        }
    }

    /// Returns true only when an empty slot was filled; calls never overwrite saved cues.
    @discardableResult
    func activateHotCue(_ slot: HotCueSlot) -> Bool {
        guard let audioData, audioData.frameLength > 0 else { return false }
        if let time = hotCues[slot.index] {
            realtimeState.requestSeek(to: min(audioData.frameLength - 1, time * audioData.format.sampleRate),
                                      startsPlayback: true)
            return false
        }
        let frame = min(audioData.frameLength - 1, max(0, realtimeState.publicReadPosition))
        hotCues[slot.index] = frame / audioData.format.sampleRate
        return true
    }

    @discardableResult
    func clearHotCue(_ slot: HotCueSlot) -> Bool {
        guard hotCues[slot.index] != nil else { return false }
        hotCues[slot.index] = nil
        return true
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

    func setPitchBendPercent(_ value: Double) {
        realtimeState.setPitchBendPercent(value)
    }

    func endPitchBend() {
        realtimeState.setPitchBendPercent(0)
    }

    func setTempoPercent(_ value: Double) {
        realtimeState.setTempoPercent(value)
    }

    func adjustTempoPercent(by delta: Double) {
        setTempoPercent(tempoPercent + delta)
    }

    func resetTempo() {
        setTempoPercent(0)
    }

    func applyBeatGrid(_ beatGrid: BeatGrid?) {
        self.beatGrid = beatGrid
    }

    func restoreAutomaticBeatGrid() {
        beatGrid = automaticBeatGrid
    }

}
