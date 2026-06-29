import XCTest
import Foundation
import CoreBluetooth
import HealthKit
import LoopKit
@testable import TandemKit

// TandemDeliveryGateIntegrationTests
// ----------------------------------
// Closes WP4 (TK-H5): the protocol flag modifiesInsulinDelivery was set on
// delivery request types but read nowhere. A central precondition gate now
// lives at the top of TandemPeripheralManager.send(_:) — the single universal
// write path. The production request/response transport closure calls
// try await self.send(request) (installed in init), so guarding send() covers
// both fire-and-forget and request/response delivery from one chokepoint.
//
// Scope is connection-and-auth only by design. Dose limits remain owned by
// enactBolus/enactTempBasal upstream and are not re-checked in the gate, so
// these tests never assert on limits.
//
// The gate runs BEFORE any txID allocation, serialization, or characteristic
// lookup. We exercise it by calling send(_:) directly:
//   * A delivery request (SetTempRateRequest, modifiesInsulinDelivery == true)
//     submitted while disconnected, or connected without an auth key, must
//     throw .deliveryPreconditionUnmet and never reach the wire.
//   * With connection AND auth both established, the gate passes and send()
//     proceeds. Because this peripheral never ran service discovery, its
//     characteristics map is empty, so send() then fails at the characteristic
//     lookup with .notConnected. Reaching that point PROVES the gate passed:
//     .notConnected is raised strictly after the gate, by the lookup, not by it.
//   * A non-delivery request (InsulinStatusRequest, modifiesInsulinDelivery
//     defaults to false) passes the gate regardless of connection or auth, and
//     likewise fails later at the empty-characteristics lookup.
//
// Construction reuses the proven offline seam from the WP3/WP5 integration
// suites: a nil-returning central factory on BOTH the pump manager and the BLE
// manager so no live CoreBluetooth manager is built and the eager
// state-restoration authorization probe (which SIGABRTs the bare xctest host)
// never runs. The pump manager is held by the test for the duration of each
// case because TandemPeripheralManager references it weakly; a discarded pump
// manager would deallocate and the gate would read a nil state, changing the
// diagnostic from "not connected" to "pump manager unavailable".
final class TandemDeliveryGateIntegrationTests: XCTestCase {

    // MARK: - Doubles

    // A peripheral that records nothing and discovers nothing. Its characteristic
    // set stays empty, which is exactly what makes the post-gate lookup fail with
    // .notConnected — the signal we use to prove the gate let a request through.
    private final class InertPeripheral: TandemPeripheral {
        weak var delegate: CBPeripheralDelegate?
        let identifier = UUID()  // WP6/M1: protocol now requires a UUID; a stub is fine for the double.
        var services: [CBService]? { nil }
        func discoverCharacteristics(_ characteristicUUIDs: [CBUUID]?, for service: CBService) {}
        func setNotifyValue(_ enabled: Bool, for characteristic: CBCharacteristic) {}
        func readValue(for characteristic: CBCharacteristic) {}
        func writeValue(_ data: Data, for characteristic: CBCharacteristic, type: CBCharacteristicWriteType) {}
    }

    // MARK: - Fixture

    private static let fixedTimeZone = TimeZone(identifier: "America/Denver")!

    // Builds a real TandemPeripheralManager over the offline construction seam.
    // connectionState and authKey are left at their constructed values; each test
    // sets them to model the precondition it exercises. Returns the pump manager
    // too so the caller can retain it (held weakly by the peripheral manager).
    private func makeManager() -> (TandemPeripheralManager, TandemPumpManager) {
        let schedule = BasalRateSchedule(
            dailyItems: [RepeatingScheduleValue(startTime: 0, value: 1.0)],
            timeZone: TandemDeliveryGateIntegrationTests.fixedTimeZone
        )!
        let state = TandemPumpState(basalRateSchedule: schedule)
        state.maximumBolusUnits = 25
        let pumpManager = TandemPumpManager(state: state, centralFactory: { _, _ in nil })
        let bleManager = TandemBLEManager(pumpManager: pumpManager, centralFactory: { _, _ in nil })
        let queue = DispatchQueue(label: "test.TandemDeliveryGateIntegration")

        let pm = TandemPeripheralManager(
            peripheral: InertPeripheral(),
            bleManager: bleManager,
            pumpManager: pumpManager,
            queue: queue
        )
        return (pm, pumpManager)
    }

    // Runs send(_:) synchronously from a test and returns the thrown error, or
    // nil if it returned. send() cannot return successfully in these tests (the
    // characteristics map is always empty), so a nil here is itself a failure
    // the caller asserts against.
    private func errorFromSend(
        _ pm: TandemPeripheralManager,
        _ request: some TandemRequest
    ) -> Error? {
        let exp = expectation(description: "send completed")
        var captured: Error?
        Task {
            do {
                try await pm.send(request)
            } catch {
                captured = error
            }
            exp.fulfill()
        }
        waitForExpectations(timeout: 5)
        return captured
    }

    // A delivery request fixture: 200% for 30 minutes. The exact values do not
    // matter — only that modifiesInsulinDelivery is true so the gate engages.
    private func deliveryRequest() -> SetTempRateRequest {
        SetTempRateRequest(durationMinutes: 30, percent: 200)
    }

    // MARK: - Delivery request, preconditions UNMET

