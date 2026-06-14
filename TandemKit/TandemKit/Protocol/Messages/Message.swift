import CoreBluetooth
import Foundation

// Protocol that every Tandem BLE message type conforms to.
protocol TandemMessage: Sendable {
    // The 1-byte opcode identifying this message type on the wire.
    static var opCode: UInt8 { get }
    // Which BLE characteristic this message is sent on / received from.
    static var characteristic: CBUUID { get }
    // Whether this message is signed with HMAC-SHA1 on the CONTROL characteristic.
    static var isSigned: Bool { get }
    // Whether this message modifies insulin delivery (safety gate must be enabled).
    static var modifiesInsulinDelivery: Bool { get }
}

extension TandemMessage {
    static var isSigned: Bool { false }
    static var modifiesInsulinDelivery: Bool { false }
    static var characteristic: CBUUID { TandemCharacteristicUUID.currentStatus }
}

// A request message that can be serialized to bytes.
protocol TandemRequest: TandemMessage {
    func cargo() -> Data
}

// A response message that can be parsed from raw bytes.
protocol TandemResponse: TandemMessage {
    init?(cargo: Data)
}

// Tandem timestamps use the Jan 1, 2008 epoch (not Unix).
// Offset from Unix epoch: 2008-01-01T00:00:00Z = 1199145600 seconds.
enum TandemEpoch {
    static let offsetFromUnix: TimeInterval = 1_199_145_600

    static func date(fromPumpSeconds seconds: UInt32) -> Date {
        Date(timeIntervalSince1970: TimeInterval(seconds) + offsetFromUnix)
    }

    static func pumpSeconds(from date: Date) -> UInt32 {
        UInt32(max(0, date.timeIntervalSince1970 - offsetFromUnix))
    }
}
