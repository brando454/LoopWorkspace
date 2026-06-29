import XCTest
import LoopKit
@testable import TandemKit

// WP6 / M2 (status fidelity): proves the PumpManager status-observer fan-out is
// actually fired AND carries a genuine oldStatus. Before this fix
// notifyStatusDidChange() passed old == new and was never called from any
// mutation path, so Loop's DeviceDataManager observer never saw a transition.
// These tests drive real mutations through the updateState seam (the production
// funnel) and assert the (didUpdate, oldStatus) pairs an observer receives.
// Built on the offline test initializer (InMemorySecretStore, nil central
// factory) so no Keychain or live CoreBluetooth is touched.
final class TandemPumpManagerStatusNotifyTests: XCTestCase {

    // Records every (new, old) pair delivered, on its own serial queue, and
    // fulfills one expectation per delivery so tests can await async fan-out
    // without sleeping.
    private final class FakeStatusObserver: PumpManagerStatusObserver {
        struct Update { let new: PumpManagerStatus; let old: PumpManagerStatus }
        private(set) var updates: [Update] = []
        var onUpdate: ((Update) -> Void)?
        func pumpManager(_ pumpManager: PumpManager,
                         didUpdate status: PumpManagerStatus,
                         oldStatus: PumpManagerStatus) {
            let u = Update(new: status, old: oldStatus)
            updates.append(u)
            onUpdate?(u)
        }
    }

    private let observerQueue = DispatchQueue(label: "test.statusObserver")

    private func makeManager(initialBattery: UInt8 = 50) -> TandemPumpManager {
        let state = TandemPumpState(basalRateSchedule: nil)
        state.batteryPercent = initialBattery
        state.basalState = .active
        return TandemPumpManager(state: state, secretStore: InMemorySecretStore())
    }

    // pumpBatteryChargeRemaining is Double? on PumpManagerStatus; unwrap before
    // the accuracy-based comparison.
    private func battery(_ s: PumpManagerStatus) throws -> Double {
        try XCTUnwrap(s.pumpBatteryChargeRemaining)
    }

    // 1. First status-changing mutation: observer's oldStatus is the init
    //    baseline, didUpdate is the new value, and old != new.
    func testFirstStatusChangeDeliversSeedBaselineAsOldStatus() throws {
        let pm = makeManager(initialBattery: 50)
        let observer = FakeStatusObserver()
        let exp = expectation(description: "first notification")
        observer.onUpdate = { _ in exp.fulfill() }
        pm.addStatusObserver(observer, queue: observerQueue)

        pm.updateState { $0.batteryPercent = 75 }

        wait(for: [exp], timeout: 2.0)
        observerQueue.sync {}
        XCTAssertEqual(observer.updates.count, 1)
        let u = observer.updates[0]
        XCTAssertEqual(try battery(u.old), 0.50, accuracy: 0.0001)
        XCTAssertEqual(try battery(u.new), 0.75, accuracy: 0.0001)
        XCTAssertNotEqual(u.old, u.new)
    }

    // 2. Second status-changing mutation: notification #2's oldStatus equals
    //    notification #1's newStatus (the watermark advanced); never old == new.
    func testSecondStatusChangeOldEqualsPriorNew() throws {
        let pm = makeManager(initialBattery: 50)
        let observer = FakeStatusObserver()
        var exp = expectation(description: "n1")
        observer.onUpdate = { _ in exp.fulfill() }
        pm.addStatusObserver(observer, queue: observerQueue)

        pm.updateState { $0.batteryPercent = 75 }
        wait(for: [exp], timeout: 2.0)

        exp = expectation(description: "n2")
        observer.onUpdate = { _ in exp.fulfill() }
        pm.updateState { $0.batteryPercent = 90 }
        wait(for: [exp], timeout: 2.0)
        observerQueue.sync {}

        XCTAssertEqual(observer.updates.count, 2)
        let n1 = observer.updates[0], n2 = observer.updates[1]
        XCTAssertEqual(n2.old, n1.new)
        XCTAssertEqual(try battery(n2.old), 0.75, accuracy: 0.0001)
        XCTAssertEqual(try battery(n2.new), 0.90, accuracy: 0.0001)
        XCTAssertNotEqual(n2.old, n2.new)
    }

    // 3. A connection-state-only mutation does not change any status field and
    //    must fire NO notification. We prove it by following it with a real
    //    battery change and asserting the ONLY notification is that battery
    //    change, whose oldStatus is still the baseline (so the suppressed write
    //    never advanced the watermark).
    func testConnectionStateOnlyMutationFiresNoNotification() throws {
        let pm = makeManager(initialBattery: 50)
        let observer = FakeStatusObserver()
        let exp = expectation(description: "only the battery change notifies")
        observer.onUpdate = { _ in exp.fulfill() }
        pm.addStatusObserver(observer, queue: observerQueue)

        pm.updateState { $0.connectionState = .authenticating }
        pm.updateState { $0.batteryPercent = 60 }

        wait(for: [exp], timeout: 2.0)
        observerQueue.sync {}
        XCTAssertEqual(observer.updates.count, 1)
        let u = observer.updates[0]
        XCTAssertEqual(try battery(u.old), 0.50, accuracy: 0.0001)
        XCTAssertEqual(try battery(u.new), 0.60, accuracy: 0.0001)
    }

    // 4. A battery change and a basalState change each fire exactly one
    //    notification with the correct old/new pair.
    func testBatteryAndBasalChangesEachFireOneNotification() throws {
        let pm = makeManager(initialBattery: 50)
        let observer = FakeStatusObserver()
        var exp = expectation(description: "battery")
        observer.onUpdate = { _ in exp.fulfill() }
        pm.addStatusObserver(observer, queue: observerQueue)

        pm.updateState { $0.batteryPercent = 70 }
        wait(for: [exp], timeout: 2.0)

        exp = expectation(description: "basal")
        observer.onUpdate = { _ in exp.fulfill() }
        pm.updateState { $0.basalState = .suspended }
        wait(for: [exp], timeout: 2.0)
        observerQueue.sync {}

        XCTAssertEqual(observer.updates.count, 2)
        XCTAssertEqual(try battery(observer.updates[0].new), 0.70, accuracy: 0.0001)
        if case .suspended = observer.updates[1].new.basalDeliveryState {} else {
            XCTFail("expected new basalDeliveryState == .suspended")
        }
        if case .active = observer.updates[1].old.basalDeliveryState {} else {
            XCTFail("expected old basalDeliveryState == .active")
        }
    }
}
