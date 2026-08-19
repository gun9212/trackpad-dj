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
