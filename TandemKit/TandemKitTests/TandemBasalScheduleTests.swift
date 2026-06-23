import XCTest
import Foundation
import HealthKit
import LoopKit
@testable import TandemKit

/// H1 (TK-H1): the scheduled basal rate used as the temp-basal denominator must
/// be selected from the correct schedule segment, honoring the schedule's own
/// timeZone and evaluated at the dose's effective date — not via a hand-rolled
/// elapsed-since-local-midnight computation that breaks across DST and when the
/// schedule timeZone differs from the device locale.
///
/// scheduledBasalRate(at:) now routes through LoopKit's timezone-aware
/// value(at:). These tests pin specific instants and assert the expected
/// segment value, so a regression to a locale- or Date()-pinned lookup fails.
final class TandemBasalScheduleTests: XCTestCase {

    // A three-segment day in a fixed zone:
    //   00:00 -> 0.50 U/hr
    //   06:00 -> 1.00 U/hr   (21600 s)
    //   22:00 -> 0.75 U/hr   (79200 s)
    private func makeSchedule(timeZone: TimeZone) -> BasalRateSchedule {
        return BasalRateSchedule(
            dailyItems: [
                RepeatingScheduleValue(startTime: 0, value: 0.50),
                RepeatingScheduleValue(startTime: 6 * 3600, value: 1.00),
                RepeatingScheduleValue(startTime: 22 * 3600, value: 0.75),
            ],
            timeZone: timeZone
        )!
    }

    private func date(_ iso: String, in tz: TimeZone) -> Date {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = tz
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f.date(from: iso)!
    }

    // MARK: - Basic segment selection at the schedule's own wall-clock times

    func testSelectsCorrectSegmentWithinDay() {
        let tz = TimeZone(identifier: "America/Denver")!
        let schedule = makeSchedule(timeZone: tz)

        // 02:00 local -> first segment (0.50)
        XCTAssertEqual(schedule.scheduledBasalRate(at: date("2026-03-01 02:00:00", in: tz)), 0.50, accuracy: 1e-9)
        // 12:00 local -> middle segment (1.00)
        XCTAssertEqual(schedule.scheduledBasalRate(at: date("2026-03-01 12:00:00", in: tz)), 1.00, accuracy: 1e-9)
        // 23:00 local -> last segment (0.75)
        XCTAssertEqual(schedule.scheduledBasalRate(at: date("2026-03-01 23:00:00", in: tz)), 0.75, accuracy: 1e-9)
    }

    // MARK: - Midnight boundary

    func testMidnightBoundarySelectsFirstSegment() {
        let tz = TimeZone(identifier: "America/Denver")!
        let schedule = makeSchedule(timeZone: tz)
        // 00:00 exactly -> first segment, not the prior day's last segment.
        XCTAssertEqual(schedule.scheduledBasalRate(at: date("2026-03-01 00:00:00", in: tz)), 0.50, accuracy: 1e-9)
        // One minute before midnight -> last segment of that day.
        XCTAssertEqual(schedule.scheduledBasalRate(at: date("2026-02-28 23:59:00", in: tz)), 0.75, accuracy: 1e-9)
    }

    // MARK: - DST boundary (US spring-forward 2026-03-08: 02:00 -> 03:00 MST->MDT)

    func testDSTSpringForwardSelectsCorrectSegment() {
        let tz = TimeZone(identifier: "America/Denver")!
        let schedule = makeSchedule(timeZone: tz)
        // Just before the spring-forward gap: 01:59 local -> first segment (0.50).
        XCTAssertEqual(schedule.scheduledBasalRate(at: date("2026-03-08 01:59:00", in: tz)), 0.50, accuracy: 1e-9)
        // After the jump to MDT, 07:00 local -> middle segment (1.00). A lookup
        // that ignored the zone's DST offset would land in the wrong segment.
        XCTAssertEqual(schedule.scheduledBasalRate(at: date("2026-03-08 07:00:00", in: tz)), 1.00, accuracy: 1e-9)
    }

    func testDSTFallBackSelectsCorrectSegment() {
        let tz = TimeZone(identifier: "America/Denver")!
        let schedule = makeSchedule(timeZone: tz)
        // US fall-back 2026-11-01: 02:00 MDT -> 01:00 MST. 12:00 local that day
        // is still the middle segment (1.00).
        XCTAssertEqual(schedule.scheduledBasalRate(at: date("2026-11-01 12:00:00", in: tz)), 1.00, accuracy: 1e-9)
    }

    // MARK: - Schedule timeZone differs from device locale

    func testScheduleTimeZoneIndependentOfDeviceLocale() {
        // Schedule pinned to Tokyo; the assertion uses Tokyo wall-clock. The
        // result must follow the schedule's zone regardless of the host's
        // Calendar.current, which the old hand-rolled lookup would have used.
        let tokyo = TimeZone(identifier: "Asia/Tokyo")!
        let schedule = makeSchedule(timeZone: tokyo)
        // 23:00 Tokyo -> last segment (0.75).
        let tokyoInstant = date("2026-03-01 23:00:00", in: tokyo)
        XCTAssertEqual(schedule.scheduledBasalRate(at: tokyoInstant), 0.75, accuracy: 1e-9)
        // That same absolute instant is 07:00 Denver wall-clock. A lookup that
        // computed elapsed-since-midnight against the device's Denver locale
        // would read 07:00 (past the 06:00 boundary, before 22:00) and select
        // the MIDDLE segment (1.00). Asserting 0.75 proves the schedule's own
        // Tokyo zone governs the lookup, not the host locale.
        let denver = TimeZone(identifier: "America/Denver")!
        let sameInstant = date("2026-03-01 07:00:00", in: denver)
        XCTAssertEqual(sameInstant, tokyoInstant)
        XCTAssertEqual(schedule.scheduledBasalRate(at: sameInstant), 0.75, accuracy: 1e-9)
    }
}