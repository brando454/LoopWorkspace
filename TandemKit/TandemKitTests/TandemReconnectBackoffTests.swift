//  WP6/M5: bounded auto-reconnect backoff + auth-reset terminal state.
//
//  Three concerns, all offline (no CBCentralManager):
//    1. The pure ReconnectBackoff policy: full delay schedule, cap, and ceiling.
//    2. setPumpUnreachable drives the transient state.pumpUnreachable flag and
//       is idempotent.
//    3. The M2 status-diff property: a pumpUnreachable-only change does NOT move
//       the assembled PumpManagerStatus, so it must not fan out to status
//       observers (the terminal condition surfaces via pumpStatusHighlight,
//       which reads the flag, not via a PumpManagerStatus change).
//
//  Determinism: no sleeps. State mutations are fenced on the
//  pumpManagerDidUpdateState delegate callback, which setPumpUnreachable
//  enqueues on delegateQueue from inside the stateQueue block (so the state
//  write happens-before the callback). This mirrors the event-driven await +
//  queue.sync drain the M2/M3 tests use rather than the timing-based pattern
//  that left the WP5 ceiling test flaky.
//
//  Coverage boundary (intentional): the pumpStatusHighlight -> "Signal Loss"
//  critical mapping lives in the TandemKitUI module, which is not a dependency
//  of the TandemKitTests host. It is a three-line pure transform of the public
//  state.pumpUnreachable flag asserted here; it is not re-exercised through the
//  UI module to avoid pulling TandemKitUI into the xctest host.

import XCTest
import LoopKit
@testable import TandemKit

final class TandemReconnectBackoffTests: XCTestCase {

    // MARK: - Pure policy

    private let policy = ReconnectBackoff(baseDelay: 2.0, maxDelay: 60.0, maxAttempts: 8)

    func testBackoffScheduleDoublesThenCapsThenCeilings() {
        // Production parameters: 2,4,8,16,32,60,60,60 then ceiling.
        let expected: [ReconnectBackoff.Decision] = [
            .retry(2), .retry(4), .retry(8), .retry(16),
            .retry(32), .retry(60), .retry(60), .retry(60),
        ]
        for (attempt, want) in expected.enumerated() {
            XCTAssertEqual(policy.decision(forAttempt: attempt), want,
                           "attempt \(attempt) should decide \(want)")
        }
    }

    func testCeilingReachedAtMaxAttempts() {
        XCTAssertEqual(policy.decision(forAttempt: 8), .ceiling)
        XCTAssertEqual(policy.decision(forAttempt: 9), .ceiling)
        XCTAssertEqual(policy.decision(forAttempt: 100), .ceiling)
    }

    func testDelayNeverExceedsCap() {
        for attempt in 0..<8 {
            if case .retry(let delay) = policy.decision(forAttempt: attempt) {
                XCTAssertLessThanOrEqual(delay, 60.0)
                XCTAssertGreaterThanOrEqual(delay, 2.0)
            } else {
                XCTFail("attempt \(attempt) should retry, not ceiling")
            }
        }
    }

    func testZeroMaxAttemptsCeilingsImmediately() {
        let p = ReconnectBackoff(baseDelay: 2.0, maxDelay: 60.0, maxAttempts: 0)
        XCTAssertEqual(p.decision(forAttempt: 0), .ceiling)
    }

    // MARK: - Terminal flag on the pump manager

    private func makeManager() -> (TandemPumpManager, ReconnectFenceDelegate, DispatchQueue) {
        let state = TandemPumpState(basalRateSchedule: nil)
        let manager = TandemPumpManager(state: state, secretStore: InMemorySecretStore())
        let delegateQueue = DispatchQueue(label: "test.delegate")
        let delegate = ReconnectFenceDelegate()
        manager.delegateQueue = delegateQueue
        manager.pumpManagerDelegate = delegate
        return (manager, delegate, delegateQueue)
    }

    func testSetPumpUnreachableTrueThenClear() {
        let (manager, delegate, delegateQueue) = makeManager()
        XCTAssertFalse(manager.state.pumpUnreachable)

        var exp = expectation(description: "set true")
        delegate.onUpdate = { exp.fulfill() }
        manager.setPumpUnreachable(true)
        wait(for: [exp], timeout: 1.0)
        delegateQueue.sync {}
        XCTAssertTrue(manager.state.pumpUnreachable)

        exp = expectation(description: "clear")
        delegate.onUpdate = { exp.fulfill() }
        manager.setPumpUnreachable(false)
        wait(for: [exp], timeout: 1.0)
        delegateQueue.sync {}
        XCTAssertFalse(manager.state.pumpUnreachable)
    }

    func testSetPumpUnreachableIsIdempotentNoSpuriousStatusFanOut() {
        let (manager, delegate, delegateQueue) = makeManager()
        let observer = CountingStatusObserver()
        let observerQueue = DispatchQueue(label: "test.observer")
        manager.addStatusObserver(observer, queue: observerQueue)

        // First real change fences via the delegate. The duplicate true is a
        // no-op (guarded), so it fires no callback; we then fence on the clear.
        var exp = expectation(description: "set true")
        delegate.onUpdate = { exp.fulfill() }
        manager.setPumpUnreachable(true)
        manager.setPumpUnreachable(true)   // idempotent: no delegate callback
        wait(for: [exp], timeout: 1.0)

        exp = expectation(description: "clear")
        delegate.onUpdate = { exp.fulfill() }
        manager.setPumpUnreachable(false)
        wait(for: [exp], timeout: 1.0)
        delegateQueue.sync {}
        observerQueue.sync {}

        // pumpUnreachable is not part of the assembled PumpManagerStatus
        // (battery/basal/bolus/insulin), so flipping it must NOT fan out to
        // status observers. The M2 diff guard is responsible for this.
        XCTAssertEqual(observer.updateCount, 0,
                       "pumpUnreachable changes must not move PumpManagerStatus")
        XCTAssertFalse(manager.state.pumpUnreachable)
    }
}

// Minimal status observer that counts didUpdate callbacks.
private final class CountingStatusObserver: PumpManagerStatusObserver {
    private(set) var updateCount = 0
    func pumpManager(_ pumpManager: PumpManager,
                     didUpdate status: PumpManagerStatus,
                     oldStatus: PumpManagerStatus) {
        updateCount += 1
    }
}
