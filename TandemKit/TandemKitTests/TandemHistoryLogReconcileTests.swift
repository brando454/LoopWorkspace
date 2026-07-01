import XCTest
import Foundation
import CoreBluetooth
import HealthKit
import LoopKit
@testable import TandemKit

// TandemHistoryLogReconcileTests
// ------------------------------
// Drives the events-only history-log reconcile end to end through the REAL
// reconcileHistoryLog / collectHistoryLogBatch / reportSuspendResume path, with
// the transport seam answering the status (0x3B) and fetch-ACK (0x3D) requests
// and injecting stream frames through the historyLogStreamHandler seam exactly
// as dispatchResponse would. Pins the three safety-relevant behaviors:
//
//   1. Seeding: a never-seeded watermark (0) is set to the pump's
//      lastSequenceNum WITHOUT reporting — pre-pairing history is not replayed.
//   2. Reporting + advance: suspended/resumed entries become .suspend/.resume
//      NewPumpEvents (replacePendingEvents: false, reconciliation = the entry's
//      pump timestamp) and the watermark advances to the last processed entry.
//   3. Confirm-before-persist: a delegate failure halts the reconcile and the
//      watermark does NOT advance, so the same entries re-fetch next poll.
final class TandemHistoryLogReconcileTests: XCTestCase {

    // MARK: - Byte helpers

    private func u16LE(_ v: UInt16) -> [UInt8] { [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)] }
    private func u32LE(_ v: UInt32) -> [UInt8] {
        [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 24) & 0xFF)]
    }

    private func entryBytes(typeId: UInt16, timeSec: UInt32, seq: UInt32) -> [UInt8] {
        // Suspend/resume payloads: insulinAmount@4, reasonId@6 (payload-relative);
        // filler elsewhere.
        var payload = Array(repeating: 0 as UInt8, count: 16)
        payload.replaceSubrange(4..<6, with: u16LE(100))
        payload[6] = 0
        return u16LE(typeId) + u32LE(timeSec) + u32LE(seq) + payload
    }

    private func streamResponse(entries: [[UInt8]], streamId: UInt8 = 7) -> HistoryLogStreamResponse {
        HistoryLogStreamResponse(cargo: Data([UInt8(entries.count), streamId] + entries.flatMap { $0 }))!
    }

    // MARK: - Fixture

    private final class RecordingPeripheral: TandemPeripheral {
        weak var delegate: CBPeripheralDelegate?
        let identifier = UUID()
        var services: [CBService]? { nil }
        func discoverCharacteristics(_ characteristicUUIDs: [CBUUID]?, for service: CBService) {}
        func setNotifyValue(_ enabled: Bool, for characteristic: CBCharacteristic) {}
        func readValue(for characteristic: CBCharacteristic) {}
        func writeValue(_ data: Data, for characteristic: CBCharacteristic, type: CBCharacteristicWriteType) {}
    }

    private struct Fixture {
        let pm: TandemPeripheralManager
        let pumpManager: TandemPumpManager
        let delegate: CapturingDelegate
        let queue: DispatchQueue
    }

    // Transport answers status/ACK by opCode; on a successful ACK the given
    // stream frames are injected onto the manager's queue, mirroring how
    // dispatchResponse delivers real frames after the ACK round-trip.
    private func makeFixture(
        watermark: UInt32,
        pumpLastSeq: UInt32,
        frames: [HistoryLogStreamResponse]
    ) -> Fixture {
        let state = TandemPumpState(basalRateSchedule: nil)
        state.lastHistoryLogSequenceNum = watermark
        let pumpManager = TandemPumpManager(state: state, centralFactory: { _, _ in nil })
        let delegate = CapturingDelegate()
        pumpManager.pumpManagerDelegate = delegate
        let bleManager = TandemBLEManager(pumpManager: pumpManager, centralFactory: { _, _ in nil })
        let queue = DispatchQueue(label: "test.TandemHistoryLogReconcile")
        let pm = TandemPeripheralManager(
            peripheral: RecordingPeripheral(),
            bleManager: bleManager,
            pumpManager: pumpManager,
            queue: queue
        )

        let statusCargo = Data(u32LE(pumpLastSeq) + u32LE(1) + u32LE(pumpLastSeq))
        pm.sendAndReceiveTransport = { [weak pm] _, _, opCode in
            switch opCode {
            case 0x3B:  // HistoryLogStatusResponse
                return statusCargo
            case 0x3D:  // HistoryLogResponse ACK -> then push the stream frames
                queue.async {
                    frames.forEach { pm?.historyLogStreamHandler?($0) }
                }
                return Data([0x00, 7])
            default:
                return Data([0x00])
            }
        }
        return Fixture(pm: pm, pumpManager: pumpManager, delegate: delegate, queue: queue)
    }

    private func awaitWatermark(_ expected: UInt32, on pumpManager: TandemPumpManager) {
        let exp = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in pumpManager.state.lastHistoryLogSequenceNum == expected },
            object: nil
        )
        wait(for: [exp], timeout: 3.0)
    }

    // MARK: - Tests

    func testFirstReconcileSeedsWatermarkWithoutReporting() async {
        let f = makeFixture(watermark: 0, pumpLastSeq: 100, frames: [])
        await f.pm.reconcileHistoryLog()
        awaitWatermark(100, on: f.pumpManager)
        XCTAssertEqual(f.delegate.eventCalls.count, 0,
                       "seeding must not replay pre-pairing history into Loop")
    }

    func testSuspendResumeEntriesReportedAndWatermarkAdvances() async {
        let suspendTime: UInt32 = 50_000
        let frames = [streamResponse(entries: [
            entryBytes(typeId: 11, timeSec: suspendTime, seq: 11),        // suspended
            entryBytes(typeId: 12, timeSec: suspendTime + 600, seq: 12),  // resumed
        ])]
        let f = makeFixture(watermark: 10, pumpLastSeq: 12, frames: frames)

        await f.pm.reconcileHistoryLog()
        awaitWatermark(12, on: f.pumpManager)

        XCTAssertEqual(f.delegate.eventCalls.count, 2, "one report per boundary entry")
        let types = f.delegate.eventCalls.compactMap { $0.events.first?.type }
        XCTAssertEqual(types, [.suspend, .resume], "suspend then resume, in sequence order")
        XCTAssertEqual(f.delegate.eventCalls.first?.reconciliation,
                       TandemEpoch.date(fromPumpSeconds: suspendTime),
                       "reconciliation must be the entry's pump-confirmed timestamp")
        XCTAssertEqual(f.delegate.eventCalls.first?.replacePending, false)
    }

    func testDelegateFailureHaltsAndDoesNotAdvanceWatermark() async {
        let frames = [streamResponse(entries: [
            entryBytes(typeId: 11, timeSec: 50_000, seq: 11),
        ])]
        let f = makeFixture(watermark: 10, pumpLastSeq: 11, frames: frames)
        f.delegate.completionError = TestError()

        await f.pm.reconcileHistoryLog()

        // Give any (incorrect) async watermark write a beat to land, then assert
        // it did not: confirm-before-persist means a failed report re-fetches.
        f.pumpManager.delegateQueue.sync {}
        XCTAssertEqual(f.delegate.eventCalls.count, 1, "the failing report was attempted once")
        XCTAssertEqual(f.pumpManager.state.lastHistoryLogSequenceNum, 10,
                       "watermark must NOT advance past an unconfirmed report")
    }

    func testNonBoundaryEntriesAdvanceWatermarkWithoutReporting() async {
        // A bolusCompleted entry (typeId 20) must NOT be reported by this path —
        // boluses stay on the LastBolusStatusV2 reconcile — but the watermark
        // still advances past it.
        let frames = [streamResponse(entries: [
            entryBytes(typeId: 20, timeSec: 50_000, seq: 11),
        ])]
        let f = makeFixture(watermark: 10, pumpLastSeq: 11, frames: frames)

        await f.pm.reconcileHistoryLog()
        awaitWatermark(11, on: f.pumpManager)
        XCTAssertEqual(f.delegate.eventCalls.count, 0,
                       "bolus entries are the LastBolusStatusV2 path's job — no report from history log")
    }

    private struct TestError: Error {}
}

