import XCTest
import LoopKit
@testable import TandemKit

// WP6 / M3 (in-progress dose event) + M6 (live dose-progress reporter).
//
// Two facts, both verified in the driver, govern this design and these tests:
//   1. CurrentBolusStatusResponse (opcode 0x2D) has NO delivered-so-far field.
//      Live delivered-so-far is therefore a TIME ESTIMATE off the nominal
//      1.5 U/min rate, anchored on state.activeBolusStartDate, and later
//      superseded by the pump-confirmed completed reconcile.
//   2. The durable TandemBolusState enum collapses the wire .delivering and
//      .requesting cases into a single .inProgress, so the estimate cannot read
//      "delivering vs requesting" from state. The poll passes the live wire
//      status in as `delivering:`; during requesting it is false and the
//      estimate is zero.
//
// These tests exercise the real integrated path (reportInProgressBolus ->
// estimate on stateQueue -> reporter.update on the reporter's own queue ->
// observer notification) plus the pure event builder, on the offline test
// initializer (InMemorySecretStore, nil central factory). No BLE, no Keychain.
final class TandemInProgressBolusTests: XCTestCase {

    // Nominal Tandem delivery rate the estimate uses: 1.5 U/min.
    private let unitsPerSecond = 1.5 / 60.0

    // The reporter notifies on the dispatchQueue handed to
    // createBolusProgressReporter. Records every progress value delivered and
    // fulfills one expectation per delivery so tests await without sleeping.
    private final class FakeProgressObserver: DoseProgressObserver {
        private(set) var updates: [DoseProgress] = []
        var onUpdate: ((DoseProgress) -> Void)?
        func doseProgressReporterDidUpdate(_ reporter: DoseProgressReporter) {
            let p = reporter.progress
            updates.append(p)
            onUpdate?(p)
        }
    }

    private let reporterQueue = DispatchQueue(label: "test.doseProgress")

    private func makeManager() -> TandemPumpManager {
        let state = TandemPumpState(basalRateSchedule: nil)
        state.basalState = .active
        return TandemPumpManager(state: state, secretStore: InMemorySecretStore())
    }

    // Arrange an active bolus in durable state with a known anchor. bolusState is
    // set to .inProgress to mirror the poll, but the estimate's delivering/zero
    // decision rides on the `delivering:` argument, not on bolusState.
    private func armActiveBolus(_ pm: TandemPumpManager,
                                requested: Double,
                                startedSecondsAgo: TimeInterval,
                                bolusId: UInt16 = 7) {
        pm.updateState {
            $0.bolusState = .inProgress
            $0.activeBolusId = bolusId
            $0.activeBolusUnits = requested
            $0.activeBolusStartDate = Date().addingTimeInterval(-startedSecondsAgo)
        }
    }

    // MARK: - M6: estimate feeds the reporter, observer notified on its queue

    // 1a. While delivering, with elapsed below full delivery, the reporter
    //     receives deliveredSoFar ~= elapsed * 1.5/60 and the matching percent.
    //     The observer is notified on the reporter's queue.
    func testDeliveringPushesTimeEstimateToReporter() throws {
        let pm = makeManager()
        let reporter = try XCTUnwrap(pm.createBolusProgressReporter(reportingOn: reporterQueue)
                                        as? TandemDoseProgressReporter)
        let observer = FakeProgressObserver()
        let exp = expectation(description: "progress update")
        observer.onUpdate = { _ in exp.fulfill() }
        reporter.addObserver(observer)

        let requested = 5.0
        let elapsed: TimeInterval = 30        // 30s * 1.5/60 = 0.75 U, < 5 U requested
        armActiveBolus(pm, requested: requested, startedSecondsAgo: elapsed)

        pm.reportInProgressBolus(delivering: true)

        wait(for: [exp], timeout: 2.0)
        reporterQueue.sync {}
        let p = try XCTUnwrap(observer.updates.last)
        let expected = elapsed * unitsPerSecond
        // Tolerance absorbs the sub-second gap between arming and the internal
        // Date() read; well under the headroom to the 5 U clamp.
        XCTAssertEqual(p.deliveredUnits, expected, accuracy: 0.05)
        XCTAssertEqual(p.percentComplete, expected / requested, accuracy: 0.01)
        XCTAssertFalse(p.deliveredUnits >= requested, "must not be clamped this early")
        // progress property reflects the same value.
        XCTAssertEqual(reporter.progress.deliveredUnits, p.deliveredUnits, accuracy: 1e-9)
    }

