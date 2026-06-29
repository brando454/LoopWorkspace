import Combine
import HealthKit
import LoopKit
import os.log

public final class TandemPumpManager: PumpManager, ObservableObject {

    // MARK: - PumpManager static requirements

    public static let pluginIdentifier = "TandemMobi"
    public static let localizedTitle = "Tandem Mobi"

    public static let onboardingMaximumBasalScheduleEntryCount = 48
    public static let onboardingSupportedBasalRates: [Double] = stride(from: 0.05, through: 15.0, by: 0.05).map { $0 }
    public static let onboardingSupportedBolusVolumes: [Double] = stride(from: 0.05, through: 25.0, by: 0.05).map { $0 }
    public static let onboardingSupportedMaximumBolusVolumes: [Double] = stride(from: 0.05, through: 25.0, by: 0.05).map { $0 }

    // MARK: - PumpManager instance requirements

    public var delegateQueue: DispatchQueue! = DispatchQueue(label: "com.loopandlearn.TandemKit.delegateQueue", qos: .utility)
    public weak var pumpManagerDelegate: PumpManagerDelegate?

    /// H2 (TK-H2): how to handle a temp rate whose computed percentage exceeds
    /// the pump ceiling. Defaults to .reject (conservative): an over-ceiling
    /// request fails so Loop recomputes, rather than silently capping. Settable
    /// at runtime to .reportEnactedRate to proceed at the ceiling and report the
    /// true enacted rate. Read by the peripheral manager in enactTempBasal.
    public var tempRateCeilingPolicy: TempRateCeilingPolicy = .reject

    public var supportedBasalRates: [Double] { TandemPumpManager.onboardingSupportedBasalRates }
    public var supportedBolusVolumes: [Double] { TandemPumpManager.onboardingSupportedBolusVolumes }
    public var supportedMaximumBolusVolumes: [Double] { TandemPumpManager.onboardingSupportedMaximumBolusVolumes }
    public var maximumBasalScheduleEntryCount: Int { TandemPumpManager.onboardingMaximumBasalScheduleEntryCount }
    public var minimumBasalScheduleEntryDuration: TimeInterval { TimeInterval(30 * 60) }
    public var pumpRecordsBasalProfileStartEvents: Bool { false }
    public var pumpReservoirCapacity: Double { 300 }

    public var isOnboarded: Bool { state.isOnboarded }
    public var localizedTitle: String { TandemPumpManager.localizedTitle }

    public var status: PumpManagerStatus {
        PumpManagerStatus(
            timeZone: .current,
            device: device,
            pumpBatteryChargeRemaining: Double(state.batteryPercent) / 100.0,
            basalDeliveryState: state.basalDeliveryState,
            bolusState: state.bolusDeliveryState,
            insulinType: state.insulinType
        )
    }

    public var lastSync: Date? { state.lastSync == .distantPast ? nil : state.lastSync }

    // MARK: - Internal

    public private(set) var state: TandemPumpState
    // WP6/M1: where the three pairing secrets persist. Defaults to the Keychain
    // in production; the offline migration suite injects an in-memory fake via
    // the test initializer. Mutable only through init so production cannot swap it.
    private var secretStore: SecretStore = KeychainSecretStore()
    private let stateQueue = DispatchQueue(label: "com.loopandlearn.TandemKit.stateQueue", qos: .utility)
    private var statusObservers = WeakSynchronizedSet<PumpManagerStatusObserver>()
    private let logger = Logger(subsystem: "com.loopandlearn.TandemKit", category: "TandemPumpManager")
    private var bleManager: TandemBLEManager?

    // MARK: - Init

    public init(state: TandemPumpState) {
        self.state = state
        self.bleManager = TandemBLEManager(pumpManager: self)
    }

    // Test seam: construct the internal BLE manager with an injected central
    // factory so offline tests can pass a nil-returning factory. No live
    // CoreBluetooth manager is built and no TCC authorization probe runs, which
    // would otherwise SIGABRT the bare xctest host. Internal, not public —
    // production always goes through init(state:) and keeps the live central.
    init(state: TandemPumpState, centralFactory: @escaping TandemBLEManager.CentralFactory) {
        self.state = state
        self.bleManager = TandemBLEManager(pumpManager: self, centralFactory: centralFactory)
    }

