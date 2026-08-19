import Atomics
import Foundation

final class AtomicDouble: @unchecked Sendable {
    private let storage: ManagedAtomic<UInt64>

    init(_ value: Double) {
        storage = ManagedAtomic(value.bitPattern)
    }

    @inline(__always)
    func load() -> Double {
        Double(bitPattern: storage.load(ordering: .relaxed))
    }

    @inline(__always)
    func store(_ value: Double) {
        storage.store(value.bitPattern, ordering: .relaxed)
    }
}

/// Retains the highest finite sample magnitude until the display thread consumes it.
final class AtomicPeak: @unchecked Sendable {
    private let storage = ManagedAtomic<UInt32>(0)

    @inline(__always)
    func publish(_ value: Float) {
        guard value.isFinite, value > 0 else { return }

        var original = storage.load(ordering: .relaxed)
        while value > Float(bitPattern: original) {
            let result = storage.compareExchange(
                expected: original,
                desired: value.bitPattern,
                ordering: .relaxed
            )
            if result.exchanged {
                return
            }
            original = result.original
        }
    }

    @inline(__always)
    func consume() -> Float {
        Float(bitPattern: storage.exchange(0, ordering: .relaxed))
    }

    @inline(__always)
    func reset() {
        storage.store(0, ordering: .relaxed)
    }
}
