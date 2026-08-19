import Atomics
import Foundation

struct DeckSeekCommand: Equatable, Sendable {
    let generation: UInt64
    let targetFrame: Double
}

/// Lock-free state shared by the main actor and one audio render callback.
final class DeckRealtimeState: @unchecked Sendable {

    private let playing = ManagedAtomic<Bool>(false)
    private let scratchActive = ManagedAtomic<Bool>(false)
    private let scratchRate = AtomicDouble(0)
    private let tempo = AtomicDouble(0)
    private let publishedPosition = AtomicDouble(0)
    private let seekTarget = AtomicDouble(0)
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

    @discardableResult
    func requestSeek(to targetFrame: Double) -> UInt64 {
        seekTarget.store(targetFrame)
        return seekGeneration.wrappingIncrementThenLoad(ordering: .releasing)
    }

    func seekCommand(after consumedGeneration: UInt64) -> DeckSeekCommand? {
        let generation = seekGeneration.load(ordering: .acquiring)
        guard generation != consumedGeneration else { return nil }
        return DeckSeekCommand(
            generation: generation,
            targetFrame: seekTarget.load()
        )
    }

    func publish(readPosition: Double) {
        publishedPosition.store(readPosition)
    }

    func reset(initialPosition: Double) {
        playing.store(false, ordering: .relaxed)
        scratchRate.store(0)
        scratchActive.store(false, ordering: .relaxed)
        tempo.store(0)
        publishedPosition.store(initialPosition)
        requestSeek(to: initialPosition)
    }
}