    // WP6/M1 test seam: inject an offline SecretStore (e.g. InMemorySecretStore)
    // so the secret-migration logic can be exercised without the iOS Keychain.
    // Internal, not public; production goes through init(state:) and keeps the
    // default KeychainSecretStore.
    init(state: TandemPumpState, secretStore: SecretStore) {
        self.state = state
        self.secretStore = secretStore
        // Use the nil-returning central factory so no CBCentralManager/auth probe
        // is constructed under xctest (the live convenience init traps in a test
        // host). Matches the pattern in init(state:centralFactory:).
        self.bleManager = TandemBLEManager(pumpManager: self, centralFactory: { _, _ in nil })
    }

    public convenience init?(rawState: RawStateValue) {
        self.init(state: TandemPumpState(rawValue: rawState))
    }

    public var rawState: RawStateValue { state.rawValue }

    // MARK: - Status observers

    public func addStatusObserver(_ observer: PumpManagerStatusObserver, queue: DispatchQueue) {
        statusObservers.insert(observer, queue: queue)
    }

    public func removeStatusObserver(_ observer: PumpManagerStatusObserver) {
        statusObservers.removeElement(observer)
    }

    func notifyStatusDidChange() {
        let currentStatus = self.status
        statusObservers.forEach { observer in
            observer.pumpManager(self, didUpdate: currentStatus, oldStatus: currentStatus)
        }
        delegateQueue.async { self.pumpManagerDelegate?.pumpManagerDidUpdateState(self) }
    }

    // MARK: - BLE heartbeat

    public func setMustProvideBLEHeartbeat(_ mustProvideBLEHeartbeat: Bool) {}

    // MARK: - Diagnostics (reads-only wire probe)
    //
    #if DEBUG
    // Internal plumbing for the TandemWireProbeDriver facade only. The wireTap
    // is an observe-only frame tap (nil in production); startDiagnosticHandshake
    // drives connect + EC-JPAKE auth then stops, issuing no delivery commands.
    // Nothing here writes insulin or exposes a delivery API.
    var wireTap: ((WireDirection, Data) -> Void)? {
        didSet { bleManager?.wireTap = wireTap }
    }
    #endif

    func startDiagnosticHandshake(completion: @escaping (Error?) -> Void) {
        bleManager?.connectAndAuthenticateOnly(completion: completion)
    }

    // MARK: - Data sync

    public func ensureCurrentPumpData(completion: ((_ lastSync: Date?) -> Void)?) {
        bleManager?.refreshStatus { [weak self] error in
            if let error = error {
                self?.logger.error("ensureCurrentPumpData failed: \(error)")
            }
            completion?(self?.state.lastSync)
        }
    }

    // MARK: - Delivered-dose reconciliation (TK-C1)

    // Reconcile the most recently completed bolus (from a status poll's
    // LastBolusStatusV2 read) into Loop. The reporter is re-seeded from the durable
    // watermark each cycle: on a successful delegate completion the watermark
    // advances (dedupe); on failure it does NOT, so the same bolus is re-reported
    // next poll. Re-reporting a deduped event is safe; under-reporting delivered
    // insulin is not (Loop would over-deliver). The optional completion fires after
    // the persist decision and exists for deterministic testing.
    func reportCompletedBolus(from last: LastBolusStatusV2Response, completion: (() -> Void)? = nil) {
        stateQueue.async { [weak self] in
            guard let self else { completion?(); return }

            // The reporter is intentionally PER-CYCLE local, not an instance var:
            // its watermark advances at makeBolusEvent build time and the fixed
            // reporter API exposes no reset/seed mutator, so the only way to honor
            // "re-seed from the durable watermark each cycle" is to construct a fresh
            // reporter seeded from state.lastReportedBolusId on each call.
            let reporter = TandemDoseReporter(lastReportedBolusId: self.state.lastReportedBolusId)
            reporter.delegate = self

            guard let event = reporter.makeBolusEvent(from: last, insulinType: self.state.insulinType) else {
                completion?()
                return
            }

            // lastReconciliation = the pump-confirmed delivery time of THIS bolus
            // (LastBolusStatusV2Response.timestamp), never phone poll time.
            let reconciliation = last.timestamp
            let advancedId = reporter.reportedBolusIdForPersistence

            reporter.report(events: [event], lastReconciliation: reconciliation) { [weak self] error in
                guard let self else { completion?(); return }
                self.stateQueue.async {
                    // Confirm-before-persist: advance the durable watermark ONLY on success.
                    if error == nil {
                        self.state.lastReportedBolusId = advancedId
                        self.delegateQueue.async { self.pumpManagerDelegate?.pumpManagerDidUpdateState(self) }
                    }
                    completion?()
                }
            }
        }
    }

