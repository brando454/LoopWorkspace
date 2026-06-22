import XCTest
import Foundation
@testable import TandemKit

// WP3 (TK-C4 + TK-C5): the bolus path must reject an invalid command before any
// pump traffic, and must release a granted permission lock on every exit.
//
// These cover the pure, offline-testable surfaces:
//   - InitiateBolusRequest.init?(units:bolusId:) failable rejection (TK-C4)
//   - InitiateBolusRequest.roundedToResolution(_:) (0.05 U grid)
//   - BolusPermissionReleaseResponse success/NACK predicate (TK-C5)
//
// NOT covered here (deliberately deferred, not faked): end-to-end "release sent
// on all three enactBolus exits". enactBolus drives sendAndReceive over real
// CoreBluetooth with no offline transport seam, so that path belongs to the
// Mac/hardware pass. It is covered by code inspection of the three exits plus
// the release request/response unit coverage (the request byte layout is pinned
// in TandemMessageVectorTests.testBolusPermissionReleaseRequest_ID10676).
final class TandemBolusGuardTests: XCTestCase {

    private func hex(_ d: Data) -> String { d.map { String(format: "%02x", $0) }.joined() }

    // MARK: - TK-C4: failable init rejects invalid doses (no trap)

    func testInitiateBolusRejectsNonFinite() {
        XCTAssertNil(InitiateBolusRequest(units: .nan, bolusId: 1))
        XCTAssertNil(InitiateBolusRequest(units: .infinity, bolusId: 1))
        XCTAssertNil(InitiateBolusRequest(units: -.infinity, bolusId: 1))
    }

    func testInitiateBolusRejectsNonPositive() {
        XCTAssertNil(InitiateBolusRequest(units: 0, bolusId: 1))
        XCTAssertNil(InitiateBolusRequest(units: -1.0, bolusId: 1))
    }

    func testInitiateBolusValidEncode() throws {
        let req = try XCTUnwrap(InitiateBolusRequest(units: 2.5, bolusId: 4242))
        let c = [UInt8](req.cargo())
        let total = UInt32(c[0]) | (UInt32(c[1]) << 8) | (UInt32(c[2]) << 16) | (UInt32(c[3]) << 24)
        let id = UInt16(c[4]) | (UInt16(c[5]) << 8)
        XCTAssertEqual(total, 2500, "2.5 U must encode as 2500 mU")
        XCTAssertEqual(id, 4242, "bolusId must round-trip")
    }

    func testInitiateBolusSmallestResolutionEncodes() throws {
        let req = try XCTUnwrap(InitiateBolusRequest(units: 0.05, bolusId: 7))
        let c = [UInt8](req.cargo())
        let total = UInt32(c[0]) | (UInt32(c[1]) << 8) | (UInt32(c[2]) << 16) | (UInt32(c[3]) << 24)
        XCTAssertEqual(total, 50, "0.05 U must encode as 50 mU")
    }

    // MARK: - TK-C4: resolution rounding

    func testRoundToResolutionRejectsInvalid() {
        XCTAssertNil(InitiateBolusRequest.roundedToResolution(.nan))
        XCTAssertNil(InitiateBolusRequest.roundedToResolution(.infinity))
        XCTAssertNil(InitiateBolusRequest.roundedToResolution(0))
        XCTAssertNil(InitiateBolusRequest.roundedToResolution(-0.5))
        // Below half a step: rounds to zero, must be rejected (not delivered as 0).
        XCTAssertNil(InitiateBolusRequest.roundedToResolution(0.024))
    }

    func testRoundToResolutionRounds() throws {
        // Half a step rounds up to one step.
        XCTAssertEqual(try XCTUnwrap(InitiateBolusRequest.roundedToResolution(0.025)), 0.05, accuracy: 1e-9)
        // Exact grid value is unchanged.
        XCTAssertEqual(try XCTUnwrap(InitiateBolusRequest.roundedToResolution(0.05)), 0.05, accuracy: 1e-9)
        // Off-grid snaps to nearest 0.05.
        XCTAssertEqual(try XCTUnwrap(InitiateBolusRequest.roundedToResolution(1.07)), 1.05, accuracy: 1e-9)
    }

    func testRoundedValueEncodesWithoutFloatDust() throws {
        let rounded = try XCTUnwrap(InitiateBolusRequest.roundedToResolution(1.07)) // -> 1.05
        let req = try XCTUnwrap(InitiateBolusRequest(units: rounded, bolusId: 9))
        let c = [UInt8](req.cargo())
        let total = UInt32(c[0]) | (UInt32(c[1]) << 8) | (UInt32(c[2]) << 16) | (UInt32(c[3]) << 24)
        XCTAssertEqual(total, 1050, "1.05 U must encode as exactly 1050 mU, not 1049")
    }

    // MARK: - TK-C5: release response predicate

    func testBolusPermissionReleaseResponseSuccess() throws {
        let ok = try XCTUnwrap(BolusPermissionReleaseResponse(cargo: Data([0])))
        XCTAssertTrue(ok.success, "status 0 must be success")
    }

    func testBolusPermissionReleaseResponseNack() throws {
        let nack = try XCTUnwrap(BolusPermissionReleaseResponse(cargo: Data([3])))
        XCTAssertFalse(nack.success, "non-zero status must be a NACK")
    }

    func testBolusPermissionReleaseResponseRejectsEmpty() {
        XCTAssertNil(BolusPermissionReleaseResponse(cargo: Data()),
                     "empty cargo must not parse as a response")
    }
}
