import XCTest
import Foundation
import CoreBluetooth
import HealthKit
import LoopKit
@testable import TandemKit

// TandemTempRateCeilingIntegrationTests
// -------------------------------------
// Closes WP5 H2 (TK-H2): an over-ceiling temp rate must no longer be silently
// clamped to 250% and reported as success. The behavior is now an explicit
// TempRateCeilingPolicy on the pump manager:
//   .reject            -> fail with .deviceState, send NO command to the pump.
//   .reportEnactedRate -> send the clamped 250% command, and on confirmed
//                         success record the enacted percent into state so
//                         basalDeliveryState reports the true enacted rate.
//
// Driven through the REAL TandemPeripheralManager.enactTempBasal using the same
// construction + transport-substitution seam as the WP3 bolus tests. The
// transport keys on the SetTempRateResponse opCode 0xA5; a success cargo is
// [0x00, idLo, idHi] (status 0 = success, [1..2] = tempRateId LE).
//
// Fixture: a flat 1.0 U/hr schedule, so percent == requested U/hr * 100.
//   within-ceiling request: 2.0 U/hr  -> 200%
//   over-ceiling request:   5.0 U/hr  -> 500% (clamps to 250%)
final class TandemTempRateCeilingIntegrationTests: XCTestCase {

    // MARK: - Doubles

    private final class RecordingPeripheral: TandemPeripheral {
        weak var delegate: CBPeripheralDelegate?
        let identifier = UUID()  // WP6/M1: protocol now requires a UUID; a stub is fine for the double.
        var services: [CBService]? { nil }
        func discoverCharacteristics(_ characteristicUUIDs: [CBUUID]?, for service: CBService) {}
        func setNotifyValue(_ enabled: Bool, for characteristic: CBCharacteristic) {}
        func readValue(for characteristic: CBCharacteristic) {}
        func writeValue(_ data: Data, for characteristic: CBCharacteristic, type: CBCharacteristicWriteType) {}
    }

    // Records the response opCodes the transport is asked to satisfy and the
    // percent carried by each SetTempRateRequest, so a test can assert both that
    // a command was sent and the exact enacted percent on the wire.
    private final class TempTransportRecorder: @unchecked Sendable {
        let lock = NSLock()
        private(set) var requestedResponseOpCodes: [UInt8] = []
        private(set) var sentTempPercents: [UInt16] = []
        let tempRateId: UInt16 = 0x2222

        var tempCommandWasSent: Bool {
            lock.lock(); defer { lock.unlock() }
            return requestedResponseOpCodes.contains(0xA5)
        }

        func record(opCode: UInt8, request: TandemRequest?) {
            lock.lock()
            requestedResponseOpCodes.append(opCode)
            if let req = request as? SetTempRateRequest {
                sentTempPercents.append(req.percent)
            }
            lock.unlock()
        }
    }

    // MARK: - Fixture

    // Fixed, mid-day effective date in a pinned zone so schedule lookups and
    // assertions are deterministic regardless of when the suite runs.
    private static let fixedTimeZone = TimeZone(identifier: "America/Denver")!
    private var effectiveDate: Date {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TandemTempRateCeilingIntegrationTests.fixedTimeZone
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f.date(from: "2026-03-01 12:00:00")!
    }

    private func makeManager(
        recorder: TempTransportRecorder,
        scheduledRate: Double,
        policy: TempRateCeilingPolicy
    ) -> (TandemPeripheralManager, TandemPumpManager) {
        let schedule = BasalRateSchedule(
            dailyItems: [RepeatingScheduleValue(startTime: 0, value: scheduledRate)],
            timeZone: TandemTempRateCeilingIntegrationTests.fixedTimeZone
        )!
        let state = TandemPumpState(basalRateSchedule: schedule)
        state.maximumBolusUnits = 25
        // Inject a nil-returning central factory into the pump manager so its
        // INTERNAL bleManager builds no live CoreBluetooth manager — that
        // internal central, not the one below, is what triggers the eager
        // state-restoration authorization probe that SIGABRTs the xctest host.
        // The enact path under test substitutes the transport and never reaches
        // any central anyway.
        let pumpManager = TandemPumpManager(state: state, centralFactory: { _, _ in nil })
        pumpManager.tempRateCeilingPolicy = policy
        let bleManager = TandemBLEManager(pumpManager: pumpManager, centralFactory: { _, _ in nil })
        let queue = DispatchQueue(label: "test.TandemTempRateCeilingIntegration")

        let pm = TandemPeripheralManager(
            peripheral: RecordingPeripheral(),
            bleManager: bleManager,
            pumpManager: pumpManager,
            queue: queue
        )

        // Substitute the transport: a SetTempRateResponse (opCode 0xA5) always
        // confirms success, so the real enactTempBasal Task path and the H2
        // state write run end-to-end.
        pm.sendAndReceiveTransport = { request, _, opCode in
            recorder.record(opCode: opCode, request: request)
            let id = recorder.tempRateId
            let lo = UInt8(id & 0xFF), hi = UInt8((id >> 8) & 0xFF)
            switch opCode {
            case 0xA5: // SetTempRateResponse: success
                return Data([0x00, lo, hi])
            default:
                return Data([0x00])
            }
        }
        return (pm, pumpManager)
    }

    // MARK: - .reject policy

