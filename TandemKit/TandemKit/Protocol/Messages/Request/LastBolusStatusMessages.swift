@preconcurrency import CoreBluetooth
import Foundation

// LastBolusStatus messages — the authoritative source of DELIVERED insulin volume.
//
// Ported from jwoglom/pumpX2:
//   request/currentStatus/LastBolusStatusV2Request.java
//   response/currentStatus/LastBolusStatusV2Response.java  (opCode -91, size 24)
//
// This is the message TandemKit was missing. CurrentBolusStatus reports the
// REQUESTED volume of an in-progress bolus; LastBolusStatusV2 reports the
// DELIVERED volume of the most recently completed/cancelled bolus. Loop must
// reconcile against delivered volume, never requested, or its IOB model drifts.
//
// V2 is available on API >= 2.5, which covers all Tandem Mobi units, so we use
// V2 as the baseline. (V3 adds a few trailing fields we do not need yet.)

// IMPORTANT — OPCODE COLLISION (verified against pumpX2):
//   LastBolusStatusV2Request  opCode = -92 (0xA4)  on CURRENT_STATUS characteristic
//   LastBolusStatusV2Response opCode = -91 (0xA5)  on CURRENT_STATUS characteristic
//   SetTempRateRequest        opCode = -92 (0xA4)  on CONTROL characteristic
//   SetTempRateResponse       opCode = -91 (0xA5)  on CONTROL characteristic
//
// These share opcodes and are disambiguated ONLY by characteristic. TandemKit's
// current response router matches on opCode alone (see TandemPeripheralManager
// pendingResponses) and therefore CANNOT distinguish them. The connection-actor
// redesign (next deliverable) must key pending responses on (characteristic, opCode),
// not opCode alone. Until then, never have a temp-rate request and a
// last-bolus-status request in flight at the same time.
struct LastBolusStatusV2Request: TandemRequest {
    static let opCode: UInt8 = 0xA4  // -92 signed → 0xA4
    static let characteristic = TandemCharacteristicUUID.currentStatus

    func cargo() -> Data { Data() }
}

// Status of the bolus as reported by the pump. Values from pumpX2 BolusStatus enum.
enum TandemBolusCompletionStatus: UInt8 {
    case completed   = 0   // delivered in full
    case interrupted = 1   // stopped early (delivered < requested)
    case canceling   = 2
    case unknown     = 0xFF

    init(rawByte: UInt8) {
        self = TandemBolusCompletionStatus(rawValue: rawByte) ?? .unknown
    }
}

struct LastBolusStatusV2Response: TandemResponse {
    static let opCode: UInt8 = 0xA5  // -91 signed → 0xA5 (collides w/ SetTempRateResponse; see note above)
    static let characteristic = TandemCharacteristicUUID.currentStatus
    static let isSigned = true

    let status: UInt8
    let bolusId: UInt16
    let timestamp: Date
    let deliveredVolumeMU: UInt32   // milliunits ACTUALLY delivered — the field Loop needs
    let bolusStatusId: UInt8
    let bolusSourceId: UInt8
    let bolusTypeBitmask: UInt8
    let extendedBolusDurationMs: UInt32
    let requestedVolumeMU: UInt32   // milliunits originally requested

    var completionStatus: TandemBolusCompletionStatus {
        TandemBolusCompletionStatus(rawByte: bolusStatusId)
    }

    var deliveredUnits: Double { Double(deliveredVolumeMU) / 1000.0 }
    var requestedUnits: Double { Double(requestedVolumeMU) / 1000.0 }

    // Byte layout (pumpX2 LastBolusStatusV2Response.parse, size = 24):
    //   [0]      status
    //   [1..2]   bolusId          (LE u16)
    //   [3..4]   padding (0,0)
    //   [5..8]   timestamp        (LE u32, Jan-1-2008 epoch seconds)
    //   [9..12]  deliveredVolume  (LE u32, milliunits)
    //   [13]     bolusStatusId
    //   [14]     bolusSourceId
    //   [15]     bolusTypeBitmask
    //   [16..19] extendedBolusDuration (LE u32, ms)
    //   [20..23] requestedVolume  (LE u32, milliunits)
    init?(cargo: Data) {
        guard cargo.count >= 24 else { return nil }
        let b = [UInt8](cargo)
        status = b[0]
        bolusId = UInt16(b[1]) | (UInt16(b[2]) << 8)
        let ts = UInt32(b[5]) | (UInt32(b[6]) << 8) | (UInt32(b[7]) << 16) | (UInt32(b[8]) << 24)
        timestamp = TandemEpoch.date(fromPumpSeconds: ts)
        deliveredVolumeMU = UInt32(b[9]) | (UInt32(b[10]) << 8) | (UInt32(b[11]) << 16) | (UInt32(b[12]) << 24)
        bolusStatusId = b[13]
        bolusSourceId = b[14]
        bolusTypeBitmask = b[15]
        extendedBolusDurationMs = UInt32(b[16]) | (UInt32(b[17]) << 8) | (UInt32(b[18]) << 16) | (UInt32(b[19]) << 24)
        requestedVolumeMU = UInt32(b[20]) | (UInt32(b[21]) << 8) | (UInt32(b[22]) << 16) | (UInt32(b[23]) << 24)
    }
}

// BolusPermissionRelease — MUST be sent after a bolus sequence completes or fails.
//
// Ported from jwoglom/pumpX2:
//   request/control/BolusPermissionReleaseRequest.java  (opCode -16, size 4)
//
// The pump grants a single bolus "permission" (a lock keyed by bolusId) via
// BolusPermissionRequest. If the permission is not released, the pump can refuse
// the NEXT bolus. TandemKit never released it — that is a real reliability bug
// (second bolus silently rejected). Always release in a defer/finally after the
// initiate step, whether it succeeded or failed.
struct BolusPermissionReleaseRequest: TandemRequest {
    static let opCode: UInt8 = 0xF0  // -16 signed → 0xF0
    static let characteristic = TandemCharacteristicUUID.control
    static let isSigned = true

    let bolusId: UInt16
    let reserve: UInt16

    init(bolusId: UInt16, reserve: UInt16 = 0) {
        self.bolusId = bolusId
        self.reserve = reserve
    }

    // Byte layout (pumpX2 BolusPermissionReleaseRequest.buildCargo, size 4):
    //   [0..1] bolusID (LE u16)
    //   [2..3] reserve (LE u16)
    func cargo() -> Data {
        Data([
            UInt8(bolusId & 0xFF), UInt8((bolusId >> 8) & 0xFF),
            UInt8(reserve & 0xFF), UInt8((reserve >> 8) & 0xFF)
        ])
    }
}

struct BolusPermissionReleaseResponse: TandemResponse {
    static let opCode: UInt8 = 0xF1  // -15 signed → 0xF1
    static let characteristic = TandemCharacteristicUUID.control
    static let isSigned = true

    let status: UInt8
    var success: Bool { status == 0 }

    init?(cargo: Data) {
        guard !cargo.isEmpty else { return nil }
        status = [UInt8](cargo)[0]
    }
}
