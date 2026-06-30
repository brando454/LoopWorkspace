//  WP6/M5 test support: a PumpManagerDelegate that fences state mutations.
//
//  setPumpUnreachable enqueues pumpManagerDidUpdateState on delegateQueue from
//  inside its stateQueue block, so the state write happens-before this callback.
//  Tests set onUpdate, perform the mutation, await the expectation, then read
//  the flag — deterministic, no sleeps. The member surface mirrors the proven
//  MockPumpManagerDelegate in TandemPumpManagerReportingTests.swift (kept in a
//  separate file because that one is private to its test file).

import Foundation
import LoopKit

final class ReconnectFenceDelegate: PumpManagerDelegate {

    var onUpdate: (() -> Void)?

    func pumpManagerDidUpdateState(_ pumpManager: PumpManager) {
        onUpdate?()
    }

    // MARK: Unused PumpManagerDelegate requirements (mirrors the proven mock)

    func pumpManager(_ pumpManager: PumpManager,
                     hasNewPumpEvents events: [NewPumpEvent],
                     lastReconciliation: Date?,
                     replacePendingEvents: Bool,
                     completion: @escaping (_ error: Error?) -> Void) {
        completion(nil)
    }
    func pumpManagerBLEHeartbeatDidFire(_ pumpManager: PumpManager) {}
    func pumpManagerMustProvideBLEHeartbeat(_ pumpManager: PumpManager) -> Bool { false }
    func pumpManagerWillDeactivate(_ pumpManager: PumpManager) {}
    func pumpManagerPumpWasReplaced(_ pumpManager: PumpManager) {}
    func pumpManager(_ pumpManager: PumpManager, didUpdatePumpRecordsBasalProfileStartEvents pumpRecordsBasalProfileStartEvents: Bool) {}
    func pumpManager(_ pumpManager: PumpManager, didError error: PumpManagerError) {}
    func pumpManager(_ pumpManager: PumpManager,
                     didReadReservoirValue units: Double,
                     at date: Date,
                     completion: @escaping (_ result: Result<(newValue: ReservoirValue, lastValue: ReservoirValue?, areStoredValuesContinuous: Bool), Error>) -> Void) {}
    func pumpManager(_ pumpManager: PumpManager, didAdjustPumpClockBy adjustment: TimeInterval) {}
    func pumpManager(_ pumpManager: PumpManager,
                     didRequestBasalRateScheduleChange basalRateSchedule: BasalRateSchedule,
                     completion: @escaping (Error?) -> Void) {}
    func startDateToFilterNewPumpEvents(for manager: PumpManager) -> Date { .distantPast }
    var detectedSystemTimeOffset: TimeInterval { 0 }
    var automaticDosingEnabled: Bool { true }

    // MARK: PumpManagerStatusObserver
    func pumpManager(_ pumpManager: PumpManager, didUpdate status: PumpManagerStatus, oldStatus: PumpManagerStatus) {}

    // MARK: DeviceManagerDelegate
    func deviceManager(_ manager: DeviceManager,
                       logEventForDeviceIdentifier deviceIdentifier: String?,
                       type: DeviceLogEntryType,
                       message: String,
                       completion: ((Error?) -> Void)?) {}

    // MARK: AlertIssuer
    func issueAlert(_ alert: Alert) {}
    func retractAlert(identifier: Alert.Identifier) {}

    // MARK: PersistedAlertStore
    func doesIssuedAlertExist(identifier: Alert.Identifier, completion: @escaping (Swift.Result<Bool, Error>) -> Void) {}
    func lookupAllUnretracted(managerIdentifier: String, completion: @escaping (Swift.Result<[PersistedAlert], Error>) -> Void) {}
    func lookupAllUnacknowledgedUnretracted(managerIdentifier: String, completion: @escaping (Swift.Result<[PersistedAlert], Error>) -> Void) {}
    func recordRetractedAlert(_ alert: Alert, at date: Date) {}
}
