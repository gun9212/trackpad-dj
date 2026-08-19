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
        XCTAssertNil(command(18))
        XCTAssertNil(command(21, shift: true))
        XCTAssertNil(command(26))
        XCTAssertNil(command(29, shift: true))
        XCTAssertFalse(KeyboardMapping.handles(18, shift: false))
        XCTAssertFalse(KeyboardMapping.handles(29, shift: true))
        XCTAssertFalse(KeyboardMapping.handles(12, shift: false, hasSystemModifier: true))
        XCTAssertFalse(KeyboardMapping.handles(49, shift: false, hasSystemModifier: true))
        XCTAssertTrue(KeyboardMapping.isHeldKey(14))
        XCTAssertTrue(KeyboardMapping.isHeldKey(3))
        XCTAssertTrue(KeyboardMapping.isHeldKey(17))
        XCTAssertTrue(KeyboardMapping.isHeldKey(125))
    }

    func testEqualPowerCrossfaderCurve() {
        assertGains(at: 0, expectedA: 1, expectedB: 0)
        assertGains(at: 0.25, expectedA: 0.923_880, expectedB: 0.382_683)
        assertGains(at: 0.5, expectedA: 0.707_107, expectedB: 0.707_107)
        assertGains(at: 0.75, expectedA: 0.382_683, expectedB: 0.923_880)
        assertGains(at: 1, expectedA: 0, expectedB: 1)
        XCTAssertEqual(CrossfaderCurve.equalPowerGains(at: 0).deckB, 0)
        XCTAssertEqual(CrossfaderCurve.equalPowerGains(at: 1).deckA, 0)
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
    func testAudioEngineOwnsEqualPowerCrossfaderValue() {
        let engine = AudioEngine(startsAudioEngine: false)

        XCTAssertEqual(engine.crossfaderValue, 0.5)
        XCTAssertEqual(engine.deckA.volume, 0.707_107, accuracy: 0.000_001)
        XCTAssertEqual(engine.deckB.volume, 0.707_107, accuracy: 0.000_001)

        engine.applyCrossfader(CrossfaderState(value: 0))
        XCTAssertEqual(engine.crossfaderValue, 0)
        XCTAssertEqual(engine.deckA.volume, 1)
        XCTAssertEqual(engine.deckB.volume, 0)
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
        at value: Float,
        expectedA: Float,
        expectedB: Float,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let gains = CrossfaderCurve.equalPowerGains(at: value)
        XCTAssertEqual(gains.deckA, expectedA, accuracy: 0.0001, file: file, line: line)
        XCTAssertEqual(gains.deckB, expectedB, accuracy: 0.0001, file: file, line: line)
    }
}
