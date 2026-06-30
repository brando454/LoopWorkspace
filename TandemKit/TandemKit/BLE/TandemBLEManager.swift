import CoreBluetooth
import Foundation
import LoopKit
import os.log

// Central BLE manager for the Tandem Mobi.
// Owns the CBCentralManager and creates TandemPeripheralManager on connect.
// WP6/M5: pure, radio-free backoff policy. Given a zero-based attempt index it
// returns either the delay before the next reconnect or .ceiling once the
// attempt budget is spent. Extracted from TandemBLEManager so the
// attempt/delay/ceiling logic is unit-testable without a live CBCentralManager
// (offline tests inject a nil central, which would otherwise short-circuit the
// scheduling path before any of this logic runs).
struct ReconnectBackoff: Equatable {
    let baseDelay: TimeInterval
    let maxDelay: TimeInterval
    let maxAttempts: Int

    enum Decision: Equatable {
        case retry(TimeInterval)
        case ceiling
    }

    // attempt is zero-based: 0 is the first reconnect after a disconnect.
    func decision(forAttempt attempt: Int) -> Decision {
        guard attempt < maxAttempts else { return .ceiling }
        let uncapped = baseDelay * pow(2.0, Double(attempt))
        return .retry(min(uncapped, maxDelay))
    }
}

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

    #if DEBUG
    // Observe-only diagnostic tap, forwarded to the per-connection peripheral
    // manager when one exists. Defaults to nil; production never sets it. Set
    // only by the reads-only TandemWireProbeDriver facade for handshake capture.
    var wireTap: ((WireDirection, Data) -> Void)? {
        didSet { peripheralManager?.wireTap = wireTap }
    }
    #endif

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

    // WP6/M5: bounded auto-reconnect with exponential backoff.
    //
    // The pre-M5 disconnect handler called central.connect(peripheral)
    // immediately and unconditionally. CoreBluetooth holds a pending connect
    // open with no timeout, so an out-of-range pump is paced by the radio and
    // does not spin. But a pump that links and then drops faster than EC-JPAKE
    // auth can complete — e.g. a bonding/encryption rejection surfaced as a
    // CBError — produces a tight connect→disconnect cycle CoreBluetooth does
    // NOT pace, because each cycle establishes a brief link. That is the spin
    // TK-M5 flags. We replace the immediate reconnect with a scheduled one whose
    // delay grows per consecutive failed attempt, and we stop after a ceiling so
    // an unrecoverable link surfaces to the user instead of retrying forever.
    //
    // The counter resets ONLY on authenticationCompleted() — full auth, not bare
    // BLE link-up — so a link-up/auth-fail oscillation still advances toward the
    // ceiling rather than resetting each cycle. All five fields are touched only
    // on managerQueue.
    private var reconnectAttempt = 0
    private var reconnectWork: DispatchWorkItem?
    // 2s base, doubling, capped at 60s, 8 attempts: 2,4,8,16,32,60,60,60 then
    // ceiling (~4 min before the pump is marked unreachable).
    private let reconnectBackoff = ReconnectBackoff(baseDelay: 2.0, maxDelay: 60.0, maxAttempts: 8)

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
        // WP6/M5: full auth is the only event that clears the reconnect budget.
        // Cancel any pending scheduled reconnect, zero the attempt counter, and
        // clear the terminal "unreachable" flag the ceiling may have set so the
        // Signal Loss highlight drops once we are talking to the pump again.
        cancelReconnect()
        reconnectAttempt = 0
        pumpManager?.setPumpUnreachable(false)
        guard let completion = connectCompletion else { return }
        connectCompletion = nil
        completion(nil)
    }

    // WP6/M5: schedule the next auto-reconnect with exponential backoff, or stop
    // at the ceiling. Runs on managerQueue (the centrals delegate queue), and
    // arms its DispatchWorkItem on the same queue, mirroring armPowerOnWatchdog.
    // Factored out so offline tests (which inject a nil central) can drive the
    // attempt/delay/ceiling logic without a live radio.
    private func scheduleReconnect() {
        guard let central, let peripheral else { return }

        switch reconnectBackoff.decision(forAttempt: reconnectAttempt) {
        case .ceiling:
            // Ceiling reached. Stop the spin and surface a terminal comms state
            // so Loop renders the pump as unreachable rather than silently
            // retrying forever. authenticationCompleted() clears this on the next
            // successful auth; an explicit ensureConnected() call also restarts
            // the cycle via central.connect.
            logger.error("Reconnect ceiling (\(self.reconnectBackoff.maxAttempts)) reached; marking pump unreachable")
            cancelReconnect()
            pumpManager?.setPumpUnreachable(true)

        case .retry(let delay):
            reconnectAttempt += 1
            let work = DispatchWorkItem { [weak self] in
                guard let self, let central = self.central, let peripheral = self.peripheral else { return }
                self.reconnectWork = nil
                central.connect(peripheral)
            }
            reconnectWork = work
            managerQueue.asyncAfter(deadline: .now() + delay, execute: work)
        }
    }

    // WP6/M5: cancel any pending scheduled reconnect. Idempotent.
    private func cancelReconnect() {
        reconnectWork?.cancel()
        reconnectWork = nil
    }

    private func ensureConnected(_ completion: @escaping (Error?) -> Void) {
        // No live central (offline test construction): cannot connect.
        guard let central else {
            completion(TandemBLEError.bluetoothNotAvailable)
            return
        }
        // WP6/M5: an explicit connect request supersedes any pending scheduled
        // backoff reconnect so the two cannot issue overlapping central.connect
        // calls. The attempt counter is intentionally NOT reset here — only a
        // successful auth (authenticationCompleted) clears the budget.
        cancelReconnect()
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
        #if DEBUG
        // Propagate the diagnostic observe-only tap to the new connection
        // (nil in production, so this is inert unless a probe has set it).
        peripheralManager?.wireTap = wireTap
        #endif
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
        // DIAG(WIRE): observe-only — surface the underlying CBError.Code so a
        // bonding/encryption rejection is distinguishable from a plain remote drop.
        if let cb = error as? CBError {
            logger.error("DIAG disconnect CBError.code=\(cb.code.rawValue) (\(cb.localizedDescription))")
        } else if let error = error {
            logger.error("DIAG disconnect non-CBError: \(error.localizedDescription)")
        } else {
            logger.info("DIAG disconnect clean (no error)")
        }
        logger.info("Disconnected: \(error?.localizedDescription ?? "clean")")
        peripheralManager?.cleanup()
        peripheralManager = nil
        pumpManager?.updateState { $0.connectionState = .disconnected }

        if let completion = connectCompletion {
            // An explicit ensureConnected() is in flight: fail it and let the
            // caller decide. Drop any pending scheduled reconnect so the two
            // paths cannot race.
            cancelReconnect()
            connectCompletion = nil
            completion(error)
        } else {
            // WP6/M5: bounded auto-reconnect. Schedule with backoff instead of an
            // immediate central.connect; at the ceiling this stops and marks the
            // pump unreachable.
            scheduleReconnect()
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
