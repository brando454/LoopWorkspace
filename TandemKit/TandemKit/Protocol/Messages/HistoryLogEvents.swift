import Foundation

// Typed decoding of the 16-byte type-specific payload carried by each 26-byte
// history-log entry (see HistoryLogEntry in HistoryLogMessages.swift). TypeIds
// and field layouts are ported from the pumpX2 HistoryLog subclasses; offsets
// below are PAYLOAD-relative (pumpX2 quotes them relative to the full 26-byte
// entry — subtract the 10-byte common header).
//
// Only the event types reconciliation needs are decoded; anything else is
// carried as .unrecognized with its raw payload so a fetcher can log or count
// it without dropping the entry's header (timestamp / sequenceNum still apply).
//
// Insulin fields are IEEE-754 float32 LE in units of insulin, exactly as the
// pump reports them; no scaling is applied here.
enum HistoryLogEvent: Equatable {
    /// typeId 20 — a bolus finished (fully or partially). insulinDelivered is
    /// the actual delivered amount; insulinRequested the commanded amount.
    case bolusCompleted(completionStatusId: UInt16, bolusId: UInt16,
                        iob: Float, insulinDelivered: Float, insulinRequested: Float)
    /// typeId 2 — a temp rate started.
    case tempRateActivated(percent: Float, durationMinutes: Float, tempRateId: UInt16)
    /// typeId 15 — a temp rate ended (expired or stopped).
    case tempRateCompleted(tempRateId: UInt16, timeLeftSeconds: UInt32)
    /// typeId 11 — pumping suspended. reasonId per pumpX2 SuspendReason:
    /// 0 user, 1 alarm, 2 malfunction, 6 auto-suspend predictive low glucose.
    case pumpingSuspended(insulinAmount: UInt16, reasonId: UInt8)
    /// typeId 12 — pumping resumed.
    case pumpingResumed(insulinAmount: UInt16)
    /// Any typeId we do not decode; header fields remain usable on the entry.
    case unrecognized(typeId: UInt16)

    // Decode the typed event for an entry. Never nil: unknown typeIds map to
    // .unrecognized so a stream is never silently shortened by a new event type.
    static func decode(from entry: HistoryLogEntry) -> HistoryLogEvent {
        let p = entry.payload  // 16 bytes, 0-based
        switch entry.typeId {
        case 20:
            return .bolusCompleted(
                completionStatusId: p.u16LE(at: 0),   // entry offset 10
                bolusId:            p.u16LE(at: 2),   // entry offset 12
                iob:                p.f32LE(at: 4),   // entry offset 14
                insulinDelivered:   p.f32LE(at: 8),   // entry offset 18
                insulinRequested:   p.f32LE(at: 12)   // entry offset 22
            )
        case 2:
            return .tempRateActivated(
                percent:         p.f32LE(at: 0),      // entry offset 10
                durationMinutes: p.f32LE(at: 4),      // entry offset 14
                tempRateId:      p.u16LE(at: 10)      // entry offset 20
            )
        case 15:
            return .tempRateCompleted(
                tempRateId:      p.u16LE(at: 2),      // entry offset 12
                timeLeftSeconds: p.u32LE(at: 4)       // entry offset 14
            )
        case 11:
            return .pumpingSuspended(
                insulinAmount: p.u16LE(at: 4),        // entry offset 14
                reasonId:      p.u8(at: 6)            // entry offset 16
            )
        case 12:
            return .pumpingResumed(
                insulinAmount: p.u16LE(at: 4)         // entry offset 14
            )
        default:
            return .unrecognized(typeId: entry.typeId)
        }
    }
}

// Little-endian field readers over the fixed 16-byte payload. Offsets are
// payload-relative and statically in-bounds for every use above (max end 16);
// the precondition documents that invariant rather than silently clamping.
private extension Data {
    func u8(at offset: Int) -> UInt8 {
        precondition(offset + 1 <= count)
        return self[startIndex + offset]
    }

    func u16LE(at offset: Int) -> UInt16 {
        precondition(offset + 2 <= count)
        let i = startIndex + offset
        return UInt16(self[i]) | (UInt16(self[i + 1]) << 8)
    }

    func u32LE(at offset: Int) -> UInt32 {
        precondition(offset + 4 <= count)
        let i = startIndex + offset
        return UInt32(self[i]) | (UInt32(self[i + 1]) << 8) |
               (UInt32(self[i + 2]) << 16) | (UInt32(self[i + 3]) << 24)
    }

    func f32LE(at offset: Int) -> Float {
        Float(bitPattern: u32LE(at: offset))
    }
}
