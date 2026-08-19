import AVFoundation
import XCTest
@testable import TrackpadDJ

final class TrackLoaderTests: XCTestCase {

    func testLoaderDecodesShortFixtureAndBuildsFixedWaveform() async throws {
        let fixture = try RuntimeWAVFixture(duration: 0.01, sampleRate: 8_000, channels: 1)
        addTeardownBlock { [url = fixture.url] in
            try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
        }

        let track = try await TrackLoader().load(url: fixture.url)

        XCTAssertEqual(track.name, "fixture")
        XCTAssertEqual(track.audio.buffer.frameLength, 80)
        XCTAssertEqual(track.waveformSamples.count, 800)
        XCTAssertTrue(track.waveformSamples.contains { $0 > 0 })
        XCTAssertNil(track.beatGrid)
    }

    func testBeatAnalyzerFindsSyntheticClickTemposAndLeadingSilence() throws {
        for bpm in [90.0, 120.0, 150.0] {
            let buffer = try makeClickBuffer(bpm: bpm, leadingSilence: 1.25)
            let grid = try XCTUnwrap(BeatGridAnalyzer.analyze(buffer), "Missing grid for \(bpm) BPM")

            XCTAssertEqual(grid.bpm, bpm, accuracy: 1.0)
            XCTAssertEqual(grid.firstBeatTime, 1.25, accuracy: 0.025)
            XCTAssertGreaterThanOrEqual(grid.confidence, BeatGridAnalyzer.minimumConfidence)
            XCTAssertEqual(grid.source, .automatic)
        }
    }

    func testBeatAnalyzerFindsRegularBeatThroughDenseEnergyModulation() throws {
        let sampleRate = 200.0
        let energy = makeEnergyEnvelope(
            sampleRate: sampleRate,
            pulseTrains: [(bpm: 92, amplitude: 0.03, width: 14)],
            modulation: (frequency: 30, amplitude: 0.01)
        )

        let grid = try XCTUnwrap(BeatGridAnalyzer.analyzeEnergyEnvelope(
            energy,
            sampleRate: sampleRate
        ))

        XCTAssertEqual(grid.bpm, 92, accuracy: 1)
        XCTAssertGreaterThanOrEqual(grid.confidence, BeatGridAnalyzer.minimumConfidence)
    }

    func testBeatAnalyzerCombinesBaseAndDoubleTempoEvidence() throws {
        let sampleRate = 200.0
        let energy = makeEnergyEnvelope(
            sampleRate: sampleRate,
            pulseTrains: [
                (bpm: 96, amplitude: 0.02, width: 12),
                (bpm: 192, amplitude: 0.01, width: 6),
                (bpm: 64, amplitude: 0.05, width: 18),
            ]
        )

        let grid = try XCTUnwrap(BeatGridAnalyzer.analyzeEnergyEnvelope(
            energy,
            sampleRate: sampleRate
        ))

        XCTAssertEqual(grid.bpm, 96, accuracy: 1)
        XCTAssertGreaterThanOrEqual(grid.confidence, BeatGridAnalyzer.minimumConfidence)
    }

