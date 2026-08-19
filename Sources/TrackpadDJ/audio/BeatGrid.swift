import Accelerate
import AVFoundation
import Foundation

enum BeatGridSource: String, Equatable, Sendable {
    case automatic
    case tap
}

struct BeatGrid: Equatable, Sendable {
    let bpm: Double
    let firstBeatTime: TimeInterval
    let confidence: Double
    let source: BeatGridSource
}

enum BeatGridAnalyzer {
    static let minimumDuration: TimeInterval = 8
    static let maximumDuration: TimeInterval = 90
    static let minimumConfidence = 0.35

    private static let targetEnvelopeRate = 200.0
    private static let candidateBPMRange = 60.0...200.0
    private static let normalizedBPMRange = 80.0...160.0
    private static let onsetSmoothingKernel: [Float] = [1, 2, 3, 4, 5, 4, 3, 2, 1]
    private static let doubleTempoSupportWeight: Float = 0.75

    static func analyze(_ buffer: AVAudioPCMBuffer) -> BeatGrid? {
        guard let channelData = buffer.floatChannelData else { return nil }
        let sampleRate = buffer.format.sampleRate
        let totalFrames = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        guard sampleRate > 0,
              channelCount > 0,
              Double(totalFrames) / sampleRate >= minimumDuration else {
            return nil
        }

        let analyzedFrames = min(totalFrames, Int(sampleRate * maximumDuration))
        let windowLength = max(1, Int((sampleRate / targetEnvelopeRate).rounded()))
        let windowCount = analyzedFrames / windowLength
        guard windowCount > 1 else { return nil }

        var energy = [Float](repeating: 0, count: windowCount)
        for window in 0..<windowCount {
            let start = window * windowLength
            var meanSquare: Float = 0
            for channel in 0..<channelCount {
                let samples = UnsafeBufferPointer(
                    start: channelData[channel].advanced(by: start),
                    count: windowLength
                )
                let rms: Float = vDSP.rootMeanSquare(samples)
                meanSquare += rms * rms
            }
            energy[window] = sqrt(meanSquare / Float(channelCount))
        }

        let envelopeRate = sampleRate / Double(windowLength)
        return analyzeEnergyEnvelope(energy, sampleRate: envelopeRate)
    }

