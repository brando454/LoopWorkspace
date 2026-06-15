import CoreBluetooth
import Foundation
import LoopKit
import os.log

// Central BLE manager for the Tandem Mobi.
// Owns the CBCentralManager and creates TandemPeripheralManager on connect.
final class TandemBLEManager: NSObject, CBCentralManagerDelegate, @unchecked Sendable {

    weak var pumpManager: TandemPumpManager?

    private var central: CBCentralManager!
    private let managerQueue = DispatchQueue(label: "com.loopandlearn.TandemKit.bleManagerQueue", qos: .utility)
    private var peripheral: CBPeripheral?
    private var peripheralManager: TandemPeripheralManager?
    private let logger = Logger(subsystem: "com.loopandlearn.TandemKit", category: "TandemBLEManager")

    private var connectCompletion: ((Error?) -> Void)?

    init(pumpManager: TandemPumpManager) {
        self.pumpManager = pumpManager
        super.init()
        managerQueue.sync {
            self.central = CBCentralManager(
                delegate: self,
                queue: managerQueue,
                options: [CBCentralManagerOptionRestoreIdentifierKey: "com.loopandlearn.TandemKit.bleManager"]
            )
        }
    }

    // MARK: - Public interface (called by TandemPumpManager)

    func refreshStatus(completion: @escaping (Error?) -> Void) {
        ensureConnected { [weak self] error in
            guard error == nil else { completion(error); return }
            self?.peripheralManager?.fetchStatus(completion: completion)
        }
    }

    func enactBolus(units: Double, completion: @escaping (PumpManagerError?) -> Void) {
        ensureConnected { [weak self] error in
            guard error == nil else {
                completion(.communication(error as? LocalizedError))
                return
            }
            self?.peripheralManager?.enactBolus(units: units, completion: completion)
        }
    }

    func cancelBolus(completion: @escaping (PumpManagerResult<DoseEntry?>) -> Void) {
        ensureConnected { [weak self] error in
            guard error == nil else {
                completion(.failure(.communication(error as? LocalizedError)))
                return
            }
            self?.peripheralManager?.cancelBolus(completion: completion)
        }
    }

    func enactTempBasal(
        unitsPerHour: Double,
        duration: TimeInterval,
        completion: @escaping (PumpManagerError?) -> Void
    ) {
        ensureConnected { [weak self] error in
            guard error == nil else {
                completion(.communication(error as? LocalizedError))
                return
            }
            self?.peripheralManager?.enactTempBasal(
                unitsPerHour: unitsPerHour,
                duration: duration,
                completion: completion
            )
        }
    }

    func suspendDelivery(completion: @escaping (Error?) -> Void) {
        ensureConnected { [weak self] error in
            guard error == nil else { completion(error); return }
            self?.peripheralManager?.suspendDelivery(completion: completion)
        }
    }

    func resumeDelivery(completion: @escaping (Error?) -> Void) {
        ensureConnected { [weak self] error in
            guard error == nil else { completion(error); return }
            self?.peripheralManager?.resumeDelivery(completion: completion)
        }
    }

    // MARK: - Connection management

    private func ensureConnected(_ completion: @escaping (Error?) -> Void) {
        if let p = peripheral, p.state == .connected {
            completion(nil)
            return
        }

        connectCompletion = completion

        if let p = peripheral {
            central.connect(p)
            return
        }

        // Check if already connected via another app (e.g., Tandem official app)
        let existing = central.retrieveConnectedPeripherals(withServices: [TandemServiceUUID.tip])
        if let p = existing.first {
            peripheral = p
            central.connect(p)
            return
        }

        guard central.state == .poweredOn else {
            completion(TandemBLEError.bluetoothNotAvailable)
            return
        }

        central.scanForPeripherals(
            withServices: [TandemServiceUUID.tip],
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
        )
    }

    private func handleConnected(_ peripheral: CBPeripheral) {
        guard let pumpManager else { return }
        self.peripheral = peripheral
        peripheralManager = TandemPeripheralManager(
            peripheral: peripheral,
            bleManager: self,
            pumpManager: pumpManager
        )
        peripheral.discoverServices([TandemServiceUUID.tip, TandemServiceUUID.deviceInformation])
    }

    // MARK: - CBCentralManagerDelegate

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        logger.info("CBCentralManager state: \(central.state.rawValue)")

        if central.state == .poweredOn {
            if let p = peripheral, p.state != .connected {
                central.connect(p)
            }
        }
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        guard let name = peripheral.name, isTandemMobi(name: name, advertisementData: advertisementData) else {
            return
        }
        logger.info("Discovered \(name), connecting…")
        central.stopScan()
        self.peripheral = peripheral
        central.connect(peripheral)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        logger.info("Connected to \(peripheral.name ?? "unknown")")
        handleConnected(peripheral)
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        logger.info("Disconnected: \(error?.localizedDescription ?? "clean")")
        peripheralManager?.cleanup()
        peripheralManager = nil
        pumpManager?.updateState { $0.connectionState = .disconnected }

        if let completion = connectCompletion {
            connectCompletion = nil
            completion(error)
        } else {
            // Auto-reconnect
            central.connect(peripheral)
        }
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        logger.error("Failed to connect: \(error?.localizedDescription ?? "unknown")")
        connectCompletion?(error)
        connectCompletion = nil
    }

    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        let peripherals = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral] ?? []
        self.peripheral = peripherals.first
    }

    // MARK: - Helpers

    private func isTandemMobi(name: String, advertisementData: [String: Any]) -> Bool {
        name == TandemAdvertisedName.mobi || name == TandemAdvertisedName.tslimX2
    }
}

enum TandemBLEError: Error {
    case bluetoothNotAvailable
    case notConnected
    case timeout
    case noResponse
}
