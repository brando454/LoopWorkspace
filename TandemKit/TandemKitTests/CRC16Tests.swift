import XCTest
@testable import TandemKit

final class CRC16Tests: XCTestCase {

    // Known-good: CRC-16/CCITT-FALSE of empty input = 0xFFFF
    func testEmptyInput() {
        XCTAssertEqual(CRC16.calculate(Data()), 0xFFFF)
    }

    // CRC-16/CCITT-FALSE of [0x31..0x39] ("123456789") = 0x29B1 — standard test vector
    func testKnownVector() {
        let input = Data([0x31, 0x32, 0x33, 0x34, 0x35, 0x36, 0x37, 0x38, 0x39])
        XCTAssertEqual(CRC16.calculate(input), 0x29B1)
    }

    func testAppendAndVerify() {
        let payload = Data([0x01, 0x02, 0x03])
        let withCRC = CRC16.appending(to: payload)
        XCTAssertEqual(withCRC.count, payload.count + 2)
        XCTAssertTrue(CRC16.verify(withCRC))
    }

    func testCorruptedDataFailsVerify() {
        var data = CRC16.appending(to: Data([0xAA, 0xBB]))
        data[0] ^= 0xFF  // flip bits in payload
        XCTAssertFalse(CRC16.verify(data))
    }
}
