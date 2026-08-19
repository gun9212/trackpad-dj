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
