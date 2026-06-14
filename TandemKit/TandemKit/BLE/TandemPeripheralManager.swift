import CoreBluetooth
import Foundation
import LoopKit
import os.log

// Per-connection peripheral delegate.
// Drives the 4-step initialization, then auth, then handles ongoing requests.
final class TandemPeripheralManager: NSObject, CBPeripheralDelegate, @unchecked Sendable {

    private let peripheral: CBPeripheral
    private weak var bleManager: TandemBLEManager?
    private weak var pumpManager: TandemPumpManager?
    private let logger = Logger(subsystem: "com.loopandlearn.TandemKit", category: "TandemPeripheralManager")

    // Discovered characteristics keyed by UUID
    private var characteristics: [CBUUID: CBCharacteristic] = [:]

    // Pending request tracking: (characteristic UUID, transactionId) → continuation
    private var pendingResponses: [(opCode: UInt8, continuation: CheckedContinuation<Data, Error>)] = []

    // Receive buffer: accumulate chunks per characteristic
    private var receiveBuffers: [CBUUID: [Data]] = [:]

    private let txID = TransactionID()
    private var authState: TandemAuthState?

    // Initialization gate: auth starts when both flags are true.
    private var servicesDiscovered = false
    private var notificationsEnabled = false
    private var notificationsSubscribed = 0

    init(peripheral: CBPeripheral, bleManager: TandemBLEManager, pumpManager: TandemPumpManager) {
        self.peripheral = peripheral
        self.bleManager = bleManager
        self.pumpManager = pumpManager
        super.init()
        peripheral.delegate = self
    }

    func cleanup() {
        peripheral.delegate = nil
        pendingResponses.forEach { $0.continuation.resume(throwing: TandemBLEError.notConnected) }
        pendingResponses.removeAll()
    }