    // 1b. With elapsed far beyond requested/rate, deliveredSoFar clamps EXACTLY
    //     to requested and percentComplete is 1.0.
    func testDeliveringClampsToRequested() throws {
        let pm = makeManager()
        let reporter = try XCTUnwrap(pm.createBolusProgressReporter(reportingOn: reporterQueue)
                                        as? TandemDoseProgressReporter)
        let observer = FakeProgressObserver()
        let exp = expectation(description: "clamped update")
        observer.onUpdate = { _ in exp.fulfill() }
        reporter.addObserver(observer)

        let requested = 2.0
        // 2 U at 1.5 U/min would finish in 80s; 1000s is well past full delivery.
        armActiveBolus(pm, requested: requested, startedSecondsAgo: 1000)

        pm.reportInProgressBolus(delivering: true)

        wait(for: [exp], timeout: 2.0)
        reporterQueue.sync {}
        let p = try XCTUnwrap(observer.updates.last)
        XCTAssertEqual(p.deliveredUnits, requested, accuracy: 1e-9, "must clamp exactly to requested")
        XCTAssertEqual(p.percentComplete, 1.0, accuracy: 1e-9)
    }

    // 2. During .requesting (delivering=false), no insulin is flowing yet, so the
    //    estimate is zero on both surfaces, regardless of elapsed time.
    func testRequestingYieldsZeroProgress() throws {
        let pm = makeManager()
        let reporter = try XCTUnwrap(pm.createBolusProgressReporter(reportingOn: reporterQueue)
                                        as? TandemDoseProgressReporter)
        let observer = FakeProgressObserver()
        let exp = expectation(description: "zero update")
        observer.onUpdate = { _ in exp.fulfill() }
        reporter.addObserver(observer)

        // A long elapsed window would yield nonzero IF delivering were inferred
        // from elapsed alone; passing delivering:false must force zero.
        armActiveBolus(pm, requested: 4.0, startedSecondsAgo: 500)

        pm.reportInProgressBolus(delivering: false)

        wait(for: [exp], timeout: 2.0)
        reporterQueue.sync {}
        let p = try XCTUnwrap(observer.updates.last)
        XCTAssertEqual(p.deliveredUnits, 0.0, accuracy: 1e-9)
        XCTAssertEqual(p.percentComplete, 0.0, accuracy: 1e-9)
    }

