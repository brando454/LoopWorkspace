import CoreBluetooth
import Foundation

// Step 1 of 2-step bolus: request permission from the pump.
// The pump responds with a bolusId that must be used in InitiateBolusRequest.
struct BolusPermissionRequest: TandemRequest {
    static let opCode: UInt8 = 0xA2  // -94 signed
    static let characteristic = TandemCharacteristicUUID.control
    static let isSigned = true

    func cargo() -> Data { Data() }
}

struct BolusPermissionResponse: TandemResponse {
    static let opCode: UInt8 = 0xA3  // -93 signed
    static let characteristic = TandemCharacteristicUUID.control
    static let isSigned = true

    let status: UInt8
    let bolusId: UInt16
    let nackReasonId: UInt8

    var permissionGranted: Bool { status == 0 }

    init?(cargo: Data) {
        guard cargo.count >= 6 else { return nil }
        status = cargo[0]
        bolusId = UInt16(cargo[1]) | (UInt16(cargo[2]) << 8)
        nackReasonId = cargo[5]
    }
}

// Step 2 of 2-step bolus: deliver the bolus.
// All volumes are in milliunits (1 U = 1000 mU). Minimum: 50 mU = 0.05 U.
struct InitiateBolusRequest: TandemRequest {
    static let opCode: UInt8 = 0x9E  // -98 signed
    static let characteristic = TandemCharacteristicUUID.control
    static let isSigned = true
    static let modifiesInsulinDelivery = true

    let totalVolume: UInt32        // milliunits
    let bolusId: UInt16            // from BolusPermissionResponse
    let bolusTypeBitmask: UInt8    // 0 for a simple standard bolus
    let foodVolume: UInt32
    let correctionVolume: UInt32
    let bolusCarbs: UInt16         // grams
    let bolusBG: UInt16            // mg/dL
    let bolusIOB: UInt32           // milliunits
    let extendedVolume: UInt32     // 0 for standard bolus
    let extendedSeconds: UInt32    // 0 for standard bolus

    // Convenience initializer for a simple standard bolus.
    init(units: Double, bolusId: UInt16) {
        self.totalVolume = UInt32(units * 1000)
        self.bolusId = bolusId
        bolusTypeBitmask = 0
        foodVolume = UInt32(units * 1000)
        correctionVolume = 0
        bolusCarbs = 0
        bolusBG = 0
        bolusIOB = 0
        extendedVolume = 0
        extendedSeconds = 0
    }

    func cargo() -> Data {
        var d = Data(count: 37)
        func writeU32(_ v: UInt32, at offset: Int) {
            d[offset]   = UInt8(v & 0xFF)
            d[offset+1] = UInt8((v >> 8)  & 0xFF)
            d[offset+2] = UInt8((v >> 16) & 0xFF)
            d[offset+3] = UInt8((v >> 24) & 0xFF)
        }
        func writeU16(_ v: UInt16, at offset: Int) {
            d[offset]   = UInt8(v & 0xFF)
            d[offset+1] = UInt8((v >> 8) & 0xFF)
        }
        writeU32(totalVolume,     at: 0)
        writeU16(bolusId,         at: 4)
        // bytes 6-7: padding (0)
        d[8] = bolusTypeBitmask
        writeU32(foodVolume,      at: 9)
        writeU32(correctionVolume, at: 13)
        writeU16(bolusCarbs,      at: 17)
        writeU16(bolusBG,         at: 19)
        writeU32(bolusIOB,        at: 21)
        writeU32(extendedVolume,  at: 25)
        writeU32(extendedSeconds, at: 29)
        // bytes 33-36: extended3 (0)
        return d
    }
}

struct InitiateBolusResponse: TandemResponse {
    static let opCode: UInt8 = 0x9F  // -97 signed
    static let characteristic = TandemCharacteristicUUID.control
    static let isSigned = true

    let status: UInt8
    let bolusId: UInt16

    var success: Bool { status == 0 }

    init?(cargo: Data) {
        guard cargo.count >= 3 else { return nil }
        status = cargo[0]
        bolusId = UInt16(cargo[1]) | (UInt16(cargo[2]) << 8)
    }
}

// Cancel an in-progress bolus (phone-initiated or pump-initiated, including extended).
struct CancelBolusRequest: TandemRequest {
    static let opCode: UInt8 = 0xA0  // -96 signed
    static let characteristic = TandemCharacteristicUUID.control
    static let isSigned = true
    static let modifiesInsulinDelivery = true

    let bolusId: UInt16

    func cargo() -> Data {
        Data([UInt8(bolusId & 0xFF), UInt8((bolusId >> 8) & 0xFF), 0, 0])
    }
}

struct CancelBolusResponse: TandemResponse {
    static let opCode: UInt8 = 0xA1
    static let characteristic = TandemCharacteristicUUID.control
    static let isSigned = true

    let status: UInt8
    var success: Bool { status == 0 }

    init?(cargo: Data) {
        guard !cargo.isEmpty else { return nil }
        status = cargo[0]
    }
}
