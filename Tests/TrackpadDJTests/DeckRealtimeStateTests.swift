import AVFoundation
import Dispatch
import XCTest
@testable import TrackpadDJ

final class DeckRealtimeStateTests: XCTestCase {

    func testSeekGenerationPublishesLatestTargetAndIsConsumedOnce() {
        let state = DeckRealtimeState()
        let initialGeneration = state.currentSeekGeneration

        _ = state.requestSeek(to: 10)
        let latestGeneration = state.requestSeek(to: 20)

        XCTAssertEqual(
            state.seekCommand(after: initialGeneration),
            DeckSeekCommand(generation: latestGeneration, targetFrame: 20)
        )
        XCTAssertNil(state.seekCommand(after: latestGeneration))
    }

    func testAtomicPlayToggleRemainsCoherentUnderContention() {
        let state = DeckRealtimeState()

        DispatchQueue.concurrentPerform(iterations: 10_000) { _ in
            _ = state.togglePlaying()
        }

        XCTAssertFalse(state.isPlaying)
    }

    func testPeakAccumulatorKeepsConcurrentMaximumAndResetsOnConsume() {
        let state = DeckRealtimeState()

        DispatchQueue.concurrentPerform(iterations: 1_000) { index in
            state.publish(preFaderPeak: Float(index) / 1_000)
        }

        XCTAssertEqual(state.consumePreFaderPeak(), 0.999, accuracy: 0.000_001)
        XCTAssertEqual(state.consumePreFaderPeak(), 0)
    }

    func testTempoIsClampedBeforePublication() {
        let state = DeckRealtimeState()
        state.setTempoPercent(20)
        XCTAssertEqual(state.tempoPercent, 8)
        state.setTempoPercent(-20)
        XCTAssertEqual(state.tempoPercent, -8)
    }

    func testPitchBendIsClampedAndCombinesWithTempo() {
        let state = DeckRealtimeState()
        state.setTempoPercent(5)
        state.setPitchBendPercent(20)
        XCTAssertEqual(state.pitchBendPercent, 8)
        XCTAssertEqual(state.normalPlaybackRate, 1.13, accuracy: 0.000_001)

        state.setPitchBendPercent(-20)
        XCTAssertEqual(state.pitchBendPercent, -8)
        XCTAssertEqual(state.normalPlaybackRate, 0.97, accuracy: 0.000_001)
    }

