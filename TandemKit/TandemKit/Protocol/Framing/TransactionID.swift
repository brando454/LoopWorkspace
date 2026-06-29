import Foundation

// Monotonically incrementing per-connection transaction ID.
// Wraps 255 → 0. Reset on disconnect.
//
// WP6/M4: internally synchronized with a lock as defense in depth. The primary
// serialization is SendSerializer (which orders the whole send critical
// section), but locking the allocator itself means a caller that bypasses that
// discipline can never double-allocate or tear a read-modify-write. The lock is
// uncontended on the normal path (SendSerializer already serializes callers),
// so its cost is negligible.
final class TransactionID: @unchecked Sendable {
    private var current: UInt8 = 0
    private let lock = NSLock()

    func next() -> UInt8 {
        lock.lock()
        defer { lock.unlock() }
        let id = current
        current = current &+ 1
        return id
    }

    func reset() {
        lock.lock()
        defer { lock.unlock() }
        current = 0
    }
}
