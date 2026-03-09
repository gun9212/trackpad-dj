import AVFoundation

enum DeckError: Error {
    case bufferAllocationFailed
}

/// AVAudioSourceNode-based deck.
/// Playback uses 4-point cubic Hermite interpolation for both normal and scratch modes.
/// Scratch = varispeed: readPosition advances at scratchRate frames/output-frame,
/// so pitch naturally shifts with speed — matching the vinyl record model.
final class Deck: DeckProtocol {

    // MARK: - Audio Nodes

    let mixerNode = AVAudioMixerNode()

    let eqNode: AVAudioUnitEQ = {
        let eq = AVAudioUnitEQ(numberOfBands: 1)
        eq.bands[0].filterType = .lowPass
        eq.bands[0].frequency = 20_000
        eq.bands[0].bypass = false
        return eq
    }()

    private(set) var sourceNode: AVAudioSourceNode?

    // MARK: - Playback State

    private(set) var isPlaying: Bool = false
    private(set) var trackName: String?
    private(set) var processingFormat: AVAudioFormat?

    var volume: Float {
        get { mixerNode.outputVolume }
        set { mixerNode.outputVolume = newValue }
    }

    private(set) var waveformSamples: [Float] = []

    var playbackProgress: Double {
        guard let buf = buffer, buf.frameLength > 0 else { return 0 }
        return min(max(readPosition, 0) / Double(buf.frameLength), 1.0)
    }

    var extendedProgress: Double {
        guard let buf = buffer, buf.frameLength > 0 else { return 0 }
        return readPosition / Double(buf.frameLength)  // 음수 허용 (프리롤 구간)
    }

    var duration: Double {
        guard let buf = buffer, let fmt = processingFormat else { return 0 }
        return Double(buf.frameLength) / fmt.sampleRate
    }

    // Accessed from audio render thread.
    // Double/Bool reads on 64-bit ARM/x86 are effectively atomic — acceptable for prototype.
    private var buffer: AVAudioPCMBuffer?
    private var readPosition: Double = 0.0

    /// 2-second silent pre-roll before frame 0. Lets user scratch from silence into the track.
    private var preRollFrames: Double = 0.0

    /// Playback rate for scratch. 1.0 = normal, negative = reverse, 0 = freeze.
    var scratchRate: Double = 1.0
    /// True while a finger is on the deck zone.
    var isScratchActive: Bool = false

    /// 오디오 렌더 스레드 전용 — EMA 저역통과 필터로 scratchRate 스무딩.
    private var smoothedRate: Double = 1.0

    // MARK: - DeckProtocol

    func load(url: URL) throws {
        isPlaying = false

        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let frameCount = AVAudioFrameCount(file.length)

        guard let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            throw DeckError.bufferAllocationFailed
        }
        try file.read(into: buf)

        trackName = file.url.deletingPathExtension().lastPathComponent
        processingFormat = format
        preRollFrames = format.sampleRate * 2.0  // 2 seconds of silent pre-roll
        readPosition = -preRollFrames            // cue starts in silence
        waveformSamples = Self.downsample(buf, targetCount: 800)
        buffer = buf

