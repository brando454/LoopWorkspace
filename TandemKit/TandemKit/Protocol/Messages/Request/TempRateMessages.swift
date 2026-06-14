@preconcurrency import CoreBluetooth
import Foundation

// Mobi-only: set a temporary basal rate.
// Control-IQ must be off before calling this.
// Duration range: 15 min–72 hr. On wire: milliseconds (minutes × 60000).
// Percent range: 0–250.
struct SetTempRateRequest: TandemRequest {
    static let opCode: UInt8 = 0xA4  // -92 signed
    static let characteristic = TandemCharacteristicUUID.control
    static let isSigned = true
    static let modifiesInsulinDelivery = true

    let durationMinutes: UInt32   // 15–4320
    let percent: UInt16           // 0–250

    func cargo() -> Data {
        let durationMs = durationMinutes * 60_000
        var d = Data(count: 6)
        d[0] = UInt8(durationMs & 0xFF)
        d[1] = UInt8((durationMs >> 8)  & 0xFF)
        d[2] = UInt8((durationMs >> 16) & 0xFF)
        d[3] = UInt8((durationMs >> 24) & 0xFF)
        d[4] = UInt8(percent & 0xFF)
        d[5] = UInt8((percent >> 8) & 0xFF)
        return d
    }
}

struct SetTempRateResponse: TandemResponse {
    static let opCode: UInt8 = 0xA5  // -91 signed
    static let characteristic = TandemCharacteristicUUID.control
    static let isSigned = true

    let status: UInt8
    let tempRateId: UInt16

    var success: Bool { status == 0 }

    init?(cargo: Data) {
        guard cargo.count >= 3 else { return nil }
        status = cargo[0]
        tempRateId = UInt16(cargo[1]) | (UInt16(cargo[2]) << 8)
    }
}

// Mobi-only: cancel the active temp rate.
struct StopTempRateRequest: TandemRequest {
    static let opCode: UInt8 = 0xA6  // -90 signed
    static let characteristic = TandemCharacteristicUUID.control
    static let isSigned = true
    static let modifiesInsulinDelivery = true

    func cargo() -> Data { Data() }
}

struct StopTempRateResponse: TandemResponse {
    static let opCode: UInt8 = 0xA7  // -89 signed
    static let characteristic = TandemCharacteristicUUID.control
    static let isSigned = true

    let status: UInt8
    let tempRateId: UInt16

    var success: Bool { status == 0 }

    init?(cargo: Data) {
        guard cargo.count >= 3 else { return nil }
        status = cargo[0]
        tempRateId = UInt16(cargo[1]) | (UInt16(cargo[2]) << 8)
    }
}

// Read current temp rate status (both pumps, read-only).
struct TempRateStatusRequest: TandemRequest {
    static let opCode: UInt8 = 0x1E  // 30

    func cargo() -> Data { Data() }
}

struct TempRateStatusResponse: TandemResponse {
    static let opCode: UInt8 = 0x1F  // 31

    let isActive: Bool
    let tempRateId: UInt16
    let percentage: UInt8
    let startDate: Date
    let durationSeconds: UInt32

    init?(cargo: Data) {
        guard cargo.count >= 16 else { return nil }
        isActive = cargo[0] != 0
        tempRateId = UInt16(cargo[1]) | (UInt16(cargo[2]) << 8)
        percentage = cargo[3]
        let startRaw = UInt32(cargo[4]) | (UInt32(cargo[5]) << 8) |
                       (UInt32(cargo[6]) << 16) | (UInt32(cargo[7]) << 24)
        startDate = TandemEpoch.date(fromPumpSeconds: startRaw)
        durationSeconds = UInt32(cargo[12]) | (UInt32(cargo[13]) << 8) |
                          (UInt32(cargo[14]) << 16) | (UInt32(cargo[15]) << 24)
    }
}