    // MARK: - CBPeripheralDelegate

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard error == nil else { logger.error("Service discovery failed: \(error!)"); return }
        peripheral.services?.forEach { service in
            peripheral.discoverCharacteristics(nil, for: service)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard error == nil else { return }
        service.characteristics?.forEach { char in
            characteristics[char.uuid] = char
        }

        // Once TIP service characteristics are found, enable notifications and request MTU
        if service.uuid == TandemServiceUUID.tip {
            TandemCharacteristicUUID.allNotifiable.forEach { uuid in
                if let char = characteristics[uuid] {
                    peripheral.setNotifyValue(true, for: char)
                }
            }
            if let modelChar = characteristics[TandemCharacteristicUUID.modelNumber] {
                peripheral.readValue(for: modelChar)
            }
            servicesDiscovered = true
            checkInitializationComplete()
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard error == nil, characteristic.isNotifying else { return }
        notificationsSubscribed += 1
        if notificationsSubscribed >= TandemCharacteristicUUID.allNotifiable.count {
            notificationsEnabled = true
            checkInitializationComplete()
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard error == nil, let data = characteristic.value else { return }
        receive(data: data, on: characteristic.uuid)
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error = error {
            logger.error("Write to \(characteristic.uuid) failed: \(error)")
        }
    }

    // MARK: - Initialization gate

    private func checkInitializationComplete() {
        guard servicesDiscovered && notificationsEnabled else { return }
        startAuthentication()
    }

    // MARK: - Authentication

    private func startAuthentication() {
        guard let pm = pumpManager else { return }
        pm.updateState { $0.connectionState = .authenticating }

        authState = TandemAuthState(
            pairingCode: pm.state.pairingCode,
            derivedSecretHex: pm.state.derivedSecretHex,
            serverNonce3Hex: pm.state.serverNonce3Hex
        )

        Task { [weak self] in
            guard let self else { return }
            do {
                let firstRequest = try await MainActor.run { try self.authState!.begin() }
                try await self.send(firstRequest)
            } catch {
                self.logger.error("Auth failed: \(error)")
            }
        }
    }

    // MARK: - Send / receive

    func send(_ request: some TandemRequest) async throws {
        let txId = txID.next()
        let cargo = request.cargo()
        let chunkSize = (type(of: request).characteristic == TandemCharacteristicUUID.control)
            ? TandemMTU.controlChunk : TandemMTU.defaultChunk

        let serialized: Data
        if type(of: request).isSigned, let authKey = pumpManager?.state.authKey {
            serialized = PacketFramer.serializeSigned(
                opCode: type(of: request).opCode,
                transactionId: txId,
                cargo: cargo,
                authKey: authKey,
                timeSinceReset: pumpManager?.state.pumpTimeSinceReset ?? 0
            )
        } else {
            serialized = PacketFramer.serialize(
                opCode: type(of: request).opCode,
                transactionId: txId,
                cargo: cargo
            )
        }

        let chunks = PacketFramer.chunk(serialized: serialized, transactionId: txId, chunkSize: chunkSize)
        guard let char = characteristics[type(of: request).characteristic] else {
            throw TandemBLEError.notConnected
        }

        for chunk in chunks {
            peripheral.writeValue(chunk, for: char, type: .withResponse)
        }
    }

    private func receive(data: Data, on uuid: CBUUID) {
        guard data.count >= 2 else { return }
        let packetsRemaining = data[0]

        receiveBuffers[uuid, default: []].append(data)

        if packetsRemaining == 0 {
            var buffer = receiveBuffers[uuid] ?? []
            defer { receiveBuffers[uuid] = nil }

            guard let assembled = try? PacketFramer.reassemble(chunks: &buffer),
                  assembled.count >= 3 else { return }

            let opCode = assembled[0]
            let cargo = assembled.count > 3 ? assembled[3...] : Data()

            dispatchResponse(opCode: opCode, cargo: Data(cargo), on: uuid)
        }
    }

    private func dispatchResponse(opCode: UInt8, cargo: Data, on uuid: CBUUID) {
        // Check if this is an auth response
        if uuid == TandemCharacteristicUUID.authorization {
            Task { @MainActor [weak self] in
                guard let self, let authState = self.authState else { return }
                do {
                    if let nextRequest = try authState.handleResponse(opCode: opCode, cargo: cargo) {
                        try await self.send(nextRequest)
                    } else if case .authenticated = authState.state {
                        self.pumpManager?.updateState {
                            $0.authKey = authState.authKey
                            $0.derivedSecretHex = authState.derivedSecretHex
                            $0.serverNonce3Hex = authState.serverNonce3Hex
                            $0.connectionState = .connected
                        }
                    }
                } catch {
                    self.logger.error("Auth response error: \(error)")
                }
            }
            return
        }

        // Route to pending request continuation
        if let idx = pendingResponses.firstIndex(where: { $0.opCode == opCode }) {
            let cont = pendingResponses.remove(at: idx).continuation
            cont.resume(returning: cargo)
        }
    }

    // MARK: - High-level operations (called by TandemBLEManager)

    func fetchStatus(completion: @escaping (Error?) -> Void) {
        Task { [weak self] in
            guard let self, let pm = self.pumpManager else { return }
            do {
                try await self.send(InsulinStatusRequest())
                try await self.send(CurrentBatteryV2Request())
                try await self.send(CurrentBolusStatusRequest())
                pm.updateState { $0.lastSync = Date() }
                completion(nil)
            } catch {
                completion(error)
            }
        }
    }

    func enactBolus(units: Double, completion: @escaping (PumpManagerError?) -> Void) {
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.send(BolusPermissionRequest())
                // Response handling is asynchronous via dispatchResponse — full impl pending
                completion(nil)
            } catch {
                completion(.communication(error))
            }
        }
    }

    func cancelBolus(completion: @escaping (PumpManagerResult<DoseEntry?>) -> Void) {
        guard let bolusId = pumpManager?.state.activeBolusId else {
            completion(.success(nil))
            return
        }
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.send(CancelBolusRequest(bolusId: bolusId))
                completion(.success(nil))
            } catch {
                completion(.failure(.communication(error)))
            }
        }
    }

    func enactTempBasal(
        unitsPerHour: Double,
        duration: TimeInterval,
        completion: @escaping (PumpManagerError?) -> Void
    ) {
        guard let schedule = pumpManager?.state.basalRateSchedule else {
            completion(.configuration(nil))
            return
        }
        let currentRate = schedule.currentBasalRate()
        guard currentRate > 0 else { completion(.configuration(nil)); return }

        let percent = UInt16(min(250, max(0, (unitsPerHour / currentRate) * 100)))
        let durationMinutes = UInt32(duration / 60)

        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.send(SetTempRateRequest(durationMinutes: durationMinutes, percent: percent))
                completion(nil)
            } catch {
                completion(.communication(error))
            }
        }
    }
}