        sourceNode = AVAudioSourceNode(format: format) { [weak self] isSilence, _, frameCount, audioBufferList -> OSStatus in
            guard let self, (self.isPlaying || self.isScratchActive), let buf = self.buffer else {
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
        readPosition = -preRollFrames
    }

    func scrub(normalizedDelta: Double) {
        guard let buf = buffer else { return }
        // 15 seconds per full trackpad width
        let frameDelta = normalizedDelta * 15.0 * buf.format.sampleRate
        readPosition = max(-preRollFrames, min(Double(buf.frameLength) - 1, readPosition + frameDelta))
    }

    // MARK: - Waveform Downsampling

    private static func downsample(_ buffer: AVAudioPCMBuffer, targetCount: Int) -> [Float] {
        guard let channelData = buffer.floatChannelData else { return [] }
        let totalFrames = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        guard totalFrames > 0, targetCount > 0 else { return [] }

        let chunkSize = max(1, totalFrames / targetCount)
        var result = [Float](repeating: 0, count: targetCount)

        for i in 0..<targetCount {
            let start = i * chunkSize
            let end = min(start + chunkSize, totalFrames)
            var peak: Float = 0
            for frame in start..<end {
                for ch in 0..<channelCount {
                    peak = max(peak, abs(channelData[ch][frame]))
                }
            }
            result[i] = peak
        }
        return result
    }

    // MARK: - Render Callback (audio thread)

    private func render(
        into audioBufferList: UnsafeMutablePointer<AudioBufferList>,
        frameCount: AVAudioFrameCount,
        buffer: AVAudioPCMBuffer
    ) {
        let abl = UnsafeMutableAudioBufferListPointer(audioBufferList)
        guard let channelData = buffer.floatChannelData else { return }

        let chCount = min(Int(buffer.format.channelCount), abl.count)
        let totalFrames = Int(buffer.frameLength)

        // EMA 스무딩: α=0.3 → 터치 이벤트 3~4회 만에 목표 속도 도달.
        let alpha = 0.3
        if isScratchActive {
            smoothedRate = smoothedRate * (1.0 - alpha) + scratchRate * alpha
        } else {
            smoothedRate = 1.0  // 일반 재생 시 즉시 리셋
        }
        let advance = isScratchActive ? smoothedRate : 1.0

        for frame in 0..<Int(frameCount) {
            let srcInt = Int(readPosition < 0 ? readPosition - 1 : readPosition)

            // Pre-roll silence or past end of track.
            if srcInt < 0 || srcInt >= totalFrames {
                for ch in 0..<chCount {
                    abl[ch].mData?.assumingMemoryBound(to: Float.self)[frame] = 0
                }
                readPosition += advance
                // Clamp reverse past pre-roll.
                if readPosition < -preRollFrames { readPosition = -preRollFrames }
                continue
            }

            // 4-point cubic Hermite interpolation for smooth varispeed.
            let frac = Float(readPosition - Double(srcInt))
            for ch in 0..<chCount {
                let out = abl[ch].mData?.assumingMemoryBound(to: Float.self)
                out?[frame] = cubicHermite(channelData[ch], at: srcInt, frac: frac, total: totalFrames)
            }

            readPosition += advance
            if readPosition < -preRollFrames { readPosition = -preRollFrames }
        }
    }

    // 나중에 교체: cubicHermite → sinc6 (한 줄만 바꾸면 됨)
    // let sample = sinc6(channelData[ch], at: srcInt, frac: frac, total: totalFrames)

    /// Olli Niemitalo 6-point, 5th-order optimal windowed-sinc interpolation.
    /// cubicHermite보다 고주파 왜곡이 적어 스크래치 품질 향상에 유리.
    @inline(__always)
    private func sinc6(
        _ data: UnsafePointer<Float>,
        at i: Int, frac: Float, total: Int
    ) -> Float {
        let p0 = data[max(0, i - 2)], p1 = data[max(0, i - 1)], p2 = data[i]
        let p3 = data[min(total - 1, i + 1)], p4 = data[min(total - 1, i + 2)], p5 = data[min(total - 1, i + 3)]
        let z = frac - 0.5
        let even1 = p3 + p2, odd1 = p3 - p2
        let even2 = p4 + p1, odd2 = p4 - p1
        let even3 = p5 + p0, odd3 = p5 - p0
        let c0 = even1 * 0.42685983 + even2 * 0.07038497 + even3 * 0.00275520
        let c1 = odd1  * 0.35831772 + odd2  * 0.20451600 + odd3  * 0.00613512
        let c2 = even1 * (-0.19986974) + even2 * 0.29938400 + even3 * (-0.09951427)
        let c3 = odd1  * (-0.37624795) + odd2  * 0.12448479 + odd3  * 0.02524552
        let c4 = even1 * 0.04907776 + even2 * (-0.08777327) + even3 * 0.03869550
        let c5 = odd1  * 0.07640710 + odd2  * (-0.04648683) + odd3  * (-0.02991970)
        return ((((c5 * z + c4) * z + c3) * z + c2) * z + c1) * z + c0
    }

    /// 4-point cubic Hermite (Catmull-Rom) sample interpolation.
    /// Smoother than linear; avoids the "gritty" aliasing at non-unity rates.
    @inline(__always)
    private func cubicHermite(
        _ data: UnsafePointer<Float>,
        at i: Int,
        frac: Float,
        total: Int
    ) -> Float {
        let p0 = data[max(0, i - 1)]
        let p1 = data[i]
        let p2 = data[min(total - 1, i + 1)]
        let p3 = data[min(total - 1, i + 2)]

        let a = -0.5 * p0 + 1.5 * p1 - 1.5 * p2 + 0.5 * p3
        let b =        p0 - 2.5 * p1 + 2.0 * p2 - 0.5 * p3
        let c = -0.5 * p0             + 0.5 * p2
        let d =                         p1

        return ((a * frac + b) * frac + c) * frac + d
    }
}
