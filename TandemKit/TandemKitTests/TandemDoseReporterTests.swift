import XCTest
import Foundation
import LoopKit
@testable import TandemKit

// TandemDoseReporterTests
// -----------------------
// Verifies the LoopKit-facing reconciliation logic. The single most important
// safety property of the whole integration lives here: Loop must learn how much
// insulin was DELIVERED, never how much was requested. If these tests pass, Loop's
// IOB model tracks reality; if they regress, the integration can stack insulin.
//
// The reporter is pure logic (it builds NewPumpEvent/DoseEntry and dedupes by
// bolusId). It does not touch BLE, so it tests cleanly with no hardware.
//
// Response fixtures reuse the same pumpX2 device-captured cargos validated in
// TandemMessageVectorTests, so the dose math is exercised against real packets.

final class TandemDoseReporterTests: XCTestCase {

    private func bytes(_ vals: [Int]) -> Data {
        Data(vals.map { UInt8(bitPattern: Int8($0)) })
    }

    // pumpX2 partial-stop capture: delivered 1975 mU of requested 2500 mU, bolusId 3245.
    private func partialStopResponse() -> LastBolusStatusV2Response {
        LastBolusStatusV2Response(
            cargo: bytes([1, -83, 12, 0, 0, -118, -103, 85, 27, -73, 7, 0, 0, 0, 1, 8, 0, 0, 0, 0, -60, 9, 0, 0])
        )!
    }

    // pumpX2 completed capture: delivered == requested == 6670 mU, bolusId 3240.
    private func completedResponse() -> LastBolusStatusV2Response {
        LastBolusStatusV2Response(
            cargo: bytes([1, -88, 12, 0, 0, -76, 83, 85, 27, 14, 26, 0, 0, 3, 1, 1, 0, 0, 0, 0, 14, 26, 0, 0])
        )!
    }

    // MARK: - THE safety-critical assertion: report delivered, not requested

    func testBolusEventReportsDeliveredNotRequested_onPartialStop() throws {
        let reporter = TandemDoseReporter()
        let event = try XCTUnwrap(
            reporter.makeBolusEvent(from: partialStopResponse(), insulinType: .novolog)
        )
        let dose = try XCTUnwrap(event.dose)

        // programmedUnits (public view of `value` for a .units bolus) carries the
        // DELIVERED amount (1.975 U), not the 2.5 U requested.
        XCTAssertEqual(dose.programmedUnits, 1.975, accuracy: 0.0001,
                       "DoseEntry value must be DELIVERED units, never requested")
        XCTAssertEqual(dose.deliveredUnits ?? -1, 1.975, accuracy: 0.0001,
                       "deliveredUnits must be the actual amount given")
        // LoopKit derives IOB from deliveredUnits ?? programmedUnits — confirm the
        // number Loop will actually consume is the delivered one.
        XCTAssertEqual(dose.netBasalUnits, 1.975, accuracy: 0.0001,
                       "Loop's IOB input (netBasalUnits) must equal delivered, not requested")
        XCTAssertEqual(dose.type, .bolus)
        XCTAssertFalse(dose.isMutable, "a completed/stopped bolus must be immutable")
    }

    func testBolusEventReportsFullDelivery_onCompleted() throws {
        let reporter = TandemDoseReporter()
        let event = try XCTUnwrap(
            reporter.makeBolusEvent(from: completedResponse(), insulinType: .novolog)
        )
        let dose = try XCTUnwrap(event.dose)
        XCTAssertEqual(dose.programmedUnits, 6.670, accuracy: 0.0001)
        XCTAssertEqual(dose.deliveredUnits ?? -1, 6.670, accuracy: 0.0001)
        XCTAssertEqual(dose.netBasalUnits, 6.670, accuracy: 0.0001)
    }

    // MARK: - Dedupe: never double-count a bolus across status polls

    func testDedupeSameBolusIdReportedOnce() throws {
        let reporter = TandemDoseReporter()
        let resp = completedResponse()

        let first = reporter.makeBolusEvent(from: resp, insulinType: .novolog)
        XCTAssertNotNil(first, "first sighting of a bolusId must produce an event")

        let second = reporter.makeBolusEvent(from: resp, insulinType: .novolog)
        XCTAssertNil(second, "the same bolusId must not be re-emitted on the next poll")
    }

    func testNewBolusIdAfterDedupeStillReports() throws {
        let reporter = TandemDoseReporter()
        _ = reporter.makeBolusEvent(from: completedResponse(), insulinType: .novolog) // id 3240
        let next = reporter.makeBolusEvent(from: partialStopResponse(), insulinType: .novolog) // id 3245
        XCTAssertNotNil(next, "a different, higher bolusId must still be reported after a dedupe")
    }

    func testReporterSeededWithLastReportedIdSkipsThatBolus() throws {
        // Simulate restart: persisted lastReportedBolusId == 3240 (the completed one).
        let reporter = TandemDoseReporter(lastReportedBolusId: 3240)
        XCTAssertNil(reporter.makeBolusEvent(from: completedResponse(), insulinType: .novolog),
                     "a bolus already reported before a restart must not be re-emitted")
    }

    func testZeroBolusIdIsNotReported() throws {
        // bolusId 0 is the pump's "no bolus" sentinel (empty LastBolusStatus).
        let reporter = TandemDoseReporter()
        let empty = LastBolusStatusV2Response(cargo: Data(count: 24))!
        XCTAssertNil(reporter.makeBolusEvent(from: empty, insulinType: .novolog),
                     "bolusId 0 (no bolus) must never become an event")
    }

    // MARK: - Sync identifier stability (dedupe across reconnects in Loop's store)

