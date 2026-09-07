import Atomics
import Foundation

struct DeckSeekCommand: Equatable, Sendable {
    let generation: UInt64
    let targetFrame: Double
    var startsPlayback = false
}

/// Lock-free state shared by the main actor and one audio render callback.
final class DeckRealtimeState: @unchecked Sendable {

    private let playing = ManagedAtomic<Bool>(false)
    private let scratchActive = ManagedAtomic<Bool>(false)
    private let scratchRate = AtomicDouble(0)
    private let tempo = AtomicDouble(0)
    private let pitchBend = AtomicDouble(0)
    private let publishedPosition = AtomicDouble(0)
    private let preFaderPeak = AtomicPeak()
    private let seekTarget = ManagedAtomic<UInt64>(Double(0).bitPattern)
    private let seekStartsPlayback = ManagedAtomic<Bool>(false)
    private let seekGeneration = ManagedAtomic<UInt64>(0)

    var isPlaying: Bool {
        playing.load(ordering: .relaxed)
    }

    var isScratchActive: Bool {
        scratchActive.load(ordering: .acquiring)
    }

    var targetScratchRate: Double {
        scratchRate.load()
    }

    var tempoPercent: Double {
        tempo.load()
    }

    var pitchBendPercent: Double {
        pitchBend.load()
    }

    var normalPlaybackRate: Double {
        1 + (tempoPercent + pitchBendPercent) / 100
    }

    var publicReadPosition: Double {
        publishedPosition.load()
    }

    var currentSeekGeneration: UInt64 {
        seekGeneration.load(ordering: .acquiring)
    }

    @discardableResult
    func togglePlaying() -> Bool {
        var original = playing.load(ordering: .relaxed)
        while true {
            let result = playing.compareExchange(
                expected: original,
                desired: !original,
                ordering: .acquiringAndReleasing
            )
            if result.exchanged {
                return !original
            }
            original = result.original
        }
    }

    func setPlaying(_ value: Bool) {
        playing.store(value, ordering: .relaxed)
    }

    func setScratch(active: Bool, rate: Double) {
        scratchRate.store(rate)
        scratchActive.store(active, ordering: .releasing)
    }

    func setTempoPercent(_ value: Double) {
        tempo.store(min(8, max(-8, value)))
    }

    func setPitchBendPercent(_ value: Double) {
        pitchBend.store(min(8, max(-8, value)))
    }

    @discardableResult
    func requestSeek(to targetFrame: Double, startsPlayback: Bool = false) -> UInt64 {
        // Single main-actor writer, bounded read on the audio thread. Odd = publication in progress.
        _ = seekGeneration.wrappingIncrementThenLoad(ordering: .sequentiallyConsistent)
        seekTarget.store(targetFrame.bitPattern, ordering: .sequentiallyConsistent)
        seekStartsPlayback.store(startsPlayback, ordering: .sequentiallyConsistent)
        return seekGeneration.wrappingIncrementThenLoad(ordering: .sequentiallyConsistent)
    }

    func seekCommand(after consumedGeneration: UInt64) -> DeckSeekCommand? {
        let generation = seekGeneration.load(ordering: .sequentiallyConsistent)
        guard generation.isMultiple(of: 2), generation != consumedGeneration else { return nil }
        let target = Double(bitPattern: seekTarget.load(ordering: .sequentiallyConsistent))
        let startsPlayback = seekStartsPlayback.load(ordering: .sequentiallyConsistent)
        guard generation == seekGeneration.load(ordering: .sequentiallyConsistent) else { return nil }
        return DeckSeekCommand(
            generation: generation,
            targetFrame: target,
            startsPlayback: startsPlayback
        )
    }

    func publish(readPosition: Double) {
        publishedPosition.store(readPosition)
    }

    func publish(preFaderPeak value: Float) {
        preFaderPeak.publish(value)
    }

    func consumePreFaderPeak() -> Float {
        preFaderPeak.consume()
    }

    func reset(initialPosition: Double) {
        playing.store(false, ordering: .relaxed)
        scratchRate.store(0)
        scratchActive.store(false, ordering: .relaxed)
        tempo.store(0)
        pitchBend.store(0)
        publishedPosition.store(initialPosition)
        preFaderPeak.reset()
        requestSeek(to: initialPosition)
    }
}