    // 6. On the delivering->idle edge, finalize pushes a single 100% with the
    //    requested volume, then subsequent idle polls no-op (one-shot guard).
    func testFinalizePushesHundredPercentOnceOnEdge() throws {
        let pm = makeManager()
        let reporter = try XCTUnwrap(pm.createBolusProgressReporter(reportingOn: reporterQueue)
                                        as? TandemDoseProgressReporter)
        let observer = FakeProgressObserver()
        reporter.addObserver(observer)

        // First, a delivering report so the one-shot guard is armed.
        let requested = 3.0
        armActiveBolus(pm, requested: requested, startedSecondsAgo: 20)
        let deliverExp = expectation(description: "delivering update")
        observer.onUpdate = { _ in deliverExp.fulfill() }
        pm.reportInProgressBolus(delivering: true)
        wait(for: [deliverExp], timeout: 2.0)

        // Now the bolus completes: the poll nils the anchor, then finalizes. We
        // mirror that ordering (state cleared, then finalize with requested from
        // the poll-side capture).
        pm.updateState {
            $0.bolusState = .noBolus
            $0.activeBolusId = nil
            $0.activeBolusUnits = nil
            $0.activeBolusStartDate = nil
        }
        let finalizeExp = expectation(description: "finalize 100%")
        observer.onUpdate = { _ in finalizeExp.fulfill() }
        pm.finalizeInProgressBolusProgress(requestedUnits: requested)
        wait(for: [finalizeExp], timeout: 2.0)
        reporterQueue.sync {}

        let p = try XCTUnwrap(observer.updates.last)
        XCTAssertEqual(p.percentComplete, 1.0, accuracy: 1e-9)
        XCTAssertEqual(p.deliveredUnits, requested, accuracy: 1e-9)
        let countAfterFinalize = observer.updates.count

        // A second idle finalize must NOT notify again (one-shot edge guard).
        pm.finalizeInProgressBolusProgress(requestedUnits: requested)
        reporterQueue.sync {}
        // Give any erroneous async hop a chance to land before asserting silence.
        let settle = expectation(description: "settle")
        reporterQueue.asyncAfter(deadline: .now() + 0.2) { settle.fulfill() }
        wait(for: [settle], timeout: 2.0)
        XCTAssertEqual(observer.updates.count, countAfterFinalize,
                       "second idle finalize must not re-notify")
    }

    // MARK: - M3: the in-progress DoseEntry is mutable and carries the estimate

    // 3. makeInProgressBolusEvent builds a mutable .bolus event whose value is the
    //    requested volume, deliveredUnits is the estimate, and whose raw key
    //    equals that of the completed event for the same bolusId (so the mutable
    //    in-progress entry and the immutable completed entry coalesce in Loop).
    func testInProgressEventIsMutableAndKeyedForCoalescing() throws {
        let reporter = TandemDoseReporter()
        let bolusId: UInt16 = 42
        let requested = 6.0
        let deliveredSoFar = 1.5
        let start = Date()

        let event = reporter.makeInProgressBolusEvent(bolusId: bolusId,
                                                      requestedUnits: requested,
                                                      deliveredSoFar: deliveredSoFar,
                                                      startDate: start,
                                                      insulinType: .novolog)
        let dose = try XCTUnwrap(event.dose)
        XCTAssertEqual(dose.type, .bolus)
        XCTAssertTrue(dose.isMutable, "in-progress bolus must be mutable until finalized")
        XCTAssertEqual(dose.programmedUnits, requested, accuracy: 1e-9,
                       "value carries the REQUESTED volume for an in-progress dose")
        XCTAssertEqual(dose.deliveredUnits ?? -1, deliveredSoFar, accuracy: 1e-9,
                       "deliveredUnits carries the time estimate")
        XCTAssertEqual(event.type, .bolus)

        // raw is bolusSyncIdentifier(bolusId): the same bolusId yields the same
        // raw key, so a later immutable completed event REPLACES this one rather
        // than duplicating. Compare against a second in-progress event with the
        // same id (proxy for the completed event, which uses the same identifier).
        let sameId = reporter.makeInProgressBolusEvent(bolusId: bolusId,
                                                       requestedUnits: requested,
                                                       deliveredSoFar: deliveredSoFar,
                                                       startDate: start,
                                                       insulinType: .novolog)
        let otherId = reporter.makeInProgressBolusEvent(bolusId: bolusId &+ 1,
                                                        requestedUnits: requested,
                                                        deliveredSoFar: deliveredSoFar,
                                                        startDate: start,
                                                        insulinType: .novolog)
        XCTAssertEqual(event.raw, sameId.raw, "same bolusId must produce the same raw key")
        XCTAssertNotEqual(event.raw, otherId.raw, "different bolusId must produce a different raw key")
    }
}
