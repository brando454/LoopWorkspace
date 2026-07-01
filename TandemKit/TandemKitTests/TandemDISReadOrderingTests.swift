import XCTest
import Foundation
import CoreBluetooth
import LoopKit
@testable import TandemKit

// TandemDISReadOrderingTests
// --------------------------
// Pins the Device Information Service read-ordering fix. The two DIS reads
// (0x2A24 model / 0x2A25 serial) belong to service 0x180A, which CoreBluetooth
// discovers on a SEPARATE didDiscoverCharacteristicsFor invocation than the TIP
// service (0xFDFB). While the reads sat in the TIP-service branch, the DIS
// characteristics were still unknown when that branch ran, both `if let` guards
// failed silently, and no read ever went out on the production connect path.
// The fix issues the reads from the deviceInformation-service branch instead.
//
// Construction seam (Option A): the peripheral manager stores its peripheral as
// the TandemPeripheral protocol. CBPeripheral (the type CoreBluetooth passes to
// the delegate) has no public initializer, so the delegate entry point cannot be
// invoked offline. The discovery core is therefore driven through
// handleDiscoveredCharacteristics(for:peripheral:), whose peripheral is the same
// TandemPeripheral seam — in production that IS the delegate's peripheral, so the
// behavior is identical. CBMutableService / CBMutableCharacteristic (which DO
// have public initializers) stand in for the discovered GATT objects.
final class TandemDISReadOrderingTests: XCTestCase {

    private let modelUUID  = TandemCharacteristicUUID.modelNumber   // 0x2A24
    private let serialUUID = TandemCharacteristicUUID.serialNumber  // 0x2A25

    // MARK: - Doubles

    // Records the characteristics readValue() was requested for, so a test can
    // assert exactly which reads the discovery core issued and on which callback.
    private final class RecordingPeripheral: TandemPeripheral {
        weak var delegate: CBPeripheralDelegate?
        let identifier = UUID()
        var services: [CBService]? { nil }
        private(set) var readUUIDs: [CBUUID] = []

        func discoverCharacteristics(_ characteristicUUIDs: [CBUUID]?, for service: CBService) {}
        func setNotifyValue(_ enabled: Bool, for characteristic: CBCharacteristic) {}
        func readValue(for characteristic: CBCharacteristic) { readUUIDs.append(characteristic.uuid) }
        func writeValue(_ data: Data, for characteristic: CBCharacteristic, type: CBCharacteristicWriteType) {}

        func reset() { readUUIDs.removeAll() }
    }

    // MARK: - Fixture

    private func makeManager(
        peripheral: RecordingPeripheral
    ) -> (TandemPeripheralManager, TandemPumpManager) {
        let state = TandemPumpState(basalRateSchedule: nil)
        // nil central factory: offline construction with no live CoreBluetooth
        // manager, matching the other integration tests.
        let pumpManager = TandemPumpManager(state: state, centralFactory: { _, _ in nil })
        let bleManager = TandemBLEManager(pumpManager: pumpManager, centralFactory: { _, _ in nil })
        let queue = DispatchQueue(label: "test.TandemDISReadOrdering")
        let pm = TandemPeripheralManager(
            peripheral: peripheral,
            bleManager: bleManager,
            pumpManager: pumpManager,
            queue: queue
        )
        return (pm, pumpManager)
    }

    private func readChar(_ uuid: CBUUID) -> CBMutableCharacteristic {
        CBMutableCharacteristic(type: uuid, properties: [.read], value: nil, permissions: [.readable])
    }

    private func service(_ uuid: CBUUID, chars: [CBUUID]) -> CBMutableService {
        let s = CBMutableService(type: uuid, primary: true)
        s.characteristics = chars.map { readChar($0) }
        return s
    }

    // MARK: - Ordering

