import CoreBluetooth
import Foundation
import LoopKit
import os.log

#if DEBUG
// Direction of a frame on the wire, for the DEBUG-only `wireTap` diagnostic
// seam consumed by TandemWireProbeDriver. Gated out of release builds entirely.
public enum WireDirection {
    case outbound
    case inbound
}
#endif

// Per-connection peripheral delegate.
// Drives the 4-step initialization, then auth, then handles ongoing requests.
final class TandemPeripheralManager: NSObject, CBPeripheralDelegate, @unchecked Sendable {

    #if DEBUG
    // Observe-only DEBUG-only diagnostic tap, gated out of release builds.
    // Defaults to nil so every test is unaffected: nothing is invoked unless a
    // caller explicitly sets it. It returns Void and MUST never alter, drop,
    // filter, or reorder a frame — it is a passive tap, not a filter. Used only
    // by the reads-only TandemWireProbeDriver to capture handshake frames.
    var wireTap: ((WireDirection, Data) -> Void)?
    #endif

    private let peripheral: TandemPeripheral
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

    // Test-infrastructure seam. The single BLE send-and-receive I/O boundary,
    // expressed as a replaceable closure over an erased request plus the
    // RESPONSEs (characteristic, opCode). The real continuation / queue /
    // pending / timeout / send machinery is installed once in init, after
    // super.init(). It is a var ONLY so test setup can substitute a recording
    // mock; production sets it exactly once in init and never mutates it again,
    // which preserves the @unchecked Sendable contract (no concurrent writes).
    typealias SendAndReceiveTransport =
        (_ request: any TandemRequest, _ characteristic: CBUUID, _ opCode: UInt8) async throws -> Data

    var sendAndReceiveTransport: SendAndReceiveTransport = { _, _, _ in
        throw TandemBLEError.notConnected
    }

    // Receive buffer: accumulate chunks per characteristic
    private var receiveBuffers: [CBUUID: [Data]] = [:]

    private let txID = TransactionID()
    private var authState: TandemAuthState?

    // Auth-response serialization. CoreBluetooth callbacks arrive ordered on
    // `queue`, but the old per-response `Task` hop discarded that ordering and
    // raced concurrent handlers against the shared `authState`, intermittently
    // halting the handshake after RX 0x23. A single long-lived consumer Task
    // drains this stream and processes each response to completion — including
    // the `await send` of the follow-up — before pulling the next, restoring
    // strict arrival-order, one-at-a-time handling across suspension points.
    private var authResponseContinuation: AsyncStream<(UInt8, Data)>.Continuation?
    private var authConsumerTask: Task<Void, Never>?

    // Initialization gate: auth starts when both flags are true.
    private var servicesDiscovered = false
    private var notificationsEnabled = false
    private var notificationsSubscribed = 0

