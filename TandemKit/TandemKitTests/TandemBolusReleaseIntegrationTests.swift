import XCTest
import Foundation
import CoreBluetooth
import HealthKit
import LoopKit
@testable import TandemKit

// TandemBolusReleaseIntegrationTests
// ----------------------------------
// Closes the WP3 follow-up: end-to-end coverage that enactBolus releases the
// bolus-permission lock (TK-C5) on EVERY post-grant exit, driven through the
// REAL TandemPeripheralManager.enactBolus rather than inspection.
//
// Construction seam (Option A): the peripheral manager stores its peripheral as
// the TandemPeripheral protocol, so a RecordingPeripheral double satisfies init
// without a live CBPeripheral. The peripheral stays non-optional; only its type
// is an interface. Bolus traffic is intercepted by substituting
// sendAndReceiveTransport with a recording closure that returns byte-correct
// response cargo, so the real init?(cargo:) parsers and the real exit-path logic
// run. The transport identifies each step by the RESPONSE opCode the seam passes
// it: 0xA3 BolusPermissionResponse, 0x9F InitiateBolusResponse, 0xF1
// BolusPermissionReleaseResponse. "Release fired" == the transport was asked to
// satisfy opCode 0xF1.
//
// Cargo layouts (verified against source):
//   BolusPermissionResponse  : >=6 bytes; [0]=status(0=granted), [1..2]=bolusId LE, [5]=nackReason
//   InitiateBolusResponse    : >=3 bytes; [0]=status(0=success), [1..2]=bolusId LE
//   BolusPermissionRelease   : non-empty; [0]=status(0=ack)
final class TandemBolusReleaseIntegrationTests: XCTestCase {

    // MARK: - Doubles

    // Construction-only peripheral. enactBolus never drives discovery or the
    // low-level send/writeValue path (that flows through the substituted
    // transport), so every member is a no-op. Exists solely to satisfy the
    // TandemPeripheral init parameter without a live CBPeripheral.
    private final class RecordingPeripheral: TandemPeripheral {
        weak var delegate: CBPeripheralDelegate?
        var services: [CBService]? { nil }
        func discoverCharacteristics(_ characteristicUUIDs: [CBUUID]?, for service: CBService) {}
        func setNotifyValue(_ enabled: Bool, for characteristic: CBCharacteristic) {}
        func readValue(for characteristic: CBCharacteristic) {}
        func writeValue(_ data: Data, for characteristic: CBCharacteristic, type: CBCharacteristicWriteType) {}
    }

    // Records every response opCode the transport is asked to satisfy and lets a
    // test decide the InitiateBolus outcome (success cargo / NACK cargo / throw).
    private final class TransportRecorder: @unchecked Sendable {
        enum InitiateOutcome { case success, nack, throwError }
        let lock = NSLock()
        private(set) var requestedResponseOpCodes: [UInt8] = []
        var initiateOutcome: InitiateOutcome = .success
        let grantedBolusId: UInt16 = 0x1234

        var releaseWasRequested: Bool {
            lock.lock(); defer { lock.unlock() }
            return requestedResponseOpCodes.contains(0xF1)
        }

        func record(_ opCode: UInt8) {
            lock.lock(); requestedResponseOpCodes.append(opCode); lock.unlock()
        }
    }

    private struct TransportThrow: LocalizedError {
        var errorDescription: String? { "injected transport failure" }
    }

    // MARK: - Fixture

