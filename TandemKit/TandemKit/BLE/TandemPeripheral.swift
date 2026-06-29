import CoreBluetooth

// Construction seam over the CoreBluetooth peripheral (Option-A test-infrastructure
// follow-up). TandemPeripheralManager stores its peripheral as this protocol rather
// than as a concrete CBPeripheral so a test can construct the manager with a recording
// double and drive the real enactBolus exit-path logic offline. The peripheral stays a
// non-optional `let` on the manager; only its static type changes. This protocol does
// NOT carry bolus traffic — that flows through the injectable sendAndReceiveTransport
// closure, which sits above the low-level `send`/`writeValue` path. The protocol exists
// purely to make the object constructible; its write/discovery members are exercised
// only when the production transport runs.
//
// The surface is exactly the seven members TandemPeripheralManager invokes on its stored
// peripheral. CBPeripheral already implements all of them, so conformance is empty.
public protocol TandemPeripheral: AnyObject {
    // WP6/M1: peripheral UUID, used to scope per-pump Keychain secret keys.
    // CBPeripheral already provides `identifier`, so conformance stays empty.
    var identifier: UUID { get }
    var delegate: CBPeripheralDelegate? { get set }
    var services: [CBService]? { get }
    func discoverCharacteristics(_ characteristicUUIDs: [CBUUID]?, for service: CBService)
    func setNotifyValue(_ enabled: Bool, for characteristic: CBCharacteristic)
    func readValue(for characteristic: CBCharacteristic)
    func writeValue(_ data: Data, for characteristic: CBCharacteristic, type: CBCharacteristicWriteType)
}

extension CBPeripheral: TandemPeripheral {}