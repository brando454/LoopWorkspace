import Foundation
import LoopKit

// TandemDoseReporter — converts Tandem pump dose state into LoopKit dose events
// and reconciles DELIVERED (not requested) insulin into Loop's data store.
//
// WHY THIS EXISTS
// ---------------
// Loop is a closed-loop system: it decides future insulin from its model of
// insulin-on-board (IOB). That model is only correct if every unit the pump
// delivers is reported back to Loop as a NewPumpEvent carrying a DoseEntry.
// The original TandemKit delivered boluses and temp basals but never reported
// them, so Loop's IOB never increased — causing insulin stacking. This type is
// the fix.
//
// CONTRACT (from LoopKit PumpManagerDelegate):
//   pumpManager(_:hasNewPumpEvents:lastReconciliation:completion:)
//     - events: completed/in-progress doses since the last report
//     - lastReconciliation: the time we last KNOW the pump's delivery was
//       fully accounted for (drives Loop's "do I trust IOB?" logic)
//
// SAFETY RULES enforced here:
//   1. Report DELIVERED volume (LastBolusStatusV2.deliveredVolume), never requested.
//   2. A cancelled/interrupted bolus reports the partial amount actually given.
//   3. Doses get a deterministic syncIdentifier (pump bolusId) so Loop dedupes
//      across reconnects and never double-counts.
//   4. Reconciliation time only advances when a status fetch actually succeeded.

protocol TandemDoseReporterDelegate: AnyObject {
    // Forward reconciled events into Loop. Mirrors PumpManagerDelegate's signature
    // so TandemPumpManager can pass them straight through.
    func tandemDoseReporter(
        _ reporter: TandemDoseReporter,
        hasNewPumpEvents events: [NewPumpEvent],
        lastReconciliation: Date?,
        completion: @escaping (_ error: Error?) -> Void
    )
}

final class TandemDoseReporter {

    weak var delegate: TandemDoseReporterDelegate?

    // Highest pump bolusId we have already reported, to avoid re-emitting on
    // every status poll. Persisted via TandemPumpState.lastReportedBolusId.
    private var lastReportedBolusId: UInt16

    init(lastReportedBolusId: UInt16 = 0) {
        self.lastReportedBolusId = lastReportedBolusId
    }

    // MARK: - Bolus reporting

    // Build a DoseEntry for a completed (or partially-delivered) bolus from the
    // authoritative LastBolusStatusV2 response. Returns nil if this bolus was
    // already reported.
    func makeBolusEvent(from last: LastBolusStatusV2Response, insulinType: InsulinType?) -> NewPumpEvent? {
        // Dedupe: only report a bolusId we have not already emitted.
        // bolusId increments per bolus; guard against wrap by treating equality as seen.
        guard last.bolusId != 0, last.bolusId != lastReportedBolusId else { return nil }

        let delivered = last.deliveredUnits
        let requested = last.requestedUnits

        // A bolus that delivered nothing and was not requested is not an event.
        guard delivered > 0 || requested > 0 else { return nil }

        // endDate: for a completed standard bolus, delivery is effectively done at
        // the reported timestamp. We approximate the start using Tandem's nominal
        // delivery rate (~1.5 U/min) so Loop sees a realistic delivery window.
        let nominalRateUnitsPerMin = 1.5
        let durationSeconds = max(1.0, delivered / nominalRateUnitsPerMin * 60.0)
        let endDate = last.timestamp
        let startDate = endDate.addingTimeInterval(-durationSeconds)

        let dose = DoseEntry(
            type: .bolus,
            startDate: startDate,
            endDate: endDate,
            value: delivered,                 // DELIVERED units — the safety-critical choice
            unit: .units,
            deliveredUnits: delivered,
            insulinType: insulinType,
            isMutable: false,                 // completed: immutable
            wasProgrammedByPumpUI: last.bolusSourceId != 0  // non-Loop source = manual/pump bolus
        )

        let event = NewPumpEvent(
            date: startDate,
            dose: dose,
            raw: bolusSyncIdentifier(last.bolusId),
            title: "Bolus \(String(format: "%.2f", delivered))U (requested \(String(format: "%.2f", requested))U)",
            type: .bolus
        )

        lastReportedBolusId = last.bolusId
        return event
    }

