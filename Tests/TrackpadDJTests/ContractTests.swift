import AVFoundation
import XCTest
@testable import TrackpadDJ

final class ContractTests: XCTestCase {

    func testCurrentKeyboardMapping() {
        XCTAssertEqual(command(123), .stepCrossfader(-1))
        XCTAssertEqual(command(124), .stepCrossfader(1))
        XCTAssertEqual(command(48), .selectActiveDeck(.b))
        XCTAssertEqual(command(12), .load(.a))
        XCTAssertEqual(command(12, activeDeck: .b), .load(.b))
        XCTAssertEqual(command(49), .togglePlay(.a))
        XCTAssertEqual(command(8), .cue(.a))
        XCTAssertEqual(command(1), .syncTempo(.a))
        XCTAssertEqual(command(11), .tapBPM(.a))
        XCTAssertEqual(command(11, shift: true), .restoreAutomaticBPM(.a))
        XCTAssertEqual(command(23, activeDeck: .b), .resetTempo(.b))
        XCTAssertEqual(command(9), .toggleMonitor(.a))
        XCTAssertEqual(command(46), .toggleOutputMode)
        XCTAssertEqual(command(35), .toggleCursorLock)
        XCTAssertEqual(command(53), .cancelJogAndUnlock)
        XCTAssertNil(command(13))
        XCTAssertNil(command(0))
        XCTAssertNil(command(6))
        XCTAssertNil(command(45))
        XCTAssertEqual(command(18), .activateHotCue(.a, .one))
        XCTAssertEqual(command(21, shift: true), .clearHotCue(.a, .four))
        XCTAssertNil(command(26))
        XCTAssertNil(command(29, shift: true))
        XCTAssertTrue(KeyboardMapping.handles(18, shift: false))
        XCTAssertFalse(KeyboardMapping.handles(29, shift: true))
        XCTAssertFalse(KeyboardMapping.handles(12, shift: false, hasSystemModifier: true))
        XCTAssertFalse(KeyboardMapping.handles(49, shift: false, hasSystemModifier: true))
        XCTAssertTrue(KeyboardMapping.isHeldKey(14))
        XCTAssertTrue(KeyboardMapping.isHeldKey(3))
        XCTAssertTrue(KeyboardMapping.isHeldKey(17))
        XCTAssertTrue(KeyboardMapping.isHeldKey(125))
    }

    func testThreePositionCrossfaderGate() {
        assertGains(for: .deckAOnly, expectedA: 1, expectedB: 0)
        assertGains(for: .both, expectedA: 1, expectedB: 1)
        assertGains(for: .deckBOnly, expectedA: 0, expectedB: 1)

        XCTAssertEqual(CrossfaderState.deckAOnly.stepped(toward: 1), .both)
        XCTAssertEqual(CrossfaderState.both.stepped(toward: 1), .deckBOnly)
        XCTAssertEqual(CrossfaderState.deckBOnly.stepped(toward: -1), .both)
        XCTAssertEqual(CrossfaderState.both.stepped(toward: -1), .deckAOnly)
        XCTAssertEqual(CrossfaderState.deckAOnly.stepped(toward: -1), .deckAOnly)
        XCTAssertEqual(CrossfaderState.deckBOnly.stepped(toward: 1), .deckBOnly)
    }

    func testBPMTapCalculationAndSequenceReset() {
        var state = BPMTapState()
        state.tap(at: 10.0, progress: 0.2)
        state.tap(at: 10.5, progress: 0.3)
        state.tap(at: 11.0, progress: 0.4)
        XCTAssertEqual(state.bpm, 120, accuracy: 0.0001)
        XCTAssertEqual(state.beatOffset, 0.2, accuracy: 0.0001)

        state.tap(at: 13.1, progress: 0.8)
        XCTAssertEqual(state.tapTimes.count, 1)
        XCTAssertEqual(state.beatOffset, 0.8, accuracy: 0.0001)
    }

    @MainActor
    func testAudioEngineAppliesCrossfaderAsAnOutputGate() {
        let engine = AudioEngine(startsAudioEngine: false)

        XCTAssertEqual(engine.crossfaderValue, 0.5)
        XCTAssertEqual(engine.deckA.volume, 1)
        XCTAssertEqual(engine.deckB.volume, 1)

        engine.applyCrossfader(.deckAOnly)
        XCTAssertEqual(engine.crossfaderValue, 0)
        XCTAssertEqual(engine.deckA.volume, 1)
        XCTAssertEqual(engine.deckB.volume, 0)

        engine.setFader(deck: .a, deltaY: -0.25)
        engine.applyCrossfader(.both)
        XCTAssertEqual(engine.deckA.volume, 0.75)
        XCTAssertEqual(engine.deckB.volume, 1)

        engine.applyCrossfader(.deckBOnly)
        XCTAssertEqual(engine.deckA.volume, 0)
        XCTAssertEqual(engine.deckB.volume, 1)
    }

    @MainActor
    func testAudioEngineTempoControlsClampAndReset() {
        let engine = AudioEngine(startsAudioEngine: false)

        engine.adjustTempo(deck: .a, by: 20)
        XCTAssertEqual(engine.deckA.tempoPercent, 8)
        engine.adjustTempo(deck: .a, by: -0.05)
        XCTAssertEqual(engine.deckA.tempoPercent, 7.95, accuracy: 0.000_001)
        engine.resetTempo(deck: .a)
        XCTAssertEqual(engine.deckA.tempoPercent, 0)
    }

    @MainActor
    func testRuntimeWAVFixtureLoadsIntoDeck() async throws {
        let fixture = try RuntimeWAVFixture(duration: 0.1, sampleRate: 8_000, channels: 2)
        addTeardownBlock { fixture.remove() }

        let track = try await TrackLoader().load(url: fixture.url)
        let deck = Deck()
        deck.install(track)

        XCTAssertEqual(deck.trackName, fixture.url.deletingPathExtension().lastPathComponent)
        XCTAssertEqual(deck.duration, 0.1, accuracy: 0.001)
        XCTAssertEqual(deck.waveformSamples.count, 800)
        XCTAssertEqual(deck.extendedProgress, -20, accuracy: 0.001)
    }

    private func command(
        _ keyCode: UInt16,
        shift: Bool = false,
        activeDeck: DeckID = .a
    ) -> DJAction? {
        KeyboardMapping.oneShotAction(
            for: keyCode,
            shift: shift,
            activeDeck: activeDeck
        )
    }

    private func assertGains(
        for state: CrossfaderState,
        expectedA: Float,
        expectedB: Float,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let gains = CrossfaderGate.gains(for: state)
        XCTAssertEqual(gains.deckA, expectedA, accuracy: 0.0001, file: file, line: line)
        XCTAssertEqual(gains.deckB, expectedB, accuracy: 0.0001, file: file, line: line)
    }
}
