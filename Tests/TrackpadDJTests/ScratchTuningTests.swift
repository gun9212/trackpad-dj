import AVFoundation
import XCTest
@testable import TrackpadDJ

final class ScratchTuningTests: XCTestCase {
    func testResponseIsIndependentOfRenderBlockSizeAndReversesQuickly() throws {
        let small = try makeRig(blockSize: 64)
        let large = try makeRig(blockSize: 256)
        for rig in [small, large] {
            rig.state.setScratch(active: true, rate: 1)
            render(rig, frames: 1024)
            let beforeReverse = rig.state.publicReadPosition
            rig.state.setScratch(active: true, rate: -1)
            render(rig, frames: 256)
            XCTAssertLessThan(rig.state.publicReadPosition, beforeReverse)
        }
        XCTAssertEqual(small.state.publicReadPosition, large.state.publicReadPosition, accuracy: 1e-8)
    }

    func testStoppedScratchBecomesSilentWithoutPositionDrift() throws {
        let rig = try makeRig(blockSize: 64)
        rig.state.setScratch(active: true, rate: 1)
        render(rig, frames: 1024)
        rig.state.setScratch(active: true, rate: 0)
        render(rig, frames: 2048)
        let stopped = rig.state.publicReadPosition
        render(rig, frames: 256)
        XCTAssertEqual(rig.state.publicReadPosition, stopped)
        let samples = try XCTUnwrap(rig.output.floatChannelData?[0])
        for index in 0..<64 { XCTAssertEqual(samples[index], 0) }
        XCTAssertTrue(rig.state.isPlaying)
    }

    func testHighSpeedResamplerSuppressesAliasingAndPreservesLowTone() {
        let resampler = ScratchResampler()
        for speed in [2.0, 4.0, 8.0] {
            // Source frequencies in cycles per sample; high tone exceeds the new Nyquist limit.
            let high = (0..<8192).map { Float(sin(2 * Double.pi * 0.35 * Double($0))) }
            let low = (0..<8192).map { Float(sin(2 * Double.pi * 0.01 * Double($0))) }
            func rms(_ source: [Float]) -> Double {
                source.withUnsafeBufferPointer { buffer in
                    var energy = 0.0
                    for frame in 0..<512 {
                        let sample = resampler.sample(buffer.baseAddress!,
                            position: 64.25 + Double(frame) * speed, speed: speed, frameCount: source.count)
                        energy += Double(sample * sample)
                    }
                    return sqrt(energy / 512)
                }
            }
            XCTAssertLessThan(rms(high), 0.04, "speed \(speed)")
            XCTAssertGreaterThan(rms(low), 0.6, "speed \(speed)")
        }
    }

    func testPairSensitivityDoesNotJumpWhenSecondFingerStartsMoving() {
        var machine = GestureStateMachine()
        func frame(_ time: Double, _ y1: Double, _ y2: Double) -> GestureInputEvent {
            .frame([
                TouchPoint(identity: TouchID(rawValue: 1), position: CGPoint(x: 0.2, y: y1), timestamp: time),
                TouchPoint(identity: TouchID(rawValue: 2), position: CGPoint(x: 0.6, y: y2), timestamp: time)
            ], deck: .a, mode: .scratch)
        }
        _ = machine.process(frame(0, 0.4, 0.4))
        let first = machine.process(frame(0.01, 0.41, 0.4))
        let next = machine.process(frame(0.02, 0.42, 0.400001))
        guard case .setScratch(_, let firstRate) = first.first,
              case .setScratch(_, let nextRate) = next.first else { return XCTFail("Missing movement") }
        XCTAssertEqual(firstRate, nextRate, accuracy: 0.001)
        XCTAssertEqual(machine.process(frame(0.03, 0.42, 0.400001)), [.setScratch(.a, 0)])
    }

    func testHighSpeedStereoRenderStaysFinite() throws {
        let rig = try makeRig(blockSize: 256, channels: 2)
        rig.state.setScratch(active: true, rate: 8)
        let start = ProcessInfo.processInfo.systemUptime
        for _ in 0..<188 {
            rig.state.requestSeek(to: 2048)
            render(rig, frames: 256)
            for channel in 0..<2 {
                let samples = try XCTUnwrap(rig.output.floatChannelData?[channel])
                for index in 0..<256 {
                    XCTAssertTrue(samples[index].isFinite)
                    XCTAssertLessThanOrEqual(abs(samples[index]), 0.501)
                }
            }
        }
        // Informational only: machine load makes a hard timing assertion unsuitable for CI.
        print("Scratch stereo 1.003s render + assertions: \(ProcessInfo.processInfo.systemUptime - start)s")
    }

    private struct Rig {
        let state: DeckRealtimeState
        let renderer: DeckRenderer
        let output: AVAudioPCMBuffer
    }

    private func makeRig(blockSize: AVAudioFrameCount, channels: AVAudioChannelCount = 1) throws -> Rig {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: channels))
        let source = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8192))
        source.frameLength = 8192
        for channel in 0..<Int(channels) {
            let samples = try XCTUnwrap(source.floatChannelData?[channel])
            for index in 0..<8192 { samples[index] = 0.5 }
        }
        let state = DeckRealtimeState()
        state.setPlaying(true)
        let renderer = DeckRenderer(audio: DeckAudioData(buffer: source, format: format, preRollFrames: 0),
                                    state: state)
        state.requestSeek(to: 2048)
        let output = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: blockSize))
        output.frameLength = blockSize
        return Rig(state: state, renderer: renderer, output: output)
    }

    private func render(_ rig: Rig, frames: Int) {
        var silence = ObjCBool(false)
        for _ in 0..<(frames / Int(rig.output.frameLength)) {
            XCTAssertEqual(rig.renderer.render(isSilence: &silence, frameCount: rig.output.frameLength,
                                              audioBufferList: rig.output.mutableAudioBufferList), noErr)
        }
    }
}
