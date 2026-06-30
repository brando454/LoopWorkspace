import LoopKit

public enum TandemBasalState: Int, Sendable {
    case active = 0
    case suspended = 1
    case tempBasal = 2
}

public enum TandemBolusState: Int, Sendable {
    case noBolus = 0
    case inProgress = 1
    case canceling = 2
}

public enum TandemConnectionState: Int, Sendable {
    case disconnected = 0
    case connecting = 1
    case authenticating = 2
    case connected = 3
}

/// H2 (TK-H2): policy for a requested temp rate whose computed percentage
/// exceeds the pump ceiling (250%). The prior code silently clamped to 250%
/// and reported success, so Loop believed it enacted the requested rate while
/// the pump delivered less and IOB drifted. This seam makes the behavior an
/// explicit, configurable choice rather than a hidden truncation.
public enum TempRateCeilingPolicy: Int, Sendable {
    /// Reject the over-ceiling request with an error so Loop knows its
    /// instruction was not honored and recomputes on the next cycle.
    case reject = 0
    /// Proceed at the clamped ceiling rate, but record the actually-enacted
    /// percent into state so basalDeliveryState reports the true enacted
    /// absolute rate back to Loop and IOB stays truthful.
    case reportEnactedRate = 1
}

public final class TandemPumpState: RawRepresentable, @unchecked Sendable {
    public typealias RawValue = PumpManager.RawStateValue

    // MARK: - Persisted state

    public var isOnboarded: Bool
    public var insulinType: InsulinType?
    public var lastSync: Date
    // WP6/M1: these three secrets are kept in memory for the auth path but are
    // NOT serialized into rawValue (the plaintext, unencrypted PumpManager
    // rawState). They persist in the iOS Keychain via SecretStore, keyed by the
    // BLE peripheral UUID. TandemPumpManager owns the connect-time migration
    // (read-through with legacy-plaintext fallback, then write-through).
    public var pairingCode: String        // 6-digit pairing code (Keychain-only; never in rawValue)
    public var derivedSecretHex: String?  // EC-JPAKE derived secret (Keychain-only; never in rawValue)
    public var serverNonce3Hex: String?   // stored alongside derivedSecretHex (Keychain-only)

    // Pump identity (from DIS at connect time)
    public var pumpSerialNumber: String
    public var firmwareVersion: String

    // Last known pump readings
    public var reservoirUnits: Double     // whole units
    public var batteryPercent: UInt8
    public var basalState: TandemBasalState
    public var bolusState: TandemBolusState
    public var activeTempRatePercent: UInt8?
    public var activeTempRateEndDate: Date?

    // Active bolus tracking
    public var activeBolusId: UInt16?
    public var activeBolusUnits: Double?
    public var activeBolusStartDate: Date?

    // Highest bolusId already reported to Loop; persisted so dose-event dedupe
    // survives app restarts (WP1 / TK-H6). Without persistence the reporter
    // would re-emit completed boluses after relaunch, inflating IOB.
    public var lastReportedBolusId: UInt16

    // Delivery limits
    public var maximumBasalRateUnitsPerHour: Double
    public var maximumBolusUnits: Double

    // Basal schedule
    public var basalRateSchedule: BasalRateSchedule?

    // MARK: - Non-persisted runtime state

    public var connectionState: TandemConnectionState = .disconnected
    public var authKey: Data?
    public var pumpTimeSinceReset: UInt32 = 0

    // WP6/M5: set true when bounded auto-reconnect exhausts its retry ceiling
    // without re-authenticating. Surfaced to Loop as a critical "Signal Loss"
    // pumpStatusHighlight. Cleared on the next successful auth. Transient
    // runtime state — never persisted to rawValue.
    public var pumpUnreachable: Bool = false

    // MARK: - Init

    public init(basalRateSchedule: BasalRateSchedule?) {
        isOnboarded = false
        insulinType = nil
        lastSync = .distantPast
        pairingCode = ""
        derivedSecretHex = nil
        serverNonce3Hex = nil
        pumpSerialNumber = ""
        firmwareVersion = ""
        reservoirUnits = 0
        batteryPercent = 0
        basalState = .active
        bolusState = .noBolus
        activeTempRatePercent = nil
        activeTempRateEndDate = nil
        activeBolusId = nil
        activeBolusUnits = nil
        activeBolusStartDate = nil
        lastReportedBolusId = 0
        maximumBasalRateUnitsPerHour = 15
        maximumBolusUnits = 25
        self.basalRateSchedule = basalRateSchedule
    }

    // MARK: - RawRepresentable

