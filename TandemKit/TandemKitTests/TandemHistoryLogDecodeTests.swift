import XCTest
import Foundation
@testable import TandemKit

// TandemHistoryLogDecodeTests
// ---------------------------
// Pins the verified pumpX2 history-log decoding foundation: the status range
// response (opcode 59), the range-fetch request cargo (opcode 60), the 26-byte
// entry header, and the stream-frame envelope (opcode 0x81) with its framing
// invariant (2 header bytes + count * 26). These pure decoders are exercised
// against synthetic frames; per-typeId payload decoding + Loop reconciliation
// land in a later commit.
final class TandemHistoryLogDecodeTests: XCTestCase {

    private func u32LE(_ v: UInt32) -> [UInt8] {
        [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 24) & 0xFF)]
    }

    // Build a 26-byte entry: typeId (2B LE), pumpTimeSec (4B LE), sequenceNum
    // (4B LE), then 16 payload bytes.
    private func entry(typeRaw: UInt16, timeSec: UInt32, seq: UInt32, payload: [UInt8]) -> [UInt8] {
        precondition(payload.count == 16)
        var out: [UInt8] = [UInt8(typeRaw & 0xFF), UInt8((typeRaw >> 8) & 0xFF)]
        out += u32LE(timeSec)
        out += u32LE(seq)
        out += payload
        return out
    }

    // MARK: - Status response

    func testStatusResponseDecodesThreeU32FieldsLE() {
        let cargo = Data(u32LE(42) + u32LE(1000) + u32LE(1041))
        let resp = HistoryLogStatusResponse(cargo: cargo)
        XCTAssertEqual(resp?.numEntries, 42)
        XCTAssertEqual(resp?.firstSequenceNum, 1000)
        XCTAssertEqual(resp?.lastSequenceNum, 1041)
    }

    func testStatusResponseRejectsShortCargo() {
        XCTAssertNil(HistoryLogStatusResponse(cargo: Data(count: 11)))
    }

    // MARK: - Range request cargo

    func testRangeRequestCargoIsStartLogLEPlusCountByte() {
        let cargo = HistoryLogRequest(startLog: 0x01020304, numberOfLogs: 20).cargo()
        XCTAssertEqual(Array(cargo), [0x04, 0x03, 0x02, 0x01, 20],
                       "cargo is startLog as u32 LE followed by the one-byte count")
        XCTAssertEqual(HistoryLogRequest.opCode, 0x3C)
    }

    // MARK: - Entry header

    func testEntryHeaderDecodesAndMasksTypeIdTo12Bits() {
        // High nibble (0xF000) set on the type field must be masked off: only the
        // low 12 bits are the typeId.
        let raw = entry(typeRaw: 0xF123, timeSec: 500, seq: 7, payload: Array(0..<16))
        let e = HistoryLogEntry(entry: Data(raw))
        XCTAssertEqual(e?.typeId, 0x123, "typeId must be the low 12 bits (0xFFF mask)")
        XCTAssertEqual(e?.timestamp, TandemEpoch.date(fromPumpSeconds: 500))
        XCTAssertEqual(e?.sequenceNum, 7)
        XCTAssertEqual(e?.payload, Data(Array(0..<16) as [UInt8]))
    }

    func testEntryRejectsWrongLength() {
        XCTAssertNil(HistoryLogEntry(entry: Data(count: 25)))
        XCTAssertNil(HistoryLogEntry(entry: Data(count: 27)))
    }

    // MARK: - Stream envelope

    func testStreamResponseDecodesEntriesAndStreamId() {
        let e0 = entry(typeRaw: 10, timeSec: 100, seq: 1, payload: Array(repeating: 0xAA, count: 16))
        let e1 = entry(typeRaw: 20, timeSec: 200, seq: 2, payload: Array(repeating: 0xBB, count: 16))
        let cargo = Data([2, 0x5A] + e0 + e1)  // count=2, streamId=0x5A

        let resp = HistoryLogStreamResponse(cargo: cargo)
        XCTAssertEqual(resp?.streamId, 0x5A)
        XCTAssertEqual(resp?.entries.count, 2)
        XCTAssertEqual(resp?.entries.first?.typeId, 10)
        XCTAssertEqual(resp?.entries.first?.sequenceNum, 1)
        XCTAssertEqual(resp?.entries.last?.typeId, 20)
        XCTAssertEqual(resp?.entries.last?.sequenceNum, 2)
    }

    func testStreamResponseZeroEntriesIsEmptyNotNil() {
        // A valid empty frame: count=0, streamId only.
        let resp = HistoryLogStreamResponse(cargo: Data([0, 0x01]))
        XCTAssertNotNil(resp)
        XCTAssertEqual(resp?.entries.count, 0)
        XCTAssertEqual(resp?.streamId, 0x01)
    }

    func testStreamResponseRejectsCountLengthMismatch() {
        // Claims 2 entries but carries only one entry's worth of bytes.
        let e0 = entry(typeRaw: 10, timeSec: 100, seq: 1, payload: Array(repeating: 0, count: 16))
        XCTAssertNil(HistoryLogStreamResponse(cargo: Data([2, 0x00] + e0)),
                     "count * 26 + 2 must equal the frame length")
    }

    func testStreamResponseRejectsTruncatedHeader() {
        XCTAssertNil(HistoryLogStreamResponse(cargo: Data([0x00])))
    }
}
