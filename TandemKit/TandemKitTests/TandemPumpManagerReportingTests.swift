import XCTest
import Foundation
import HealthKit
import LoopKit
@testable import TandemKit

// TandemPumpManagerReportingTests
// -------------------------------
// Verifies the TK-C1 wiring: TandemPumpManager forwards a completed bolus into
// LoopKit's PumpManagerDelegate and only advances the durable
// `state.lastReportedBolusId` watermark AFTER the delegate confirms the report.
//
// This is the integration seam the reporter alone cannot cover: the
// `replacePendingEvents: false` flag and the confirm-before-persist semantics
// live in TandemPumpManager, not TandemDoseReporter. A mock PumpManagerDelegate
// captures exactly what Loop would receive.
//
// Style mirrors TandemDoseReporterTests (pumpX2 device-captured cargos) and the
// CapturingDelegate pattern, lifted up to the full PumpManagerDelegate.

final class TandemPumpManagerReportingTests: XCTestCase {

    private func bytes(_ vals: [Int]) -> Data {
        Data(vals.map { UInt8(bitPattern: Int8($0)) })
    }

    // pumpX2 completed capture: delivered == requested == 6670 mU, bolusId 3240.
    private func completedResponse() -> LastBolusStatusV2Response {
        LastBolusStatusV2Response(
            cargo: bytes([1, -88, 12, 0, 0, -76, 83, 85, 27, 14, 26, 0, 0, 3, 1, 1, 0, 0, 0, 0, 14, 26, 0, 0])
        )!
    }

    private func makeManager(insulinType: InsulinType? = .novolog) -> TandemPumpManager {
        let state = TandemPumpState(basalRateSchedule: nil)
        state.insulinType = insulinType
        // nil central factory: offline construction with no live CoreBluetooth
        // manager, so no TCC authorization probe can SIGABRT the xctest host.
        return TandemPumpManager(state: state, centralFactory: { _, _ in nil })
    }

    // (a) completed-bolus status produces the correct NewPumpEvent payload, and
    // (b) delegate is invoked with the pump-confirmed reconciliation time and
    //     replacePendingEvents: false.
    func testReportsCorrectEventAndReconciliationToDelegate() throws {
        let manager = makeManager()
        let delegate = MockPumpManagerDelegate()
        manager.pumpManagerDelegate = delegate

        let last = completedResponse()
        let exp = expectation(description: "reported")
        manager.reportCompletedBolus(from: last) { exp.fulfill() }
        wait(for: [exp], timeout: 2.0)

        XCTAssertTrue(delegate.hasNewPumpEventsCalled, "delegate must receive the completed bolus")
        XCTAssertEqual(delegate.capturedReplacePendingEvents, false,
                       "incremental single events must use replacePendingEvents: false")
        XCTAssertEqual(delegate.capturedReconciliation, last.timestamp,
                       "lastReconciliation must be the pump-confirmed delivery time, not phone poll time")

        XCTAssertEqual(delegate.capturedEvents.count, 1)
        let event = try XCTUnwrap(delegate.capturedEvents.first)
        let dose = try XCTUnwrap(event.dose)
        XCTAssertEqual(dose.type, .bolus)
        XCTAssertEqual(dose.deliveredUnits ?? -1, 6.670, accuracy: 0.0001,
                       "Loop must learn DELIVERED units")
        XCTAssertEqual(dose.programmedUnits, 6.670, accuracy: 0.0001)
        XCTAssertFalse(dose.isMutable, "a completed bolus must be immutable")
        XCTAssertEqual(String(data: event.raw, encoding: .utf8), "tandem-bolus-3240",
                       "deterministic syncIdentifier so Loop dedupes across reconnects")
    }

    // (c) state.lastReportedBolusId advances ONLY after a successful delegate completion.
    func testWatermarkAdvancesAfterSuccessfulCompletion() {
        let manager = makeManager()
        let delegate = MockPumpManagerDelegate()
        delegate.completionError = nil   // success
        manager.pumpManagerDelegate = delegate

        XCTAssertEqual(manager.state.lastReportedBolusId, 0, "precondition: nothing reported yet")

        let exp = expectation(description: "persisted")
        var persistedId: UInt16 = .max
        manager.reportCompletedBolus(from: completedResponse()) {
            persistedId = manager.state.lastReportedBolusId
            exp.fulfill()
        }
        wait(for: [exp], timeout: 2.0)

        XCTAssertEqual(persistedId, 3240,
                       "watermark must advance to the reported bolusId on success")
    }

