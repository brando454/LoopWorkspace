import XCTest
import Foundation
import CoreBluetooth
import LoopKit
@testable import TandemKit

// TandemBolusUncertaintyTests
// ---------------------------
// Pins the TK-C6 delivery-uncertainty mapping in enactBolus: the outcome must
// distinguish "the pump may have started delivering" from "nothing was delivered."
//
//   - throw AFTER InitiateBolus is transmitted  -> .uncertainDelivery
//   - throw BEFORE initiate (permission step)   -> .communication (clean failure)
//   - explicit initiate NACK                    -> .communication (certain non-delivery)
//   - success                                   -> nil
//
// Reporting .communication when the bolus may in fact have started would tell Loop
// nothing was delivered and silently under-count IOB — the unsafe direction — so
// erring toward .uncertainDelivery once the initiate is on the wire is the point.
//
// Driven through the real enactBolus via the sendAndReceiveTransport seam, keyed on
// the response opCode each step requests: 0xA3 permission, 0x9F initiate, 0xF1 release.
final class TandemBolusUncertaintyTests: XCTestCase {

    // Construction-only peripheral (bolus traffic flows through the substituted
    // transport, not this object).
    private final class RecordingPeripheral: TandemPeripheral {
        weak var delegate: CBPeripheralDelegate?
        let identifier = UUID()
        var services: [CBService]? { nil }
        func discoverCharacteristics(_ characteristicUUIDs: [CBUUID]?, for service: CBService) {}
        func setNotifyValue(_ enabled: Bool, for characteristic: CBCharacteristic) {}
        func readValue(for characteristic: CBCharacteristic) {}
        func writeValue(_ data: Data, for characteristic: CBCharacteristic, type: CBCharacteristicWriteType) {}
    }

    private struct TransportThrow: LocalizedError {
        var errorDescription: String? { "injected transport failure" }
    }

    private enum FailPoint { case permission, initiate, initiateNack, none }

    private func makeManager(fail: FailPoint) -> (TandemPeripheralManager, TandemPumpManager) {
        let state = TandemPumpState(basalRateSchedule: nil)
        let pumpManager = TandemPumpManager(state: state, centralFactory: { _, _ in nil })
        let bleManager = TandemBLEManager(pumpManager: pumpManager, centralFactory: { _, _ in nil })
        let queue = DispatchQueue(label: "test.TandemBolusUncertainty")
        let pm = TandemPeripheralManager(
            peripheral: RecordingPeripheral(),
            bleManager: bleManager,
            pumpManager: pumpManager,
            queue: queue
        )

        let bolusId: UInt16 = 0x1234
        let lo = UInt8(bolusId & 0xFF), hi = UInt8((bolusId >> 8) & 0xFF)
        pm.sendAndReceiveTransport = { _, _, opCode in
            switch opCode {
            case 0xA3: // BolusPermissionResponse
                if fail == .permission { throw TransportThrow() }
                return Data([0x00, lo, hi, 0, 0, 0])   // granted
            case 0x9F: // InitiateBolusResponse
                if fail == .initiate { throw TransportThrow() }
                if fail == .initiateNack { return Data([0x01, lo, hi]) }  // status != 0 -> NACK
                return Data([0x00, lo, hi])            // success
            case 0xF1: // BolusPermissionReleaseResponse
                return Data([0x00])
            default:
                return Data([0x00])
            }
        }
        return (pm, pumpManager)
    }

    private func enact(fail: FailPoint) -> PumpManagerError? {
        let (pm, pumpManager) = makeManager(fail: fail)
        var captured: PumpManagerError??  // outer optional: was completion called
        let exp = expectation(description: "enactBolus completed")
        pm.enactBolus(units: 2.0) { error in
            captured = error
            exp.fulfill()
        }
        waitForExpectations(timeout: 5)
        withExtendedLifetime(pumpManager) {}
        return captured ?? nil
    }

    func testThrowAfterInitiateIsUncertainDelivery() {
        guard case .uncertainDelivery = enact(fail: .initiate) else {
            return XCTFail("a throw after the initiate was transmitted must be .uncertainDelivery")
        }
    }

    func testThrowAtPermissionIsCleanCommunicationFailure() {
        guard case .communication = enact(fail: .permission) else {
            return XCTFail("a throw before the initiate must be a clean .communication failure, not uncertain")
        }
    }

    func testInitiateNackIsCertainCommunicationFailureNotUncertain() {
        // An explicit NACK means the pump rejected the initiate — a CERTAIN
        // non-delivery, which must stay .communication and never be reported as
        // uncertain (over-reporting uncertainty on a known reject is a regression).
        guard case .communication = enact(fail: .initiateNack) else {
            return XCTFail("an explicit initiate NACK must be .communication, not .uncertainDelivery")
        }
    }

    func testSuccessReportsNoError() {
        XCTAssertNil(enact(fail: .none), "a fully successful bolus must report no error")
    }
}
