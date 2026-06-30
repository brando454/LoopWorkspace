import XCTest
import Foundation
@testable import TandemKit

// TandemMessageVectorTests
// ------------------------
// These tests pin TandemKit's wire encoding/parsing to REAL device-captured byte
// vectors published by jwoglom/pumpX2 — the reverse-engineered reference library
// that TandemKit was written against. Every expected byte array below is the
// logical message cargo extracted from a pumpX2 unit test (links inline). pumpX2
// captured these from physical Tandem pumps, so matching them is the closest thing
// we have to validating against hardware without a pump in hand.
//
// Source revision: jwoglom/pumpX2 @ 9bfc6691a463e783ac55067dd3eeffb76be8b0f7
//
// NOTE — the InitiateBolusRequest encoder bug this file once guarded against is
// FIXED. The convenience initializer formerly double-booked the dose (foodVolume
// duplicated total) and set bolusTypeBitmask to 0 instead of 8; both are
// corrected. The bolus tests below now PASS against the pumpX2 device-captured
// cargo and stand as the landed regression guard — do not relax them.
// See `testInitiateBolusRequest_1u_matchesPumpX2Capture`.

final class TandemMessageVectorTests: XCTestCase {

    // MARK: helpers

    private func hex(_ d: Data) -> String { d.map { String(format: "%02x", $0) }.joined() }

    // Build Data from a pumpX2-style signed-byte array (Java bytes are signed).
    private func bytes(_ vals: [Int]) -> Data {
        Data(vals.map { UInt8(bitPattern: Int8($0)) })
    }

    // MARK: - Request encoding (cargo() must match pumpX2 logical cargo)

    // pumpX2 SetTempRateRequestTest.testSetTempRateRequest_0pct_15min
    // logical cargo = a0 bb 0d 00 | 00 00  (durationMs=900000 LE, percent=0 LE)
    func testSetTempRateRequest_0pct_15min() {
        let req = SetTempRateRequest(durationMinutes: 15, percent: 0)
        XCTAssertEqual(hex(req.cargo()), "a0bb0d000000")
    }

    // pumpX2 SetTempRateRequestTest.testSetTempRateRequest_1pct_15min
    // logical cargo = a0 bb 0d 00 | 01 00
    func testSetTempRateRequest_1pct_15min() {
        let req = SetTempRateRequest(durationMinutes: 15, percent: 1)
        XCTAssertEqual(hex(req.cargo()), "a0bb0d000100")
    }

    // pumpX2 SetTempRateRequestTest.testSetTempRateRequest_2pct_15min
    func testSetTempRateRequest_2pct_15min() {
        let req = SetTempRateRequest(durationMinutes: 15, percent: 2)
        XCTAssertEqual(hex(req.cargo()), "a0bb0d000200")
    }

    // pumpX2 CancelBolusRequestTest.testCancelBolusRequest_ID10677
    // logical cargo = b5 29 | 00 00  (bolusId=10677 LE + 2 padding)
    func testCancelBolusRequest_ID10677() {
        let req = CancelBolusRequest(bolusId: 10677)
        XCTAssertEqual(hex(req.cargo()), "b5290000")
    }

    // pumpX2 CancelBolusRequestTest.testCancelBolusRequest_ID10678
    func testCancelBolusRequest_ID10678() {
        let req = CancelBolusRequest(bolusId: 10678)
        XCTAssertEqual(hex(req.cargo()), "b6290000")
    }

    // pumpX2 BolusPermissionReleaseRequestTest.testBolusPermissionReleaseRequest_ID10676
    // logical cargo = b4 29 | 00 00  (bolusId=10676 LE + reserve 0)
    func testBolusPermissionReleaseRequest_ID10676() {
        let req = BolusPermissionReleaseRequest(bolusId: 10676)
        XCTAssertEqual(hex(req.cargo()), "b4290000")
    }