    // (d) on a FAILING delegate completion, the watermark does NOT advance, so the
    //     bolus is re-reported next cycle (re-report-on-failure is intended).
    func testWatermarkDoesNotAdvanceOnFailedCompletion() {
        let manager = makeManager()
        let delegate = MockPumpManagerDelegate()
        delegate.completionError = MockError.storeFailed   // failure
        manager.pumpManagerDelegate = delegate

        let exp = expectation(description: "attempted")
        var persistedId: UInt16 = .max
        manager.reportCompletedBolus(from: completedResponse()) {
            persistedId = manager.state.lastReportedBolusId
            exp.fulfill()
        }
        wait(for: [exp], timeout: 2.0)

        XCTAssertTrue(delegate.hasNewPumpEventsCalled, "the report attempt must still reach the delegate")
        XCTAssertEqual(persistedId, 0,
                       "watermark must NOT advance when the delegate fails — the bolus is retried next poll")
    }

    // (i) SAME-SESSION failure-then-retry — the load-bearing dosing-safety path.
    //     A failed report must NOT advance the watermark; the SAME bolus reported
    //     again on the SAME manager must be RE-EMITTED and the watermark must
    //     advance ONLY after the successful retry.
    func testSameSessionFailureThenRetryReEmitsAndAdvancesOnlyOnSuccess() throws {
        let manager = makeManager()
        let delegate = MockPumpManagerDelegate()
        manager.pumpManagerDelegate = delegate

        let last = completedResponse()

        // Attempt 1: delegate FAILS.
        delegate.completionError = MockError.storeFailed
        let exp1 = expectation(description: "failed attempt")
        var idAfterFailure: UInt16 = .max
        manager.reportCompletedBolus(from: last) {
            idAfterFailure = manager.state.lastReportedBolusId
            exp1.fulfill()
        }
        wait(for: [exp1], timeout: 2.0)

        XCTAssertEqual(delegate.hasNewPumpEventsCallCount, 1, "first attempt must reach the delegate")
        XCTAssertEqual(delegate.capturedEvents.count, 1, "first attempt must emit the bolus")
        XCTAssertEqual(idAfterFailure, 0, "a failed report must NOT advance the watermark")

        // Attempt 2 (same manager, same bolus): delegate SUCCEEDS.
        delegate.completionError = nil
        let exp2 = expectation(description: "successful retry")
        var idAfterRetry: UInt16 = .max
        manager.reportCompletedBolus(from: last) {
            idAfterRetry = manager.state.lastReportedBolusId
            exp2.fulfill()
        }
        wait(for: [exp2], timeout: 2.0)

        XCTAssertEqual(delegate.hasNewPumpEventsCallCount, 2,
                       "the SAME bolus must be RE-EMITTED on retry because the watermark never advanced")
        let retryEvent = try XCTUnwrap(delegate.capturedEvents.first)
        XCTAssertEqual(String(data: retryEvent.raw, encoding: .utf8), "tandem-bolus-3240",
                       "retry must re-emit the same bolus")
        XCTAssertEqual(idAfterRetry, 3240,
                       "watermark must advance ONLY after the successful retry")
    }

    // (ii) ID-MATCH invariant: the watermark persisted after a successful report must
    //      equal the bolusId of the bolus that was actually EMITTED in the
    //      NewPumpEvent — not merely "some advanced number".
    func testPersistedWatermarkEqualsEmittedEventBolusId() throws {
        let manager = makeManager()
        let delegate = MockPumpManagerDelegate()
        delegate.completionError = nil   // success
        manager.pumpManagerDelegate = delegate

        let exp = expectation(description: "persisted")
        var persistedId: UInt16 = .max
        manager.reportCompletedBolus(from: completedResponse()) {
            persistedId = manager.state.lastReportedBolusId
            exp.fulfill()
        }
        wait(for: [exp], timeout: 2.0)

        let event = try XCTUnwrap(delegate.capturedEvents.first)
        let emittedBolusId = try XCTUnwrap(Self.bolusId(from: event),
                                           "emitted event must carry a tandem-bolus-<id> syncIdentifier")
        XCTAssertEqual(persistedId, emittedBolusId,
                       "the persisted watermark must correspond to the EMITTED bolus, not an arbitrary advance")
    }

