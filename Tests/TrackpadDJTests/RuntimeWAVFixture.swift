import AVFoundation
import Foundation

final class RuntimeWAVFixture {

    let url: URL

    init(duration: TimeInterval, sampleRate: Double, channels: AVAudioChannelCount) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TrackpadDJTests-(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        url = directory.appendingPathComponent("fixture.wav")

        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: channels,
            interleaved: false
        ) else {
            throw FixtureError.formatCreationFailed
        }

        let frameCount = AVAudioFrameCount((duration * sampleRate).rounded())
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount),
              let channelData = buffer.floatChannelData else {
            throw FixtureError.bufferAllocationFailed
        }
        buffer.frameLength = frameCount

        for channel in 0..<Int(channels) {
            for frame in 0..<Int(frameCount) {
                let phase = 2 * Double.pi * 220 * Double(frame) / sampleRate
                channelData[channel][frame] = Float(sin(phase)) * 0.25
            }
        }

        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
    }

    func remove() {
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    enum FixtureError: Error {
        case formatCreationFailed
        case bufferAllocationFailed
    }
}
