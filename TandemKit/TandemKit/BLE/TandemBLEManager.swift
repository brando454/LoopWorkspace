import CoreBluetooth
import Foundation
import LoopKit
import os.log

// Central BLE manager for the Tandem Mobi.
// Owns the CBCentralManager and creates TandemPeripheralManager on connect.
final class TandemBLEManager: NSObject, CBCentralManagerDelegate, @unchecked Sendable {

    weak var pumpManager: TandemPumpManager?

    private var central: CBCentralManager?
    private let managerQueue = DispatchQueue(label: "com.loopandlearn.TandemKit.bleManagerQueue", qos: .utility)

    // Constructs the live CoreBluetooth central. Factored out so offline tests
    // can inject a factory that returns nil, avoiding the eager state-restoration
    // authorization probe that the CBCentralManagerOptionRestoreIdentifierKey
    // triggers — that probe SIGABRTs the bare xctest host on platforms where TCC
    // reads the usage description from the running executable (which the
    // command-line xctest agent lacks). Production keeps the restoring central.
    typealias CentralFactory = (_ delegate: CBCentralManagerDelegate, _ queue: DispatchQueue) -> CBCentralManager?

    private static let liveCentralFactory: CentralFactory = { delegate, queue in
        CBCentralManager(
            delegate: delegate,
            queue: queue,
            options: [CBCentralManagerOptionRestoreIdentifierKey: "com.loopandlearn.TandemKit.bleManager"]
        )
    }
    private var peripheral: CBPeripheral?
    private var peripheralManager: TandemPeripheralManager?
    private let logger = Logger(subsystem: "com.loopandlearn.TandemKit", category: "TandemBLEManager")

    private var connectCompletion: ((Error?) -> Void)?

    convenience init(pumpManager: TandemPumpManager) {
        self.init(pumpManager: pumpManager, centralFactory: TandemBLEManager.liveCentralFactory)
    }

    // Designated initializer. Production reaches it via the convenience init,
    // which supplies the live restoring central; tests inject a factory
    // returning nil so no authorization probe ever runs. When the factory
    // returns nil the manager exists but can never connect — ensureConnected
    // fails fast with .bluetoothNotAvailable.
    init(pumpManager: TandemPumpManager, centralFactory: CentralFactory) {
        self.pumpManager = pumpManager
        super.init()
        managerQueue.sync {
            self.central = centralFactory(self, managerQueue)
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

    // Called by TandemPeripheralManager once EC-JPAKE auth succeeds.
    func authenticationCompleted() {
        guard let completion = connectCompletion else { return }
        connectCompletion = nil
        completion(nil)
    }

    private func ensureConnected(_ completion: @escaping (Error?) -> Void) {
        // No live central (offline test construction): cannot connect.
        guard let central else {
            completion(TandemBLEError.bluetoothNotAvailable)
            return
        }
        // Require both BLE link AND completed auth before calling completion.
        if let p = peripheral, p.state == .connected,
           pumpManager?.state.connectionState == .connected {
            completion(nil)
            return
        }

        connectCompletion = completion

        if let p = peripheral {
            if p.state != .connected {
                central.connect(p)
            }
            // else: BLE link up but auth not yet done — wait for authenticationCompleted()
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
            pumpManager: pumpManager,
            queue: managerQueue
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