    // The read must NOT be issued from the TIP-service callback (DIS chars are
    // unknown then), and MUST be issued for both 0x2A24 and 0x2A25 from the
    // deviceInformation-service callback.
    func testDISReadsIssuedOnDeviceInformationCallbackNotTIP() {
        let peripheral = RecordingPeripheral()
        let (pm, pumpManager) = makeManager(peripheral: peripheral)

        // TIP callback carries only a TIP characteristic (authorization). At this
        // point the DIS characteristics are not yet discovered.
        let tip = service(TandemServiceUUID.tip, chars: [TandemCharacteristicUUID.authorization])
        pm.handleDiscoveredCharacteristics(for: tip, peripheral: peripheral)
        XCTAssertFalse(peripheral.readUUIDs.contains(modelUUID),
                       "no model read may be issued on the TIP-service callback")
        XCTAssertFalse(peripheral.readUUIDs.contains(serialUUID),
                       "no serial read may be issued on the TIP-service callback")
        XCTAssertTrue(peripheral.readUUIDs.isEmpty,
                      "the TIP-service callback must issue no DIS reads at all")

        // DIS callback carries the model + serial characteristics.
        let dis = service(TandemServiceUUID.deviceInformation, chars: [modelUUID, serialUUID])
        pm.handleDiscoveredCharacteristics(for: dis, peripheral: peripheral)
        XCTAssertTrue(peripheral.readUUIDs.contains(modelUUID),
                      "model (0x2A24) must be read on the deviceInformation-service callback")
        XCTAssertTrue(peripheral.readUUIDs.contains(serialUUID),
                      "serial (0x2A25) must be read on the deviceInformation-service callback")

        withExtendedLifetime(pumpManager) {}
    }

    // Anti-regression for the exact bug: even once the DIS characteristics ARE
    // known, the TIP-service branch must never issue the reads — they are gated on
    // the deviceInformation-service branch, not merely on the characteristics being
    // present in the dictionary.
    func testTIPCallbackNeverIssuesDISReadEvenAfterCharsKnown() {
        let peripheral = RecordingPeripheral()
        let (pm, pumpManager) = makeManager(peripheral: peripheral)

        // Discover DIS first so both characteristics are known to the manager.
        let dis = service(TandemServiceUUID.deviceInformation, chars: [modelUUID, serialUUID])
        pm.handleDiscoveredCharacteristics(for: dis, peripheral: peripheral)
        XCTAssertEqual(peripheral.readUUIDs.count, 2, "DIS callback should issue exactly the two reads")

        peripheral.reset()

        // Now the TIP callback — with DIS chars already in the dict — must still
        // issue zero reads.
        let tip = service(TandemServiceUUID.tip, chars: [TandemCharacteristicUUID.authorization])
        pm.handleDiscoveredCharacteristics(for: tip, peripheral: peripheral)
        XCTAssertTrue(peripheral.readUUIDs.isEmpty,
                      "the TIP-service branch must never issue DIS reads, even once the chars are known")

        withExtendedLifetime(pumpManager) {}
    }

    // MARK: - Disposition (Change 2)

    // A decoded DIS serial must land in the diagnostic-only field and must NEVER
    // be written into pumpSerialNumber. "bi 883" is the real Mobi capture: a
    // fragment of the advertised BLE name, not the pump serial.
    func testDISSerialLandsInDiagnosticFieldNotPumpSerial() {
        let peripheral = RecordingPeripheral()
        let (pm, pumpManager) = makeManager(peripheral: peripheral)
        XCTAssertEqual(pumpManager.state.pumpSerialNumber, "", "precondition: serial identity empty")

        pm.handleUpdatedValue(for: serialUUID, data: Data("bi 883".utf8))

        // updateState mutates on the pump manager's stateQueue; poll the class-typed
        // state until the diagnostic field reflects the write.
        let landed = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in pumpManager.state.disReportedSerialRaw == "bi 883" },
            object: nil
        )
        wait(for: [landed], timeout: 2.0)

        XCTAssertEqual(pumpManager.state.disReportedSerialRaw, "bi 883",
                       "DIS serial must be captured into the diagnostic-only field")
        XCTAssertEqual(pumpManager.state.pumpSerialNumber, "",
                       "DIS serial must NEVER be written into the pumpSerialNumber identity field")
    }
}