    func testBolusSyncIdentifierIsDeterministicPerBolusId() throws {
        let reporter = TandemDoseReporter()
        let e1 = try XCTUnwrap(reporter.makeBolusEvent(from: completedResponse(), insulinType: nil))
        // Rebuild from a fresh reporter to get the same id again.
        let e2 = try XCTUnwrap(TandemDoseReporter().makeBolusEvent(from: completedResponse(), insulinType: nil))
        XCTAssertEqual(e1.raw, e2.raw,
                       "the same bolusId must map to the same syncIdentifier so Loop dedupes across reconnects")
        XCTAssertEqual(String(data: e1.raw, encoding: .utf8), "tandem-bolus-3240")
    }

    func testProgressPersistenceValueAdvances() throws {
        let reporter = TandemDoseReporter()
        XCTAssertEqual(reporter.reportedBolusIdForPersistence, 0)
        _ = reporter.makeBolusEvent(from: completedResponse(), insulinType: nil)
        XCTAssertEqual(reporter.reportedBolusIdForPersistence, 3240,
                       "the persisted high-water mark must advance so it survives a restart")
    }

    // MARK: - In-progress bolus (mutable, shows live delivery)

    func testInProgressBolusIsMutableAndCarriesDeliveredSoFar() throws {
        let reporter = TandemDoseReporter()
        let start = Date()
        let event = reporter.makeInProgressBolusEvent(
            bolusId: 4000, requestedUnits: 2.0, deliveredSoFar: 0.4,
            startDate: start, insulinType: .novolog
        )
        let dose = try XCTUnwrap(event.dose)
        XCTAssertTrue(dose.isMutable, "in-progress bolus must be mutable until finalized")
        XCTAssertEqual(dose.deliveredUnits ?? -1, 0.4, accuracy: 0.0001)
        XCTAssertEqual(dose.programmedUnits, 2.0, accuracy: 0.0001,
                       "programmed (requested) volume drives the projected end of delivery")
    }

    // MARK: - Temp basal: report ABSOLUTE rate in U/hr

    func testTempBasalReportsAbsoluteRateInUnitsPerHour() throws {
        let reporter = TandemDoseReporter()
        let start = Date()
        let event = reporter.makeTempBasalEvent(
            unitsPerHour: 0.75, startDate: start, duration: 1800, // 30 min
            tempRateId: 42, insulinType: .novolog, isMutable: true
        )
        let dose = try XCTUnwrap(event.dose)
        XCTAssertEqual(dose.type, .tempBasal)
        XCTAssertEqual(dose.unit, .unitsPerHour)
        XCTAssertEqual(dose.unitsPerHour, 0.75, accuracy: 0.0001,
                       "temp basal must report the absolute U/hr the pump is running, not a percentage")
        // Over 30 min at 0.75 U/hr, programmedUnits should be 0.375 U.
        XCTAssertEqual(dose.programmedUnits, 0.375, accuracy: 0.0001)
        XCTAssertTrue(dose.isMutable)
    }

    func testZeroTempBasalIsAValidSuspendLikeRate() throws {
        let reporter = TandemDoseReporter()
        let event = reporter.makeTempBasalEvent(
            unitsPerHour: 0.0, startDate: Date(), duration: 900,
            tempRateId: 7, insulinType: nil, isMutable: false
        )
        let dose = try XCTUnwrap(event.dose)
        XCTAssertEqual(dose.unitsPerHour, 0.0, accuracy: 0.0001)
        XCTAssertEqual(dose.programmedUnits, 0.0, accuracy: 0.0001)
    }

    // MARK: - Suspend / resume

    func testSuspendAndResumeEvents() throws {
        let reporter = TandemDoseReporter()
        let t = Date()
        let suspend = try XCTUnwrap(reporter.makeSuspendEvent(at: t).dose)
        XCTAssertEqual(suspend.type, .suspend)
        let resume = try XCTUnwrap(reporter.makeResumeEvent(at: t.addingTimeInterval(300)).dose)
        XCTAssertEqual(resume.type, .resume)
    }

    // MARK: - Delivery plumbing

    func testReportNoOpsOnEmptyEvents() {
        let reporter = TandemDoseReporter()
        let exp = expectation(description: "completes")
        reporter.report(events: [], lastReconciliation: nil) { error in
            XCTAssertNil(error)
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1.0)
    }

    func testReportForwardsToDelegateWithReconciliationTime() throws {
        final class CapturingDelegate: TandemDoseReporterDelegate {
            var events: [NewPumpEvent] = []
            var reconciliation: Date?
            var didReport = false
            func tandemDoseReporter(_ reporter: TandemDoseReporter,
                                    hasNewPumpEvents events: [NewPumpEvent],
                                    lastReconciliation: Date?,
                                    completion: @escaping (Error?) -> Void) {
                self.events = events
                self.reconciliation = lastReconciliation
                self.didReport = true
                completion(nil)
            }
        }
        let reporter = TandemDoseReporter()
        let delegate = CapturingDelegate()
        reporter.delegate = delegate

        let recon = Date()
        let event = try XCTUnwrap(reporter.makeBolusEvent(from: completedResponse(), insulinType: nil))
        let exp = expectation(description: "forwarded")
        reporter.report(events: [event], lastReconciliation: recon) { _ in exp.fulfill() }
        wait(for: [exp], timeout: 1.0)

        XCTAssertTrue(delegate.didReport)
        XCTAssertEqual(delegate.events.count, 1)
        XCTAssertEqual(delegate.reconciliation, recon,
                       "reconciliation time must pass through unchanged")
    }
}
