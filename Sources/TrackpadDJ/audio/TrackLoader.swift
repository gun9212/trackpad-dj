import AVFoundation
import Foundation

enum TrackLoaderError: LocalizedError {
    case emptyTrack
    case trackTooLong
    case bufferAllocationFailed

    var errorDescription: String? {
        switch self {
        case .emptyTrack:
            return "The selected audio file contains no frames."
        case .trackTooLong:
            return "The selected audio file is too long to load into memory."
        case .bufferAllocationFailed:
            return "The audio buffer could not be allocated."
        }
    }
}

struct LoadedTrack: @unchecked Sendable {
    let name: String
    let audio: DeckAudioData
    let waveformSamples: [Float]
    let beatGrid: BeatGrid?
    let trackID: TrackID?

    init(
        name: String,
        audio: DeckAudioData,
        waveformSamples: [Float],
        beatGrid: BeatGrid? = nil,
        trackID: TrackID? = nil
    ) {
        self.name = name
        self.audio = audio
        self.waveformSamples = waveformSamples
        self.beatGrid = beatGrid
        self.trackID = trackID
    }

    var duration: TimeInterval {
        audio.frameLength / audio.format.sampleRate
    }
}

protocol TrackLoading: Sendable {
    func load(url: URL) async throws -> LoadedTrack
}

struct TrackLoader: TrackLoading, Sendable {

    func load(url: URL) async throws -> LoadedTrack {
        try await Task.detached(priority: .userInitiated) {
            try Self.decode(url: url)
        }.value
    }

    static func decode(url: URL) throws -> LoadedTrack {
        let file = try AVAudioFile(forReading: url)
        guard file.length > 0 else { throw TrackLoaderError.emptyTrack }
        guard file.length <= AVAudioFramePosition(AVAudioFrameCount.max) else {
            throw TrackLoaderError.trackTooLong
        }

        let format = file.processingFormat
        let frameCount = AVAudioFrameCount(file.length)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            throw TrackLoaderError.bufferAllocationFailed
        }
        try file.read(into: buffer)
        guard buffer.frameLength > 0 else { throw TrackLoaderError.emptyTrack }

        let audio = DeckAudioData(
            buffer: buffer,
            format: format,
            preRollFrames: format.sampleRate * 2
        )
        return LoadedTrack(
            name: url.deletingPathExtension().lastPathComponent,
            audio: audio,
            waveformSamples: downsample(buffer, targetCount: 800),
            beatGrid: BeatGridAnalyzer.analyze(buffer),
            trackID: try? TrackID.fingerprint(url: url)
        )
    }

    private static func downsample(
        _ buffer: AVAudioPCMBuffer,
        targetCount: Int
    ) -> [Float] {
        guard let channelData = buffer.floatChannelData else { return [] }
        let totalFrames = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        guard totalFrames > 0, targetCount > 0 else { return [] }

        var result = [Float](repeating: 0, count: targetCount)
        for index in 0..<targetCount {
            let start = index * totalFrames / targetCount
            let proportionalEnd = (index + 1) * totalFrames / targetCount
            let end = min(totalFrames, max(start + 1, proportionalEnd))
            guard start < totalFrames else { break }

            var peak: Float = 0
            for frame in start..<end {
                for channel in 0..<channelCount {
                    peak = max(peak, abs(channelData[channel][frame]))
                }
            }
            result[index] = peak
        }
        return result
    }
}

enum TrackLoadOutcome: Sendable {
    case ready(LoadedTrack)
    case superseded
}

/// Applies a generation barrier independently to each deck's asynchronous requests.
@MainActor
final class TrackLoadCoordinator {
    private let loader: any TrackLoading
    private let hotCueLibrary: HotCueLibrary?
    private var generationByDeck: [DeckID: UInt64] = [.a: 0, .b: 0]

    init(loader: any TrackLoading, hotCueLibrary: HotCueLibrary? = nil) {
        self.loader = loader
        self.hotCueLibrary = hotCueLibrary
    }

    func load(url: URL, deck: DeckID) async throws -> TrackLoadOutcome {
        let generation = nextGeneration(for: deck)

        do {
            let track = try await loader.load(url: url)
            if let id = track.trackID { await hotCueLibrary?.restore(id) }
            guard generationByDeck[deck] == generation else { return .superseded }
            return .ready(track)
        } catch {
            guard generationByDeck[deck] == generation else { return .superseded }
            throw error
        }
    }

    private func nextGeneration(for deck: DeckID) -> UInt64 {
        let generation = (generationByDeck[deck] ?? 0) &+ 1
        generationByDeck[deck] = generation
        return generation
    }
}
