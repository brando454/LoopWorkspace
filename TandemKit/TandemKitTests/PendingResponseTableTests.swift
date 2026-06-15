import XCTest
import CoreBluetooth
@testable import TandemKit

// Tests for the (characteristic, opCode) response-routing table.
//
// The headline test is `testOpcodeCollisionRoutesByCharacteristic`: it pins the
// safety fix that 0xA5 on CONTROL (SetTempRateResponse) and 0xA5 on
// CURRENT_STATUS (LastBolusStatusV2Response) are routed to the correct waiter
// rather than by opcode alone.
final class PendingResponseTableTests: XCTestCase {

    private let control = TandemCharacteristicUUID.control
    private let status  = TandemCharacteristicUUID.currentStatus

    // The collision: same opcode, two characteristics, two waiters.
    func testOpcodeCollisionRoutesByCharacteristic() {
        let table = PendingResponseTable()

        var controlResult: Result<Data, Error>?
        var statusResult: Result<Data, Error>?

        // Both register the SAME opcode 0xA5 on DIFFERENT characteristics.
        table.register(characteristic: control, opCode: 0xA5) { controlResult = $0 }
        table.register(characteristic: status,  opCode: 0xA5) { statusResult = $0 }
        XCTAssertEqual(table.count, 2)

        // A 0xA5 arriving on CONTROL must resolve ONLY the control waiter.
        let controlCargo = Data([0xC0, 0xC0])
        XCTAssertTrue(table.resolve(characteristic: control, opCode: 0xA5, cargo: controlCargo))

        XCTAssertEqual(try controlResult?.get(), controlCargo)
        XCTAssertNil(statusResult, "status waiter must NOT be resolved by a CONTROL response")
        XCTAssertEqual(table.count, 1)

        // The 0xA5 on CURRENT_STATUS still resolves independently.
        let statusCargo = Data([0x57, 0x57])
        XCTAssertTrue(table.resolve(characteristic: status, opCode: 0xA5, cargo: statusCargo))
        XCTAssertEqual(try statusResult?.get(), statusCargo)
        XCTAssertTrue(table.isEmpty)
    }

    func testResolveNoMatchReturnsFalse() {
        let table = PendingResponseTable()
        var called = false
        table.register(characteristic: control, opCode: 0xA5) { _ in called = true }

        // Right opcode, wrong characteristic -> no match.
        XCTAssertFalse(table.resolve(characteristic: status, opCode: 0xA5, cargo: Data()))
        // Right characteristic, wrong opcode -> no match.
        XCTAssertFalse(table.resolve(characteristic: control, opCode: 0xA4, cargo: Data()))

        XCTAssertFalse(called)
        XCTAssertEqual(table.count, 1, "no-match resolves must not remove the waiter")
    }

    func testFailByTokenRemovesExactEntry() {
        let table = PendingResponseTable()
        var firstResult: Result<Data, Error>?
        var secondResult: Result<Data, Error>?

        // Two entries that share an opcode on the same characteristic. Without a
        // token we could not tell them apart; with a token we fail exactly one.
        let firstToken = table.register(characteristic: control, opCode: 0xA5) { firstResult = $0 }
        table.register(characteristic: control, opCode: 0xA5) { secondResult = $0 }

        XCTAssertTrue(table.fail(token: firstToken, error: TandemBLEError.timeout))
        XCTAssertEqual(table.count, 1)

        // The failed one carries the error; the other is untouched.
        XCTAssertThrowsError(try firstResult?.get())
        XCTAssertNil(secondResult)

        // The surviving entry still resolves on a matching response.
        XCTAssertTrue(table.resolve(characteristic: control, opCode: 0xA5, cargo: Data([0x01])))
        XCTAssertEqual(try secondResult?.get(), Data([0x01]))
    }

    func testFailAfterResolveIsNoOp() {
        let table = PendingResponseTable()
        var result: Result<Data, Error>?
        let token = table.register(characteristic: control, opCode: 0xA5) { result = $0 }

        XCTAssertTrue(table.resolve(characteristic: control, opCode: 0xA5, cargo: Data([0xAB])))
        // Resolved already removed the entry, so a later timeout is a no-op and
        // cannot overwrite the success or double-resume.
        XCTAssertFalse(table.fail(token: token, error: TandemBLEError.timeout))
        XCTAssertEqual(try result?.get(), Data([0xAB]))
    }

    func testFailAllFailsEveryOutstandingEntry() {
        let table = PendingResponseTable()
        var a: Result<Data, Error>?
        var b: Result<Data, Error>?
        table.register(characteristic: control, opCode: 0xA5) { a = $0 }
        table.register(characteristic: status,  opCode: 0x33) { b = $0 }

        table.failAll(error: TandemBLEError.notConnected)

        XCTAssertTrue(table.isEmpty)
        XCTAssertThrowsError(try a?.get())
        XCTAssertThrowsError(try b?.get())
    }

    func testTokensAreUnique() {
        let table = PendingResponseTable()
        let t1 = table.register(characteristic: control, opCode: 0x01) { _ in }
        let t2 = table.register(characteristic: control, opCode: 0x01) { _ in }
        XCTAssertNotEqual(t1, t2)
    }
}
