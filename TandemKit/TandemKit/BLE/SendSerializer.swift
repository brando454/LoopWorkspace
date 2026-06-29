import Foundation

// WP6 / M4 (concurrency): serializes the BLE `send` critical section.
//
// `send` allocates a transaction ID, serializes the packet, and enqueues the
// transaction's chunk writes. That whole sequence must be atomic per
// transaction: if two `send` calls overlap, their txID allocations and chunk
// writes can interleave, so the pump receives chunks of two transactions
// intermixed and request/response matching corrupts. TransactionID's own
// contract ("must be accessed from a single serial queue") was never enforced
// because `send` runs on the cooperative pool, off the response queue.
//
// This actor enforces that contract for the async world. Swift actors are
// reentrant — a second call can enter while the first is suspended at an await
// — so a bare actor method does NOT serialize an async body on its own. We
// chain each run onto the previous one's completion via a stored Task, so the
// bodies execute strictly one at a time, in call order. `send` returns Void,
// so no result needs to cross the chain boundary.
//
// The send critical section never blocks on the wire (CBPeripheral.writeValue
// enqueues and returns; completion arrives via didWriteValueFor), so a run can
// never hold the serializer indefinitely waiting on hardware.
actor SendSerializer {
    // Tail of the serialized chain: the most recently enqueued run. A new run
    // awaits this before executing, then becomes the new tail. Errors are
    // captured per-run and rethrown to that run's caller; the chain itself is
    // a Task<Void, Never> so one failing body still releases the next run.
    private var tail: Task<Void, Never>?

    func run(_ body: @escaping () async throws -> Void) async throws {
        let previous = tail
        // Captures the body's thrown error (if any) so we can rethrow it to the
        // caller after the chained task completes.
        let errorBox = ErrorBox()

        let task = Task<Void, Never> {
            // Wait for the previous run to finish before starting this one. The
            // previous task never throws (errors are boxed), so awaiting .value
            // cannot propagate an unrelated error into this run.
            await previous?.value
            do {
                try await body()
            } catch {
                await errorBox.set(error)
            }
        }
        tail = task
        await task.value
        if let error = await errorBox.get() {
            throw error
        }
    }
}

// Minimal async-safe carrier for a single optional error crossing the chain.
private actor ErrorBox {
    private var error: Error?
    func set(_ e: Error) { error = e }
    func get() -> Error? { error }
}