import CoreBluetooth
import Foundation

// History-log access, ported from pumpX2 (opcodes 58/59/60 on currentStatus, plus
// the 0x81 stream frames the pump pushes unsolicited on the historyLog
// characteristic). All unsigned.
//
// Reconciliation flow (wiring lands in a later commit):
//   1. HistoryLogStatusRequest -> HistoryLogStatusResponse gives the available
//      sequence range [firstSequenceNum ... lastSequenceNum] and total count.
//   2. HistoryLogRequest(startLog, numberOfLogs) asks the pump to STREAM a batch
//      starting at a sequence number.
//   3. The pump pushes HistoryLogStreamResponse frames, each carrying up to N
//      fixed-width 26-byte entries. Each entry shares a common header; the 16-byte
//      tail is type-specific and decoded per typeId by decoders added later.
//
// This file provides the verified message + envelope + entry-header decoders only.
// It changes no live behavior: the stream frames are not yet routed or reconciled.

// MARK: - Status (available range)

struct HistoryLogStatusRequest: TandemRequest {
    static let opCode: UInt8 = 0x3A  // 58

    func cargo() -> Data { Data() }
}

struct HistoryLogStatusResponse: TandemResponse {
    static let opCode: UInt8 = 0x3B  // 59

    let numEntries: UInt32
    let firstSequenceNum: UInt32
    let lastSequenceNum: UInt32

    init?(cargo: Data) {
        guard cargo.count >= 12 else { return nil }
        let b = Data(cargo)  // rebase to 0-based indices
        numEntries       = UInt32(b[0]) | (UInt32(b[1]) << 8) | (UInt32(b[2]) << 16) | (UInt32(b[3]) << 24)
        firstSequenceNum = UInt32(b[4]) | (UInt32(b[5]) << 8) | (UInt32(b[6]) << 16) | (UInt32(b[7]) << 24)
        lastSequenceNum  = UInt32(b[8]) | (UInt32(b[9]) << 8) | (UInt32(b[10]) << 16) | (UInt32(b[11]) << 24)
    }
}

// MARK: - Range fetch (triggers streaming)

struct HistoryLogRequest: TandemRequest {
    static let opCode: UInt8 = 0x3C  // 60

    let startLog: UInt32
    let numberOfLogs: UInt8

    func cargo() -> Data {
        var d = Data()
        withUnsafeBytes(of: startLog.littleEndian) { d.append(contentsOf: $0) }
        d.append(numberOfLogs)
        return d
    }
}

// ACK for HistoryLogRequest: status (0 = success) plus the streamId that the
// subsequent HistoryLogStreamResponse frames will carry, so a fetcher can match
// pushed batches to the request that asked for them.
struct HistoryLogResponse: TandemResponse {
    static let opCode: UInt8 = 0x3D  // 61

    let status: UInt8
    let streamId: UInt8

    var isSuccess: Bool { status == 0 }

    init?(cargo: Data) {
        guard cargo.count >= 2 else { return nil }
        let b = Data(cargo)  // rebase to 0-based indices
        status = b[0]
        streamId = b[1]
    }
}

// MARK: - Stream frames (unsolicited on the historyLog characteristic)

// One 26-byte history-log entry. Only the common header is decoded here; the
// 16-byte payload is retained raw for the per-typeId decoders added later.
struct HistoryLogEntry: Equatable {
    static let byteCount = 26

    let typeId: UInt16      // lower 12 bits of the 2-byte type field
    let timestamp: Date     // pumpTimeSec, Jan-2008 epoch
    let sequenceNum: UInt32
    let payload: Data       // bytes 10..25 (16 bytes), type-specific

    init?(entry raw: Data) {
        guard raw.count == HistoryLogEntry.byteCount else { return nil }
        let b = Data(raw)  // rebase to 0-based indices
        let typeRaw = UInt16(b[0]) | (UInt16(b[1]) << 8)
        typeId = typeRaw & 0x0FFF
        let ts = UInt32(b[2]) | (UInt32(b[3]) << 8) | (UInt32(b[4]) << 16) | (UInt32(b[5]) << 24)
        timestamp = TandemEpoch.date(fromPumpSeconds: ts)
        sequenceNum = UInt32(b[6]) | (UInt32(b[7]) << 8) | (UInt32(b[8]) << 16) | (UInt32(b[9]) << 24)
        payload = b.subdata(in: 10..<26)
    }
}

struct HistoryLogStreamResponse: TandemResponse {
    static let opCode: UInt8 = 0x81  // -127 as a signed byte
    // Unlike the status reads, stream frames arrive on the historyLog char.
    static var characteristic: CBUUID { TandemCharacteristicUUID.historyLog }

    let streamId: UInt8
    let entries: [HistoryLogEntry]

    init?(cargo: Data) {
        let b = Data(cargo)  // rebase to 0-based indices
        guard b.count >= 2 else { return nil }
        let count = Int(b[0])
        streamId = b[1]
        // Framing invariant (pumpX2): 2 header bytes + count * 26.
        guard b.count == 2 + count * HistoryLogEntry.byteCount else { return nil }
        var parsed: [HistoryLogEntry] = []
        parsed.reserveCapacity(count)
        var offset = 2
        for _ in 0..<count {
            guard let entry = HistoryLogEntry(entry: b.subdata(in: offset..<(offset + HistoryLogEntry.byteCount))) else {
                return nil
            }
            parsed.append(entry)
            offset += HistoryLogEntry.byteCount
        }
        entries = parsed
    }
}