    init(peripheral: TandemPeripheral, bleManager: TandemBLEManager, pumpManager: TandemPumpManager, queue: DispatchQueue) {
        self.peripheral = peripheral
        self.bleManager = bleManager
        self.pumpManager = pumpManager
        self.queue = queue
        super.init()
        peripheral.delegate = self

        // Install the real transport (Option A seam). This is the FORMER body of
        // sendAndReceive<Response>, relocated verbatim: the only substitutions are
        // Response.characteristic -> characteristic and Response.opCode -> opCode,
        // which are now closure parameters. Captured weakly to avoid a retain cycle
        // (self stores this closure). Set once, here; never reassigned in production.
        sendAndReceiveTransport = { [weak self] request, characteristic, opCode in
            guard let self else { throw TandemBLEError.notConnected }
            return try await withCheckedThrowingContinuation { cont in
                self.queue.async { [weak self] in
                    guard let self else {
                        cont.resume(throwing: TandemBLEError.notConnected)
                        return
                    }

                    // resumeOnce guards against double-resume: whichever of
                    // response / timeout / send-error fires first wins; the rest
                    // are no-ops because the table entry is already gone.
                    let resumed = ResumeGuard()

                    let token = self.pending.register(
                        characteristic: characteristic,
                        opCode: opCode
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
    }

    func cleanup() {
        peripheral.delegate = nil
        pending.failAll(error: TandemBLEError.notConnected)
        authResponseContinuation?.finish()
        authResponseContinuation = nil
        authConsumerTask?.cancel()
        authConsumerTask = nil
    }

    // MARK: - CBPeripheralDelegate

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard error == nil else { logger.error("Service discovery failed: \(error!)"); return }
        #if DEBUG
        // DEBUG-only diagnostics: which services did the pump expose?
        logger.info("DIAG services: \((peripheral.services ?? []).map { $0.uuid.uuidString }.joined(separator: ", "))")
        #endif
        peripheral.services?.forEach { service in
            peripheral.discoverCharacteristics(nil, for: service)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard error == nil else { return }
        service.characteristics?.forEach { char in
            characteristics[char.uuid] = char
        }
        #if DEBUG
        // DEBUG-only diagnostics: which characteristics under this service?
        logger.info("DIAG chars for \(service.uuid.uuidString): \((service.characteristics ?? []).map { $0.uuid.uuidString }.joined(separator: ", "))")
        #endif

        // Once TIP service characteristics are found, enable notifications and request MTU
        if service.uuid == TandemServiceUUID.tip {
            #if DEBUG
            // DEBUG-only diagnostics: how many of allNotifiable are present?
            let present = TandemCharacteristicUUID.allNotifiable.filter { characteristics[$0] != nil }
            let missing = TandemCharacteristicUUID.allNotifiable.filter { characteristics[$0] == nil }
            logger.info("DIAG notifiable present \(present.count)/\(TandemCharacteristicUUID.allNotifiable.count); missing: \(missing.map { $0.uuidString }.joined(separator: ", "))")
            #endif
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
        #if DEBUG
        // DEBUG-only diagnostics: log every subscription result, including failures.
        if let error = error {
            logger.error("DIAG notify FAILED \(characteristic.uuid.uuidString): \(error.localizedDescription)")
        } else {
            logger.info("DIAG notify ok \(characteristic.uuid.uuidString) isNotifying=\(characteristic.isNotifying)")
        }
        #endif
        guard error == nil, characteristic.isNotifying else { return }
        notificationsSubscribed += 1
        #if DEBUG
        logger.info("DIAG notify count \(self.notificationsSubscribed)/\(TandemCharacteristicUUID.allNotifiable.count)")
        #endif
        // Gate auth on the AUTHORIZATION characteristic alone. The EC-JPAKE
        // handshake is self-contained on AUTHORIZATION (7B83FFF9): startAuthentication
        // writes the first request there and dispatchResponse drives every
        // subsequent step from inbound AUTHORIZATION frames, never reading any
        // other characteristic. The remaining subscriptions (status/control)
        // are needed later but must not block the handshake — counting the full
        // set stalled forever when the pump exposed fewer characteristics than
        // the list assumed.
        if characteristic.uuid == TandemCharacteristicUUID.authorization {
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

        let authState = TandemAuthState(
            pairingCode: pm.state.pairingCode,
            derivedSecretHex: pm.state.derivedSecretHex,
            serverNonce3Hex: pm.state.serverNonce3Hex
        )
        self.authState = authState

        // Tear down any prior handshake's consumer before starting a new one so a
        // reconnect mid-handshake cannot leave a stale consumer racing the new one.
        authConsumerTask?.cancel()
        authResponseContinuation?.finish()

        let stream = AsyncStream<(UInt8, Data)> { continuation in
            self.authResponseContinuation = continuation
        }

        // Single serialized consumer. Captures `authState` once (no per-response
        // optional read that could observe nil mid-handshake) and processes the
        // begin() request plus every response in strict order, one at a time.
        authConsumerTask = Task { [weak self] in
            guard let self else { return }
            do {
                let firstRequest = try authState.begin()
                try await self.send(firstRequest)
            } catch {
                #if DEBUG
                self.wireTap?(.inbound, Data("DIAG-AUTH-BEGIN-ERROR: \(error)".utf8))
                #endif
                self.logger.error("Auth failed: \(error)")
                return
            }

            for await (opCode, cargo) in stream {
                if Task.isCancelled { break }
                #if DEBUG
                // DEBUG-only diagnostics: dispatch entry trace in the serialized consumer.
                self.wireTap?(.inbound, Data("DIAG-DISPATCH-ENTER: op=\(String(format: "0x%02X", opCode)) state=\(authState.state)".utf8))
                #endif
                do {
                    if let nextRequest = try authState.handleResponse(opCode: opCode, cargo: cargo) {
                        #if DEBUG
                        self.wireTap?(.inbound, Data("DIAG-DISPATCH-NEXT: next=\(String(format: "0x%02X", type(of: nextRequest).opCode))".utf8))
                        #endif
                        try await self.send(nextRequest)
                    } else {
                        #if DEBUG
                        self.wireTap?(.inbound, Data("DIAG-DISPATCH-NIL: state=\(authState.state)".utf8))
                        #endif
                        if case .authenticated = authState.state {
                            self.pumpManager?.updateState {
                                $0.authKey = authState.authKey
                                $0.derivedSecretHex = authState.derivedSecretHex
                                $0.serverNonce3Hex = authState.serverNonce3Hex
                                $0.connectionState = .connected
                            }
                            self.bleManager?.authenticationCompleted()
                            break
                        }
                    }
                } catch {
                    #if DEBUG
                    self.wireTap?(.inbound, Data("DIAG-AUTH-RESP-ERROR: op=\(opCode) \(error)".utf8))
                    #endif
                    self.logger.error("Auth response error: \(error)")
                    break
                }
            }
        }
    }

    // MARK: - Send / receive

    func send(_ request: some TandemRequest) async throws {
        // TK-H5 central delivery-precondition gate. This is the single universal
        // write path: the production request/response transport closure calls
        // try await self.send(request) (see init), so guarding here covers both
        // fire-and-forget and request/response delivery from one chokepoint.
        try assertDeliveryPreconditions(for: request)

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
            // Observe-only: emit the exact serialized bytes going on the wire
            // (opCode/txId/length/cargo/CRC trailer), per chunk. Passive — fires
            // only when a diagnostic caller has set wireTap; never mutates.
            #if DEBUG
            wireTap?(.outbound, chunk)
            #endif
            peripheral.writeValue(chunk, for: char, type: .withResponse)
        }
    }

    // TK-H5: central precondition gate for insulin-delivery commands.
    //
    // Requests whose type sets modifiesInsulinDelivery == true may only be
    // transmitted when the pump is connected AND an authentication key is
    // present. Scope is connection-and-auth only by design: dose limits are
    // owned upstream by enactBolus/enactTempBasal and are not re-checked here.
    //
    // pumpManager is a weak reference. If it has deallocated we cannot read
    // connectionState or authKey, so a delivery request fails closed (throws)
    // rather than transmitting insulin against state we cannot verify. A
    // non-delivery request passes unconditionally regardless of pump-manager
    // liveness, connection, or auth.
    private func assertDeliveryPreconditions(for request: some TandemRequest) throws {
        guard type(of: request).modifiesInsulinDelivery else { return }

        guard let state = pumpManager?.state else {
            throw TandemBLEError.deliveryPreconditionUnmet("pump manager unavailable")
        }
        guard state.connectionState == .connected else {
            throw TandemBLEError.deliveryPreconditionUnmet("not connected")
        }
        guard state.authKey != nil else {
            throw TandemBLEError.deliveryPreconditionUnmet("missing auth key")
        }
    }

    private func receive(data: Data, on uuid: CBUUID) {
        // Observe-only: emit raw inbound bytes exactly as received, before any
        // length guard or reassembly. This is the spot where TK-WIRE1 used to
        // drop the pump's first frame silently. Passive; never mutates or drops.
        #if DEBUG
        wireTap?(.inbound, data)
        #endif
        guard data.count >= 2 else { return }
        let packetsRemaining = data[0]

        receiveBuffers[uuid, default: []].append(data)

        if packetsRemaining == 0 {
            var buffer = receiveBuffers[uuid] ?? []
            defer { receiveBuffers[uuid] = nil }

            // Reassemble the per-characteristic chunk buffer into a full frame.
            // The DEBUG-only traces below surface the three failure outcomes
            // (nil / throw / too-short) that a bare `try?` would have swallowed;
            // the surrounding control flow is unconditional in every build.
            let assembled: Data
            do {
                guard let result = try PacketFramer.reassemble(chunks: &buffer) else {
                    #if DEBUG
                    wireTap?(.inbound, Data("DIAG-REASM-NIL: reassemble returned nil".utf8))
                    #endif
                    return
                }
                assembled = result
            } catch {
                #if DEBUG
                wireTap?(.inbound, Data("DIAG-REASM-ERROR: \(error)".utf8))
                #endif
                return
            }
            guard assembled.count >= 3 else {
                #if DEBUG
                wireTap?(.inbound, Data("DIAG-REASM-SHORT: \(assembled.count)B".utf8))
                #endif
                return
            }
            #if DEBUG
            wireTap?(.inbound, Data("DIAG-REASM-OK: op=\(String(format: "0x%02X", assembled[0])) len=\(assembled.count)".utf8))
            #endif

            let opCode = assembled[0]
            let cargo = assembled.count > 3 ? assembled[3...] : Data()

            dispatchResponse(opCode: opCode, cargo: Data(cargo), on: uuid)
        }
    }

    private func dispatchResponse(opCode: UInt8, cargo: Data, on uuid: CBUUID) {
        // Check if this is an auth response
        if uuid == TandemCharacteristicUUID.authorization {
            // Hand the auth response to the single-consumer AsyncStream. The
            // yield itself is unconditional in every build; the DEBUG-only trace
            // records whether the continuation was live and whether the buffered
            // item was accepted, which is how the 0x23 delivery halt was found.
            #if DEBUG
            let hadCont = authResponseContinuation != nil
            let r = authResponseContinuation?.yield((opCode, cargo))
            wireTap?(.inbound, Data("DIAG-YIELD: op=\(String(format: "0x%02X", opCode)) cont=\(hadCont) result=\(String(describing: r))".utf8))
            #else
            authResponseContinuation?.yield((opCode, cargo))
            #endif
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

                // TK-H3/TK-C1: reconcile the most recently completed bolus into Loop.
                // Best-effort: a LastBolusStatus failure must not fail the status poll,
                // and an unreported bolus is retried next cycle (watermark unchanged).
                // Safe alongside the 0xA5 opcode collision with SetTempRateResponse:
                // routing is keyed on (characteristic, opCode) and no temp-rate request
                // is in flight during a status poll.
                if let lastBolusData = try? await sendAndReceive(LastBolusStatusV2Request(),
                                                                 responseType: LastBolusStatusV2Response.self),
                   let last = LastBolusStatusV2Response(cargo: lastBolusData) {
                    pm.reportCompletedBolus(from: last)
                }

                // TK-H3 (temp-basal half): best-effort active temp-rate read.
                // A failure here must NOT fail the poll, so it is awaited with
                // try? and detached from the status updateState above. The reporter
                // emits a mutable .tempBasal DoseEntry to Loop each cycle while a
                // temp rate runs. No temp-rate command is in flight during a poll,
                // so the (characteristic, opCode) routing stays unambiguous.
                if let tempData = try? await sendAndReceive(TempRateStatusRequest(),
                                                            responseType: TempRateStatusResponse.self),
                   let tempResp = TempRateStatusResponse(cargo: tempData) {
                    pm.reportActiveTempBasal(from: tempResp)
                }
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
    // Thin typed wrapper over the transport seam. Resolves the RESPONSE types
    // characteristic + opCode and forwards to sendAndReceiveTransport, which
    // holds the actual continuation / queue / pending / timeout / send machinery
    // (installed in init, replaceable by tests). Keeping THIS signature unchanged
    // is what lets every call site stay byte-for-byte identical -- only the body
    // moved into the closure.
    private func sendAndReceive<Response: TandemResponse>(
        _ request: some TandemRequest,
        responseType: Response.Type
    ) async throws -> Data {
        try await sendAndReceiveTransport(request, Response.characteristic, Response.opCode)
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
        // TK-C4: reject an invalid command BEFORE any pump traffic. A non-finite,
        // non-positive, or over-max dose, or one that rounds below the delivery
        // resolution, is a bad argument (.configuration) not a comms failure. The
        // over-max check is on the RAW units so rounding cannot pull it under.
        let maxUnits = pumpManager?.state.maximumBolusUnits ?? 25
        guard units.isFinite, units > 0, units <= maxUnits else {
            completion(.configuration(nil))
            return
        }
        guard let roundedUnits = InitiateBolusRequest.roundedToResolution(units) else {
            completion(.configuration(nil))
            return
        }
        Task { [weak self] in
            guard let self else { return }
            var grantedBolusId: UInt16?
            do {
                // Step 1: request permission and get bolusId
                let permData = try await sendAndReceive(BolusPermissionRequest(),
                                                       responseType: BolusPermissionResponse.self)
                guard let perm = BolusPermissionResponse(cargo: permData), perm.permissionGranted else {
                    completion(.communication(nil))
                    return
                }
                // The lock is held from here on; record it so every post-grant
                // exit releases it (TK-C5). A throw before this point holds no lock.
                grantedBolusId = perm.bolusId
                // Step 2: initiate the bolus using the granted, resolution-rounded dose.
                guard let initiate = InitiateBolusRequest(units: roundedUnits, bolusId: perm.bolusId) else {
                    // Defensive: roundedUnits is already finite and > 0, so this
                    // should not happen, but never leave the permission lock held.
                    await self.releasePermission(perm.bolusId)
                    completion(.configuration(nil))
                    return
                }
                let initData = try await sendAndReceive(initiate,
                                                       responseType: InitiateBolusResponse.self)
                guard let resp = InitiateBolusResponse(cargo: initData), resp.success else {
                    await self.releasePermission(perm.bolusId)
                    completion(.communication(nil))
                    return
                }
                // TK-C3: record the active bolus the instant it is enacted, so it is
                // cancellable (cancelBolus reads state.activeBolusId) before the next
                // status poll observes it.
                self.pumpManager?.updateState { state in
                    state.activeBolusId = perm.bolusId
                    // Track the dose the pump was actually told to deliver
                    // (resolution-rounded), not the raw command, so in-progress
                    // state matches delivery when the command is off the 0.05 grid.
                    state.activeBolusUnits = roundedUnits
                    state.activeBolusStartDate = Date()
                    state.bolusState = .inProgress
                }
                // TK-C5: release the permission lock on the confirmed-success exit
                // too. The lock is a pre-delivery gate, not a record of an in-flight
                // bolus; the active bolus is tracked by state above.
                await self.releasePermission(perm.bolusId)
                completion(nil)
            } catch {
                // TK-C5: if the throw happened after the lock was granted, release
                // it before reporting. A throw from the permission request itself
                // leaves grantedBolusId nil, so nothing is released (none was held).
                if let grantedBolusId {
                    await self.releasePermission(grantedBolusId)
                }
                completion(.communication(error as? LocalizedError))
            }
        }
    }

    // TK-C5: confirmed release of a granted bolus-permission lock. Awaits the
    // pump response and checks success; a non-ack or thrown error is LOGGED ONLY
    // and never alters the Loop-facing bolus outcome (it neither calls completion
    // nor returns a value). Invoked only on post-grant exits of enactBolus.
    private func releasePermission(_ bolusId: UInt16) async {
        do {
            let data = try await sendAndReceive(BolusPermissionReleaseRequest(bolusId: bolusId),
                                               responseType: BolusPermissionReleaseResponse.self)
            guard let resp = BolusPermissionReleaseResponse(cargo: data), resp.success else {
                logger.error("BolusPermissionRelease NACK for bolusId \(bolusId)")
                return
            }
        } catch {
            logger.error("BolusPermissionRelease failed for bolusId \(bolusId): \(error)")
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
                // Await and verify the pump CancelBolusResponse instead of
                // fire-and-forget. Loop must not be told the cancel succeeded
                // until the pump confirms it.
                let data = try await self.sendAndReceive(
                    CancelBolusRequest(bolusId: bolusId),
                    responseType: CancelBolusResponse.self
                )
                guard let resp = CancelBolusResponse(cargo: data), resp.success else {
                    // NACK or unparseable: leave IOB uncertain so Loop does not
                    // assume the bolus stopped.
                    completion(.failure(.communication(nil)))
                    return
                }
                // Confirmed cancel. Return no DoseEntry: Loop ignores the cancel
                // payload, and the partial delivered volume reconciles on the next
                // status poll via the bolus reporter watermark seam (separate path).
                completion(.success(nil))
            } catch {
                completion(.failure(.communication(error as? LocalizedError)))
            }
        }
    }

    func enactTempBasal(
        unitsPerHour: Double,
        duration: TimeInterval,
        at effectiveDate: Date = Date(),
        completion: @escaping (PumpManagerError?) -> Void
    ) {
        guard let schedule = pumpManager?.state.basalRateSchedule else {
            completion(.configuration(nil))
            return
        }
        // H1 (TK-H1): evaluate the scheduled rate at the dose's effective date
        // using the schedule's own timeZone, not Date() against device locale.
        let currentRate = schedule.scheduledBasalRate(at: effectiveDate)
        guard currentRate > 0 else { completion(.configuration(nil)); return }

        // H2 (TK-H2): compute the raw percentage and detect the over-ceiling
        // case explicitly instead of swallowing it inside a min(250,...) clamp.
        let rawPercent = max(0, (unitsPerHour / currentRate) * 100)
        let ceiling = 250.0
        let exceedsCeiling = rawPercent > ceiling
        let policy = pumpManager?.tempRateCeilingPolicy ?? .reject

        if exceedsCeiling && policy == .reject {
            // Tell Loop plainly the rate could not be honored so it recomputes,
            // rather than silently delivering less than requested.
            completion(.deviceState(TempRateCeilingError(
                requestedPercent: rawPercent,
                ceilingPercent: ceiling,
                requestedRate: unitsPerHour,
                scheduledRate: currentRate
            )))
            return
        }

        // Either within ceiling, or over-ceiling under .reportEnactedRate:
        // clamp to the ceiling for the wire command. When we clamped an
        // over-ceiling request, we will record the actually-enacted percent
        // into state on confirmed success so basalDeliveryState reports the
        // true enacted absolute rate to Loop.
        let enactedPercent = UInt16(min(ceiling, rawPercent))
        let durationMinutes = UInt32(duration / 60)
        let endDate = effectiveDate.addingTimeInterval(duration)

        Task { [weak self] in
            guard let self else { return }
            do {
                // Mirror suspend/resume: await SetTempRateResponse and gate
                // completion on resp.success instead of fire-and-forget. Confirm
                // only that the pump accepted the command \u2014 nothing more.
                let data = try await self.sendAndReceive(
                    SetTempRateRequest(durationMinutes: durationMinutes, percent: enactedPercent),
                    responseType: SetTempRateResponse.self
                )
                guard let resp = SetTempRateResponse(cargo: data), resp.success else {
                    completion(.communication(nil))
                    return
                }
                // H2: on confirmed success of a clamped over-ceiling request,
                // record the enacted percent and end date so the reported
                // absolute rate reflects what the pump actually delivers.
                if exceedsCeiling {
                    self.pumpManager?.updateState { state in
                        state.activeTempRatePercent = UInt8(min(250, enactedPercent))
                        state.activeTempRateEndDate = endDate
                        state.basalState = .tempBasal
                    }
                }
                completion(nil)
            } catch {
                completion(.communication(error as? LocalizedError))
            }
        }
    }
}

/// H2 (TK-H2): carried by .deviceState when an over-ceiling temp rate is
/// rejected, so the failure is diagnostic rather than opaque.
struct TempRateCeilingError: LocalizedError {
    let requestedPercent: Double
    let ceilingPercent: Double
    let requestedRate: Double
    let scheduledRate: Double

    var errorDescription: String? {
        String(
            format: "Requested temp rate %.3f U/hr is %.0f%% of the scheduled %.3f U/hr, exceeding the pump ceiling of %.0f%%.",
            requestedRate, requestedPercent, scheduledRate, ceilingPercent
        )
    }
}