// Minimal capturing PumpManagerDelegate (the reporting tests' mock is private to
// its file). Records every hasNewPumpEvents call; other requirements are no-ops.
private final class CapturingDelegate: PumpManagerDelegate {
    struct EventCall {
        let events: [NewPumpEvent]
        let reconciliation: Date?
        let replacePending: Bool
    }
    var eventCalls: [EventCall] = []
    var completionError: Error?

    func pumpManager(_ pumpManager: PumpManager,
                     hasNewPumpEvents events: [NewPumpEvent],
                     lastReconciliation: Date?,
                     replacePendingEvents: Bool,
                     completion: @escaping (_ error: Error?) -> Void) {
        eventCalls.append(EventCall(events: events, reconciliation: lastReconciliation, replacePending: replacePendingEvents))
        completion(completionError)
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
    func pumpManagerDidUpdateState(_ pumpManager: PumpManager) {}
    func pumpManager(_ pumpManager: PumpManager,
                     didRequestBasalRateScheduleChange basalRateSchedule: BasalRateSchedule,
                     completion: @escaping (Error?) -> Void) {}
    func startDateToFilterNewPumpEvents(for manager: PumpManager) -> Date { .distantPast }
    var detectedSystemTimeOffset: TimeInterval { 0 }
    var automaticDosingEnabled: Bool { true }
    func pumpManager(_ pumpManager: PumpManager, didUpdate status: PumpManagerStatus, oldStatus: PumpManagerStatus) {}
    func deviceManager(_ manager: DeviceManager,
                       logEventForDeviceIdentifier deviceIdentifier: String?,
                       type: DeviceLogEntryType,
                       message: String,
                       completion: ((Error?) -> Void)?) {}
    func issueAlert(_ alert: Alert) {}
    func retractAlert(identifier: Alert.Identifier) {}
    func doesIssuedAlertExist(identifier: Alert.Identifier, completion: @escaping (Swift.Result<Bool, Error>) -> Void) {}
    func lookupAllUnretracted(managerIdentifier: String, completion: @escaping (Swift.Result<[PersistedAlert], Error>) -> Void) {}
    func lookupAllUnacknowledgedUnretracted(managerIdentifier: String, completion: @escaping (Swift.Result<[PersistedAlert], Error>) -> Void) {}
    func recordRetractedAlert(_ alert: Alert, at date: Date) {}
}
