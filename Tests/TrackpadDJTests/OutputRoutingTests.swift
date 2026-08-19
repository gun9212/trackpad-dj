import AVFoundation
import XCTest
@testable import TrackpadDJ

final class OutputRoutingTests: XCTestCase {

    func testCueGainLeavesHeadroomWhenBothDecksAreSelected() {
        var gains = CueMonitorGains.values(deckAEnabled: false, deckBEnabled: false)
        XCTAssertEqual(gains.deckA, 0)
        XCTAssertEqual(gains.deckB, 0)

        gains = CueMonitorGains.values(deckAEnabled: true, deckBEnabled: false)
        XCTAssertEqual(gains.deckA, 1)
        XCTAssertEqual(gains.deckB, 0)

        gains = CueMonitorGains.values(deckAEnabled: true, deckBEnabled: true)
        XCTAssertEqual(gains.deckA, 0.5)
        XCTAssertEqual(gains.deckB, 0.5)
    }

    @MainActor
    func testStereoMasterMutesCueAndSplitCueAppliesIndependentSelections() async throws {
        let engine = AudioEngine(startsAudioEngine: false)
        defer { engine.shutdown() }

        XCTAssertEqual(engine.outputMode, .stereoMaster)
        engine.toggleMonitor(deck: .a)
        XCTAssertTrue(engine.isMonitorEnabled(deck: .a))
        XCTAssertEqual(engine.monitorGain(deck: .a), 0)

        try await engine.setOutputMode(.splitCue)
        XCTAssertEqual(engine.monitorGain(deck: .a), 1)
        XCTAssertEqual(engine.monitorGain(deck: .b), 0)

        engine.toggleMonitor(deck: .b)
        XCTAssertTrue(engine.isMonitorEnabled(deck: .b))
        XCTAssertEqual(engine.monitorGain(deck: .a), 0.5)
        XCTAssertEqual(engine.monitorGain(deck: .b), 0.5)

        try await engine.setOutputMode(.stereoMaster)
        XCTAssertEqual(engine.monitorGain(deck: .a), 0)
        XCTAssertEqual(engine.monitorGain(deck: .b), 0)

        try await engine.setOutputMode(.splitCue)
        XCTAssertEqual(engine.outputMode, .splitCue)
        XCTAssertEqual(engine.monitorGain(deck: .a), 0.5)
        XCTAssertEqual(engine.monitorGain(deck: .b), 0.5)
    }

    @MainActor
    func testSyntheticSplitSignalRoutesMasterLeftAndCueRightWithoutLeak() async throws {
        let sampleRate = 8_000.0
        let mono = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        ))
        let stereo = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 2,
            interleaved: false
        ))

        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        let masterPath = AVAudioMixerNode()
        let cuePath = AVAudioMixerNode()
        let matrix = try await SplitCueMatrix.instantiate()
        engine.attach(player)
        engine.attach(masterPath)
        engine.attach(cuePath)
        engine.attach(matrix.node)

        OutputGraphConnector.split(
            source: player,
            masterPath: masterPath,
            cuePath: cuePath,
            format: mono,
            in: engine
        )
        masterPath.outputVolume = 0.25
        cuePath.outputVolume = 0.5
        try OutputGraphConnector.connectMonoPath(
            masterPath,
            to: matrix,
            inputBus: 0,
            sampleRate: sampleRate,
            in: engine
        )
        try OutputGraphConnector.connectMonoPath(
            cuePath,
            to: matrix,
            inputBus: 1,
            sampleRate: sampleRate,
            in: engine
        )
        try engine.enableManualRenderingMode(
            .offline,
            format: stereo,
            maximumFrameCount: 256
        )
        try OutputGraphConnector.connectMatrixOutput(
            matrix,
            to: engine.mainMixerNode,
            sampleRate: sampleRate,
            in: engine
        )

        let input = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: mono, frameCapacity: 256))
        input.frameLength = 256
        let inputSamples = try XCTUnwrap(input.floatChannelData?[0])
        for frame in 0..<Int(input.frameLength) {
            inputSamples[frame] = 1
        }

        try matrix.applyChannelMap()
        player.scheduleBuffer(
            input,
            completionCallbackType: .dataConsumed,
            completionHandler: nil
        )
        try engine.start()
        player.play()

        let output = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: stereo, frameCapacity: 256))
        let status = try engine.renderOffline(256, to: output)
        XCTAssertEqual(status, .success)

        let left = try XCTUnwrap(output.floatChannelData?[0])
        let right = try XCTUnwrap(output.floatChannelData?[1])
        for frame in 0..<Int(output.frameLength) {
            XCTAssertEqual(left[frame], 0.25, accuracy: 0.000_1)
            XCTAssertEqual(right[frame], 0.5, accuracy: 0.000_1)
        }

        engine.stop()
        engine.disconnectNodeOutput(player)
        engine.disconnectNodeInput(masterPath)
        engine.disconnectNodeInput(cuePath)
        engine.disconnectNodeInput(matrix.node)
        engine.disconnectNodeOutput(matrix.node)
    }

    @MainActor
    func testSplitCueAcceptsDecksWithDifferentSampleRates() async throws {
        let deckAFixture = try RuntimeWAVFixture(
            duration: 0.02,
            sampleRate: 8_000,
            channels: 1
        )
        let deckBFixture = try RuntimeWAVFixture(
            duration: 0.02,
            sampleRate: 16_000,
            channels: 2
        )
        addTeardownBlock {
            deckAFixture.remove()
            deckBFixture.remove()
        }

        let engine = AudioEngine(startsAudioEngine: false)
        defer { engine.shutdown() }
        try await engine.setOutputMode(.splitCue)

        let deckAResult = try await engine.loadTrack(url: deckAFixture.url, deck: .a)
        let deckBResult = try await engine.loadTrack(url: deckBFixture.url, deck: .b)
        XCTAssertEqual(deckAResult, .installed)
        XCTAssertEqual(deckBResult, .installed)
        XCTAssertNil(engine.routingErrorMessage)
    }

    @MainActor
    func testSplitCueShutdownIsIdempotent() async throws {
        let engine = AudioEngine(startsAudioEngine: false)
        try await engine.setOutputMode(.splitCue)

        engine.shutdown()
        engine.shutdown()
    }
}