    // Over-ceiling under .reject: fail with .deviceState and send NO command.
    func testRejectPolicyOverCeilingFailsAndSendsNoCommand() {
        let recorder = TempTransportRecorder()
        // Retain the pump manager: TandemPeripheralManager holds it weakly, so a
        // discarded pump manager deallocates before enactTempBasal runs and the
        // schedule guard returns .configuration(nil) instead of exercising policy.
        let (pm, pumpManager) = makeManager(recorder: recorder, scheduledRate: 1.0, policy: .reject)

        let exp = expectation(description: "enactTempBasal completed")
        // 5.0 U/hr against a 1.0 U/hr schedule = 500%, over the 250% ceiling.
        pm.enactTempBasal(unitsPerHour: 5.0, duration: 1800, at: effectiveDate) { error in
            guard case .some(.deviceState) = error else {
                XCTFail("over-ceiling under .reject must fail with .deviceState, got \(String(describing: error))")
                exp.fulfill(); return
            }
            exp.fulfill()
        }
        waitForExpectations(timeout: 5)
        withExtendedLifetime(pumpManager) {}
        XCTAssertFalse(recorder.tempCommandWasSent,
                       "a rejected over-ceiling request must send no command to the pump")
        XCTAssertTrue(recorder.requestedResponseOpCodes.isEmpty,
                      "a rejected over-ceiling request must produce no pump traffic at all")
    }

    // Within-ceiling under .reject: behaves normally — command sent at the true
    // percent, success reported.
    func testRejectPolicyWithinCeilingSendsTruePercent() {
        let recorder = TempTransportRecorder()
        // Retain the pump manager (held weakly by the peripheral manager).
        let (pm, pumpManager) = makeManager(recorder: recorder, scheduledRate: 1.0, policy: .reject)

        let exp = expectation(description: "enactTempBasal completed")
        // 2.0 U/hr against 1.0 U/hr = 200%, within ceiling.
        pm.enactTempBasal(unitsPerHour: 2.0, duration: 1800, at: effectiveDate) { error in
            XCTAssertNil(error, "a within-ceiling request must succeed")
            exp.fulfill()
        }
        waitForExpectations(timeout: 5)
        withExtendedLifetime(pumpManager) {}
        XCTAssertTrue(recorder.tempCommandWasSent, "a within-ceiling request must send a command")
        XCTAssertEqual(recorder.sentTempPercents, [200],
                       "within-ceiling request must be sent at its true percent")
    }

    // MARK: - .reportEnactedRate policy

    // Over-ceiling under .reportEnactedRate: send the CLAMPED 250% command,
    // report success, and record the enacted percent into state so
    // basalDeliveryState reports the true enacted rate.
    func testReportPolicyOverCeilingSendsClampedAndRecordsEnactedRate() {
        let recorder = TempTransportRecorder()
        let (pm, pumpManager) = makeManager(recorder: recorder, scheduledRate: 1.0, policy: .reportEnactedRate)

        let exp = expectation(description: "enactTempBasal completed")
        // 5.0 U/hr against 1.0 U/hr = 500%, clamps to 250%.
        pm.enactTempBasal(unitsPerHour: 5.0, duration: 1800, at: effectiveDate) { error in
            XCTAssertNil(error, "over-ceiling under .reportEnactedRate must proceed and report success")
            exp.fulfill()
        }
        waitForExpectations(timeout: 5)
        XCTAssertTrue(recorder.tempCommandWasSent, "must send a command under .reportEnactedRate")
        XCTAssertEqual(recorder.sentTempPercents, [250],
                       "over-ceiling command must be clamped to the 250% ceiling on the wire")

        // State must reflect the actually-enacted 250%, not the requested 500%,
        // and basalDeliveryState must report 250% * 1.0 = 2.5 U/hr.
        XCTAssertEqual(pumpManager.state.activeTempRatePercent, 250,
                       "enacted percent recorded in state must be the clamped ceiling")
        XCTAssertEqual(pumpManager.state.basalState, .tempBasal,
                       "state must mark a temp basal active after a clamped enactment")
        guard case .tempBasal(let dose) = pumpManager.state.basalDeliveryState else {
            return XCTFail("basalDeliveryState must report an active temp basal")
        }
        XCTAssertEqual(dose.unitsPerHour, 2.5, accuracy: 1e-9,
                       "reported rate must be the true enacted rate (250% of 1.0 U/hr), not the requested 5.0")
    }

    // Within-ceiling under .reportEnactedRate: true percent on the wire, and no
    // enacted-rate state write (the normal status poll owns reporting here).
    func testReportPolicyWithinCeilingSendsTruePercentNoStateWrite() {
        let recorder = TempTransportRecorder()
        let (pm, pumpManager) = makeManager(recorder: recorder, scheduledRate: 1.0, policy: .reportEnactedRate)

        let exp = expectation(description: "enactTempBasal completed")
        pm.enactTempBasal(unitsPerHour: 2.0, duration: 1800, at: effectiveDate) { error in
            XCTAssertNil(error, "a within-ceiling request must succeed")
            exp.fulfill()
        }
        waitForExpectations(timeout: 5)
        XCTAssertEqual(recorder.sentTempPercents, [200],
                       "within-ceiling request must be sent at its true percent")
        XCTAssertNil(pumpManager.state.activeTempRatePercent,
                     "within-ceiling enactment must not write the enacted-rate override; the status poll reports it")
    }
}