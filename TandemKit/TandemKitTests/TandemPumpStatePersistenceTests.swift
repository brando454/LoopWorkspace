import XCTest
import Foundation
import LoopKit
@testable import TandemKit

// TandemPumpStatePersistenceTests
// -------------------------------
// WP1 / TK-H6: the dose reporter dedupes boluses by `lastReportedBolusId`, and
// that high-water mark MUST survive an app restart or the integration will
// re-emit (double-count) completed boluses after relaunch — inflating IOB and
// causing under-dosing.
//
// The reporter exposes `reportedBolusIdForPersistence` and accepts a seed via
// `init(lastReportedBolusId:)`. TandemPumpState is where that value is saved and
// restored. These tests assert the persistence contract: the field round-trips
// through rawValue -> init(rawValue:) unchanged, defaults cleanly for an old
// rawState that predates the field, and correctly seeds the reporter's dedupe.
//
// Pure value-type tests: no BLE, no pump, no LoopKit delegate. Runs on
// Mac Catalyst with the rest of TandemKitTests.

final class TandemPumpStatePersistenceTests: XCTestCase {

    // Mirror the byte helper used in TandemDoseReporterTests so cargo literals
    // are identical (signed Int -> UInt8 bit pattern).
    private func bytes(_ vals: [Int]) -> Data {
        Data(vals.map { UInt8(bitPattern: Int8(truncatingIfNeeded: $0)) })
    }

    // Same completed-bolus fixture as TandemDoseReporterTests: bolusId 3240.
    private func completedResponse() -> LastBolusStatusV2Response {
        LastBolusStatusV2Response(
            cargo: bytes([1, -88, 12, 0, 0, -76, 83, 85, 27, 14, 26, 0, 0, 3, 1, 1, 0, 0, 0, 0, 14, 26, 0, 0])
        )!
    }

    private func makeState() -> TandemPumpState {
        let schedule = BasalRateSchedule(dailyItems: [
            RepeatingScheduleValue(startTime: 0, value: 0.8)
        ], timeZone: TimeZone(identifier: "America/Boise")!)
        return TandemPumpState(basalRateSchedule: schedule)
    }

    // MARK: - Default

    func testFreshStateReportsZeroLastReportedBolusId() {
        XCTAssertEqual(makeState().lastReportedBolusId, 0,
                       "a pump that has never reported a bolus must start at 0")
    }

    // MARK: - Round-trip

    func testLastReportedBolusIdSurvivesRawValueRoundTrip() {
        let state = makeState()
        state.lastReportedBolusId = 3240

        let raw = state.rawValue
        let restored = TandemPumpState(rawValue: raw)

        XCTAssertEqual(restored.lastReportedBolusId, 3240,
                       "lastReportedBolusId must survive rawValue -> init(rawValue:) so dedupe holds across restart")
    }

    func testLastReportedBolusIdRoundTripsAtUInt16Max() {
        let state = makeState()
        state.lastReportedBolusId = UInt16.max
        let restored = TandemPumpState(rawValue: state.rawValue)
        XCTAssertEqual(restored.lastReportedBolusId, UInt16.max,
                       "the full UInt16 range must persist; no truncation to a narrower type")
    }

    func testMissingKeyRestoresToZeroNotCrash() {
        // Simulate a rawState saved by an OLD build that predates the field.
        let state = makeState()
        var raw = state.rawValue
        raw["lastReportedBolusId"] = nil
        let restored = TandemPumpState(rawValue: raw)
        XCTAssertEqual(restored.lastReportedBolusId, 0,
                       "upgrade from a build without the field must default to 0, not crash")
    }

    // MARK: - Seeds the reporter

    func testPersistedIdSeedsReporterDedupeAfterRestart() {
        // End-to-end purpose: a restored high-water mark seeds the reporter so a
        // bolus already reported before relaunch is not re-emitted.
        let state = makeState()
        state.lastReportedBolusId = 3240
        let restored = TandemPumpState(rawValue: state.rawValue)

        let reporter = TandemDoseReporter(lastReportedBolusId: restored.lastReportedBolusId)
        XCTAssertNil(reporter.makeBolusEvent(from: completedResponse(), insulinType: nil),
                     "a bolus reported before restart must stay deduped after the persisted id seeds the reporter")
    }
}