    // pumpX2 InitiateBolusRequestTest.testInitiateBolusRequest_ID10650_1u
    //   asserts: totalVolume=1000, bolusID=10650, bolusTypeBitmask=8, foodVolume=0.
    //   logical cargo first 9 bytes = e8 03 00 00 | 9a 29 | 00 00 | 08, rest 0.
    //
    // Regression guard for the InitiateBolusRequest.init(units:bolusId:) fix:
    // foodVolume must be 0 (not units*1000, which double-booked the dose) and
    // bolusTypeBitmask must be 8 (FOOD2), not 0. Do NOT relax these assertions —
    // they encode the bytes a real pump expects for a standard override bolus.
    func testInitiateBolusRequest_1u_matchesPumpX2Capture() throws {
        let req = try XCTUnwrap(InitiateBolusRequest(units: 1.0, bolusId: 10650))
        let expected = bytes([
            -24, 3, 0, 0,   // totalVolume = 1000 mU (LE)
            -102, 41,       // bolusId = 10650 (LE) = 9a 29
            0, 0,           // padding
            8,              // bolusTypeBitmask = 8 (FOOD2 standard)
            0, 0, 0, 0,     // foodVolume = 0  (NOT units*1000)
            0, 0, 0, 0,     // correctionVolume = 0
            0, 0,           // bolusCarbs = 0
            0, 0,           // bolusBG = 0
            0, 0, 0, 0,     // bolusIOB = 0
            0, 0, 0, 0,     // extendedVolume = 0
            0, 0, 0, 0,     // extendedSeconds = 0
            0, 0, 0, 0      // extended3 = 0
        ])
        XCTAssertEqual(req.cargo().count, 37, "InitiateBolus cargo must be 37 bytes")
        XCTAssertEqual(hex(req.cargo()), hex(expected),
                       "InitiateBolus 1u must encode to the pumpX2 device-captured cargo (foodVolume=0, bolusTypeBitmask=8)")
    }

    // A narrower, always-on guard that does not depend on fixing init: the header
    // fields the pump reads first must be right regardless of the carb/type bug.
    func testInitiateBolusRequest_totalVolumeAndIdAreCorrect() throws {
        let req = try XCTUnwrap(InitiateBolusRequest(units: 1.0, bolusId: 10650))
        let c = [UInt8](req.cargo())
        let total = UInt32(c[0]) | (UInt32(c[1]) << 8) | (UInt32(c[2]) << 16) | (UInt32(c[3]) << 24)
        let id = UInt16(c[4]) | (UInt16(c[5]) << 8)
        XCTAssertEqual(total, 1000, "1.0 U must encode as 1000 mU")
        XCTAssertEqual(id, 10650, "bolusId must round-trip")
    }

    // MARK: - Response parsing (init?(cargo:) must reproduce pumpX2 fields)

    // pumpX2 LastBolusStatusV2ResponseTest.testLastBolusStatusV2ResponsePresent
    // completed 1u-ish standard food bolus, delivered == requested == 6670 mU.
    func testLastBolusStatusV2_present_completed() throws {
        let cargo = bytes([1, -88, 12, 0, 0, -76, 83, 85, 27, 14, 26, 0, 0, 3, 1, 1, 0, 0, 0, 0, 14, 26, 0, 0])
        let r = try XCTUnwrap(LastBolusStatusV2Response(cargo: cargo))
        XCTAssertEqual(r.bolusId, 3240)
        XCTAssertEqual(r.deliveredVolumeMU, 6670)
        XCTAssertEqual(r.requestedVolumeMU, 6670)
        XCTAssertEqual(r.bolusStatusId, 3)
        XCTAssertEqual(r.bolusSourceId, 1)
        XCTAssertEqual(r.completionStatus, .complete, "statusId 3 == COMPLETE per pumpX2")
        XCTAssertTrue(r.completionStatus.deliveredInFull)
        XCTAssertEqual(r.deliveredUnits, 6.670, accuracy: 0.0001)
    }