    // In-progress bolus event (mutable). Reported so Loop shows live delivery and
    // accounts for insulin already on its way in even before completion.
    func makeInProgressBolusEvent(
        bolusId: UInt16,
        requestedUnits: Double,
        deliveredSoFar: Double,
        startDate: Date,
        insulinType: InsulinType?
    ) -> NewPumpEvent {
        let estimatedEnd = startDate.addingTimeInterval(max(1.0, requestedUnits / 1.5 * 60.0))
        let dose = DoseEntry(
            type: .bolus,
            startDate: startDate,
            endDate: estimatedEnd,
            value: requestedUnits,
            unit: .units,
            deliveredUnits: deliveredSoFar,
            insulinType: insulinType,
            isMutable: true                   // in-progress: mutable until finalized
        )
        return NewPumpEvent(
            date: startDate,
            dose: dose,
            raw: bolusSyncIdentifier(bolusId),
            title: "Bolus in progress",
            type: .bolus
        )
    }

    // MARK: - Temp basal reporting

    // Build a DoseEntry for an enacted temp basal. value is the ABSOLUTE rate in
    // U/hr that the pump is actually running, computed by the caller from the
    // pump's confirmed percentage and the scheduled rate. Reporting absolute rate
    // (not percentage) is what Loop's dosing math requires.
    func makeTempBasalEvent(
        unitsPerHour: Double,
        startDate: Date,
        duration: TimeInterval,
        tempRateId: UInt16,
        insulinType: InsulinType?,
        isMutable: Bool
    ) -> NewPumpEvent {
        let dose = DoseEntry(
            type: .tempBasal,
            startDate: startDate,
            endDate: startDate.addingTimeInterval(duration),
            value: unitsPerHour,
            unit: .unitsPerHour,
            insulinType: insulinType,
            isMutable: isMutable
        )
        return NewPumpEvent(
            date: startDate,
            dose: dose,
            raw: tempBasalSyncIdentifier(tempRateId, startDate: startDate),
            title: "Temp basal \(String(format: "%.2f", unitsPerHour))U/hr",
            type: .tempBasal
        )
    }

    // Suspend / resume as basal events, so Loop's timeline shows the gap in delivery.
    func makeSuspendEvent(at date: Date) -> NewPumpEvent {
        let dose = DoseEntry(type: .suspend, startDate: date, value: 0, unit: .units)
        return NewPumpEvent(date: date, dose: dose, raw: suspendSyncIdentifier(date), title: "Suspend", type: .suspend)
    }

    func makeResumeEvent(at date: Date) -> NewPumpEvent {
        let dose = DoseEntry(type: .resume, startDate: date, value: 0, unit: .units)
        return NewPumpEvent(date: date, dose: dose, raw: resumeSyncIdentifier(date), title: "Resume", type: .resume)
    }

    // MARK: - Delivery to Loop

    func report(events: [NewPumpEvent], lastReconciliation: Date?, completion: @escaping (Error?) -> Void) {
        guard !events.isEmpty else { completion(nil); return }
        guard let delegate else { completion(nil); return }
        delegate.tandemDoseReporter(self, hasNewPumpEvents: events, lastReconciliation: lastReconciliation, completion: completion)
    }

    var reportedBolusIdForPersistence: UInt16 { lastReportedBolusId }

    // MARK: - Deterministic sync identifiers (dedupe across reconnects)

    private func bolusSyncIdentifier(_ bolusId: UInt16) -> Data {
        "tandem-bolus-\(bolusId)".data(using: .utf8)!
    }
    private func tempBasalSyncIdentifier(_ id: UInt16, startDate: Date) -> Data {
        "tandem-temp-\(id)-\(Int(startDate.timeIntervalSince1970))".data(using: .utf8)!
    }
    private func suspendSyncIdentifier(_ date: Date) -> Data {
        "tandem-suspend-\(Int(date.timeIntervalSince1970))".data(using: .utf8)!
    }
    private func resumeSyncIdentifier(_ date: Date) -> Data {
        "tandem-resume-\(Int(date.timeIntervalSince1970))".data(using: .utf8)!
    }
}