    // Disconnected: the gate must throw .deliveryPreconditionUnmet("not connected")
    // before any serialization or characteristic lookup.
    func testDeliveryRequestRejectedWhenDisconnected() {
        let (pm, pumpManager) = makeManager()
        pumpManager.state.connectionState = .disconnected
        pumpManager.state.authKey = Data([0x01, 0x02, 0x03, 0x04])

        let error = errorFromSend(pm, deliveryRequest())
        withExtendedLifetime(pumpManager) {}

        guard case TandemBLEError.deliveryPreconditionUnmet(let reason)? = error else {
            XCTFail("disconnected delivery request must throw .deliveryPreconditionUnmet, got \(String(describing: error))")
            return
        }
        XCTAssertEqual(reason, "not connected")
    }

    // Connected but no auth key: must throw .deliveryPreconditionUnmet("missing auth key").
    func testDeliveryRequestRejectedWhenConnectedButUnauthenticated() {
        let (pm, pumpManager) = makeManager()
        pumpManager.state.connectionState = .connected
        pumpManager.state.authKey = nil

        let error = errorFromSend(pm, deliveryRequest())
        withExtendedLifetime(pumpManager) {}

        guard case TandemBLEError.deliveryPreconditionUnmet(let reason)? = error else {
            XCTFail("unauthenticated delivery request must throw .deliveryPreconditionUnmet, got \(String(describing: error))")
            return
        }
        XCTAssertEqual(reason, "missing auth key")
    }

    // Mid-handshake (authenticating, not yet connected) with an auth key present:
    // connection precondition still unmet, so the gate rejects on "not connected".
    // Guards against treating any non-disconnected state as good enough.
    func testDeliveryRequestRejectedWhileAuthenticating() {
        let (pm, pumpManager) = makeManager()
        pumpManager.state.connectionState = .authenticating
        pumpManager.state.authKey = Data([0xAA, 0xBB, 0xCC, 0xDD])

        let error = errorFromSend(pm, deliveryRequest())
        withExtendedLifetime(pumpManager) {}

        guard case TandemBLEError.deliveryPreconditionUnmet(let reason)? = error else {
            XCTFail("authenticating-state delivery request must throw .deliveryPreconditionUnmet, got \(String(describing: error))")
            return
        }
        XCTAssertEqual(reason, "not connected")
    }

    // MARK: - Delivery request, preconditions MET

    // Connected AND authenticated: the gate passes. send() proceeds and fails
    // later at the characteristic lookup (empty map) with .notConnected. The
    // error type is the proof: .notConnected is raised by the lookup strictly
    // after the gate, never by the gate itself.
    func testDeliveryRequestPassesGateWhenConnectedAndAuthenticated() {
        let (pm, pumpManager) = makeManager()
        pumpManager.state.connectionState = .connected
        pumpManager.state.authKey = Data([0x10, 0x20, 0x30, 0x40])

        let error = errorFromSend(pm, deliveryRequest())
        withExtendedLifetime(pumpManager) {}

        if case TandemBLEError.deliveryPreconditionUnmet? = error {
            XCTFail("a connected, authenticated delivery request must pass the gate, but it was rejected: \(String(describing: error))")
            return
        }
        guard case TandemBLEError.notConnected? = error else {
            XCTFail("past the gate, send() must fail at the empty characteristic lookup with .notConnected, got \(String(describing: error))")
            return
        }
    }

    // MARK: - Non-delivery request

    // A request whose type does NOT modify insulin delivery must pass the gate
    // regardless of connection or auth. We submit it fully disconnected with no
    // auth key — the most hostile precondition state — and require that it is NOT
    // rejected by the gate. It then fails at the empty characteristic lookup with
    // .notConnected, proving the gate did not interfere.
    func testNonDeliveryRequestPassesGateRegardlessOfPreconditions() {
        let (pm, pumpManager) = makeManager()
        pumpManager.state.connectionState = .disconnected
        pumpManager.state.authKey = nil

        let error = errorFromSend(pm, InsulinStatusRequest())
        withExtendedLifetime(pumpManager) {}

        if case TandemBLEError.deliveryPreconditionUnmet? = error {
            XCTFail("a non-delivery request must never be rejected by the delivery gate, got \(String(describing: error))")
            return
        }
        guard case TandemBLEError.notConnected? = error else {
            XCTFail("non-delivery request should pass the gate and fail at the lookup with .notConnected, got \(String(describing: error))")
            return
        }
    }

    // MARK: - Deallocated pump manager fails closed

    // The peripheral manager holds the pump manager weakly. If it has
    // deallocated, the gate cannot read connectionState or authKey, so a
    // delivery request must fail closed with "pump manager unavailable" rather
    // than transmitting insulin against unverifiable state. We deliberately do
    // NOT retain the pump manager here.
    func testDeliveryRequestFailsClosedWhenPumpManagerDeallocated() {
        let pm: TandemPeripheralManager = {
            let (pm, pumpManager) = makeManager()
            pumpManager.state.connectionState = .connected
            pumpManager.state.authKey = Data([0x55, 0x66, 0x77, 0x88])
            // pumpManager goes out of scope at the end of this closure; only the
            // weakly-referenced peripheral manager escapes.
            return pm
        }()

        let error = errorFromSend(pm, deliveryRequest())

        guard case TandemBLEError.deliveryPreconditionUnmet(let reason)? = error else {
            XCTFail("with a deallocated pump manager a delivery request must fail closed, got \(String(describing: error))")
            return
        }
        XCTAssertEqual(reason, "pump manager unavailable")
    }
}