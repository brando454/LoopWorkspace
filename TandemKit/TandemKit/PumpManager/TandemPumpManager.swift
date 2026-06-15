import HealthKit
import LoopKit
import os.log

// TandemPumpManager conforms to LoopKit's PumpManager protocol.
// BLE communication and auth are delegated to TandemBLEManager.
//
// NOTE: enactBolus, enactTempBasal, suspendDelivery, resumeDelivery are
// stubbed to .failure until the BLE layer and auth state machine are complete.
public final class TandemPumpManager: PumpManager {

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

    private(set) var state: TandemPumpState
    private let stateQueue = DispatchQueue(label: "com.loopandlearn.TandemKit.stateQueue", qos: .utility)
    private var statusObservers = WeakSynchronizedSet<PumpManagerStatusObserver>()
    private let logger = Logger(subsystem: "com.loopandlearn.TandemKit", category: "TandemPumpManager")
    private var bleManager: TandemBLEManager?

    // MARK: - Init

    public init(state: TandemPumpState) {
        self.state = state
        self.bleManager = TandemBLEManager(pumpManager: self)
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

    // MARK: - Data sync

    public func ensureCurrentPumpData(completion: ((_ lastSync: Date?) -> Void)?) {
        bleManager?.refreshStatus { [weak self] error in
            if let error = error {
                self?.logger.error("ensureCurrentPumpData failed: \(error)")
            }
            completion?(self?.state.lastSync)
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
        completion(PumpManagerError.configuration(nil))  // TODO: implement
    }

    public func resumeDelivery(completion: @escaping (_ error: Error?) -> Void) {
        completion(PumpManagerError.configuration(nil))  // TODO: implement
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

    // Internal: update state and notify Loop.
    func updateState(_ block: (TandemPumpState) -> Void) {
        stateQueue.async {
            block(self.state)
            self.delegateQueue.async {
                self.pumpManagerDelegate?.pumpManagerDidUpdateState(self)
            }
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