    func testBeatAnalyzerRejectsShortAndLowConfidenceSignals() throws {
        XCTAssertNil(BeatGridAnalyzer.analyze(
            try makeClickBuffer(bpm: 120, leadingSilence: 0, duration: 7.9)
        ))

        let constant = try XCTUnwrap(AVAudioPCMBuffer(
            pcmFormat: try XCTUnwrap(AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: 2_000,
                channels: 1,
                interleaved: false
            )),
            frameCapacity: 20_000
        ))
        constant.frameLength = 20_000
        let samples = try XCTUnwrap(constant.floatChannelData?[0])
        for frame in 0..<20_000 {
            samples[frame] = 0.1
        }
        XCTAssertNil(BeatGridAnalyzer.analyze(constant))
    }

    @MainActor
    func testLatestRequestWinsWhenOlderDecodeFinishesLast() async throws {
        let loader = ControlledTrackLoader()
        let coordinator = TrackLoadCoordinator(loader: loader)
        let oldURL = URL(fileURLWithPath: "/tmp/old.wav")
        let newURL = URL(fileURLWithPath: "/tmp/new.wav")
        let oldTrack = try makeTrack(name: "old")
        let newTrack = try makeTrack(name: "new")

        let oldTask = Task { @MainActor in
            try await coordinator.load(url: oldURL, deck: .a)
        }
        await loader.waitUntilRequested(oldURL)

        let newTask = Task { @MainActor in
            try await coordinator.load(url: newURL, deck: .a)
        }
        await loader.waitUntilRequested(newURL)

        await loader.succeed(url: newURL, with: newTrack)
        let newOutcome = try await newTask.value
        guard case .ready(let installedTrack) = newOutcome else {
            return XCTFail("Newest request should be ready")
        }
        XCTAssertEqual(installedTrack.name, "new")

        await loader.succeed(url: oldURL, with: oldTrack)
        let oldOutcome = try await oldTask.value
        guard case .superseded = oldOutcome else {
            return XCTFail("Older request should be superseded")
        }
    }

    @MainActor
    func testFailedReloadKeepsInstalledTrack() async throws {
        let goodURL = URL(fileURLWithPath: "/tmp/good.wav")
        let badURL = URL(fileURLWithPath: "/tmp/bad.wav")
        let original = try makeTrack(name: "original")
        let loader = StubTrackLoader(trackByURL: [goodURL: original], failingURLs: [badURL])
        let engine = AudioEngine(trackLoader: loader, startsAudioEngine: false)

        let loadResult = try await engine.loadTrack(url: goodURL, deck: .a)
        XCTAssertEqual(loadResult, .installed)
        XCTAssertEqual(engine.deckA.trackName, "original")

        do {
            _ = try await engine.loadTrack(url: badURL, deck: .a)
            XCTFail("Expected the failing loader to throw")
        } catch {
            XCTAssertEqual(engine.deckA.trackName, "original")
        }
    }

    @MainActor
    func testInstallingNewTrackResetsRealtimeTransportAndTempo() throws {
        let deck = Deck()
        deck.install(try makeTrack(name: "first"))
        deck.setTempoPercent(7)
        deck.togglePlayPause()
        XCTAssertTrue(deck.isPlaying)

        deck.install(try makeTrack(name: "second"))

        XCTAssertEqual(deck.trackName, "second")
        XCTAssertFalse(deck.isPlaying)
        XCTAssertEqual(deck.tempoPercent, 0)
        XCTAssertLessThan(deck.extendedProgress, 0)
    }

    private func makeTrack(name: String) throws -> LoadedTrack {
        let format = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 8_000,
            channels: 1,
            interleaved: false
        ))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: 800
        ))
        buffer.frameLength = 800
        return LoadedTrack(
            name: name,
            audio: DeckAudioData(
                buffer: buffer,
                format: format,
                preRollFrames: 16_000
            ),
            waveformSamples: Array(repeating: 0, count: 800)
        )
    }

    private func makeClickBuffer(
        bpm: Double,
        leadingSilence: TimeInterval,
        duration: TimeInterval = 12,
        sampleRate: Double = 2_000
    ) throws -> AVAudioPCMBuffer {
        let format = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        ))
        let frameCount = AVAudioFrameCount((duration * sampleRate).rounded())
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: frameCount
        ))
        buffer.frameLength = frameCount
        let samples = try XCTUnwrap(buffer.floatChannelData?[0])

        var beatTime = leadingSilence
        while beatTime < duration {
            let start = Int((beatTime * sampleRate).rounded())
            for offset in 0..<5 where start + offset < Int(frameCount) {
                samples[start + offset] = 1 - Float(offset) * 0.15
            }
            beatTime += 60 / bpm
        }
        return buffer
    }

    private func makeEnergyEnvelope(
        duration: TimeInterval = 20,
        sampleRate: Double,
        pulseTrains: [(bpm: Double, amplitude: Float, width: Int)],
        modulation: (frequency: Double, amplitude: Float)? = nil
    ) -> [Float] {
        let count = Int((duration * sampleRate).rounded())
        var energy = [Float](repeating: 0.3, count: count)

        if let modulation {
            for index in energy.indices {
                let time = Double(index) / sampleRate
                energy[index] += modulation.amplitude * Float(
                    0.5 + 0.5 * sin(2 * .pi * modulation.frequency * time)
                )
            }
        }

        for train in pulseTrains {
            var beatTime: TimeInterval = 0
            while beatTime < duration {
                let start = Int((beatTime * sampleRate).rounded())
                for offset in 0..<train.width where start + offset < count {
                    let decay = exp(-Double(offset) / (Double(train.width) / 3))
                    energy[start + offset] += train.amplitude * Float(decay)
                }
                beatTime += 60 / train.bpm
            }
        }

        return energy
    }
}

private actor ControlledTrackLoader: TrackLoading {
    private var continuations: [URL: CheckedContinuation<LoadedTrack, any Error>] = [:]

    func load(url: URL) async throws -> LoadedTrack {
        try await withCheckedThrowingContinuation { continuation in
            continuations[url] = continuation
        }
    }

    func waitUntilRequested(_ url: URL) async {
        while continuations[url] == nil {
            await Task.yield()
        }
    }

    func succeed(url: URL, with track: LoadedTrack) {
        continuations.removeValue(forKey: url)?.resume(returning: track)
    }
}

private struct StubTrackLoader: TrackLoading {
    let trackByURL: [URL: LoadedTrack]
    let failingURLs: Set<URL>

    func load(url: URL) async throws -> LoadedTrack {
        if failingURLs.contains(url) {
            throw StubError.expectedFailure
        }
        guard let track = trackByURL[url] else {
            throw StubError.missingTrack
        }
        return track
    }

    enum StubError: Error {
        case expectedFailure
        case missingTrack
    }
}
