import XCTest
import Foundation
import LoopKit
@testable import TandemKit

// TandemTimeSinceResetTests
// -------------------------
// Covers the pump-uptime bootstrap that freshness-stamps signed CONTROL commands
// (see TimeSinceResetResponse / PacketFramer.serializeSigned). Two concerns:
//   1. TimeSinceResetResponse decodes the pumpX2 8-byte cargo (two u32 LE fields:
//      currentTime at [0..3], pumpTimeSinceReset at [4..7]).
//   2. TandemPumpState.estimatedPumpTimeSinceReset(now:) advances the last read
//      value by elapsed wall-clock, so a signed command sent after the read still
//      carries a fresh value — and returns nil until the first read (the case the
//      old hardcoded 0 masked).
final class TandemTimeSinceResetTests: XCTestCase {

    private func u32LE(_ v: UInt32) -> [UInt8] {
        [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 24) & 0xFF)]
    }

    // MARK: - Decode

    func testResponseDecodesBothU32FieldsLittleEndian() {
        let ctRaw: UInt32 = 16_909_060       // 0x01020304
        let uptime: UInt32 = 168_496_141     // 0x0A0B0C0D
        let cargo = Data(u32LE(ctRaw) + u32LE(uptime))

        let resp = TimeSinceResetResponse(cargo: cargo)
        XCTAssertNotNil(resp)
        XCTAssertEqual(resp?.pumpTimeSinceReset, uptime)
        XCTAssertEqual(resp?.currentTime, TandemEpoch.date(fromPumpSeconds: ctRaw),
                       "currentTime must decode from cargo[0..3] via the Jan-2008 epoch")
    }

    func testResponseRejectsShortCargo() {
        // 7 bytes: one short of the two required u32 fields.
        XCTAssertNil(TimeSinceResetResponse(cargo: Data(count: 7)))
    }

    func testRequestHasEmptyCargoAndExpectedOpcode() {
        XCTAssertEqual(TimeSinceResetRequest.opCode, 0x36)
        XCTAssertEqual(TimeSinceResetResponse.opCode, 0x37)
        XCTAssertTrue(TimeSinceResetRequest().cargo().isEmpty)
        // Bootstrap read must be unsigned, or it could not precede a valid signature.
        XCTAssertFalse(TimeSinceResetRequest.isSigned)
    }

    // MARK: - Estimator

    func testEstimateIsNilBeforeAnyRead() {
        let state = TandemPumpState(basalRateSchedule: nil)
        XCTAssertNil(state.estimatedPumpTimeSinceReset(now: Date()),
                     "no read yet must yield nil (signer then falls back to 0), not a stale value")
    }

    func testEstimateAdvancesByElapsedSinceRead() {
        let state = TandemPumpState(basalRateSchedule: nil)
        let readAt = Date(timeIntervalSince1970: 1_000_000)
        state.pumpTimeSinceResetAtRead = 1000
        state.pumpTimeSinceResetReadAt = readAt

        XCTAssertEqual(state.estimatedPumpTimeSinceReset(now: readAt), 1000,
                       "at the moment of read the estimate equals the read value")
        XCTAssertEqual(state.estimatedPumpTimeSinceReset(now: readAt.addingTimeInterval(30)), 1030,
                       "estimate must advance one second per elapsed second")
        XCTAssertEqual(state.estimatedPumpTimeSinceReset(now: readAt.addingTimeInterval(3600)), 4600,
                       "estimate stays monotonic over longer intervals")
    }

    func testEstimateClampsNegativeElapsedToReadValue() {
        let state = TandemPumpState(basalRateSchedule: nil)
        let readAt = Date(timeIntervalSince1970: 1_000_000)
        state.pumpTimeSinceResetAtRead = 500
        state.pumpTimeSinceResetReadAt = readAt
        // A `now` before the read (clock skew) must not underflow below the read value.
        XCTAssertEqual(state.estimatedPumpTimeSinceReset(now: readAt.addingTimeInterval(-10)), 500)
    }
}
