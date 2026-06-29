import CoreBluetooth
import Foundation

// Reservoir (insulin remaining). Note: response is in whole units, not milliunits.
struct InsulinStatusRequest: TandemRequest {
    static let opCode: UInt8 = 0x24  // 36

    func cargo() -> Data { Data() }
}

struct InsulinStatusResponse: TandemResponse {
    static let opCode: UInt8 = 0x25  // 37

    let currentUnits: UInt16    // whole units (NOT milliunits — this is the one exception)
    let isEstimate: Bool
    let lowAlertThresholdUnits: UInt8

    init?(cargo: Data) {
        guard cargo.count >= 4 else { return nil }
        currentUnits = UInt16(cargo[0]) | (UInt16(cargo[1]) << 8)
        isEstimate = cargo[2] != 0
        lowAlertThresholdUnits = cargo[3]
    }
}

// Battery status (use CurrentBatteryV2 for API > 2.1, which covers all Mobi).
struct CurrentBatteryV2Request: TandemRequest {
    static let opCode: UInt8 = 0x90  // -112 signed

    func cargo() -> Data { Data() }
}

struct CurrentBatteryV2Response: TandemResponse {
    static let opCode: UInt8 = 0x91  // -111 signed

    let batteryPercent: UInt8    // displayed percentage (batteryIbc field from pumpX2)
    let isCharging: Bool

    init?(cargo: Data) {
        guard cargo.count >= 3 else { return nil }
        batteryPercent = cargo[1]
        isCharging = cargo[2] != 0
    }
}

// Active bolus status.
struct CurrentBolusStatusRequest: TandemRequest {
    static let opCode: UInt8 = 0x2C  // 44

    func cargo() -> Data { Data() }
}

struct CurrentBolusStatusResponse: TandemResponse {
    static let opCode: UInt8 = 0x2D  // 45

    enum DeliveryStatus: UInt8 {
        case done        = 0
        case delivering  = 1
        case requesting  = 2
    }

    let deliveryStatus: DeliveryStatus
    let bolusId: UInt16
    let timestamp: Date
    let requestedVolumeMU: UInt32   // milliunits
    let bolusTypeBitmask: UInt8

    // WP6/L3: liveness rests on deliveryStatus ALONE. bolusId is the identifier
    // of the most recent bolus and stays non-zero after delivery finishes, so the
    // old bolusId-not-zero clause latched this to true forever once any bolus had
    // run, telling Loop a bolus was perpetually in progress. The parser defaults an
    // unrecognized status byte to .done (see init), so a garbled status reads as
    // no-active-bolus — the safe direction here: erring toward "not delivering"
    // rather than "forever in progress."
    var hasActiveBolus: Bool {
        deliveryStatus != .done
    }

    init?(cargo: Data) {
        guard cargo.count >= 15 else { return nil }
        deliveryStatus = DeliveryStatus(rawValue: cargo[0]) ?? .done
        bolusId = UInt16(cargo[1]) | (UInt16(cargo[2]) << 8)
        let tsRaw = UInt32(cargo[5]) | (UInt32(cargo[6]) << 8) |
                    (UInt32(cargo[7]) << 16) | (UInt32(cargo[8]) << 24)
        timestamp = TandemEpoch.date(fromPumpSeconds: tsRaw)
        requestedVolumeMU = UInt32(cargo[9]) | (UInt32(cargo[10]) << 8) |
                            (UInt32(cargo[11]) << 16) | (UInt32(cargo[12]) << 24)
        bolusTypeBitmask = cargo[14]
    }
}

// Qualifying events bitmask — key values for a pump manager.
struct QualifyingEventMask: OptionSet, Sendable {
    let rawValue: UInt32

    static let pumpSuspend       = QualifyingEventMask(rawValue: 1 << 6)   // 64
    static let pumpResume        = QualifyingEventMask(rawValue: 1 << 7)   // 128
    static let basalChange       = QualifyingEventMask(rawValue: 1 << 9)   // 512
    static let bolusChange       = QualifyingEventMask(rawValue: 1 << 10)  // 1024
    static let battery           = QualifyingEventMask(rawValue: 1 << 16)  // 65536
    static let remainingInsulin  = QualifyingEventMask(rawValue: 1 << 18)  // 262144
    static let homeScreenChange  = QualifyingEventMask(rawValue: 1 << 5)   // 32
    static let bolusPermissionRevoked = QualifyingEventMask(rawValue: 1 << 31)
}
