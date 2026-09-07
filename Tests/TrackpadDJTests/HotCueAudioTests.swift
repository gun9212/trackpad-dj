import AVFoundation
import Dispatch
import XCTest
@testable import TrackpadDJ

final class HotCueAudioTests: XCTestCase {
    @MainActor
    func testEmptySlotStoresPrerollAtZeroAndClearDoesNotChangeTransport() throws {
        let deck = Deck()
        XCTAssertFalse(deck.activateHotCue(.one))
        let fixture = try RuntimeWAVFixture(duration: 1, sampleRate: 8_000, channels: 1)
        defer { fixture.remove() }
        deck.install(try TrackLoader.decode(url: fixture.url))
        XCTAssertTrue(deck.activateHotCue(.one))
        XCTAssertEqual(deck.hotCues[0], 0)
        XCTAssertFalse(deck.isPlaying)
        deck.togglePlayPause()
        XCTAssertTrue(deck.activateHotCue(.two))
        XCTAssertTrue(deck.isPlaying)
        XCTAssertTrue(deck.clearHotCue(.one))
        XCTAssertFalse(deck.clearHotCue(.one))
        XCTAssertTrue(deck.isPlaying)
        deck.applyHotCues([-1, .infinity, deck.duration, 0.5])
        XCTAssertEqual(deck.hotCues, [nil, nil, nil, 0.5])
    }

    @MainActor
    func testSameTrackSharesCuesWithoutChangingOtherDeckAndRestoresOnReload() async throws {
        let fixture = try RuntimeWAVFixture(duration: 1, sampleRate: 8_000, channels: 1)
        defer { fixture.remove() }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let engine = AudioEngine(startsAudioEngine: false, hotCueStore: HotCueStore(directory: dir))
        defer { engine.shutdown() }
        _ = try await engine.loadTrack(url: fixture.url, deck: .a)
        _ = try await engine.loadTrack(url: fixture.url, deck: .b)
        let other = engine.snapshot(for: .b)
        engine.activateHotCue(deck: .a, slot: .one)
        XCTAssertEqual(engine.snapshot(for: .b).hotCues[0], 0)
        XCTAssertEqual(engine.snapshot(for: .b).extendedProgress, other.extendedProgress)
        XCTAssertEqual(engine.snapshot(for: .b).isPlaying, other.isPlaying)
        let flushed = await engine.flushHotCues()
        XCTAssertTrue(flushed)
        XCTAssertNil(engine.snapshot(for: .a).hotCueStorageMessage)
        _ = try await engine.loadTrack(url: fixture.url, deck: .a)
        XCTAssertEqual(engine.snapshot(for: .a).hotCues[0], 0)
        engine.clearHotCue(deck: .b, slot: .one)
        XCTAssertNil(engine.snapshot(for: .a).hotCues[0])
        _ = await engine.flushHotCues()
    }

    func testJumpStartsPlaybackAtDestinationAndCrossfadesAtBothSampleRates() throws {
        for rate in [44_100.0, 48_000.0] {
            for block in [64, 256] {
              for alreadyPlaying in [false, true] {
                let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2))
                let source = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096))
                source.frameLength = 4096
                for channel in 0..<2 {
                    for index in 0..<4096 { source.floatChannelData![channel][index] = index < 2048 ? 0.5 : -0.5 }
                }
                let state = DeckRealtimeState()
                let renderer = DeckRenderer(audio: DeckAudioData(buffer: source, format: format, preRollFrames: 0), state: state)
                let output = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(block)))
                output.frameLength = AVAudioFrameCount(block)
                var silence = ObjCBool(false)
                if alreadyPlaying {
                    state.setPlaying(true)
                    _ = renderer.render(isSilence: &silence, frameCount: output.frameLength,
                                        audioBufferList: output.mutableAudioBufferList)
                }
                state.requestSeek(to: 1500, startsPlayback: true)
                state.requestSeek(to: 2048, startsPlayback: true)
                var previous: Float = alreadyPlaying ? 0.5 : 0
                for _ in 0..<(512 / block) {
                    XCTAssertEqual(renderer.render(isSilence: &silence, frameCount: output.frameLength,
                                                   audioBufferList: output.mutableAudioBufferList), noErr)
                    for index in 0..<block {
                        let sample = output.floatChannelData![0][index]
                        XCTAssertTrue(sample.isFinite)
                        XCTAssertLessThan(abs(sample - previous), 0.02)
                        XCTAssertEqual(sample, output.floatChannelData![1][index])
                        previous = sample
                    }
                }
                XCTAssertEqual(previous, -0.5, accuracy: 0.001)
                XCTAssertEqual(state.publicReadPosition, 2560)
                XCTAssertTrue(state.isPlaying)
              }
            }
        }
    }

    func testJumpKeepsScratchHoldUntilRelease() throws {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 8_000, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024))
        buffer.frameLength = 1024
        for index in 0..<1024 { buffer.floatChannelData![0][index] = 0 }
        let state = DeckRealtimeState()
        let renderer = DeckRenderer(audio: DeckAudioData(buffer: buffer, format: format, preRollFrames: 0), state: state)
        let output = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 64))
        output.frameLength = 64
        var silence = ObjCBool(false)
        state.setScratch(active: true, rate: 0)
        state.requestSeek(to: 512, startsPlayback: true)
        _ = renderer.render(isSilence: &silence, frameCount: 64, audioBufferList: output.mutableAudioBufferList)
        XCTAssertEqual(state.publicReadPosition, 512)
        XCTAssertTrue(state.isPlaying)
        XCTAssertTrue(state.isScratchActive)
        state.setScratch(active: false, rate: 0)
        _ = renderer.render(isSilence: &silence, frameCount: 64, audioBufferList: output.mutableAudioBufferList)
        XCTAssertEqual(state.publicReadPosition, 576)
    }

    func testSeekAndPlaybackFlagArePublishedCoherently() {
        let state = DeckRealtimeState()
        DispatchQueue.concurrentPerform(iterations: 2) { worker in
            if worker == 0 {
                for index in 1...10_000 { state.requestSeek(to: Double(index), startsPlayback: index.isMultiple(of: 2)) }
            } else {
                var consumed: UInt64 = 0
                for _ in 0..<10_000 {
                    if let command = state.seekCommand(after: consumed) {
                        XCTAssertEqual(command.startsPlayback, Int(command.targetFrame).isMultiple(of: 2))
                        consumed = command.generation
                    }
                }
            }
        }
        XCTAssertEqual(state.seekCommand(after: 0)?.targetFrame, 10_000)
    }
}
