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
}