    // MARK: - Bolus

    public func createBolusProgressReporter(reportingOn dispatchQueue: DispatchQueue) -> DoseProgressReporter? {
        TandemDoseProgressReporter(pumpManager: self, queue: dispatchQueue)
    }

    public func estimatedDuration(toBolus units: Double) -> TimeInterval {
        units / 1.5 * 60  // ~1.5 U/min typical Tandem delivery rate
    }

    public func enactBolus(
        units: Double,
        activationType: BolusActivationType,
        completion: @escaping (_ error: PumpManagerError?) -> Void
    ) {
        bleManager?.enactBolus(units: units, completion: completion)
    }

    public func cancelBolus(completion: @escaping (_ result: PumpManagerResult<DoseEntry?>) -> Void) {
        bleManager?.cancelBolus(completion: completion)
    }

    // MARK: - Basal

    public func enactTempBasal(
        unitsPerHour: Double,
        for duration: TimeInterval,
        completion: @escaping (_ error: PumpManagerError?) -> Void
    ) {
        bleManager?.enactTempBasal(unitsPerHour: unitsPerHour, duration: duration, completion: completion)
    }

    public func notifyDelegateOfDeactivation(completion: @escaping () -> Void) {
        delegateQueue.async {
            self.pumpManagerDelegate?.pumpManagerWillDeactivate(self)
            completion()
        }
    }

    public func suspendDelivery(completion: @escaping (_ error: Error?) -> Void) {
        bleManager?.suspendDelivery { [weak self] error in
            if error == nil {
                self?.updateState { $0.basalState = .suspended }
            }
            completion(error)
        }
    }

    public func resumeDelivery(completion: @escaping (_ error: Error?) -> Void) {
        bleManager?.resumeDelivery { [weak self] error in
            if error == nil {
                self?.updateState { $0.basalState = .active }
            }
            completion(error)
        }
    }

    public func syncBasalRateSchedule(
        items scheduleItems: [RepeatingScheduleValue<Double>],
        completion: @escaping (_ result: Result<BasalRateSchedule, Error>) -> Void
    ) {
        guard let schedule = BasalRateSchedule(dailyItems: scheduleItems) else {
            completion(.failure(PumpManagerError.configuration(nil)))
            return
        }
        stateQueue.async {
            self.state.basalRateSchedule = schedule
            self.delegateQueue.async {
                self.pumpManagerDelegate?.pumpManagerDidUpdateState(self)
                completion(.success(schedule))
            }
        }
    }

    public func syncDeliveryLimits(
        limits deliveryLimits: DeliveryLimits,
        completion: @escaping (_ result: Result<DeliveryLimits, Error>) -> Void
    ) {
        let iuPerHour = HKUnit.internationalUnit().unitDivided(by: .hour())
        stateQueue.async {
            if let max = deliveryLimits.maximumBasalRate?.doubleValue(for: iuPerHour) {
                self.state.maximumBasalRateUnitsPerHour = max
            }
            if let max = deliveryLimits.maximumBolus?.doubleValue(for: .internationalUnit()) {
                self.state.maximumBolusUnits = max
            }
            completion(.success(deliveryLimits))
        }
    }

    // MARK: - Dose reporting (temp basal)

