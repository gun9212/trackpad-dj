import AVFoundation
import XCTest
@testable import TrackpadDJ

final class ContractTests: XCTestCase {

    func testCurrentKeyboardMapping() {
        XCTAssertEqual(command(123), .stepCrossfader(-1))
        XCTAssertEqual(command(124), .stepCrossfader(1))
        XCTAssertEqual(command(12), .load(.a))
        XCTAssertEqual(command(13), .load(.b))
        XCTAssertEqual(command(0), .togglePlay(.a))
        XCTAssertEqual(command(1), .togglePlay(.b))
        XCTAssertEqual(command(6), .cue(.a))
        XCTAssertEqual(command(7), .cue(.b))
        XCTAssertEqual(command(11), .tapBPM(.a))
        XCTAssertEqual(command(45), .tapBPM(.b))
        XCTAssertEqual(command(23), .resetTempo(.a))
        XCTAssertEqual(command(22), .resetTempo(.b))
        XCTAssertEqual(command(8), .toggleMonitor(.a))
        XCTAssertEqual(command(9), .toggleMonitor(.b))
        XCTAssertEqual(command(46), .toggleOutputMode)
        XCTAssertEqual(command(18), .jumpToHotCue(.a, 0))
        XCTAssertEqual(command(21, shift: true), .setHotCue(.a, 3))
        XCTAssertEqual(command(26), .jumpToHotCue(.b, 0))
        XCTAssertEqual(command(29, shift: true), .setHotCue(.b, 3))
        XCTAssertTrue(KeyboardMapping.isHeldKey(14))
        XCTAssertTrue(KeyboardMapping.isHeldKey(40))
        XCTAssertTrue(KeyboardMapping.isHeldKey(32))
        XCTAssertTrue(KeyboardMapping.isHeldKey(37))
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

    func testZoneLayoutContract() {
        XCTAssertEqual(ZoneLayout.zone(for: CGPoint(x: 0.25, y: 0.9))?.name, .topStrip)
        XCTAssertEqual(ZoneLayout.zone(for: CGPoint(x: 0.25, y: 0.5))?.name, .deckA)
        XCTAssertEqual(ZoneLayout.zone(for: CGPoint(x: 0.75, y: 0.5))?.name, .deckB)
        XCTAssertEqual(ZoneLayout.zone(for: CGPoint(x: 0.5, y: 0.05))?.name, .bottomStrip)
        XCTAssertNil(ZoneLayout.zone(for: CGPoint(x: 1.1, y: 0.5)))
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

    private func command(_ keyCode: UInt16, shift: Bool = false) -> DJAction? {
        KeyboardMapping.oneShotAction(for: keyCode, shift: shift)
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