    public required init(rawValue: RawValue) {
        isOnboarded              = rawValue["isOnboarded"] as? Bool ?? false
        insulinType              = (rawValue["insulinType"] as? InsulinType.RawValue).flatMap(InsulinType.init)
        lastSync                 = rawValue["lastSync"] as? Date ?? .distantPast
        // WP6/M1: these reads are the legacy-plaintext FALLBACK only. Installs
        // paired under the old scheme still carry these keys in rawState; the
        // values land in memory here so TandemPumpManager's connect-time
        // migration can write them through to the Keychain and then they stop
        // being serialized (see rawValue getter). Post-migration rawState has
        // no such keys and these resolve to the empty/nil defaults.
        pairingCode              = rawValue["pairingCode"] as? String ?? ""
        derivedSecretHex         = rawValue["derivedSecretHex"] as? String
        serverNonce3Hex          = rawValue["serverNonce3Hex"] as? String
        pumpSerialNumber         = rawValue["pumpSerialNumber"] as? String ?? ""
        firmwareVersion          = rawValue["firmwareVersion"] as? String ?? ""
        reservoirUnits           = rawValue["reservoirUnits"] as? Double ?? 0
        batteryPercent           = rawValue["batteryPercent"] as? UInt8 ?? 0
        basalState               = (rawValue["basalState"] as? TandemBasalState.RawValue).flatMap(TandemBasalState.init) ?? .active
        bolusState               = (rawValue["bolusState"] as? TandemBolusState.RawValue).flatMap(TandemBolusState.init) ?? .noBolus
        activeTempRatePercent    = rawValue["activeTempRatePercent"] as? UInt8
        activeTempRateEndDate    = rawValue["activeTempRateEndDate"] as? Date
        activeBolusId            = rawValue["activeBolusId"] as? UInt16
        activeBolusUnits         = rawValue["activeBolusUnits"] as? Double
        activeBolusStartDate     = rawValue["activeBolusStartDate"] as? Date
        lastReportedBolusId      = rawValue["lastReportedBolusId"] as? UInt16 ?? 0
        maximumBasalRateUnitsPerHour = rawValue["maximumBasalRateUnitsPerHour"] as? Double ?? 15
        maximumBolusUnits        = rawValue["maximumBolusUnits"] as? Double ?? 25

        if let rawSchedule = rawValue["basalRateSchedule"] as? BasalRateSchedule.RawValue {
            basalRateSchedule = BasalRateSchedule(rawValue: rawSchedule)
        }
    }

    public var rawValue: RawValue {
        var v: [String: Any] = [:]
        v["isOnboarded"]          = isOnboarded
        v["insulinType"]          = insulinType?.rawValue
        v["lastSync"]             = lastSync
        // WP6/M1: pairingCode/derivedSecretHex/serverNonce3Hex are deliberately
        // NOT written here. They persist only in the Keychain via SecretStore.
        // Writing them to this plaintext dictionary is the defect M1 closes.
        v["pumpSerialNumber"]     = pumpSerialNumber
        v["firmwareVersion"]      = firmwareVersion
        v["reservoirUnits"]       = reservoirUnits
        v["batteryPercent"]       = batteryPercent
        v["basalState"]           = basalState.rawValue
        v["bolusState"]           = bolusState.rawValue
        v["activeTempRatePercent"] = activeTempRatePercent
        v["activeTempRateEndDate"] = activeTempRateEndDate
        v["activeBolusId"]        = activeBolusId
        v["activeBolusUnits"]     = activeBolusUnits
        v["activeBolusStartDate"] = activeBolusStartDate
        v["lastReportedBolusId"]  = lastReportedBolusId
        v["maximumBasalRateUnitsPerHour"] = maximumBasalRateUnitsPerHour
        v["maximumBolusUnits"]    = maximumBolusUnits
        v["basalRateSchedule"]    = basalRateSchedule?.rawValue
        return v
    }

    // MARK: - Computed

    public var basalDeliveryState: PumpManagerStatus.BasalDeliveryState {
        switch basalState {
        case .active:
            return .active(lastSync)
        case .suspended:
            return .suspended(lastSync)
        case .tempBasal:
            if let endDate = activeTempRateEndDate {
                let rate = Double(activeTempRatePercent ?? 100) / 100.0 *
                    (basalRateSchedule?.scheduledBasalRate(at: lastSync) ?? 0)
                let dose = DoseEntry(
                    type: .tempBasal,
                    startDate: lastSync,
                    endDate: endDate,
                    value: rate,
                    unit: .unitsPerHour
                )
                return .tempBasal(dose)
            }
            return .active(lastSync)
        }
    }

    public var bolusDeliveryState: PumpManagerStatus.BolusState {
        switch bolusState {
        case .noBolus:
            return .noBolus
        case .canceling:
            return .canceling
        case .inProgress:
            guard let units = activeBolusUnits, let start = activeBolusStartDate else {
                return .noBolus
            }
            let dose = DoseEntry(
                type: .bolus,
                startDate: start,
                value: units,
                unit: .units
            )
            return .inProgress(dose)
        }
    }
}

extension BasalRateSchedule {
    // H1 (TK-H1): the prior hand-rolled lookup used Calendar.current.startOfDay
    // and Date(), which selects the wrong segment when the schedule timeZone
    // differs from device locale and breaks across a DST boundary. LoopKit's
    // value(at:) honors the schedule's own timeZone and accepts the effective
    // date, so we route through it instead of recomputing elapsed-since-midnight.
    func scheduledBasalRate(at date: Date) -> Double {
        // LoopKit's value(at:) is between(date,date).first!, which force-unwraps.
        // A zero-width point query can return an empty interval at degenerate
        // offsets, trapping. Query the interval ourselves and fall back to the
        // first scheduled item rather than crashing the delivery path.
        if let match = between(start: date, end: date).first {
            return match.value
        }
        return items.first?.value ?? 0
    }
}
