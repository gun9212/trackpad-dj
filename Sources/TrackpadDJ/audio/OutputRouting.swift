import AVFoundation
import AudioToolbox

enum OutputMode: Equatable, Sendable {
    case stereoMaster
    case splitCue
}

enum OutputRoutingError: LocalizedError {
    case splitCueRequiresStereoOutput
    case invalidRouteFormat
    case matrixUnavailable
    case unexpectedMatrixDimensions(inputs: UInt32, outputs: UInt32)
    case audioUnitFailure(operation: String, status: OSStatus)

    var errorDescription: String? {
        switch self {
        case .splitCueRequiresStereoOutput:
            return "Split Cue requires an output device with at least two channels."
        case .invalidRouteFormat:
            return "A valid audio route format could not be created."
        case .matrixUnavailable:
            return "The Split Cue channel router is unavailable."
        case .unexpectedMatrixDimensions(let inputs, let outputs):
            return "The Split Cue matrix has an unexpected \(inputs)x\(outputs) layout."
        case .audioUnitFailure(let operation, let status):
            return "\(operation) failed with audio status \(status)."
        }
    }
}

enum CueMonitorGains {
    static func values(
        deckAEnabled: Bool,
        deckBEnabled: Bool
    ) -> (deckA: Float, deckB: Float) {
        switch (deckAEnabled, deckBEnabled) {
        case (false, false): return (0, 0)
        case (true, false): return (1, 0)
        case (false, true): return (0, 1)
        case (true, true): return (0.5, 0.5)
        }
    }
}

private struct UncheckedAudioUnit: @unchecked Sendable {
    let value: AVAudioUnit
}

/// Two mono inputs are mapped exactly to a stereo output:
/// post-fader master → left, pre-fader cue → right.
@MainActor
final class SplitCueMatrix {
    let node: AVAudioUnit

    private init(node: AVAudioUnit) throws {
        self.node = node
        try setBusCount(2, scope: kAudioUnitScope_Input)
        try setBusCount(1, scope: kAudioUnitScope_Output)
    }

    static func instantiate() async throws -> SplitCueMatrix {
        let description = AudioComponentDescription(
            componentType: kAudioUnitType_Mixer,
            componentSubType: kAudioUnitSubType_MatrixMixer,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )
        let box: UncheckedAudioUnit = try await withCheckedThrowingContinuation { continuation in
            AVAudioUnit.instantiate(with: description, options: []) { unit, error in
                if let unit {
                    continuation.resume(returning: UncheckedAudioUnit(value: unit))
                } else {
                    continuation.resume(throwing: error ?? OutputRoutingError.matrixUnavailable)
                }
            }
        }
        return try SplitCueMatrix(node: box.value)
    }

    func applyChannelMap() throws {
        var dimensions = [UInt32](repeating: 0, count: 2)
        var byteCount = UInt32(MemoryLayout<UInt32>.size * dimensions.count)
        let dimensionStatus = dimensions.withUnsafeMutableBytes { bytes in
            AudioUnitGetProperty(
                node.audioUnit,
                kAudioUnitProperty_MatrixDimensions,
                kAudioUnitScope_Global,
                0,
                bytes.baseAddress!,
                &byteCount
            )
        }
        guard dimensionStatus == noErr else {
            throw OutputRoutingError.audioUnitFailure(
                operation: "Reading Split Cue matrix dimensions",
                status: dimensionStatus
            )
        }
        guard dimensions == [2, 2] else {
            throw OutputRoutingError.unexpectedMatrixDimensions(
                inputs: dimensions[0],
                outputs: dimensions[1]
            )
        }

        let inputChannels = Int(dimensions[0])
        let outputChannels = Int(dimensions[1])
        let columns = outputChannels + 1
        var levels = [Float](
            repeating: 0,
            count: (inputChannels + 1) * (outputChannels + 1)
        )

        // Crosspoints: master input 0 to left, cue input 1 to right.
        levels[0 * columns + 0] = 1
        levels[1 * columns + 1] = 1

        // Per-input, per-output, and global gains.
        for input in 0..<inputChannels {
            levels[input * columns + outputChannels] = 1
        }
        let outputRow = inputChannels * columns
        for output in 0..<outputChannels {
            levels[outputRow + output] = 1
        }
        levels[outputRow + outputChannels] = 1

        let levelStatus = levels.withUnsafeBytes { bytes in
            AudioUnitSetProperty(
                node.audioUnit,
                kAudioUnitProperty_MatrixLevels,
                kAudioUnitScope_Global,
                0,
                bytes.baseAddress!,
                UInt32(bytes.count)
            )
        }
        guard levelStatus == noErr else {
            throw OutputRoutingError.audioUnitFailure(
                operation: "Configuring Split Cue channel levels",
                status: levelStatus
            )
        }
    }

    private func setBusCount(_ value: UInt32, scope: AudioUnitScope) throws {
        var count = value
        let status = AudioUnitSetProperty(
            node.audioUnit,
            kAudioUnitProperty_ElementCount,
            scope,
            0,
            &count,
            UInt32(MemoryLayout<UInt32>.size)
        )
        guard status == noErr else {
            throw OutputRoutingError.audioUnitFailure(
                operation: "Configuring Split Cue buses",
                status: status
            )
        }
    }
}

/// Shared AVAudioEngine wiring used by the production graph and routing tests.
@MainActor
enum OutputGraphConnector {

    static func split(
        source: AVAudioNode,
        masterPath: AVAudioMixerNode,
        cuePath: AVAudioMixerNode,
        format: AVAudioFormat,
        in engine: AVAudioEngine
    ) {
        engine.connect(
            source,
            to: [
                AVAudioConnectionPoint(node: masterPath, bus: 0),
                AVAudioConnectionPoint(node: cuePath, bus: 0),
            ],
            fromBus: 0,
            format: format
        )
    }

    static func connectMonoPath(
        _ path: AVAudioMixerNode,
        to matrix: SplitCueMatrix,
        inputBus: AVAudioNodeBus,
        sampleRate: Double,
        in engine: AVAudioEngine
    ) throws {
        guard sampleRate > 0,
              let monoFormat = AVAudioFormat(
                standardFormatWithSampleRate: sampleRate,
                channels: 1
              ) else {
            throw OutputRoutingError.invalidRouteFormat
        }
        engine.connect(
            path,
            to: matrix.node,
            fromBus: 0,
            toBus: inputBus,
            format: monoFormat
        )
    }

    static func connectMatrixOutput(
        _ matrix: SplitCueMatrix,
        to mainMixer: AVAudioMixerNode,
        sampleRate: Double,
        in engine: AVAudioEngine
    ) throws {
        guard sampleRate > 0,
              let stereoFormat = AVAudioFormat(
                standardFormatWithSampleRate: sampleRate,
                channels: 2
              ) else {
            throw OutputRoutingError.invalidRouteFormat
        }
        engine.connect(
            matrix.node,
            to: mainMixer,
            fromBus: 0,
            toBus: mainMixer.nextAvailableInputBus,
            format: stereoFormat
        )
        engine.prepare()
        try matrix.applyChannelMap()
    }
}
