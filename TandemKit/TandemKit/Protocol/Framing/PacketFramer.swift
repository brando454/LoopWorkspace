import Foundation

// Wire-level packet framing for the Tandem BLE protocol.
//
// Each serialized message is chunked into BLE write payloads:
//   byte[0]    packetsRemaining  (countdown; N-1 for first chunk of N, 0 for last)
//   byte[1]    transactionId
//   byte[2..]  slice of the serialized message
//
// Serialized message format (before chunking):
//   byte[0]     opCode
//   byte[1]     transactionId
//   byte[2]     cargoLength       (byte count of cargo, may include signed-cargo encoding)
//   byte[3..N]  cargo
//   [if signed:]
//   byte[N..N+3]   timeSinceReset   uint32 LE
//   byte[N+4..N+23] HMAC-SHA1       20 bytes
//   byte[-2..-1]  CRC-16 little-endian over all preceding bytes (low byte first;
//                 matches pumpX2 Bytes.calculateCRC16 and the physical pump)
enum PacketFramer {

    // Chunk a serialized message into BLE write payloads.
    //
    // chunkSize is the BODY-byte count per chunk (not the total payload size):
    // each chunk is [packetsRemaining][transactionId] + up to chunkSize bytes of
    // the serialized message. This matches pumpX2 Packetize.partitionList, which
    // partitions packetWithCRC into chunkSize-byte sublists and then prepends the
    // 2-byte header. Verified against a real pump capture on the AUTHORIZATION
    // characteristic: 18-byte bodies (defaultChunk = 18).
    //   defaultChunk = 18  -> 18-byte bodies (auth + status; confirmed on the wire)
    //   controlChunk = 40  -> 40-byte bodies (CONTROL; pumpX2 working value, not
    //                         yet validated against a control-path capture)
    static func chunk(serialized: Data, transactionId: UInt8, chunkSize: Int) -> [Data] {
        let fullPayload = serialized  // includes opCode; whole serialized message is chunked

        let cargoPerChunk = chunkSize  // chunkSize is the per-chunk body size
        let numChunks = max(1, Int(ceil(Double(fullPayload.count) / Double(cargoPerChunk))))

        var chunks: [Data] = []
        var offset = 0
        for i in 0..<numChunks {
            let remaining = UInt8(numChunks - 1 - i)
            let end = min(offset + cargoPerChunk, fullPayload.count)
            var chunk = Data()
            chunk.append(remaining)
            chunk.append(transactionId)
            chunk.append(contentsOf: fullPayload[offset..<end])
            chunks.append(chunk)
            offset = end
        }
        return chunks
    }

    // Reassemble chunks into a complete serialized message.
    // Returns nil if more chunks are still expected.
    // Throws if CRC validation fails.
    static func reassemble(chunks: inout [Data]) throws -> Data? {
        guard let last = chunks.last, last[0] == 0 else {
            return nil  // more chunks expected
        }

        // WP6/L2: the buffer now looks complete (a final chunk with
        // packetsRemaining == 0 arrived). Before concatenating, validate the
        // buffer's integrity so two interleaved transactions or a lost/reordered
        // chunk can never be silently fused into one frame. We detect, classify,
        // and let the caller drop the buffer; we never try to recover a subset.
        //
        // 1. transactionId agreement: byte[1] of every chunk must equal the
        //    first chunk's. A disagreement means chunks from two transactions
        //    landed in one per-characteristic buffer.
        // 2. countdown sequence: byte[0] across the buffer must be the strict
        //    descending run count-1, count-2, ... 1, 0 with no gap, repeat, or
        //    reorder. The final-chunk-is-0 gate above is necessary but not
        //    sufficient; this proves the whole run.
        let expectedTxId = chunks[0][1]
        let chunkCount = chunks.count
        for (index, chunk) in chunks.enumerated() {
            let txId = chunk[1]
            guard txId == expectedTxId else {
                throw TandemFramingError.transactionIdMismatch(expected: expectedTxId, found: txId)
            }
            let expectedRemaining = UInt8(chunkCount - 1 - index)
            guard chunk[0] == expectedRemaining else {
                throw TandemFramingError.sequenceError(expected: expectedRemaining, found: chunk[0])
            }
        }

        var assembled = Data()
        for chunk in chunks {
            assembled.append(contentsOf: chunk.dropFirst(2))
        }
        guard CRC16.verify(assembled) else {
            throw TandemFramingError.crcMismatch
        }
        return assembled.dropLast(2)  // strip CRC bytes
    }

