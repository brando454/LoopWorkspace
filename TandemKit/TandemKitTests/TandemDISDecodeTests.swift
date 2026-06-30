import XCTest
import CoreBluetooth
@testable import TandemKit

/// Unit coverage for the pure Device Information Service decode decision used by
/// TandemPeripheralManager.didUpdateValueFor. The delegate itself cannot be
/// driven in a unit test because CBCharacteristic has no public initializer, so
/// the decode logic was factored into the pure static decodeDISValue(uuid:data:).
/// These tests pin: serial (0x2A25) is accepted only as non-empty UTF-8; model
/// (0x2A24) is decoded for logging but never promoted to a stored value; every
/// other characteristic passes through to the Tandem framing path untouched.
final class TandemDISDecodeTests: XCTestCase {

    private let serialUUID = TandemCharacteristicUUID.serialNumber
    private let modelUUID  = TandemCharacteristicUUID.modelNumber

    func testSerialValidUTF8IsDecodedAndReturnedForStorage() {
        let data = Data("1003456789".utf8)
        let result = TandemPeripheralManager.decodeDISValue(uuid: serialUUID, data: data)
        XCTAssertEqual(result, .serial("1003456789"))
    }

    func testSerialEmptyDataIsRejectedNotStored() {
        let result = TandemPeripheralManager.decodeDISValue(uuid: serialUUID, data: Data())
        XCTAssertEqual(result, .serialUndecodable)
    }

    func testSerialNonUTF8IsRejectedNotStored() {
        // 0xFF 0xFE is not valid UTF-8; must not be stored as a serial.
        let result = TandemPeripheralManager.decodeDISValue(uuid: serialUUID, data: Data([0xFF, 0xFE]))
        XCTAssertEqual(result, .serialUndecodable)
    }

    func testModelValidUTF8IsDecodedButNotPromotedToSerial() {
        let data = Data("t:slim X2".utf8)
        let result = TandemPeripheralManager.decodeDISValue(uuid: modelUUID, data: data)
        XCTAssertEqual(result, .model("t:slim X2"))
    }

    func testModelNonUTF8YieldsModelNilStillNotPassthrough() {
        let result = TandemPeripheralManager.decodeDISValue(uuid: modelUUID, data: Data([0xFF, 0xFE]))
        XCTAssertEqual(result, .model(nil))
    }

    func testUnknownCharacteristicPassesThroughToFramingPath() {
        // The AUTHORIZATION characteristic must never be intercepted as a DIS read;
        // it has to reach receive(data:on:) for the handshake to work.
        let result = TandemPeripheralManager.decodeDISValue(
            uuid: TandemCharacteristicUUID.authorization,
            data: Data([0x00, 0x01, 0x02])
        )
        XCTAssertEqual(result, .passthrough)
    }
}
