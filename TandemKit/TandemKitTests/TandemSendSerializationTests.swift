import XCTest
@testable import TandemKit

// WP6 / M4 (concurrency): proves the two primitives the send path now relies on.
//
// These are boundary tests, not a full live-peripheral integration: CBCharacteristic
// cannot be fabricated in a unit-test host, so the real send() write loop can't run
// offline without a larger BLE seam (tracked separately). Instead we prove the exact
// mechanisms send() was changed to use — SendSerializer (no overlapping runs, strict
// call order) and TransactionID (collision-free allocation under concurrency). That
// send() actually wraps its critical section in sendSerializer.run is verified by code
// review of the wrapped body; end-to-end on-wire ordering is a SUSPECTED-NEEDS-ON-DEVICE
// confirmation.
final class TandemSendSerializationTests: XCTestCase {

    // SendSerializer must not let two run-bodies overlap, even when each body
    // suspends at an await partway through. We model a body as enter -> await ->
    // exit and record the events; correct serialization yields strictly paired
    // enter/exit with no enter occurring between another's enter and exit.
    func testSerializerPreventsOverlap() async throws {
        let serializer = SendSerializer()
        let recorder = EventRecorder()

        await withThrowingTaskGroup(of: Void.self) { group in
            for i in 0..<50 {
                group.addTask {
                    try await serializer.run {
                        await recorder.append("enter-\(i)")
                        // Yield mid-body so a reentrant actor would interleave here
                        // if the chain didn't serialize.
                        await Task.yield()
                        try? await Task.sleep(nanoseconds: 1_000)
                        await recorder.append("exit-\(i)")
                    }
                }
            }
        }

        let events = await recorder.events
        XCTAssertEqual(events.count, 100, "every run should record one enter and one exit")
        // Walk the event stream: between an enter and its matching exit, no other
        // enter may appear. Equivalent to: events come in enter,exit,enter,exit...
        // pairs where each exit matches the immediately preceding enter.
        var idx = 0
        while idx < events.count {
            let enter = events[idx]
            XCTAssertTrue(enter.hasPrefix("enter-"), "expected an enter at \(idx), got \(enter)")
            let exit = events[idx + 1]
            XCTAssertTrue(exit.hasPrefix("exit-"), "expected an exit at \(idx + 1), got \(exit)")
            XCTAssertEqual(enter.replacingOccurrences(of: "enter-", with: ""),
                           exit.replacingOccurrences(of: "exit-", with: ""),
                           "exit must match the immediately preceding enter — interleave detected")
            idx += 2
        }
    }

    // Runs execute in the order run() was called (FIFO chaining).
    func testSerializerPreservesCallOrder() async throws {
        let serializer = SendSerializer()
        let recorder = EventRecorder()

        // Awaiting each run sequentially establishes a deterministic enqueue order;
        // the bodies must execute in that same order.
        for i in 0..<25 {
            try await serializer.run {
                await recorder.append("\(i)")
            }
        }

        let events = await recorder.events
        XCTAssertEqual(events, (0..<25).map { "\($0)" })
    }

    // A throwing body propagates to its caller and still releases the next run.
    func testSerializerRethrowsAndContinues() async throws {
        let serializer = SendSerializer()
        struct Boom: Error {}

        do {
            try await serializer.run { throw Boom() }
            XCTFail("expected the thrown error to propagate")
        } catch is Boom {
            // expected
        }

        // The chain must still work after a failed run.
        var ran = false
        try await serializer.run { ran = true }
        XCTAssertTrue(ran, "serializer must continue after a body throws")
    }

    // TransactionID.next() must never hand the same id to two concurrent callers.
    func testTransactionIDIsCollisionFreeUnderConcurrency() async {
        let txID = TransactionID()
        txID.reset()
        let collector = IDCollector()

        // 256 allocations exactly covers one full wrap (0...255) with no repeats.
        await withTaskGroup(of: UInt8.self) { group in
            for _ in 0..<256 {
                group.addTask { txID.next() }
            }
            for await id in group {
                await collector.add(id)
            }
        }

        let ids = await collector.ids
        XCTAssertEqual(ids.count, 256)
        XCTAssertEqual(Set(ids).count, 256, "all 256 ids in one wrap must be unique — collision under concurrency")
    }
}

// MARK: - Test actors

private actor EventRecorder {
    private(set) var events: [String] = []
    func append(_ e: String) { events.append(e) }
}

private actor IDCollector {
    private(set) var ids: [UInt8] = []
    func add(_ id: UInt8) { ids.append(id) }
}