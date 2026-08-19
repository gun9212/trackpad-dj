import XCTest
@testable import TrackpadDJ

final class SnapshotTests: XCTestCase {

    @MainActor
    func testDeckSnapshotReflectsEngineOwnedControls() {
        let engine = AudioEngine(startsAudioEngine: false)
        defer { engine.shutdown() }

        let initial = engine.snapshot(for: .a)
        XCTAssertEqual(initial, .empty(deck: .a))

        engine.adjustTempo(deck: .a, by: 2.5)
        engine.setPitchBend(deck: .a, percent: -3)
        engine.setFader(deck: .a, deltaY: -0.25)
        engine.setFilter(deck: .a, deltaY: -0.5)
        engine.toggleMonitor(deck: .a)

        let updated = engine.snapshot(for: .a)
        XCTAssertEqual(updated.tempoPercent, 2.5)
        XCTAssertEqual(updated.pitchBendPercent, -3)
        XCTAssertEqual(updated.preFaderPeak, 0)
        XCTAssertEqual(updated.faderLevel, 0.75)
        XCTAssertEqual(updated.filterLevel, 0.5, accuracy: 0.000_001)
        XCTAssertTrue(updated.monitorEnabled)
    }

    @MainActor
    func testMixerSnapshotReflectsCrossfaderAndOutputState() async throws {
        let engine = AudioEngine(startsAudioEngine: false)
        defer { engine.shutdown() }

        engine.applyCrossfader(CrossfaderState(value: 0.25))
        XCTAssertEqual(
            engine.mixerSnapshot(),
            MixerSnapshot(
                crossfaderValue: 0.25,
                outputMode: .stereoMaster,
                routingErrorMessage: nil
            )
        )

        try await engine.setOutputMode(.splitCue)
        XCTAssertEqual(engine.mixerSnapshot().outputMode, .splitCue)
    }
}