    func testRendererClampsAtTrackEndAndStopsPlayback() throws {
        let format = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 8_000,
            channels: 1,
            interleaved: false
        ))
        let source = try XCTUnwrap(AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: 4
        ))
        source.frameLength = 4
        let sourceSamples = try XCTUnwrap(source.floatChannelData?[0])
        sourceSamples[0] = 0.1
        sourceSamples[1] = 0.2
        sourceSamples[2] = 0.3
        sourceSamples[3] = 0.4

        let state = DeckRealtimeState()
        state.reset(initialPosition: 0)
        let renderer = DeckRenderer(
            audio: DeckAudioData(buffer: source, format: format, preRollFrames: 0),
            state: state
        )
        let output = try XCTUnwrap(AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: 8
        ))
        output.frameLength = 8
        state.setPlaying(true)

        var isSilence = ObjCBool(false)
        let status = renderer.render(
            isSilence: &isSilence,
            frameCount: 8,
            audioBufferList: output.mutableAudioBufferList
        )

        XCTAssertEqual(status, noErr)
        XCTAssertFalse(isSilence.boolValue)
        XCTAssertFalse(state.isPlaying)
        XCTAssertEqual(state.publicReadPosition, 4)

        let rendered = try XCTUnwrap(output.floatChannelData?[0])
        XCTAssertEqual(rendered[0], 0.1, accuracy: 0.0001)
        XCTAssertEqual(rendered[3], 0.4, accuracy: 0.0001)
        XCTAssertEqual(rendered[4], 0, accuracy: 0.0001)
        XCTAssertEqual(rendered[7], 0, accuracy: 0.0001)
    }

    func testRendererPublishesActualMultichannelPreFaderPeak() throws {
        let format = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 8_000,
            channels: 2,
            interleaved: false
        ))
        let source = try XCTUnwrap(AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: 4
        ))
        source.frameLength = 4
        let channels = try XCTUnwrap(source.floatChannelData)
        channels[0][0] = 0.1
        channels[0][1] = -0.4
        channels[0][2] = 0.2
        channels[0][3] = 0.1
        channels[1][0] = 0.1
        channels[1][1] = 0.2
        channels[1][2] = -0.75
        channels[1][3] = 0.1

        let state = DeckRealtimeState()
        state.reset(initialPosition: 0)
        state.setPlaying(true)
        let renderer = DeckRenderer(
            audio: DeckAudioData(buffer: source, format: format, preRollFrames: 0),
            state: state
        )
        let output = try XCTUnwrap(AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: 4
        ))
        output.frameLength = 4
        var isSilence = ObjCBool(false)

        XCTAssertEqual(renderer.render(
            isSilence: &isSilence,
            frameCount: 4,
            audioBufferList: output.mutableAudioBufferList
        ), noErr)
        XCTAssertEqual(state.consumePreFaderPeak(), 0.75, accuracy: 0.000_001)
        XCTAssertEqual(state.consumePreFaderPeak(), 0)
    }

    func testRendererUsesTempoAndReturnsToItAfterScratch() throws {
        let format = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 8_000,
            channels: 1,
            interleaved: false
        ))
        let source = try XCTUnwrap(AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: 100
        ))
        source.frameLength = 100
        let state = DeckRealtimeState()
        state.reset(initialPosition: 0)
        state.setTempoPercent(8)
        state.setPitchBendPercent(-3)
        state.setPlaying(true)
        let renderer = DeckRenderer(
            audio: DeckAudioData(buffer: source, format: format, preRollFrames: 0),
            state: state
        )
        let output = try XCTUnwrap(AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: 10
        ))
        output.frameLength = 10
        var isSilence = ObjCBool(false)

        XCTAssertEqual(renderer.render(
            isSilence: &isSilence,
            frameCount: 10,
            audioBufferList: output.mutableAudioBufferList
        ), noErr)
        XCTAssertEqual(state.publicReadPosition, 10.5, accuracy: 0.000_001)

        state.setScratch(active: true, rate: 0)
        _ = renderer.render(
            isSilence: &isSilence,
            frameCount: 10,
            audioBufferList: output.mutableAudioBufferList
        )
        let positionAfterScratch = state.publicReadPosition
        XCTAssertEqual(positionAfterScratch, 10.5, accuracy: 0.000_001)

        state.setScratch(active: false, rate: 0)
        _ = renderer.render(
            isSilence: &isSilence,
            frameCount: 10,
            audioBufferList: output.mutableAudioBufferList
        )
        XCTAssertEqual(
            state.publicReadPosition - positionAfterScratch,
            10.5,
            accuracy: 0.000_001
        )
    }

    func testPitchBendDoesNotMoveStoppedDeck() throws {
        let format = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 8_000,
            channels: 1,
            interleaved: false
        ))
        let source = try XCTUnwrap(AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: 100
        ))
        source.frameLength = 100
        let state = DeckRealtimeState()
        state.reset(initialPosition: 10)
        state.setPitchBendPercent(8)
        let renderer = DeckRenderer(
            audio: DeckAudioData(buffer: source, format: format, preRollFrames: 0),
            state: state
        )
        _ = state.requestSeek(to: 10)
        let output = try XCTUnwrap(AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: 10
        ))
        output.frameLength = 10
        var isSilence = ObjCBool(false)

        XCTAssertEqual(renderer.render(
            isSilence: &isSilence,
            frameCount: 10,
            audioBufferList: output.mutableAudioBufferList
        ), noErr)
        XCTAssertTrue(isSilence.boolValue)
        XCTAssertEqual(state.publicReadPosition, 10)
    }
}
