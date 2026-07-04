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
import CoreBluetooth
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

// MARK: - Single guarded connect choke point (duplicate-connect fix)

// The bench Mobi accepts exactly one central connection. Overlapping
// central.connect sequences — a second connect issued while the first is still
// .connecting — collide and the pump drops the link with CBError.code=7
// pre-auth. All five connect sites in TandemBLEManager route through the
// connectIfIdle choke point, which connects only from .disconnected. These
// tests prove a second trigger against an in-flight (.connecting) peripheral
// issues NO second connect, and that the guard does not block a legitimate
// reconnect of an idle peripheral.
//
// Doubles: CBPeripheral has no public initializer, so the stub is allocated via
// the ObjC runtime (+new); NS_UNAVAILABLE is compile-time only. CBPeripheral's
// real designated initializer registers a KVO observer on "delegate" that its
// dealloc unconditionally removes — +new skips that, so the factory re-adds it
// to keep teardown from throwing. The recording central subclasses a real
// CBCentralManager WITHOUT the state-restoration identifier, so the eager TCC
// authorization probe the nil-factory seam exists to avoid never runs; every
// radio-touching method is overridden to record or no-op.

private final class StubStatePeripheral: CBPeripheral {
    var stubbedState: CBPeripheralState = .disconnected
    override var state: CBPeripheralState { stubbedState }
    override var name: String? { "Tandem Mobi 883" }

    static func make() -> StubStatePeripheral {
        let obj = (StubStatePeripheral.self as AnyObject)
            .perform(NSSelectorFromString("new"))!
            .takeRetainedValue()
        let p = obj as! StubStatePeripheral
        p.addObserver(p, forKeyPath: "delegate", options: .new, context: nil)
        return p
    }
}

private final class RecordingCentral: CBCentralManager {
    private(set) var connectedPeripherals: [CBPeripheral] = []
    var onConnect: ((CBPeripheral) -> Void)?

    override var state: CBManagerState { .poweredOn }

    override func connect(_ peripheral: CBPeripheral, options: [String: Any]?) {
        connectedPeripherals.append(peripheral)
        onConnect?(peripheral)
    }

    override func stopScan() {}
    override func scanForPeripherals(withServices serviceUUIDs: [CBUUID]?, options: [String: Any]?) {}
    override func cancelPeripheralConnection(_ peripheral: CBPeripheral) {}
    override func retrieveConnectedPeripherals(withServices serviceUUIDs: [CBUUID]) -> [CBPeripheral] { [] }
}

final class TandemSingleConnectGuardTests: XCTestCase {

    private var pumpManager: TandemPumpManager!
    private var bleManager: TandemBLEManager!
    private var central: RecordingCentral!

    override func setUp() {
        super.setUp()
        let state = TandemPumpState(basalRateSchedule: nil)
        pumpManager = TandemPumpManager(state: state, centralFactory: { _, _ in nil })
        let recording = RecordingCentral(delegate: nil, queue: nil)
        central = recording
        bleManager = TandemBLEManager(pumpManager: pumpManager, centralFactory: { _, _ in recording })
    }

    override func tearDown() {
        bleManager = nil
        central = nil
        pumpManager = nil
        super.tearDown()
    }

    // The defect this pins: two connect triggers while the first connect is
    // still in flight (.connecting) must yield exactly ONE central.connect.
    // Pre-fix, both the power-on re-entry (guarded only on != .connected) and a
    // re-discovery (unguarded) fired a second overlapping connect.
    func testSecondTriggerWhileConnectingIssuesNoSecondConnect() {
        let peripheral = StubStatePeripheral.make()
        // Mirror the radio: once connect is issued, the peripheral is in flight.
        central.onConnect = { p in
            (p as? StubStatePeripheral)?.stubbedState = .connecting
        }

        // Trigger 1: discovery. Peripheral is idle, so this connects.
        bleManager.centralManager(central, didDiscover: peripheral,
                                  advertisementData: [:], rssi: NSNumber(value: -50))
        XCTAssertEqual(central.connectedPeripherals.count, 1)

        // Trigger 2: power-on re-entry while the connect is in flight.
        bleManager.centralManagerDidUpdateState(central)
        XCTAssertEqual(central.connectedPeripherals.count, 1,
                       "power-on re-entry must not issue an overlapping connect while .connecting")

        // Trigger 3: a duplicate discovery callback — the previously unguarded site.
        bleManager.centralManager(central, didDiscover: peripheral,
                                  advertisementData: [:], rssi: NSNumber(value: -50))
        XCTAssertEqual(central.connectedPeripherals.count, 1,
                       "re-discovery must not issue an overlapping connect while .connecting")
    }

    // The guard must not over-block: a peripheral back at .disconnected (the
    // first connect attempt resolved and dropped) is legitimately reconnectable.
    func testPowerOnReconnectsAnIdlePeripheral() {
        let peripheral = StubStatePeripheral.make()

        bleManager.centralManager(central, didDiscover: peripheral,
                                  advertisementData: [:], rssi: NSNumber(value: -50))
        XCTAssertEqual(central.connectedPeripherals.count, 1)

        // Still .disconnected (no onConnect state flip): a fresh trigger connects.
        bleManager.centralManagerDidUpdateState(central)
        XCTAssertEqual(central.connectedPeripherals.count, 2,
                       "an idle (.disconnected) peripheral must still reconnect")
    }
}
