import Foundation

// Pump uptime + wall clock. An UNSIGNED status read on the currentStatus
// characteristic (the default), ported from pumpX2 TimeSinceResetRequest /
// TimeSinceResetResponse (opcodes 54/55).
//
// pumpTimeSinceReset is REQUIRED to frame signed CONTROL commands: PacketFramer
// .serializeSigned folds it into the HMAC as a freshness stamp, and the pump
// validates it against its own uptime, so a signed command carrying a stale or
// zero value is rejected. Because this read is unsigned, it bootstraps signing
// with no chicken-and-egg: it is issued after auth, before any signed command.
struct TimeSinceResetRequest: TandemRequest {
    static let opCode: UInt8 = 0x36  // 54

    func cargo() -> Data { Data() }
}

struct TimeSinceResetResponse: TandemResponse {
    static let opCode: UInt8 = 0x37  // 55

    // Pump's wall clock (Jan-1-2008 epoch seconds, LE at cargo[0..3]). Captured
    // for future clock-offset / time-sync work; not yet consumed.
    let currentTime: Date
    // Seconds since the pump last reset (LE at cargo[4..7]). Monotonic uptime used
    // to freshness-stamp signed CONTROL commands.
    let pumpTimeSinceReset: UInt32

    init?(cargo: Data) {
        guard cargo.count >= 8 else { return nil }
        let ct = UInt32(cargo[0]) | (UInt32(cargo[1]) << 8) |
                 (UInt32(cargo[2]) << 16) | (UInt32(cargo[3]) << 24)
        currentTime = TandemEpoch.date(fromPumpSeconds: ct)
        pumpTimeSinceReset = UInt32(cargo[4]) | (UInt32(cargo[5]) << 8) |
                             (UInt32(cargo[6]) << 16) | (UInt32(cargo[7]) << 24)
    }
}