    // Extract the bolusId encoded in the reporter's deterministic syncIdentifier
    // ("tandem-bolus-<id>"), so the test pins the watermark to the emitted event
    // rather than to a hard-coded constant.
    private static func bolusId(from event: NewPumpEvent) -> UInt16? {
        guard let raw = String(data: event.raw, encoding: .utf8),
              let idText = raw.split(separator: "-").last else { return nil }
        return UInt16(idText)
    }

    enum MockError: Error { case storeFailed }

    // MARK: - WP2 helpers (temp-basal reporting + command-confirmation predicate)

    private func makeManager(scheduledRate: Double) -> (TandemPumpManager, MockPumpManagerDelegate) {
        let schedule = BasalRateSchedule(dailyItems: [RepeatingScheduleValue(startTime: 0, value: scheduledRate)])!
        let state = TandemPumpState(basalRateSchedule: schedule)
        state.insulinType = .novolog
        let manager = TandemPumpManager(state: state, centralFactory: { _, _ in nil })
        let delegate = MockPumpManagerDelegate()
        manager.pumpManagerDelegate = delegate
        return (manager, delegate)
    }

    // Build a TempRateStatusResponse cargo (16 bytes, little-endian).
    private func tempRateCargo(isActive: Bool,
                               tempRateId: UInt16,
                               percentage: UInt8,
                               startPumpSeconds: UInt32,
                               durationSeconds: UInt32) -> Data {
        var d = Data(count: 16)
        d[0] = isActive ? 1 : 0
        d[1] = UInt8(tempRateId & 0xFF)
        d[2] = UInt8((tempRateId >> 8) & 0xFF)
        d[3] = percentage
        d[4] = UInt8(startPumpSeconds & 0xFF)
        d[5] = UInt8((startPumpSeconds >> 8) & 0xFF)
        d[6] = UInt8((startPumpSeconds >> 16) & 0xFF)
        d[7] = UInt8((startPumpSeconds >> 24) & 0xFF)
        d[12] = UInt8(durationSeconds & 0xFF)
        d[13] = UInt8((durationSeconds >> 8) & 0xFF)
        d[14] = UInt8((durationSeconds >> 16) & 0xFF)
        d[15] = UInt8((durationSeconds >> 24) & 0xFF)
        return d
    }

    // MARK: - reportActiveTempBasal: active temp basal emits a converted DoseEntry

    func testReportActiveTempBasalEmitsConvertedRate() throws {
        // Scheduled 1.0 U/hr, pump running 150% -> 1.5 U/hr absolute.
        let (manager, delegate) = makeManager(scheduledRate: 1.0)
        let startSeconds: UInt32 = 500_000_000
        let expectedStart = TandemEpoch.date(fromPumpSeconds: startSeconds)
        let response = TempRateStatusResponse(cargo: tempRateCargo(
            isActive: true, tempRateId: 42, percentage: 150,
            startPumpSeconds: startSeconds, durationSeconds: 3600))!

        let exp = expectation(description: "delegate received events")
        delegate.onHasNewPumpEvents = { exp.fulfill() }
        manager.reportActiveTempBasal(from: response)
        wait(for: [exp], timeout: 2.0)

        XCTAssertEqual(delegate.hasNewPumpEventsCallCount, 1)
        XCTAssertEqual(delegate.capturedEvents.count, 1)
        let event = try XCTUnwrap(delegate.capturedEvents.first)
        let dose = try XCTUnwrap(event.dose)

        XCTAssertEqual(dose.type, .tempBasal)
        XCTAssertEqual(dose.unit, .unitsPerHour)
        XCTAssertEqual(dose.unitsPerHour, 1.5, accuracy: 0.0001,
                       "150% of a 1.0 U/hr scheduled basal must report as 1.5 U/hr absolute")
        XCTAssertTrue(dose.isMutable, "a running temp basal must be mutable so it can be replaced each cycle")
        XCTAssertEqual(dose.startDate, expectedStart, "startDate must be the pump-confirmed start")
        XCTAssertEqual(dose.endDate, expectedStart.addingTimeInterval(3600))
    }

