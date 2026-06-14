@preconcurrency import CoreBluetooth
import Foundation

// V2 (Mobi) J-PAKE authentication messages. All use the AUTHORIZATION characteristic.
// The handshake is 4 round-trips; rounds 1a/1b split the 330-byte client round 1 data.

struct Jpake1aRequest: TandemRequest {
    static let opCode: UInt8 = 0x20  // 32
    static let characteristic = TandemCharacteristicUUID.authorization

    let appInstanceId: UInt16
    let clientRound1Part1: Data   // bytes 0..<165 of EC-JPAKE client round 1 output

    func cargo() -> Data {
        var d = Data(count: 167)
        d[0] = UInt8(appInstanceId & 0xFF)
        d[1] = UInt8((appInstanceId >> 8) & 0xFF)
        d.replaceSubrange(2..., with: clientRound1Part1.prefix(165))
        return d
    }
}

struct Jpake1aResponse: TandemResponse {
    static let opCode: UInt8 = 0x21  // 33
    static let characteristic = TandemCharacteristicUUID.authorization

    let appInstanceId: UInt16
    let serverRound1Part1: Data   // 165 bytes

    init?(cargo: Data) {
        guard cargo.count >= 167 else { return nil }
        appInstanceId = UInt16(cargo[0]) | (UInt16(cargo[1]) << 8)
        serverRound1Part1 = cargo[2..<167]
    }
}

struct Jpake1bRequest: TandemRequest {
    static let opCode: UInt8 = 0x22  // 34
    static let characteristic = TandemCharacteristicUUID.authorization

    let appInstanceId: UInt16
    let clientRound1Part2: Data   // bytes 165..<330 of EC-JPAKE client round 1 output

    func cargo() -> Data {
        var d = Data(count: 167)
        d[0] = UInt8(appInstanceId & 0xFF)
        d[1] = UInt8((appInstanceId >> 8) & 0xFF)
        d.replaceSubrange(2..., with: clientRound1Part2.prefix(165))
        return d
    }
}

struct Jpake1bResponse: TandemResponse {
    static let opCode: UInt8 = 0x23  // 35
    static let characteristic = TandemCharacteristicUUID.authorization

    let appInstanceId: UInt16
    let serverRound1Part2: Data   // 165 bytes

    init?(cargo: Data) {
        guard cargo.count >= 167 else { return nil }
        appInstanceId = UInt16(cargo[0]) | (UInt16(cargo[1]) << 8)
        serverRound1Part2 = cargo[2..<167]
    }
}

struct Jpake2Request: TandemRequest {
    static let opCode: UInt8 = 0x24  // 36 (reuse of opCode 36 on AUTHORIZATION char; no conflict with InsulinStatusRequest on CURRENT_STATUS)
    static let characteristic = TandemCharacteristicUUID.authorization

    let appInstanceId: UInt16
    let clientRound2: Data        // 165 bytes of EC-JPAKE client round 2 output

    func cargo() -> Data {
        var d = Data(count: 167)
        d[0] = UInt8(appInstanceId & 0xFF)
        d[1] = UInt8((appInstanceId >> 8) & 0xFF)
        d.replaceSubrange(2..., with: clientRound2.prefix(165))
        return d
    }
}

struct Jpake2Response: TandemResponse {
    static let opCode: UInt8 = 0x25  // 37 (on AUTHORIZATION char)
    static let characteristic = TandemCharacteristicUUID.authorization

    let appInstanceId: UInt16
    let serverRound2: Data        // 168 bytes

    init?(cargo: Data) {
        guard cargo.count >= 170 else { return nil }
        appInstanceId = UInt16(cargo[0]) | (UInt16(cargo[1]) << 8)
        serverRound2 = cargo[2..<170]
    }
}

struct Jpake3SessionKeyRequest: TandemRequest {
    static let opCode: UInt8 = 0x26  // 38
    static let characteristic = TandemCharacteristicUUID.authorization

    func cargo() -> Data {
        Data([0x00, 0x00])  // challengeParam = 0
    }
}

struct Jpake3SessionKeyResponse: TandemResponse {
    static let opCode: UInt8 = 0x27  // 39
    static let characteristic = TandemCharacteristicUUID.authorization

    let appInstanceId: UInt16
    let serverNonce3: Data        // 8 bytes — stored for auth key derivation

    init?(cargo: Data) {
        guard cargo.count >= 18 else { return nil }
        appInstanceId = UInt16(cargo[0]) | (UInt16(cargo[1]) << 8)
        serverNonce3 = cargo[2..<10]
    }
}

struct Jpake4KeyConfirmationRequest: TandemRequest {
    static let opCode: UInt8 = 0x28  // 40
    static let characteristic = TandemCharacteristicUUID.authorization

    let appInstanceId: UInt16
    let clientNonce4: Data       // 8 random bytes
    let hashDigest: Data         // 32 bytes: HMAC-SHA256(data=clientNonce4, key=authKey)

    func cargo() -> Data {
        var d = Data(count: 50)
        d[0] = UInt8(appInstanceId & 0xFF)
        d[1] = UInt8((appInstanceId >> 8) & 0xFF)
        d.replaceSubrange(2..<10, with: clientNonce4.prefix(8))
        // bytes 10..17: reserved (0)
        d.replaceSubrange(18..<50, with: hashDigest.prefix(32))
        return d
    }
}

struct Jpake4KeyConfirmationResponse: TandemResponse {
    static let opCode: UInt8 = 0x29  // 41
    static let characteristic = TandemCharacteristicUUID.authorization

    let appInstanceId: UInt16
    let serverNonce4: Data        // 8 bytes
    let serverHashDigest4: Data   // 32 bytes — verify against HMAC-SHA256(data=serverNonce4, key=authKey)

    init?(cargo: Data) {
        guard cargo.count >= 50 else { return nil }
        appInstanceId = UInt16(cargo[0]) | (UInt16(cargo[1]) << 8)
        serverNonce4 = cargo[2..<10]
        serverHashDigest4 = cargo[18..<50]
    }
}