    // pumpX2 ...testLastBolusStatusV2ResponsePartialStop
    // user-terminated: delivered 1975 mU of a requested 2500 mU. THE case Loop
    // must get right — report the 1.975 U actually given, never the 2.5 requested.
    func testLastBolusStatusV2_partialStop_deliveredLessThanRequested() throws {
        let cargo = bytes([1, -83, 12, 0, 0, -118, -103, 85, 27, -73, 7, 0, 0, 0, 1, 8, 0, 0, 0, 0, -60, 9, 0, 0])
        let r = try XCTUnwrap(LastBolusStatusV2Response(cargo: cargo))
        XCTAssertEqual(r.bolusId, 3245)
        XCTAssertEqual(r.deliveredVolumeMU, 1975)
        XCTAssertEqual(r.requestedVolumeMU, 2500)
        XCTAssertEqual(r.deliveredUnits, 1.975, accuracy: 0.0001)
        XCTAssertEqual(r.requestedUnits, 2.500, accuracy: 0.0001)
        XCTAssertLessThan(r.deliveredUnits, r.requestedUnits,
                          "partial-stop must report delivered < requested")
        XCTAssertEqual(r.completionStatus, .stoppedUserTerminated,
                       "statusId 0 == user-terminated, NOT completed")
        XCTAssertFalse(r.completionStatus.deliveredInFull,
                       "a user-terminated partial must not read as fully delivered")
    }

    // pumpX2 ...testLastBolusStatusV2Response05uCompleted
    func testLastBolusStatusV2_halfUnit_completed() throws {
        let cargo = bytes([1, -85, 12, 0, 0, 52, 122, 85, 27, 50, 0, 0, 0, 3, 1, 8, 0, 0, 0, 0, 50, 0, 0, 0])
        let r = try XCTUnwrap(LastBolusStatusV2Response(cargo: cargo))
        XCTAssertEqual(r.bolusId, 3243)
        XCTAssertEqual(r.deliveredVolumeMU, 50)
        XCTAssertEqual(r.requestedVolumeMU, 50)
        XCTAssertEqual(r.deliveredUnits, 0.05, accuracy: 0.0001)
    }

    // pumpX2 ...testLastBolusStatusV2ResponseEmpty (all-zero cargo still parses)
    func testLastBolusStatusV2_emptyAllZero() throws {
        let cargo = Data(count: 24)
        let r = try XCTUnwrap(LastBolusStatusV2Response(cargo: cargo))
        XCTAssertEqual(r.bolusId, 0)
        XCTAssertEqual(r.deliveredVolumeMU, 0)
    }

    // MARK: - CurrentBolusStatus liveness (WP6/L3)
    //
    // hasActiveBolus must rest on deliveryStatus alone. bolusId is the last
    // bolus's identifier and stays non-zero after delivery completes; the old
    // predicate OR-ed bolusId != 0 and so reported a bolus perpetually in
    // progress once any bolus had run. These vectors build a >=15-byte cargo with
    // deliveryStatus at byte[0] and bolusId (LE) at bytes[1..2].

    // status DONE (0) with a non-zero bolusId: the regression case. Must read as
    // NO active bolus despite the non-zero id.
    func testCurrentBolusStatus_doneWithNonZeroId_isNotActive() throws {
        // [0]=0 done, [1..2]=0x0190 (400) bolusId, rest zero, padded to 15.
        let cargo = bytes([0, -112, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0])
        let r = try XCTUnwrap(CurrentBolusStatusResponse(cargo: cargo))
        XCTAssertEqual(r.bolusId, 400, "bolusId is parsed and non-zero")
        XCTAssertEqual(r.deliveryStatus, .done)
        XCTAssertFalse(r.hasActiveBolus,
                       "a completed bolus with a non-zero id must NOT read as active")
    }

    // status DELIVERING (1) reads active.
    func testCurrentBolusStatus_delivering_isActive() throws {
        let cargo = bytes([1, -112, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0])
        let r = try XCTUnwrap(CurrentBolusStatusResponse(cargo: cargo))
        XCTAssertEqual(r.deliveryStatus, .delivering)
        XCTAssertTrue(r.hasActiveBolus)
    }

    // status REQUESTING (2) reads active.
    func testCurrentBolusStatus_requesting_isActive() throws {
        let cargo = bytes([2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0])
        let r = try XCTUnwrap(CurrentBolusStatusResponse(cargo: cargo))
        XCTAssertEqual(r.deliveryStatus, .requesting)
        XCTAssertTrue(r.hasActiveBolus)
    }