    static func analyzeEnergyEnvelope(
        _ energy: [Float],
        sampleRate: Double
    ) -> BeatGrid? {
        guard sampleRate > 0,
              Double(energy.count) / sampleRate >= minimumDuration else {
            return nil
        }

        // Suppress frame-scale level ripples before measuring positive energy changes.
        let smoothedEnergy = smoothEnergy(energy)
        guard let firstEnergy = smoothedEnergy.first else { return nil }

        var onsets = [Float](repeating: 0, count: smoothedEnergy.count)
        var previous = firstEnergy
        for index in smoothedEnergy.indices.dropFirst() {
            let current = smoothedEnergy[index]
            onsets[index] = max(0, current - previous)
            previous = current
        }

        guard let peak = onsets.max(), peak > 0 else { return nil }

        let minimumLag = max(1, Int((sampleRate * 60 / candidateBPMRange.upperBound).rounded(.down)))
        let maximumLag = min(
            energy.count - 1,
            Int((sampleRate * 60 / candidateBPMRange.lowerBound).rounded(.up))
        )
        guard maximumLag >= minimumLag else { return nil }

        let padded = onsets + [Float](repeating: 0, count: maximumLag)
        let rawCorrelation: [Float] = vDSP.correlate(padded, withKernel: onsets)

        var correlationScores = [Float](repeating: 0, count: maximumLag + 1)
        for lag in minimumLag...maximumLag {
            let overlap = onsets.count - lag
            guard overlap > 0, lag < rawCorrelation.count else { continue }
            let leading = onsets[0..<overlap]
            let trailing = onsets[lag..<onsets.count]
            let leadingRMS: Float = vDSP.rootMeanSquare(leading)
            let trailingRMS: Float = vDSP.rootMeanSquare(trailing)
            let denominator = leadingRMS * trailingRMS * Float(overlap)
            guard denominator > 0 else { continue }

            correlationScores[lag] = rawCorrelation[lag] / denominator
        }

        var bestLag: Int?
        var bestCombinedScore: Float = 0
        for lag in minimumLag...maximumLag {
            let bpm = 60 * sampleRate / Double(lag)
            guard normalizedBPMRange.contains(bpm) else { continue }

            // A real beat often has corroborating eighth-note energy at twice its tempo.
            var combinedScore = correlationScores[lag]
            let doubleTempo = bpm * 2
            if candidateBPMRange.contains(doubleTempo) {
                let doubleTempoLag = Int((sampleRate * 60 / doubleTempo).rounded())
                if correlationScores.indices.contains(doubleTempoLag) {
                    combinedScore += correlationScores[doubleTempoLag] * doubleTempoSupportWeight
                }
            }

            if combinedScore > bestCombinedScore {
                bestCombinedScore = combinedScore
                bestLag = lag
            }
        }

        guard let bestLag else { return nil }
        let bestScore = correlationScores[bestLag]
        let bpm = 60 * sampleRate / Double(bestLag)
        let period = sampleRate * 60 / bpm
        guard period.isFinite, period >= 1 else { return nil }

        let phase = strongestPhase(in: onsets, period: period)
        let threshold = peak * 0.25
        let beatIndices = predictedBeatIndices(
            in: onsets,
            phase: phase,
            period: period,
            threshold: threshold
        )
        let coverage = min(1, Double(beatIndices.count) / 4)
        let confidence = min(1, max(0, Double(bestScore) * coverage))
        guard confidence >= minimumConfidence,
              let firstBeatIndex = beatIndices.first else {
            return nil
        }

        return BeatGrid(
            bpm: bpm,
            firstBeatTime: Double(firstBeatIndex) / sampleRate,
            confidence: confidence,
            source: .automatic
        )
    }

    private static func smoothEnergy(_ energy: [Float]) -> [Float] {
        let radius = onsetSmoothingKernel.count / 2
        var result = [Float](repeating: 0, count: energy.count)

        for index in energy.indices {
            var weightedEnergy: Float = 0
            var weightTotal: Float = 0
            for kernelIndex in onsetSmoothingKernel.indices {
                let sourceIndex = index + kernelIndex - radius
                guard energy.indices.contains(sourceIndex) else { continue }
                let weight = onsetSmoothingKernel[kernelIndex]
                weightedEnergy += energy[sourceIndex] * weight
                weightTotal += weight
            }
            if weightTotal > 0 {
                result[index] = weightedEnergy / weightTotal
            }
        }

        return result
    }

    private static func strongestPhase(in onsets: [Float], period: Double) -> Int {
        let phaseCount = max(1, Int(period.rounded()))
        var bestPhase = 0
        var bestScore: Float = -.infinity

        for phase in 0..<phaseCount {
            var score: Float = 0
            var beat = Double(phase)
            while Int(beat.rounded()) < onsets.count {
                score += onsets[Int(beat.rounded())]
                beat += period
            }
            if score > bestScore {
                bestScore = score
                bestPhase = phase
            }
        }
        return bestPhase
    }

    private static func predictedBeatIndices(
        in onsets: [Float],
        phase: Int,
        period: Double,
        threshold: Float
    ) -> [Int] {
        var result: [Int] = []
        var beat = Double(phase)

        while Int(beat.rounded()) < onsets.count {
            let center = Int(beat.rounded())
            let lower = max(0, center - 1)
            let upper = min(onsets.count - 1, center + 1)
            if let strongest = (lower...upper).max(by: { onsets[$0] < onsets[$1] }),
               onsets[strongest] >= threshold {
                result.append(strongest)
            }
            beat += period
        }
        return result
    }
}