    // Emit the pump currently-running temp basal to Loop as a mutable DoseEntry.
    // Called best-effort from the status poll once per cycle while a temp rate is
    // active. Intentionally SEPARATE from bolus reconciliation (which owns a
    // monotonic bolusId watermark): a temp basal is mutable while running and is
    // re-emitted each cycle with replacePendingEvents so LoopKit replaces the
    // prior pending copy rather than appending duplicates.
    func reportActiveTempBasal(from response: TempRateStatusResponse) {
        guard response.isActive else { return }
        guard let schedule = state.basalRateSchedule else { return }

        // The pump expresses a temp rate as a PERCENTAGE of scheduled basal, so
        // reconstruct the absolute U/hr Loop needs from the scheduled rate at the
        // pump-confirmed start. This emitted rate is only as accurate as the basal
        // schedule Loop has stored; if the on-pump schedule diverges, so will this.
        let scheduledRate = schedule.value(at: response.startDate)
        let unitsPerHour = Double(response.percentage) / 100.0 * scheduledRate
        let endDate = response.startDate.addingTimeInterval(TimeInterval(response.durationSeconds))

        let dose = DoseEntry(
            type: .tempBasal,
            startDate: response.startDate,
            endDate: endDate,
            value: unitsPerHour,
            unit: .unitsPerHour,
            insulinType: state.insulinType,
            isMutable: true
        )

        // Stable identity from tempRateId + pump-confirmed start so re-emits of the
        // same temp basal map to one event in Loop store.
        let raw = "tandem-temp-\(response.tempRateId)-\(Int(response.startDate.timeIntervalSince1970))"
            .data(using: .utf8)!
        let event = NewPumpEvent(
            date: response.startDate,
            dose: dose,
            raw: raw,
            title: "Temp basal \(String(format: "%.2f", unitsPerHour))U/hr",
            type: .tempBasal
        )

        delegateQueue.async {
            self.pumpManagerDelegate?.pumpManager(
                self,
                hasNewPumpEvents: [event],
                lastReconciliation: response.startDate,
                replacePendingEvents: true,
                completion: { _ in }
            )
        }
    }

    // TODO(WP2-followup): wire suspend/resume boundary markers off the pump
    // QualifyingEventMask (pumpSuspend bit 6 / pumpResume bit 7, defined in
    // StatusMessages.swift). As of WP2 that mask is ONLY a type definition with no
    // runtime consumer: nothing in the connection or notification flow decodes live
    // pump event bits, so there is no signal to drive suspend/resume from. Wiring
    // this up requires (1) a message or BLE notification that delivers the
    // qualifying-event bitmask at runtime, and (2) a subscriber that decodes
    // pumpSuspend/pumpResume and calls this with the pump-confirmed boundary time.
    // Note: suspendDelivery is implemented as a 72h 0% temp rate, so a genuine
    // suspend and a real 0% temp basal are indistinguishable to the reporter
    // without these event bits \u2014 which is why this is stubbed, not approximated.
    func reportSuspendResume(suspended: Bool, at date: Date) {
        // Intentionally unimplemented \u2014 see TODO(WP2-followup) above.
    }

    // MARK: - Helpers

    private var device: HKDevice {
        HKDevice(
            name: "Tandem Mobi",
            manufacturer: "Tandem Diabetes Care",
            model: "Mobi",
            hardwareVersion: nil,
            firmwareVersion: state.firmwareVersion,
            softwareVersion: nil,
            localIdentifier: state.pumpSerialNumber,
            udiDeviceIdentifier: nil
        )
    }

    // MARK: - WP6/M1 secret persistence (Keychain via SecretStore)

    // Per-pump service key, scoped by the BLE peripheral UUID. The UUID is known
    // at connect time and stable per pump per device. pumpSerialNumber would be
    // the portable key but is not populated from DIS today (WP6 follow-up).
    private func secretServiceKey(_ uuid: UUID, field: String) -> String {
        "com.loopandlearn.TandemKit.\(uuid.uuidString).\(field)"
    }

    // Connect-time migration. Reads each secret from the Keychain; on a miss,
    // falls back to any legacy plaintext value already hydrated into state from
    // rawState, then writes it through so the upgrade self-heals. After this
    // runs, the secrets live only in the Keychain (rawValue no longer
    // serializes them). Idempotent: a second call is a pure read-through.
    func migrateSecrets(peripheralUUID uuid: UUID) {
        stateQueue.async {
            self.runSecretMigration(uuid: uuid)
        }
    }

