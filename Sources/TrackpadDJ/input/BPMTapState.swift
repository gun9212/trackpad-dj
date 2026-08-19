import Foundation

struct BPMTapState: Equatable {

    private(set) var tapTimes: [TimeInterval] = []
    private(set) var bpm: Double = 0
    private(set) var beatOffset: Double = 0

    mutating func tap(at timestamp: TimeInterval, progress: Double) {
        if let last = tapTimes.last, timestamp - last > 2.0 {
            tapTimes = []
        }

        if tapTimes.isEmpty {
            beatOffset = progress
        }

        tapTimes.append(timestamp)
        if tapTimes.count > 8 {
            tapTimes = Array(tapTimes.suffix(8))
        }

        guard tapTimes.count >= 2,
              let first = tapTimes.first,
              let last = tapTimes.last,
              last > first else { return }

        let span = last - first
        bpm = min(200, max(60, 60.0 * Double(tapTimes.count - 1) / span))
    }

    mutating func reset() {
        self = BPMTapState()
    }
}
