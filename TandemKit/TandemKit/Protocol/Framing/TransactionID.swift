import Foundation

// Monotonically incrementing per-connection transaction ID.
// Wraps 255 → 0. Reset on disconnect.
// Must be accessed from a single serial queue.
final class TransactionID: @unchecked Sendable {
    private var current: UInt8 = 0

    func next() -> UInt8 {
        let id = current
        current = current &+ 1
        return id
    }

    func reset() {
        current = 0
    }
}