    // Synchronous variant for the auth-start path: the handshake reads the three
    // secrets immediately after to decide whether it can skip a full re-pair, so
    // migration must complete before that read. Runs the migration core on the
    // stateQueue and returns only when state reflects the Keychain values.
    func migrateSecretsSync(peripheralUUID uuid: UUID) {
        stateQueue.sync {
            self.runSecretMigration(uuid: uuid)
        }
    }

    // Synchronous core, factored out so tests can drive it directly on the
    // calling thread without the stateQueue hop. Reads through with fallback,
    // updates in-memory state, and persists the resolved values.
    func runSecretMigration(uuid: UUID) {
        let codeKey   = secretServiceKey(uuid, field: "pairingCode")
        let secretKey = secretServiceKey(uuid, field: "derivedSecretHex")
        let nonceKey  = secretServiceKey(uuid, field: "serverNonce3Hex")

        // pairingCode: empty string is treated as "absent" (the blank default).
        if let stored = secretStore.secret(forService: codeKey), !stored.isEmpty {
            state.pairingCode = stored
        } else if !state.pairingCode.isEmpty {
            secretStore.setSecret(state.pairingCode, forService: codeKey)
        }

        if let stored = secretStore.secret(forService: secretKey) {
            state.derivedSecretHex = stored
        } else if let legacy = state.derivedSecretHex {
            secretStore.setSecret(legacy, forService: secretKey)
        }

        if let stored = secretStore.secret(forService: nonceKey) {
            state.serverNonce3Hex = stored
        } else if let legacy = state.serverNonce3Hex {
            secretStore.setSecret(legacy, forService: nonceKey)
        }
    }

    // Write the current in-memory secrets through to the Keychain. Called after
    // a fresh handshake derives new secrets, so they survive the next launch
    // without ever touching the plaintext rawState.
    func persistSecrets(peripheralUUID uuid: UUID) {
        stateQueue.async {
            let codeKey   = self.secretServiceKey(uuid, field: "pairingCode")
            let secretKey = self.secretServiceKey(uuid, field: "derivedSecretHex")
            let nonceKey  = self.secretServiceKey(uuid, field: "serverNonce3Hex")
            self.secretStore.setSecret(self.state.pairingCode.isEmpty ? nil : self.state.pairingCode, forService: codeKey)
            self.secretStore.setSecret(self.state.derivedSecretHex, forService: secretKey)
            self.secretStore.setSecret(self.state.serverNonce3Hex, forService: nonceKey)
        }
    }

    // Internal: update state and notify Loop.
    func updateState(_ block: @escaping (TandemPumpState) -> Void) {
        stateQueue.async {
            block(self.state)
            self.delegateQueue.async {
                self.pumpManagerDelegate?.pumpManagerDidUpdateState(self)
            }
            DispatchQueue.main.async { self.objectWillChange.send() }
        }
    }
}

// MARK: - CustomDebugStringConvertible

extension TandemPumpManager: CustomDebugStringConvertible {
    public var debugDescription: String {
        "TandemPumpManager(serial: \(state.pumpSerialNumber), connection: \(state.connectionState))"
    }
}

// MARK: - AlertResponder

extension TandemPumpManager: AlertResponder {
    public func acknowledgeAlert(alertIdentifier: Alert.AlertIdentifier, completion: @escaping (Error?) -> Void) {
        completion(nil)
    }
}

// MARK: - AlertSoundVendor

extension TandemPumpManager: AlertSoundVendor {
    public func getSoundBaseURL() -> URL? { nil }
    public func getSounds() -> [Alert.Sound] { [] }
}

// MARK: - TandemDoseReporterDelegate

extension TandemPumpManager: TandemDoseReporterDelegate {
    // Forward reconciled events straight into Loop. Incremental single events use
    // replacePendingEvents: false (matches OmnipodKit's incremental reporting).
    func tandemDoseReporter(
        _ reporter: TandemDoseReporter,
        hasNewPumpEvents events: [NewPumpEvent],
        lastReconciliation: Date?,
        completion: @escaping (_ error: Error?) -> Void
    ) {
        delegateQueue.async {
            guard let delegate = self.pumpManagerDelegate else {
                completion(nil)
                return
            }
            delegate.pumpManager(
                self,
                hasNewPumpEvents: events,
                lastReconciliation: lastReconciliation,
                replacePendingEvents: false,
                completion: completion
            )
        }
    }
}