    func testReportActiveTempBasalUsesReplacePendingAndPumpConfirmedReconciliation() throws {
        let (manager, delegate) = makeManager(scheduledRate: 0.5)
        let startSeconds: UInt32 = 450_000_000
        let expectedStart = TandemEpoch.date(fromPumpSeconds: startSeconds)
        let response = TempRateStatusResponse(cargo: tempRateCargo(
            isActive: true, tempRateId: 7, percentage: 80,
            startPumpSeconds: startSeconds, durationSeconds: 1800))!

        let exp = expectation(description: "delegate received events")
        delegate.onHasNewPumpEvents = { exp.fulfill() }
        manager.reportActiveTempBasal(from: response)
        wait(for: [exp], timeout: 2.0)

        XCTAssertEqual(delegate.capturedReplacePendingEvents, true,
                       "temp basal must use replacePendingEvents:true so Loop replaces the prior pending copy")
        XCTAssertEqual(delegate.capturedReconciliation, expectedStart,
                       "lastReconciliation must be the pump-confirmed start, not phone time")

        let dose = try XCTUnwrap(delegate.capturedEvents.first?.dose)
        // 80% of 0.5 U/hr -> 0.4 U/hr.
        XCTAssertEqual(dose.unitsPerHour, 0.4, accuracy: 0.0001)
    }

    func testReportActiveTempBasalStableRawIdentity() throws {
        let (manager, delegate) = makeManager(scheduledRate: 1.0)
        let startSeconds: UInt32 = 500_000_000
        let response = TempRateStatusResponse(cargo: tempRateCargo(
            isActive: true, tempRateId: 99, percentage: 100,
            startPumpSeconds: startSeconds, durationSeconds: 3600))!

        let exp = expectation(description: "delegate received events")
        delegate.onHasNewPumpEvents = { exp.fulfill() }
        manager.reportActiveTempBasal(from: response)
        wait(for: [exp], timeout: 2.0)

        let raw = try XCTUnwrap(delegate.capturedEvents.first?.raw)
        let unixStart = Int(TandemEpoch.date(fromPumpSeconds: startSeconds).timeIntervalSince1970)
        XCTAssertEqual(String(data: raw, encoding: .utf8), "tandem-temp-99-\(unixStart)",
                       "raw identity must be stable from tempRateId + pump-confirmed start so re-emits dedupe")
    }

    // MARK: - reportActiveTempBasal: inactive temp basal emits nothing

    func testReportActiveTempBasalInactiveEmitsNothing() {
        let (manager, delegate) = makeManager(scheduledRate: 1.0)
        let response = TempRateStatusResponse(cargo: tempRateCargo(
            isActive: false, tempRateId: 0, percentage: 0,
            startPumpSeconds: 0, durationSeconds: 0))!

        // reportActiveTempBasal returns synchronously on the !isActive guard and
        // never touches delegateQueue, so there is no async dispatch to wait for.
        // Asserting on the call count immediately is both correct and robust; an
        // inverted expectation here is fragile and verifies nothing the count does
        // not. If the inactive guard ever regresses into the async path, the failure
        // below (a non-zero count from the queued event) still catches it: we drain
        // the delegate queue first so any erroneously-queued call has run.
        delegate.onHasNewPumpEvents = {
            XCTFail("an inactive temp rate must not dispatch a pump event")
        }
        manager.reportActiveTempBasal(from: response)

        // Drain the manager's delegate queue: if the inactive path erroneously
        // enqueued a call, this sync barrier guarantees it has executed before we
        // assert, converting a latent async regression into a deterministic failure.
        manager.delegateQueue.sync {}

        XCTAssertEqual(delegate.hasNewPumpEventsCallCount, 0,
                       "an inactive temp rate must not produce any pump event")
    }

    // MARK: - Command-confirmation predicate (the gate cancelBolus/enactTempBasal branch on)

    func testCancelBolusResponseSuccessAndNackPredicate() {
        // status == 0 -> success -> cancelBolus returns .success(nil).
        let ok = CancelBolusResponse(cargo: Data([0, 0, 0]))
        XCTAssertEqual(ok?.success, true)
        // status != 0 -> NACK -> cancelBolus returns .failure(.communication).
        let nack = CancelBolusResponse(cargo: Data([3, 0, 0]))
        XCTAssertEqual(nack?.success, false)
        // empty cargo -> unparseable -> treated as failure (nil response).
        XCTAssertNil(CancelBolusResponse(cargo: Data()))
    }