    // Serialize a message for sending (without signing).
    static func serialize(opCode: UInt8, transactionId: UInt8, cargo: Data) throws -> Data {
        // WP6/L1: cargo length is encoded as a single byte (byte[2]). Reject any
        // cargo that cannot be represented in that field before framing, so an
        // unchecked UInt8(cargo.count) can never silently truncate the length or
        // trap on a count >= 256. Today every cargo is well under this bound;
        // this is a fail-closed guard against a larger message type being added
        // later on the command path.
        guard cargo.count <= 255 else {
            throw TandemFramingError.cargoTooLarge(count: cargo.count)
        }
        var out = Data()
        out.append(opCode)
        out.append(transactionId)
        out.append(UInt8(cargo.count))
        out.append(contentsOf: cargo)
        let withCRC = CRC16.appending(to: out)
        return withCRC
    }

    // Serialize and sign a message (for CONTROL characteristic).
    // authKey: runtime key from successful auth.
    // timeSinceReset: pump's uptime in seconds (UInt32 LE).
    static func serializeSigned(
        opCode: UInt8,
        transactionId: UInt8,
        cargo: Data,
        authKey: Data,
        timeSinceReset: UInt32
    ) throws -> Data {
        // WP6/L1: same single-byte length-field guard as serialize. The signed
        // path adds timeSinceReset + HMAC after the cargo, but the cargoLength
        // byte still encodes only the cargo, so the same bound applies. Fail
        // closed before computing the HMAC or framing any bytes.
        guard cargo.count <= 255 else {
            throw TandemFramingError.cargoTooLarge(count: cargo.count)
        }
        var out = Data()
        out.append(opCode)
        out.append(transactionId)
        out.append(UInt8(cargo.count))
        out.append(contentsOf: cargo)

        // Append timeSinceReset (4 bytes LE) + 20 zero bytes (HMAC placeholder)
        withUnsafeBytes(of: timeSinceReset.littleEndian) { out.append(contentsOf: $0) }
        out.append(contentsOf: Data(count: 20))

        // Compute HMAC-SHA1 over everything except the last 20 bytes
        let messageData = out.dropLast(20)
        let hmac = HmacUtils.hmacSHA1(key: authKey, data: messageData)

        // Replace the trailing 20 zero bytes with the HMAC
        out.replaceSubrange((out.count - 20)..., with: hmac)

        return CRC16.appending(to: out)
    }
}

enum TandemFramingError: Error {
    case crcMismatch
    case reassemblyFailed
    // WP6/L2: a chunk in the reassembly buffer carried a transactionId that
    // disagreed with the buffer's first chunk. Two transactions interleaved on
    // one characteristic; the frame is dropped rather than concatenated.
    case transactionIdMismatch(expected: UInt8, found: UInt8)
    // WP6/L2: the packetsRemaining countdown across the buffer was not the
    // strict descending sequence N-1, N-2, ... 1, 0 (a dropped, duplicated, or
    // reordered chunk). The frame is dropped rather than reassembled from a
    // sequence we cannot trust.
    case sequenceError(expected: UInt8, found: UInt8)
    // WP6/L1: the cargo length exceeded the single-byte length field the wire
    // format encodes (byte[2], a UInt8). Rather than truncate the count via an
    // unchecked UInt8 conversion (which would write a wrong length and, for a
    // count >= 256, trap), we reject the message before any bytes are framed.
    // Fails closed: the send path throws and the command is never transmitted.
    case cargoTooLarge(count: Int)
}
