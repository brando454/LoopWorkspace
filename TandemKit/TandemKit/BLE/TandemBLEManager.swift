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

    // Observe-only diagnostic tap, forwarded to the per-connection peripheral
    // manager when one exists. Defaults to nil; production never sets it. Set
    // only by the reads-only TandemWireProbeDriver facade for handshake capture.
    var wireTap: ((WireDirection, Data) -> Void)? {
        didSet { peripheralManager?.wireTap = wireTap }
    }

    private let logger = Logger(subsystem: "com.loopandlearn.TandemKit", category: "TandemBLEManager")

    private var connectCompletion: ((Error?) -> Void)?

    // Set when ensureConnected is called before the central has reported
    // .poweredOn. A freshly built CBCentralManager reports .unknown until
    // CoreBluetooth asynchronously delivers the first centralManagerDidUpdateState.
    // Rather than spuriously failing an early caller with .bluetoothNotAvailable,
    // we stash the request and let centralManagerDidUpdateState start the scan
    // once power-on arrives. A watchdog fails the request if it never does.
    private var pendingScanOnPowerOn = false
    private var powerOnWatchdog: DispatchWorkItem?
    private let powerOnTimeout: TimeInterval = 5.0

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

    // Diagnostic-only entry point for the reads-only wire probe. Drives the
    // existing scan -> connect -> discover -> EC-JPAKE authenticate path and
    // then STOPS: it issues no application requests of its own (no status
    // reads, no delivery commands). It reuses ensureConnected, whose completion
    // fires via authenticationCompleted() exactly when auth has succeeded, so
    // the only frames placed on the wire are the handshake that
    // startAuthentication() drives automatically once services are discovered.
    func connectAndAuthenticateOnly(completion: @escaping (Error?) -> Void) {
        ensureConnected(completion)
    }

    // Called by TandemPeripheralManager once EC-JPAKE auth succeeds.
    func authenticationCompleted() {
        // The connection resolved; cancel any power-on watchdog so it cannot
        // later fail a future request. Harmless if none is armed.
        pendingScanOnPowerOn = false
        powerOnWatchdog?.cancel()
        powerOnWatchdog = nil
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

        switch central.state {
        case .poweredOn:
            break
        case .unknown, .resetting:
            // Transient: the central has not finished settling. Defer the scan;
            // centralManagerDidUpdateState will start it on .poweredOn. The
            // completion is already stored in connectCompletion above. Arm a
            // watchdog so a radio that never powers on fails rather than hangs.
            pendingScanOnPowerOn = true
            armPowerOnWatchdog()
            return
        case .poweredOff, .unauthorized, .unsupported:
            // Terminal: will not resolve on its own. Fail fast.
            connectCompletion = nil
            completion(TandemBLEError.bluetoothNotAvailable)
            return
        @unknown default:
            connectCompletion = nil
            completion(TandemBLEError.bluetoothNotAvailable)
            return
        }

        central.scanForPeripherals(
            withServices: [TandemServiceUUID.tip],
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
        )
    }

    // Starts the scan deferred by ensureConnected while the central was settling.
    private func startDeferredScan() {
        pendingScanOnPowerOn = false
        powerOnWatchdog?.cancel()
        powerOnWatchdog = nil
        central?.scanForPeripherals(
            withServices: [TandemServiceUUID.tip],
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
        )
    }

    private func armPowerOnWatchdog() {
        powerOnWatchdog?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.pendingScanOnPowerOn else { return }
            self.pendingScanOnPowerOn = false
            self.powerOnWatchdog = nil
            let completion = self.connectCompletion
            self.connectCompletion = nil
            completion?(TandemBLEError.bluetoothNotAvailable)
        }
        powerOnWatchdog = work
        managerQueue.asyncAfter(deadline: .now() + powerOnTimeout, execute: work)
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
        // Propagate the diagnostic observe-only tap to the new connection
        // (nil in production, so this is inert unless a probe has set it).
        peripheralManager?.wireTap = wireTap
        peripheral.discoverServices([TandemServiceUUID.tip, TandemServiceUUID.deviceInformation])
    }

    // MARK: - CBCentralManagerDelegate

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        logger.info("CBCentralManager state: \(central.state.rawValue)")

        if central.state == .poweredOn {
            if let p = peripheral, p.state != .connected {
                central.connect(p)
            }
            // Resume a scan that ensureConnected deferred while the central was
            // still settling (state .unknown/.resetting at the time of the call).
            if pendingScanOnPowerOn, peripheral == nil {
                startDeferredScan()
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

    // A Mobi advertises its model name followed by a unit-specific suffix, e.g.
    // "Tandem Mobi 883". The previous exact-equality match ("Tandem Mobi") never
    // matched a real unit, so discovery silently dropped every pump. Match by
    // prefix instead. The FDFB service-UUID scan filter already gates discovery,
    // so a prefix match is specific enough to never admit an unrelated device.
    func isTandemMobi(name: String, advertisementData: [String: Any]) -> Bool {
        name.hasPrefix(TandemAdvertisedName.mobi) || name.hasPrefix(TandemAdvertisedName.tslimX2)
    }
}

enum TandemBLEError: Error {
    case bluetoothNotAvailable
    case notConnected
    case timeout
    case noResponse
    // Raised by the central delivery-precondition gate (TK-H5) when a request
    // whose type sets modifiesInsulinDelivery == true is submitted while the
    // pump is not connected or has no authentication key. The associated
    // String names the failed precondition for diagnostics and is greppable
    // in logs. A delivery command must never transmit unless connection AND
    // auth are both established.
    case deliveryPreconditionUnmet(String)
}

extension TandemBLEError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .bluetoothNotAvailable:
            return "Bluetooth is not available."
        case .notConnected:
            return "The pump is not connected."
        case .timeout:
            return "The pump did not respond in time."
        case .noResponse:
            return "The pump returned no response."
        case .deliveryPreconditionUnmet(let reason):
            return "Delivery precondition not met: \(reason)"
        }
    }
}
