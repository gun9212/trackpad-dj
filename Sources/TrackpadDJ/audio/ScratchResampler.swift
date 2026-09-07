import Foundation

/// Windowed-sinc kernels are built off the render thread. No render-time allocation or trig.
struct ScratchResampler {
    private static let taps = 32
    private static let phases = 128
    private static let rates = 15 // 1x ... 8x in half-speed steps
    private let kernels: [Float]

    init() {
        var values: [Float] = []
        values.reserveCapacity(Self.rates * Self.phases * Self.taps)
        for rate in 0..<Self.rates {
            let cutoff = 0.9 / (1 + Double(rate) * 0.5)
            for phase in 0..<Self.phases {
                let fraction = Double(phase) / Double(Self.phases)
                var weights = [Double](repeating: 0, count: Self.taps)
                for tap in 0..<Self.taps {
                    let distance = Double(tap - 15) - fraction
                    let x = Double.pi * distance * cutoff
                    let sinc = abs(x) < 1e-12 ? 1 : sin(x) / x
                    let window = 0.5 + 0.5 * cos(Double.pi * distance / 16)
                    weights[tap] = cutoff * sinc * window
                }
                let sum = weights.reduce(0, +)
                values.append(contentsOf: weights.map { Float($0 / sum) })
            }
        }
        kernels = values
    }

    func sample(_ source: UnsafePointer<Float>, position: Double,
                speed: Double, frameCount: Int) -> Float {
        let index = Int(floor(position))
        let phase = min(Self.phases - 1, Int((position - Double(index)) * Double(Self.phases)))
        let rate = min(Double(Self.rates - 1), max(0, (speed - 1) * 2))
        let low = Int(rate)
        let high = min(Self.rates - 1, low + 1)
        let blend = Float(rate - Double(low))
        let lowOffset = (low * Self.phases + phase) * Self.taps
        let highOffset = (high * Self.phases + phase) * Self.taps
        var result: Float = 0
        for tap in 0..<Self.taps {
            let weight = kernels[lowOffset + tap]
                + (kernels[highOffset + tap] - kernels[lowOffset + tap]) * blend
            result += source[min(frameCount - 1, max(0, index + tap - 15))] * weight
        }
        return result
    }
}
