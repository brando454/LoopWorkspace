import XCTest
import Foundation
import CoreBluetooth
import LoopKit
@testable import TandemKit

// TandemHistoryLogEventTests
// --------------------------
// Two layers of the history-log slice 2:
//
//   1. HistoryLogEvent.decode — the typed per-typeId payload decoders (pumpX2
//      layouts; offsets payload-relative). Synthetic payloads including IEEE-754
//      float32 LE insulin fields.
//   2. Stream routing — unsolicited 0x81 frames on the historyLog characteristic
//      must reach historyLogStreamHandler through the REAL inbound path
//      (handleUpdatedValue -> receive -> reassemble -> dispatchResponse), built
//      as genuine wire frames via PacketFramer.serialize + chunk so CRC and
//      chunk-sequencing are exercised, not bypassed. Negative controls pin that
//      the branch keys on BOTH characteristic and opcode.
final class TandemHistoryLogEventTests: XCTestCase {

    // MARK: - Byte helpers

    private func u16LE(_ v: UInt16) -> [UInt8] { [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)] }
    private func u32LE(_ v: UInt32) -> [UInt8] {
        [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 24) & 0xFF)]
    }
    private func f32LE(_ v: Float) -> [UInt8] { u32LE(v.bitPattern) }

    // Build a 26-byte entry from a typeId and a 16-byte payload.
    private func entryBytes(typeId: UInt16, timeSec: UInt32 = 1000, seq: UInt32 = 5, payload: [UInt8]) -> [UInt8] {
        precondition(payload.count == 16)
        return u16LE(typeId) + u32LE(timeSec) + u32LE(seq) + payload
    }

    private func decode(typeId: UInt16, payload: [UInt8]) -> HistoryLogEvent {
        let entry = HistoryLogEntry(entry: Data(entryBytes(typeId: typeId, payload: payload)))!
        return HistoryLogEvent.decode(from: entry)
    }

    // MARK: - Event decoders

    func testBolusCompletedDecodesDeliveredAndRequestedFloats() {
        // entry offsets: statusId@10 bolusId@12 iob@14 delivered@18 requested@22
        // -> payload offsets 0 / 2 / 4 / 8 / 12
        let payload = u16LE(3) + u16LE(0x1234) + f32LE(1.5) + f32LE(2.45) + f32LE(2.5)
        let event = decode(typeId: 20, payload: payload)
        XCTAssertEqual(event, .bolusCompleted(completionStatusId: 3, bolusId: 0x1234,
                                              iob: 1.5, insulinDelivered: 2.45, insulinRequested: 2.5))
        // The safety-relevant distinction: delivered (2.45) differs from requested
        // (2.5) on a partial bolus, and each must land in its own field.
        if case let .bolusCompleted(_, _, _, delivered, requested) = event {
            XCTAssertLessThan(delivered, requested)
        }
    }

    func testTempRateActivatedDecodesPercentDurationAndId() {
        // entry offsets: percent@10 duration@14 tempRateId@20 -> payload 0 / 4 / 10
        // (payload bytes 8..9 are an undecoded gap in the pumpX2 layout)
        let payload = f32LE(150.0) + f32LE(90.0) + [0xEE, 0xEE] + u16LE(0x0BAD) + [0, 0, 0, 0]
        XCTAssertEqual(decode(typeId: 2, payload: payload),
                       .tempRateActivated(percent: 150.0, durationMinutes: 90.0, tempRateId: 0x0BAD))
    }

    func testTempRateCompletedDecodesIdAndTimeLeft() {
        // entry offsets: tempRateId@12 timeLeft@14 -> payload 2 / 4
        let payload = [0xEE, 0xEE] + u16LE(0x0BAD) + u32LE(600) + Array(repeating: 0 as UInt8, count: 8)
        XCTAssertEqual(decode(typeId: 15, payload: payload),
                       .tempRateCompleted(tempRateId: 0x0BAD, timeLeftSeconds: 600))
    }

    func testPumpingSuspendedDecodesAmountAndReason() {
        // entry offsets: insulinAmount@14 reasonId@16 -> payload 4 / 6
        let payload = [0xEE, 0xEE, 0xEE, 0xEE] + u16LE(250) + [6] + Array(repeating: 0 as UInt8, count: 9)
        XCTAssertEqual(decode(typeId: 11, payload: payload),
                       .pumpingSuspended(insulinAmount: 250, reasonId: 6))
    }

    func testPumpingResumedDecodesAmount() {
        // entry offset: insulinAmount@14 -> payload 4
        let payload = [0xEE, 0xEE, 0xEE, 0xEE] + u16LE(250) + Array(repeating: 0 as UInt8, count: 10)
        XCTAssertEqual(decode(typeId: 12, payload: payload), .pumpingResumed(insulinAmount: 250))
    }

    func testUnknownTypeIdIsUnrecognizedNotDropped() {
        XCTAssertEqual(decode(typeId: 999, payload: Array(repeating: 0, count: 16)),
                       .unrecognized(typeId: 999))
    }

    // MARK: - ACK response

    func testHistoryLogResponseDecodesStatusAndStreamId() {
        let ok = HistoryLogResponse(cargo: Data([0x00, 0x2A]))
        XCTAssertEqual(ok?.isSuccess, true)
        XCTAssertEqual(ok?.streamId, 0x2A)
        XCTAssertEqual(HistoryLogResponse(cargo: Data([0x01, 0x00]))?.isSuccess, false)
        XCTAssertNil(HistoryLogResponse(cargo: Data([0x00])))
    }

    // MARK: - Stream routing through the real inbound path

    private final class RecordingPeripheral: TandemPeripheral {
        weak var delegate: CBPeripheralDelegate?
        let identifier = UUID()
        var services: [CBService]? { nil }
        func discoverCharacteristics(_ characteristicUUIDs: [CBUUID]?, for service: CBService) {}
        func setNotifyValue(_ enabled: Bool, for characteristic: CBCharacteristic) {}
        func readValue(for characteristic: CBCharacteristic) {}
        func writeValue(_ data: Data, for characteristic: CBCharacteristic, type: CBCharacteristicWriteType) {}
    }

    private func makeManager() -> (TandemPeripheralManager, TandemPumpManager) {
        let pumpManager = TandemPumpManager(state: TandemPumpState(basalRateSchedule: nil),
                                            centralFactory: { _, _ in nil })
        let bleManager = TandemBLEManager(pumpManager: pumpManager, centralFactory: { _, _ in nil })
        let pm = TandemPeripheralManager(
            peripheral: RecordingPeripheral(),
            bleManager: bleManager,
            pumpManager: pumpManager,
            queue: DispatchQueue(label: "test.TandemHistoryLogEvent")
        )
        return (pm, pumpManager)
    }

    // Serialize a frame exactly as the pump would (opCode/txId/len/cargo/CRC,
    // then 18-byte chunking) and feed the chunks through handleUpdatedValue.
    private func deliver(opCode: UInt8, cargo: Data, on uuid: CBUUID, to pm: TandemPeripheralManager) throws {
        let serialized = try PacketFramer.serialize(opCode: opCode, transactionId: 9, cargo: cargo)
        for chunk in PacketFramer.chunk(serialized: serialized, transactionId: 9, chunkSize: 18) {
            pm.handleUpdatedValue(for: uuid, data: chunk)
        }
    }

    func testStreamFrameOnHistoryLogCharReachesHandler() throws {
        let (pm, pumpManager) = makeManager()
        var received: HistoryLogStreamResponse?
        pm.historyLogStreamHandler = { received = $0 }

        let e = entryBytes(typeId: 20, timeSec: 777, seq: 42,
                           payload: u16LE(3) + u16LE(1) + f32LE(0) + f32LE(2.0) + f32LE(2.0))
        try deliver(opCode: 0x81, cargo: Data([1, 0x2A] + e),
                    on: TandemCharacteristicUUID.historyLog, to: pm)

        XCTAssertEqual(received?.streamId, 0x2A)
        XCTAssertEqual(received?.entries.count, 1)
        XCTAssertEqual(received?.entries.first?.sequenceNum, 42)
        XCTAssertEqual(received?.entries.first.map { HistoryLogEvent.decode(from: $0) },
                       .bolusCompleted(completionStatusId: 3, bolusId: 1,
                                       iob: 0, insulinDelivered: 2.0, insulinRequested: 2.0))
        withExtendedLifetime(pumpManager) {}
    }

    func testStreamOpcodeOnOtherCharacteristicDoesNotReachHandler() throws {
        // 0xA5 on currentStatus is LastBolusStatusV2Response — same-opcode
        // collisions are why routing keys on the (characteristic, opCode) pair.
        let (pm, pumpManager) = makeManager()
        var callCount = 0
        pm.historyLogStreamHandler = { _ in callCount += 1 }

        let e = entryBytes(typeId: 20, payload: Array(repeating: 0, count: 16))
        try deliver(opCode: 0x81, cargo: Data([1, 0x2A] + e),
                    on: TandemCharacteristicUUID.currentStatus, to: pm)

        XCTAssertEqual(callCount, 0, "0x81 on a non-historyLog characteristic must not hit the stream handler")
        withExtendedLifetime(pumpManager) {}
    }

    func testNonStreamOpcodeOnHistoryLogCharDoesNotReachHandler() throws {
        let (pm, pumpManager) = makeManager()
        var callCount = 0
        pm.historyLogStreamHandler = { _ in callCount += 1 }

        try deliver(opCode: 0x3B, cargo: Data(count: 12),
                    on: TandemCharacteristicUUID.historyLog, to: pm)

        XCTAssertEqual(callCount, 0, "a non-0x81 opcode on the historyLog characteristic must not hit the stream handler")
        withExtendedLifetime(pumpManager) {}
    }

    func testMalformedStreamFrameIsDroppedNotDelivered() throws {
        // Claims 2 entries, carries 1 — the envelope invariant fails and the
        // frame must be dropped before the handler.
        let (pm, pumpManager) = makeManager()
        var callCount = 0
        pm.historyLogStreamHandler = { _ in callCount += 1 }

        let e = entryBytes(typeId: 20, payload: Array(repeating: 0, count: 16))
        try deliver(opCode: 0x81, cargo: Data([2, 0x2A] + e),
                    on: TandemCharacteristicUUID.historyLog, to: pm)

        XCTAssertEqual(callCount, 0, "an envelope-count mismatch must be dropped, not delivered")
        withExtendedLifetime(pumpManager) {}
    }
}
