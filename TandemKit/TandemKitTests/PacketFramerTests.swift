import XCTest
@testable import TandemKit

// Wire-level framing codec coverage for PacketFramer.
//
// These tests are the specification for chunk/reassemble/serialize behavior.
// They are grounded in a real pump capture (Android btsnoop, ECJPAKE pairing on
// the AUTHORIZATION characteristic) and cross-checked against the pumpX2
// reference library. Two wire-level facts they pin, both of which earlier code
// got wrong while staying internally self-consistent:
//   1. The CRC-16 trailer is little-endian (low byte first).  [TK-WIRE1]
//   2. chunkSize is the per-chunk BODY-byte count, not the total payload size;
//      the 2-byte [packetsRemaining][txId] header is added on top. The default
//      path uses 18-byte bodies, confirmed on the wire and by pumpX2
//      Packetize.DEFAULT_MAX_CHUNK_SIZE.  [TK-WIRE3]
final class PacketFramerTests: XCTestCase {

    // MARK: - chunkSize semantics (TK-WIRE3)

    // chunkSize is the BODY size: each chunk carries up to chunkSize message
    // bytes plus a 2-byte header, so total chunk length is chunkSize + 2 (except
    // the final remainder chunk). This is the assertion the codec lacked.
    func testChunkSizeIsBodyByteCount() {
        let serialized = Data((0..<40).map { UInt8($0) })  // 40 bytes
        let chunks = PacketFramer.chunk(serialized: serialized, transactionId: 0x07, chunkSize: 18)
        // 40 body bytes / 18 per chunk -> 3 chunks (18, 18, 4)
        XCTAssertEqual(chunks.count, 3)
        XCTAssertEqual(chunks[0].count, 20, "full chunk = 18 body + 2 header")
        XCTAssertEqual(chunks[1].count, 20)
        XCTAssertEqual(chunks[2].count, 6, "remainder = 4 body + 2 header")
        // Body byte count per chunk equals chunkSize for the full chunks.
        XCTAssertEqual(chunks[0].count - 2, 18)
    }

    // packetsRemaining counts down: N-1 for the first chunk of N, 0 for the last.
    // transactionId is byte[1] of every chunk.
    func testChunkHeaderCountdownAndTxId() {
        let serialized = Data((0..<50).map { UInt8($0) })  // 50 / 18 -> 3 chunks
        let tx: UInt8 = 0x2A
        let chunks = PacketFramer.chunk(serialized: serialized, transactionId: tx, chunkSize: 18)
        XCTAssertEqual(chunks.count, 3)
        XCTAssertEqual(chunks.map { $0[0] }, [2, 1, 0], "packetsRemaining must descend to 0")
        XCTAssertTrue(chunks.allSatisfy { $0[1] == tx }, "txId must be byte[1] of every chunk")
    }

    // MARK: - Round-trip identity

    // serialize -> chunk -> reassemble reproduces the original cargo, across both
    // the default body size (18) and the control body size (40), and across a
    // payload that spans multiple chunks.
    func testRoundTripIdentityAcrossChunkSizes() {
        for chunkSize in [18, 40] {
            let cargo = Data((0..<37).map { UInt8($0 &* 7 &+ 1) })
            let serialized = PacketFramer.serialize(opCode: 0x55, transactionId: 0x11, cargo: cargo)
            var chunks = PacketFramer.chunk(serialized: serialized, transactionId: 0x11, chunkSize: chunkSize)
            let assembled = try? PacketFramer.reassemble(chunks: &chunks)
            XCTAssertEqual(assembled, serialized.dropLast(2),
                           "reassemble must reproduce the serialized message (minus CRC) at chunkSize \(chunkSize)")
            // And the recovered cargo matches the input cargo.
            if let a = assembled {
                XCTAssertEqual(a.dropFirst(3), cargo)
                XCTAssertEqual(a[0], 0x55)
                XCTAssertEqual(a[1], 0x11)
            }
        }
    }

