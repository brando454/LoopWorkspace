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

    // Serial queue that owns all CoreBluetooth callbacks for this connection.
    // Every mutation of `characteristics`, `receiveBuffers`, `pending`, and the
    // init-gate flags happens on this queue. This is what makes the
    // @unchecked Sendable conformance sound: the state is queue-confined, not
    // actually concurrent. CoreBluetooth delivers delegate callbacks here, and
    // we hop our own send/timeout work onto it.
    private let queue: DispatchQueue

    // Discovered characteristics keyed by UUID
    private var characteristics: [CBUUID: CBCharacteristic] = [:]

    // Pending request tracking, keyed on (responseCharacteristic, opCode) so
    // opcode collisions across characteristics cannot misroute responses.
    private let pending = PendingResponseTable()

    // Per-request timeout. If the pump never replies, the continuation would
    // otherwise leak and the operation would hang forever.
    private let requestTimeout: TimeInterval = 10

    // Receive buffer: accumulate chunks per characteristic
    private var receiveBuffers: [CBUUID: [Data]] = [:]

    private let txID = TransactionID()
    private var authState: TandemAuthState?

    // Initialization gate: auth starts when both flags are true.
    private var servicesDiscovered = false
    private var notificationsEnabled = false
    private var notificationsSubscribed = 0

    init(peripheral: CBPeripheral, bleManager: TandemBLEManager, pumpManager: TandemPumpManager, queue: DispatchQueue) {
        self.peripheral = peripheral
        self.bleManager = bleManager
        self.pumpManager = pumpManager
        self.queue = queue
        super.init()
        peripheral.delegate = self
    }

    func cleanup() {
        peripheral.delegate = nil
        pending.failAll(error: TandemBLEError.notConnected)
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
                let firstRequest = try self.authState!.begin()
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
            Task { [weak self] in
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
                        self.bleManager?.authenticationCompleted()
                    }
                } catch {
                    self.logger.error("Auth response error: \(error)")
                }
            }
            return
        }

        // Route to the pending request keyed on BOTH characteristic and opcode.
        // Matching on the pair is the fix for the opcode collision: e.g. 0xA5 is
        // SetTempRateResponse on CONTROL but LastBolusStatusV2Response on
        // CURRENT_STATUS, and only the (characteristic, opCode) pair tells them
        // apart. Called on `queue` (from `receive`, which runs on the CB queue).
        pending.resolve(characteristic: uuid, opCode: opCode, cargo: cargo)
    }

    // MARK: - High-level operations (called by TandemBLEManager)

    func fetchStatus(completion: @escaping (Error?) -> Void) {
        Task { [weak self] in
            guard let self, let pm = self.pumpManager else { return }
            do {
                let insulinData = try await sendAndReceive(InsulinStatusRequest(),
                                                          responseType: InsulinStatusResponse.self)
                let batteryData = try await sendAndReceive(CurrentBatteryV2Request(),
                                                          responseType: CurrentBatteryV2Response.self)
                let bolusData   = try await sendAndReceive(CurrentBolusStatusRequest(),
                                                          responseType: CurrentBolusStatusResponse.self)
                pm.updateState { state in
                    if let r = InsulinStatusResponse(cargo: insulinData) {
                        state.reservoirUnits = Double(r.currentUnits)
                    }
                    if let r = CurrentBatteryV2Response(cargo: batteryData) {
                        state.batteryPercent = r.batteryPercent
                    }
                    if let r = CurrentBolusStatusResponse(cargo: bolusData) {
                        if r.hasActiveBolus {
                            state.bolusState        = .inProgress
                            state.activeBolusId     = r.bolusId
                            state.activeBolusUnits  = Double(r.requestedVolumeMU) / 1000.0
                            state.activeBolusStartDate = r.timestamp
                        } else {
                            state.bolusState        = .noBolus
                            state.activeBolusId     = nil
                            state.activeBolusUnits  = nil
                            state.activeBolusStartDate = nil
                        }
                    }
                    state.lastSync = Date()
                }
                completion(nil)
            } catch {
                completion(error)
            }
        }
    }

    // Send a request and await its response cargo.
    //
    // The waiter is keyed on the RESPONSE type's characteristic + opCode (via
    // `Response.self`), so the response can only be matched by a reply arriving
    // on the correct characteristic. A timeout is armed on `queue`; if the pump
    // never replies, the waiter is failed with `.timeout` and removed, so the
    // continuation can never leak.
    //
    // All table mutation and the send happen on `queue`, keeping this request's
    // bookkeeping serialized with CoreBluetooth's callbacks.
    private func sendAndReceive<Response: TandemResponse>(
        _ request: some TandemRequest,
        responseType: Response.Type
    ) async throws -> Data {
        try await withCheckedThrowingContinuation { cont in
            queue.async { [weak self] in
                guard let self else {
                    cont.resume(throwing: TandemBLEError.notConnected)
                    return
                }

                // resumeOnce guards against double-resume: whichever of
                // response / timeout / send-error fires first wins; the rest
                // are no-ops because the table entry is already gone.
                let resumed = ResumeGuard()

                let token = self.pending.register(
                    characteristic: Response.characteristic,
                    opCode: Response.opCode
                ) { result in
                    guard resumed.tryConsume() else { return }
                    cont.resume(with: result)
                }

                // Arm timeout on the same queue.
                self.queue.asyncAfter(deadline: .now() + self.requestTimeout) { [weak self] in
                    guard let self else { return }
                    // fail() is a no-op if the entry was already resolved.
                    self.pending.fail(token: token, error: TandemBLEError.timeout)
                }

                // Send the request. If serialization/write fails, fail this exact
                // entry by token (not "first matching opcode").
                Task { [weak self] in
                    guard let self else { return }
                    do {
                        try await self.send(request)
                    } catch {
                        self.queue.async {
                            self.pending.fail(token: token, error: error)
                        }
                    }
                }
            }
        }
    }

    // Single-shot guard so a continuation is resumed exactly once.
    private final class ResumeGuard {
        private var consumed = false
        func tryConsume() -> Bool {
            if consumed { return false }
            consumed = true
            return true
        }
    }

    func enactBolus(units: Double, completion: @escaping (PumpManagerError?) -> Void) {
        Task { [weak self] in
            guard let self else { return }
            do {
                // Step 1: request permission and get bolusId
                let permData = try await sendAndReceive(BolusPermissionRequest(),
                                                       responseType: BolusPermissionResponse.self)
                guard let perm = BolusPermissionResponse(cargo: permData), perm.permissionGranted else {
                    completion(.communication(nil))
                    return
                }
                // Step 2: initiate the bolus using the granted bolusId
                let initData = try await sendAndReceive(InitiateBolusRequest(units: units, bolusId: perm.bolusId),
                                                       responseType: InitiateBolusResponse.self)
                guard let resp = InitiateBolusResponse(cargo: initData), resp.success else {
                    completion(.communication(nil))
                    return
                }
                completion(nil)
            } catch {
                completion(.communication(error as? LocalizedError))
            }
        }
    }

    func suspendDelivery(completion: @escaping (Error?) -> Void) {
        // Suspend via 0% temp rate for the maximum 72-hour duration.
        // Note: requires Control-IQ to be off on the pump.
        Task { [weak self] in
            guard let self else { return }
            do {
                let data = try await sendAndReceive(
                    SetTempRateRequest(durationMinutes: 4320, percent: 0),
                    responseType: SetTempRateResponse.self
                )
                guard let resp = SetTempRateResponse(cargo: data), resp.success else {
                    completion(PumpManagerError.communication(nil))
                    return
                }
                completion(nil)
            } catch {
                completion(error)
            }
        }
    }

    func resumeDelivery(completion: @escaping (Error?) -> Void) {
        Task { [weak self] in
            guard let self else { return }
            do {
                let data = try await sendAndReceive(StopTempRateRequest(),
                                                   responseType: StopTempRateResponse.self)
                guard let resp = StopTempRateResponse(cargo: data), resp.success else {
                    completion(PumpManagerError.communication(nil))
                    return
                }
                completion(nil)
            } catch {
                completion(error)
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
                completion(.failure(.communication(error as? LocalizedError)))
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
                completion(.communication(error as? LocalizedError))
            }
        }
    }
}