    func testSetTempRateResponseSuccessAndNackPredicate() {
        // status == 0 -> success -> enactTempBasal completes with nil error.
        let ok = SetTempRateResponse(cargo: Data([0, 5, 0]))
        XCTAssertEqual(ok?.success, true)
        // status != 0 -> NACK -> enactTempBasal completes with .communication error.
        let nack = SetTempRateResponse(cargo: Data([1, 5, 0]))
        XCTAssertEqual(nack?.success, false)
        // short cargo -> unparseable -> nil response -> failure path.
        XCTAssertNil(SetTempRateResponse(cargo: Data([0])))
    }
}

// MARK: - Mock PumpManagerDelegate

private final class MockPumpManagerDelegate: PumpManagerDelegate {

    // Capture of the one call under test.
    var hasNewPumpEventsCalled = false
    var hasNewPumpEventsCallCount = 0
    var capturedEvents: [NewPumpEvent] = []
    var capturedReconciliation: Date?
    var capturedReplacePendingEvents: Bool?
    var completionError: Error?
    // WP2: lets a test await the single hasNewPumpEvents dispatch made by
    // reportActiveTempBasal. Stays nil for the WP1 bolus tests (no-op).
    var onHasNewPumpEvents: (() -> Void)?

    func pumpManager(_ pumpManager: PumpManager,
                     hasNewPumpEvents events: [NewPumpEvent],
                     lastReconciliation: Date?,
                     replacePendingEvents: Bool,
                     completion: @escaping (_ error: Error?) -> Void) {
        hasNewPumpEventsCalled = true
        hasNewPumpEventsCallCount += 1
        capturedEvents = events
        capturedReconciliation = lastReconciliation
        capturedReplacePendingEvents = replacePendingEvents
        completion(completionError)
        onHasNewPumpEvents?()
    }

    // MARK: Unused PumpManagerDelegate requirements

    func pumpManagerBLEHeartbeatDidFire(_ pumpManager: PumpManager) {}
    func pumpManagerMustProvideBLEHeartbeat(_ pumpManager: PumpManager) -> Bool { false }
    func pumpManagerWillDeactivate(_ pumpManager: PumpManager) {}
    func pumpManagerPumpWasReplaced(_ pumpManager: PumpManager) {}
    func pumpManager(_ pumpManager: PumpManager, didUpdatePumpRecordsBasalProfileStartEvents pumpRecordsBasalProfileStartEvents: Bool) {}
    func pumpManager(_ pumpManager: PumpManager, didError error: PumpManagerError) {}
    func pumpManager(_ pumpManager: PumpManager,
                     didReadReservoirValue units: Double,
                     at date: Date,
                     completion: @escaping (_ result: Result<(newValue: ReservoirValue, lastValue: ReservoirValue?, areStoredValuesContinuous: Bool), Error>) -> Void) {}
    func pumpManager(_ pumpManager: PumpManager, didAdjustPumpClockBy adjustment: TimeInterval) {}
    func pumpManagerDidUpdateState(_ pumpManager: PumpManager) {}
    func pumpManager(_ pumpManager: PumpManager,
                     didRequestBasalRateScheduleChange basalRateSchedule: BasalRateSchedule,
                     completion: @escaping (Error?) -> Void) {}
    func startDateToFilterNewPumpEvents(for manager: PumpManager) -> Date { .distantPast }
    var detectedSystemTimeOffset: TimeInterval { 0 }
    var automaticDosingEnabled: Bool { true }

    // MARK: PumpManagerStatusObserver
    func pumpManager(_ pumpManager: PumpManager, didUpdate status: PumpManagerStatus, oldStatus: PumpManagerStatus) {}

    // MARK: DeviceManagerDelegate
    func deviceManager(_ manager: DeviceManager,
                       logEventForDeviceIdentifier deviceIdentifier: String?,
                       type: DeviceLogEntryType,
                       message: String,
                       completion: ((Error?) -> Void)?) {}

    // MARK: AlertIssuer
    func issueAlert(_ alert: Alert) {}
    func retractAlert(identifier: Alert.Identifier) {}

    // MARK: PersistedAlertStore
    func doesIssuedAlertExist(identifier: Alert.Identifier, completion: @escaping (Swift.Result<Bool, Error>) -> Void) {}
    func lookupAllUnretracted(managerIdentifier: String, completion: @escaping (Swift.Result<[PersistedAlert], Error>) -> Void) {}
    func lookupAllUnacknowledgedUnretracted(managerIdentifier: String, completion: @escaping (Swift.Result<[PersistedAlert], Error>) -> Void) {}
    func recordRetractedAlert(_ alert: Alert, at date: Date) {}
}