    // A synthetic multi-chunk message: 100-byte cargo at body size 18 spans many
    // chunks. Confirms the boundary logic over a long countdown.
    func testSyntheticMultiChunkRoundTrip() {
        let cargo = Data((0..<100).map { UInt8($0) })
        let serialized = PacketFramer.serialize(opCode: 0x24, transactionId: 0x09, cargo: cargo)
        var chunks = PacketFramer.chunk(serialized: serialized, transactionId: 0x09, chunkSize: 18)
        // serializedLen = 3 + 100 + 2 = 105; 105 / 18 -> 6 chunks (ceil).
        XCTAssertEqual(chunks.count, 6)
        XCTAssertEqual(chunks.first?[0], 5)
        XCTAssertEqual(chunks.last?[0], 0)
        let assembled = try? PacketFramer.reassemble(chunks: &chunks)
        XCTAssertEqual(assembled, serialized.dropLast(2))
    }

    // MARK: - Captured device-truth vector (TK-WIRE1 + TK-WIRE3)

    // A real single-chunk frame captured off a physical Tandem Mobi pump on the
    // AUTHORIZATION characteristic: Jpake3SessionKeyRequest, opCode 0x26, txId
    // 0x03, cargoLen 2, cargo 00 00 — benign, no key/serial/patient data.
    // On the wire the chunk body was: 26 03 02 00 00 81 21
    // (serialized message + little-endian CRC trailer 81 21 = CRC 0x2181).
    // The single chunk's header on the wire was rem=0x00 tx=0x03.
    func testCapturedFrameReassembles() {
        // Reconstruct the on-wire chunk: [rem=0][tx=0x03] + body.
        let body = Data([0x26, 0x03, 0x02, 0x00, 0x00, 0x81, 0x21])
        var chunks = [Data([0x00, 0x03]) + body]
        let assembled = try? PacketFramer.reassemble(chunks: &chunks)
        XCTAssertNotNil(assembled, "captured frame must reassemble (CRC verifies little-endian)")
        XCTAssertEqual(assembled, Data([0x26, 0x03, 0x02, 0x00, 0x00]),
                       "reassembled message is the serialized bytes minus the CRC trailer")
    }

    // MARK: - reassemble edge cases

    // Returns nil while more chunks are still expected (last chunk's countdown
    // is not yet 0).
    func testReassembleReturnsNilOnPartialBuffer() {
        var partial = [Data([0x02, 0x05, 0xAA, 0xBB])]  // rem=2, more expected
        XCTAssertNil(try? PacketFramer.reassemble(chunks: &partial))
    }

    // Throws crcMismatch when the trailer does not match the body.
    func testReassembleThrowsOnCrcMismatch() {
        // Take a valid frame, corrupt one body byte, keep the original trailer.
        var chunks = [Data([0x00, 0x03]) + Data([0x26, 0x03, 0x02, 0x00, 0xFF, 0x81, 0x21])]
        XCTAssertThrowsError(try PacketFramer.reassemble(chunks: &chunks)) { error in
            guard case TandemFramingError.crcMismatch = error else {
                return XCTFail("expected crcMismatch, got \(error)")
            }
        }
    }

    // MARK: - reassembly integrity validation (WP6/L2)
    //
    // The reassembler must reject a buffer whose chunks do not all belong to one
    // transaction, or whose packetsRemaining countdown is not the strict
    // descending run. These are detected and classified BEFORE CRC, so the
    // caller drops the buffer with an accurate cause instead of a misattributed
    // crcMismatch or an accidental CRC pass on fused garbage. No recovery is
    // attempted; a corrupt or interleaved frame is dropped, never reconstructed.

    // A buffer that completes (final chunk rem==0) but mixes two transactionIds
    // throws transactionIdMismatch, naming the disagreement. Built so the
    // mismatch is the only defect and is caught before CRC.
    func testReassembleThrowsOnTransactionIdMismatch() {
        var chunks = [
            Data([0x01, 0x10, 0xAA, 0xBB]),  // rem=1, tx=0x10
            Data([0x00, 0x11, 0xCC, 0xDD]),  // rem=0, tx=0x11 (interloper)
        ]
        XCTAssertThrowsError(try PacketFramer.reassemble(chunks: &chunks)) { error in
            guard case let TandemFramingError.transactionIdMismatch(expected, found) = error else {
                return XCTFail("expected transactionIdMismatch, got \(error)")
            }
            XCTAssertEqual(expected, 0x10)
            XCTAssertEqual(found, 0x11)
        }
    }

