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
        return TandemPumpManager(state: state)
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
