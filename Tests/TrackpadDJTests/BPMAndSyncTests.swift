import AVFoundation
import XCTest
@testable import TrackpadDJ

final class BPMAndSyncTests: XCTestCase {

    @MainActor
    func testOneShotSyncUsesReferenceDeckEffectiveBPMWithoutMovingPlayhead() async throws {
        let aURL = URL(fileURLWithPath: "/tmp/sync-a.wav")
        let bURL = URL(fileURLWithPath: "/tmp/sync-b.wav")
        let loader = StaticGridLoader(tracks: [
            aURL: try makeTrack(name: "A", bpm: 120),
            bURL: try makeTrack(name: "B", bpm: 122),
        ])
        let engine = AudioEngine(trackLoader: loader, startsAudioEngine: false)
        defer { engine.shutdown() }
        _ = try await engine.loadTrack(url: aURL, deck: .a)
        _ = try await engine.loadTrack(url: bURL, deck: .b)
        engine.adjustTempo(deck: .b, by: 3)

        let before = engine.snapshot(for: .a).extendedProgress
        let targetBPM = 122 * 1.03
        let requiredTempo = (targetBPM / 120 - 1) * 100
        XCTAssertEqual(
            engine.syncTempo(activeDeck: .a),
            .matched(tempoPercent: requiredTempo, targetBPM: targetBPM)
        )
        XCTAssertEqual(engine.deckA.tempoPercent, requiredTempo, accuracy: 0.000_001)
        XCTAssertEqual(engine.snapshot(for: .a).extendedProgress, before)
    }

    @MainActor
    func testSyncFailuresDoNotChangeTempo() async throws {
        let missingURL = URL(fileURLWithPath: "/tmp/sync-missing.wav")
        let fastURL = URL(fileURLWithPath: "/tmp/sync-fast.wav")
        let slowURL = URL(fileURLWithPath: "/tmp/sync-slow.wav")
        let loader = StaticGridLoader(tracks: [
            missingURL: try makeTrack(name: "missing", bpm: nil),
            fastURL: try makeTrack(name: "fast", bpm: 120),
            slowURL: try makeTrack(name: "slow", bpm: 100),
        ])
        let engine = AudioEngine(trackLoader: loader, startsAudioEngine: false)
        defer { engine.shutdown() }

        _ = try await engine.loadTrack(url: missingURL, deck: .a)
        _ = try await engine.loadTrack(url: fastURL, deck: .b)
        engine.adjustTempo(deck: .a, by: 2)
        XCTAssertEqual(engine.syncTempo(activeDeck: .a), .failed(.activeDeckBPMMissing))
        XCTAssertEqual(engine.deckA.tempoPercent, 2)

        _ = try await engine.loadTrack(url: slowURL, deck: .a)
        engine.adjustTempo(deck: .a, by: 2)
        let result = engine.syncTempo(activeDeck: .a)
        guard case .failed(.requiredTempoOutOfRange(let required)) = result else {
            return XCTFail("Expected out-of-range failure, got \(result)")
        }
        XCTAssertEqual(required, 20, accuracy: 0.000_001)
        XCTAssertEqual(engine.deckA.tempoPercent, 2)

        _ = try await engine.loadTrack(url: missingURL, deck: .b)
        XCTAssertEqual(engine.syncTempo(activeDeck: .a), .failed(.referenceDeckBPMMissing))
        XCTAssertEqual(engine.deckA.tempoPercent, 2)
    }

    @MainActor
    func testTapOverrideStartsOnSecondTapAndCanRestoreAutomaticGrid() async throws {
        let url = URL(fileURLWithPath: "/tmp/tap-grid.wav")
        let loader = StaticGridLoader(tracks: [
            url: try makeTrack(name: "tap", bpm: 128, firstBeatTime: 0.75),
        ])
        let engine = AudioEngine(trackLoader: loader, startsAudioEngine: false)
        defer { engine.shutdown() }
        _ = try await engine.loadTrack(url: url, deck: .a)

        engine.tapBPM(deck: .a, at: 10)
        XCTAssertEqual(engine.snapshot(for: .a).beatGridSource, .automatic)

        engine.tapBPM(deck: .a, at: 10.5)
        let tapped = engine.snapshot(for: .a)
        XCTAssertEqual(tapped.bpm, 120)
        XCTAssertEqual(try XCTUnwrap(tapped.firstBeatTime), -2, accuracy: 0.000_001)
        XCTAssertEqual(tapped.beatGridSource, .tap)
        XCTAssertEqual(tapped.beatConfidence, 1)

        engine.restoreAutomaticBPM(deck: .a)
        let restored = engine.snapshot(for: .a)
        XCTAssertEqual(restored.bpm, 128)
        XCTAssertEqual(restored.firstBeatTime, 0.75)
        XCTAssertEqual(restored.beatGridSource, .automatic)
    }

    @MainActor
    func testInstallingNewTrackClearsTapOverrideAndTempo() async throws {
        let firstURL = URL(fileURLWithPath: "/tmp/grid-first.wav")
        let secondURL = URL(fileURLWithPath: "/tmp/grid-second.wav")
        let loader = StaticGridLoader(tracks: [
            firstURL: try makeTrack(name: "first", bpm: 120),
            secondURL: try makeTrack(name: "second", bpm: 135),
        ])
        let engine = AudioEngine(trackLoader: loader, startsAudioEngine: false)
        defer { engine.shutdown() }
        _ = try await engine.loadTrack(url: firstURL, deck: .a)
        engine.tapBPM(deck: .a, at: 1)
        engine.tapBPM(deck: .a, at: 1.5)
        engine.adjustTempo(deck: .a, by: 5)
        XCTAssertEqual(engine.snapshot(for: .a).beatGridSource, .tap)

        _ = try await engine.loadTrack(url: secondURL, deck: .a)
        let snapshot = engine.snapshot(for: .a)
        XCTAssertEqual(snapshot.bpm, 135)
        XCTAssertEqual(snapshot.beatGridSource, .automatic)
        XCTAssertEqual(snapshot.tempoPercent, 0)
        XCTAssertEqual(snapshot.pitchBendPercent, 0)
    }

    private func makeTrack(
        name: String,
        bpm: Double?,
        firstBeatTime: TimeInterval = 0
    ) throws -> LoadedTrack {
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
            waveformSamples: Array(repeating: 0, count: 800),
            beatGrid: bpm.map {
                BeatGrid(
                    bpm: $0,
                    firstBeatTime: firstBeatTime,
                    confidence: 0.9,
                    source: .automatic
                )
            }
        )
    }
}

private struct StaticGridLoader: TrackLoading {
    let tracks: [URL: LoadedTrack]

    func load(url: URL) async throws -> LoadedTrack {
        guard let track = tracks[url] else { throw LoaderError.missingTrack }
        return track
    }

    enum LoaderError: Error {
        case missingTrack
    }
}