    // A gap in the countdown (a chunk lost between rem=2 and rem=0, so the
    // buffer holds rem=[2,0] with one txId) throws sequenceError. The
    // final-chunk-is-0 gate alone would not catch this; the per-position check
    // does. Note the buffer count is 2, so position 0 expects rem=1, not 2.
    func testReassembleThrowsOnSequenceGap() {
        var chunks = [
            Data([0x02, 0x07, 0xAA]),  // rem=2 but only 2 chunks present -> expected 1
            Data([0x00, 0x07, 0xBB]),  // rem=0
        ]
        XCTAssertThrowsError(try PacketFramer.reassemble(chunks: &chunks)) { error in
            guard case let TandemFramingError.sequenceError(expected, found) = error else {
                return XCTFail("expected sequenceError, got \(error)")
            }
            XCTAssertEqual(expected, 1, "position 0 of a 2-chunk buffer must carry rem=1")
            XCTAssertEqual(found, 2)
        }
    }

    // Reordered chunks (rem=[0,1] instead of [1,0], same txId) throw
    // sequenceError. The last chunk is rem==1 here, so this also exercises that
    // the completeness gate is on the LAST element: with rem=1 last, it returns
    // nil (more expected), not a sequence throw. Verify that boundary explicitly.
    func testReassembleReorderedTrailingNonZeroReturnsNil() {
        var reordered = [
            Data([0x00, 0x07, 0xAA]),  // rem=0 first
            Data([0x01, 0x07, 0xBB]),  // rem=1 last -> gate says more expected
        ]
        XCTAssertNil(try? PacketFramer.reassemble(chunks: &reordered),
                     "a non-zero final countdown means the buffer is treated as incomplete")
    }

    // A reorder that still ends in rem==0 (rem=[0,...,0] impossible, so use a
    // 3-chunk reorder [1,2,0] with one txId): the buffer completes but position
    // 0 carries rem=1 where 2 is required, so sequenceError fires.
    func testReassembleThrowsOnReorderWithZeroLast() {
        var chunks = [
            Data([0x01, 0x07, 0xAA]),  // pos0: expected rem=2, found 1
            Data([0x02, 0x07, 0xBB]),  // pos1: expected rem=1, found 2
            Data([0x00, 0x07, 0xCC]),  // pos2: expected rem=0, found 0
        ]
        XCTAssertThrowsError(try PacketFramer.reassemble(chunks: &chunks)) { error in
            guard case let TandemFramingError.sequenceError(expected, found) = error else {
                return XCTFail("expected sequenceError, got \(error)")
            }
            XCTAssertEqual(expected, 2)
            XCTAssertEqual(found, 1)
        }
    }

    // The validation must NOT reject a well-formed multi-chunk frame: same txId
    // throughout, clean descending countdown. Built through serialize+chunk so
    // the CRC is correct by construction; reassembly returns the original.
    func testReassembleAcceptsValidMultiChunkFrame() {
        let cargo = Data((0..<60).map { UInt8($0 &* 3 &+ 5) })
        let serialized = PacketFramer.serialize(opCode: 0x33, transactionId: 0x42, cargo: cargo)
        var chunks = PacketFramer.chunk(serialized: serialized, transactionId: 0x42, chunkSize: 18)
        XCTAssertGreaterThan(chunks.count, 1, "fixture must span multiple chunks to exercise the run check")
        let assembled = try? PacketFramer.reassemble(chunks: &chunks)
        XCTAssertEqual(assembled, serialized.dropLast(2),
                       "a valid same-txId, clean-countdown frame must pass validation unchanged")
    }
}