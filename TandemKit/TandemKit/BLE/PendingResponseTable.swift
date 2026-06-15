import CoreBluetooth
import Foundation

// Tracks in-flight pump requests awaiting a response.
//
// WHY THIS EXISTS
// The Tandem BLE protocol reuses opcodes across characteristics. For example
// 0xA5 is `LastBolusStatusV2Response` on the CURRENT_STATUS characteristic but
// `SetTempRateResponse` on the CONTROL characteristic. Routing a response by
// opcode alone (as the original code did) can hand a temp-rate reply to a
// bolus-status waiter, or vice versa. On a device that doses insulin that is a
// safety defect, not a cosmetic one.
//
// This table keys every pending request on the PAIR (responseCharacteristic,
// responseOpCode), which IS unique, and hands back a monotonic token so an
// entry can be removed precisely on timeout/error rather than removing "the
// first entry that happens to share this opcode".
//
// THREAD CONFINEMENT
// This type performs NO internal locking. The owner (TandemPeripheralManager)
// must call every method from its single serial manager queue. All CoreBluetooth
// delegate callbacks are delivered on that queue, and the manager hops its own
// send/timeout work onto the same queue, so every mutation here is serialized by
// construction. Unit tests call it from a single thread, which satisfies the
// same contract.
final class PendingResponseTable {

    struct Token: Equatable, Sendable {
        fileprivate let value: UInt64
    }

    private struct Entry {
        let token: Token
        let characteristic: CBUUID
        let opCode: UInt8
        let completion: (Result<Data, Error>) -> Void
    }

    private var entries: [Entry] = []
    private var nextToken: UInt64 = 0

    var isEmpty: Bool { entries.isEmpty }
    var count: Int { entries.count }

    // Register a waiter for a response on `characteristic` with `opCode`.
    // Returns a token the caller can later use to cancel this exact entry.
    @discardableResult
    func register(
        characteristic: CBUUID,
        opCode: UInt8,
        completion: @escaping (Result<Data, Error>) -> Void
    ) -> Token {
        let token = Token(value: nextToken)
        nextToken &+= 1
        entries.append(Entry(token: token,
                             characteristic: characteristic,
                             opCode: opCode,
                             completion: completion))
        return token
    }

    // A response arrived on `characteristic` with `opCode`. If a matching waiter
    // exists, remove it and deliver the cargo. Matching requires BOTH the
    // characteristic and the opcode to match — this is the collision fix.
    // Returns true if a waiter was resolved.
    @discardableResult
    func resolve(characteristic: CBUUID, opCode: UInt8, cargo: Data) -> Bool {
        guard let idx = entries.firstIndex(where: {
            $0.characteristic == characteristic && $0.opCode == opCode
        }) else {
            return false
        }
        let entry = entries.remove(at: idx)
        entry.completion(.success(cargo))
        return true
    }

    // Remove and fail a single entry by token (used for per-request timeout).
    // Returns true if the entry was still present (i.e. not already resolved).
    @discardableResult
    func fail(token: Token, error: Error) -> Bool {
        guard let idx = entries.firstIndex(where: { $0.token == token }) else {
            return false
        }
        let entry = entries.remove(at: idx)
        entry.completion(.failure(error))
        return true
    }

    // Fail every outstanding entry (used on disconnect/cleanup).
    func failAll(error: Error) {
        let outstanding = entries
        entries.removeAll()
        outstanding.forEach { $0.completion(.failure(error)) }
    }
}