    // Builds the real object graph offline. TandemPumpManager(state:) is proven
    // offline-constructible by the reporting tests; its CBCentralManager sits
    // unauthorized and never connects. bleManager is required by init but the
    // bolus path never invokes it (used only on the auth-success path).
    private func makeManager(
        recorder: TransportRecorder,
        peripheral: RecordingPeripheral
    ) -> (TandemPeripheralManager, TandemPumpManager) {
        let state = TandemPumpState(basalRateSchedule: nil)
        state.maximumBolusUnits = 25
        let pumpManager = TandemPumpManager(state: state)
        let bleManager = TandemBLEManager(pumpManager: pumpManager)
        let queue = DispatchQueue(label: "test.TandemBolusReleaseIntegration")

        let pm = TandemPeripheralManager(
            peripheral: peripheral,
            bleManager: bleManager,
            pumpManager: pumpManager,
            queue: queue
        )

        // Substitute the transport: return byte-correct cargo per response opCode,
        // so the real enactBolus parsers and exit logic run.
        pm.sendAndReceiveTransport = { _, _, opCode in
            recorder.record(opCode)
            let id = recorder.grantedBolusId
            let lo = UInt8(id & 0xFF), hi = UInt8((id >> 8) & 0xFF)
            switch opCode {
            case 0xA3: // BolusPermissionResponse: grant
                return Data([0x00, lo, hi, 0, 0, 0])
            case 0x9F: // InitiateBolusResponse
                switch recorder.initiateOutcome {
                case .success:    return Data([0x00, lo, hi])
                case .nack:       return Data([0x01, lo, hi])
                case .throwError: throw TransportThrow()
                }
            case 0xF1: // BolusPermissionReleaseResponse: ack
                return Data([0x00])
            default:
                return Data([0x00])
            }
        }
        return (pm, pumpManager)
    }

    // MARK: - Tests: release-on-all-exits (TK-C5)

    // Confirmed-success exit: permission granted, initiate succeeds, lock released.
    func testReleaseFiresOnConfirmedSuccessExit() {
        let recorder = TransportRecorder()
        let peripheral = RecordingPeripheral()
        let (pm, _) = makeManager(recorder: recorder, peripheral: peripheral)
        recorder.initiateOutcome = .success

        let exp = expectation(description: "enactBolus completed")
        pm.enactBolus(units: 2.0) { error in
            XCTAssertNil(error, "success exit should report no error")
            exp.fulfill()
        }
        waitForExpectations(timeout: 5)
        XCTAssertTrue(recorder.releaseWasRequested,
                      "permission lock must be released on the confirmed-success exit")
    }

    // NACK-on-initiate exit: permission granted, initiate returns failure status,
    // enactBolus reports .communication, and the held lock is still released.
    func testReleaseFiresOnInitiateNackExit() {
        let recorder = TransportRecorder()
        let peripheral = RecordingPeripheral()
        let (pm, _) = makeManager(recorder: recorder, peripheral: peripheral)
        recorder.initiateOutcome = .nack

        let exp = expectation(description: "enactBolus completed")
        pm.enactBolus(units: 2.0) { error in
            XCTAssertNotNil(error, "NACK on initiate should report an error")
            exp.fulfill()
        }
        waitForExpectations(timeout: 5)
        XCTAssertTrue(recorder.releaseWasRequested,
                      "permission lock must be released on the initiate-NACK exit")
    }

    // Catch exit: permission granted, initiate throws. enactBolus catches, and
    // because the lock was granted (grantedBolusId set) it must release before
    // reporting .communication.
    func testReleaseFiresOnThrowAfterGrantExit() {
        let recorder = TransportRecorder()
        let peripheral = RecordingPeripheral()
        let (pm, _) = makeManager(recorder: recorder, peripheral: peripheral)
        recorder.initiateOutcome = .throwError

        let exp = expectation(description: "enactBolus completed")
        pm.enactBolus(units: 2.0) { error in
            XCTAssertNotNil(error, "a throw after grant should report an error")
            exp.fulfill()
        }
        waitForExpectations(timeout: 5)
        XCTAssertTrue(recorder.releaseWasRequested,
                      "permission lock must be released when initiate throws after grant")
    }

    // Negative control: an invalid dose is rejected BEFORE any pump traffic, so no
    // lock is ever held and the release MUST NOT fire. This guards against a
    // release that fires spuriously on a pre-grant rejection.
    func testReleaseDoesNotFireOnPreGrantRejection() {
        let recorder = TransportRecorder()
        let peripheral = RecordingPeripheral()
        let (pm, _) = makeManager(recorder: recorder, peripheral: peripheral)

        let exp = expectation(description: "enactBolus completed")
        pm.enactBolus(units: -1.0) { error in
            XCTAssertNotNil(error, "invalid dose must be rejected")
            exp.fulfill()
        }
        waitForExpectations(timeout: 5)
        XCTAssertFalse(recorder.releaseWasRequested,
                       "no lock is held on a pre-grant rejection, so release must not fire")
        XCTAssertTrue(recorder.requestedResponseOpCodes.isEmpty,
                      "an invalid dose must produce no pump traffic at all")
    }
}