    // An unrecognized status byte defaults to .done (safe direction): a garbled
    // status reads as NO active bolus rather than forever-in-progress, even with
    // a non-zero bolusId.
    func testCurrentBolusStatus_unknownStatusByte_defaultsToDoneAndNotActive() throws {
        let cargo = bytes([7, -1, -1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0])
        let r = try XCTUnwrap(CurrentBolusStatusResponse(cargo: cargo))
        XCTAssertEqual(r.deliveryStatus, .done, "unknown raw status defaults to .done")
        XCTAssertFalse(r.hasActiveBolus)
    }

    // Cargo shorter than 15 bytes fails to parse (guard).
    func testCurrentBolusStatus_rejectsShortCargo() {
        XCTAssertNil(CurrentBolusStatusResponse(cargo: Data(count: 14)))
    }

    // Tandem epoch math: pumpSeconds 458576820 -> a known wall-clock instant.
    // 2008-01-01T00:00:00Z + 458576820s.
    func testTandemEpochRoundTrip() {
        let pumpSeconds: UInt32 = 458576820
        let date = TandemEpoch.date(fromPumpSeconds: pumpSeconds)
        XCTAssertEqual(TandemEpoch.pumpSeconds(from: date), pumpSeconds)
        // Sanity: 2008 epoch + ~458.5M s lands in 2022.
        let comps = Calendar(identifier: .gregorian).dateComponents(
            in: TimeZone(identifier: "UTC")!, from: date)
        XCTAssertEqual(comps.year, 2022)
    }

    // Truncated cargo must fail to parse, never produce garbage fields.
    func testLastBolusStatusV2_rejectsShortCargo() {
        XCTAssertNil(LastBolusStatusV2Response(cargo: Data(count: 23)))
        XCTAssertNil(LastBolusStatusV2Response(cargo: Data()))
    }

    // pumpX2 BolusPermissionResponseTest.testBolusPermissionResponse (granted)
    //   cargo = {0,-102,41,0,0,0,...}: status 0, bolusId 10650, nack 0.
    func testBolusPermissionResponse_granted() throws {
        let cargo = bytes([0, -102, 41, 0, 0, 0])
        let r = try XCTUnwrap(BolusPermissionResponse(cargo: cargo))
        XCTAssertTrue(r.permissionGranted)
        XCTAssertEqual(r.bolusId, 10650)
        XCTAssertEqual(r.nackReasonId, 0)
    }

    // pumpX2 ...testBolusPermissionResponse_disallowed_openOnPump
    //   status 1, bolusId 0, nackReason 3 (pump has permission / open on pump).
    func testBolusPermissionResponse_disallowed() throws {
        let cargo = bytes([1, 0, 0, 0, 0, 3])
        let r = try XCTUnwrap(BolusPermissionResponse(cargo: cargo))
        XCTAssertFalse(r.permissionGranted)
        XCTAssertEqual(r.nackReasonId, 3)
    }

    // pumpX2 InitiateBolusResponseTest.testInitiateBolusResponse_ID10650
    //   cargo begins {0, -102, 41, ...}: status 0, bolusId 10650.
    func testInitiateBolusResponse_ID10650() throws {
        let cargo = bytes([0, -102, 41])
        let r = try XCTUnwrap(InitiateBolusResponse(cargo: cargo))
        XCTAssertTrue(r.success)
        XCTAssertEqual(r.bolusId, 10650)
    }

    // pumpX2 CancelBolusResponseTest.testCancelBolusResponse_ID10677 (success)
    //   response cargo first byte status=0.
    func testCancelBolusResponse_success() throws {
        let cargo = bytes([0, -75, 41, 0, 0])
        let r = try XCTUnwrap(CancelBolusResponse(cargo: cargo))
        XCTAssertTrue(r.success)
    }

    // pumpX2 ...testCancelBolusResponse_ID10688_cancelledAfterCompletedDelivery
    //   status 1 (FAILED — already delivered). cargo {1,-64,41,2,0}.
    func testCancelBolusResponse_failedAlreadyDelivered() throws {
        let cargo = bytes([1, -64, 41, 2, 0])
        let r = try XCTUnwrap(CancelBolusResponse(cargo: cargo))
        XCTAssertFalse(r.success)
    }
}
