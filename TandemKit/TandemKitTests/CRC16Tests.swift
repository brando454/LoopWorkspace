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

    // The trailer must be LITTLE-endian: low byte first, then high byte. This is
    // the assertion the round-trip tests above cannot make, because append/verify
    // mirror each other and pass under either order. pumpX2 Bytes.calculateCRC16
    // returns { value & 0xFF, value >> 8 }, and real pump frames match that.
    func testTrailerIsLittleEndian() {
        let payload = Data([0x01, 0x02, 0x03])
        let value = CRC16.calculate(payload)
        let withCRC = CRC16.appending(to: payload)
        XCTAssertEqual(withCRC[withCRC.count - 2], UInt8(value & 0xFF),
                       "low byte of CRC must come first on the wire")
        XCTAssertEqual(withCRC[withCRC.count - 1], UInt8(value >> 8),
                       "high byte of CRC must come second on the wire")
    }

    // Golden vector: a real frame captured off a physical Tandem Mobi pump
    // (Android btsnoop, ECJPAKE pairing). This is Jpake3SessionKeyRequest, opCode
    // 0x26, txId 0x03, cargoLen 2, cargo 00 00 — a benign handshake request with no
    // key, serial, or patient data. Serialized message bytes (opCode | txId |
    // cargoLen | cargo | CRC):
    //     26 03 02 00 00 | 81 21
    // The CRC value is 0x2181; on the wire its trailer is 81 21 (little-endian).
    // Under the previous big-endian trailer this vector did NOT verify; under the
    // corrected order it does. This is the regression guard for the byte-order fix.
    func testGoldenVector_realPumpFrame_verifiesLittleEndian() {
        let frame = Data([0x26, 0x03, 0x02, 0x00, 0x00, 0x81, 0x21])
        XCTAssertTrue(CRC16.verify(frame),
                      "real captured pump frame must verify under little-endian trailer")
        // And the algorithm reproduces the captured trailer exactly.
        let body = frame.dropLast(2)
        let value = CRC16.calculate(body)
        XCTAssertEqual(value, 0x2181, "CRC of the captured body must equal the captured value")
        XCTAssertEqual(Data([UInt8(value & 0xFF), UInt8(value >> 8)]), frame.suffix(2),
                       "computed little-endian trailer must equal the captured trailer")
    }
}
