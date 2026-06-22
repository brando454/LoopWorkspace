# TandemKit Safety Audit — Pump Command, Dose Delivery & Dose Reporting Surface

**Date:** 2026-06-20
**Branch:** `tandem-mobi-integration`
**Auditor:** automated static review (identify-and-document only; no code modified, no fix applied)
**Scope:** TandemKit pump-command, dose-delivery, and dose-reporting surface for the Tandem Mobi BLE driver. The crypto/EC-JPAKE handshake layer was explicitly out of scope and was not reviewed.

> This is SAFETY-CRITICAL code. Findings below are characterized by **clinical impact** (potential to over- or under-deliver insulin, or to misreport delivered insulin to Loop's IOB model). This report drives the go/no-go decision for a live pump bench test. **Recommendation up front: do NOT bench-test against a live pump until at least all Critical findings are resolved.** See "Bench-test gating" at the end.

---

## Summary

### Files reviewed (all read in full)
- `TandemKit/TandemKit/PumpManager/TandemPumpManager.swift`
- `TandemKit/TandemKit/PumpManager/TandemPumpState.swift`
- `TandemKit/TandemKit/PumpManager/TandemDoseReporter.swift`
- `TandemKit/TandemKit/PumpManager/TandemDoseProgressReporter.swift`
- `TandemKit/TandemKit/BLE/TandemBLEManager.swift`
- `TandemKit/TandemKit/BLE/TandemPeripheralManager.swift`
- `TandemKit/TandemKit/BLE/PendingResponseTable.swift`
- `TandemKit/TandemKit/Protocol/Messages/Message.swift`
- `TandemKit/TandemKit/Protocol/Messages/Request/BolusMessages.swift`
- `TandemKit/TandemKit/Protocol/Messages/Request/LastBolusStatusMessages.swift`
- `TandemKit/TandemKit/Protocol/Messages/Request/StatusMessages.swift`
- `TandemKit/TandemKit/Protocol/Messages/Request/TempRateMessages.swift`
- `TandemKit/TandemKit/Protocol/Framing/PacketFramer.swift`
- `TandemKit/TandemKit/Protocol/Framing/TransactionID.swift`
- `TandemKit/TandemKit/Protocol/Crypto/CRC16.swift` (framing-relevant only)

### Findings by severity
| Severity | Count |
|----------|-------|
| Critical | 5 |
| High     | 6 |
| Medium   | 6 |
| Low      | 3 |
| **Total**| **20** |

### In-scope areas that could NOT be fully reviewed (and why)
1. **On-wire byte layouts vs. real pump firmware.** Encoding offsets (e.g. `InitiateBolusRequest.cargo()`, `LastBolusStatusV2Response` parse map) are cited from comments referencing `jwoglom/pumpX2`. I could read the *intended* layout but cannot confirm the live Mobi firmware agrees. Several findings are therefore SUSPECTED-NEEDS-ON-DEVICE-CONFIRMATION.
2. **Pump rejection / NACK semantics.** The meaning of `status == 0` as "success" and `nackReasonId` codes are assumed from comments; not verified against firmware.
3. **Signing / `timeSinceReset` correctness.** Out of scope (crypto layer), but it intersects delivery commands; I flag only its *structural* coupling, not its cryptographic correctness.
4. **Runtime concurrency behavior.** Hazards are identified by reading queue-confinement claims vs. actual `Task {}` usage, but actual races can only be confirmed under instrumentation / TSan on device.

---

## CRITICAL

### TK-C1 — Delivered insulin is never reported to Loop; IOB never increases (dose reporter is dead code)
- **Severity:** Critical
- **Location:** `TandemKit/TandemKit/PumpManager/TandemDoseReporter.swift:40` (entire type) is never instantiated. `TandemPumpManager.swift` (whole file) contains no call to `pumpManagerDelegate.pumpManager(_:hasNewPumpEvents:lastReconciliation:completion:)`. `TandemPeripheralManager.enactBolus` (`TandemPeripheralManager.swift:334`) returns success without emitting any dose event.
- **Failure mode:** `TandemDoseReporter` is fully implemented but wired to nothing. There is no `TandemDoseReporter` instance, no `delegate` set, and `report(...)` is never called. No `NewPumpEvent` is ever delivered to LoopKit for a bolus, temp basal, suspend, or resume. The class's own header comment states the exact bug it was meant to fix ("Loop's IOB never increased — causing insulin stacking") — but the fix is not connected.
- **Clinical consequence:** Loop's insulin-on-board model stays flat while insulin is actually delivered. Closed-loop will treat the patient as having no insulin on board and **stack additional insulin → severe hypoglycemia.** This is the single most dangerous defect in the module.
- **Proposed fix (prose):** Instantiate a `TandemDoseReporter` owned by `TandemPumpManager`, set its `delegate` to forward into `pumpManagerDelegate.pumpManager(_:hasNewPumpEvents:lastReconciliation:completion:)`. After every delivery command and on every status poll, fetch `LastBolusStatusV2` and call `makeBolusEvent`, and emit temp-basal/suspend/resume events. Persist `lastReportedBolusId` into `TandemPumpState` (the field is referenced in comments and tests but does not exist on the state struct — see TK-H6). Advance `lastReconciliation` only on a confirmed successful status fetch.
- **Confidence:** CONFIRMED-BY-READING.

### TK-C2 — `cancelBolus` discards the delivered amount and reports `.success(nil)`, corrupting IOB
- **Severity:** Critical
- **Location:** `TandemKit/TandemKit/BLE/TandemPeripheralManager.swift:397-411` (`cancelBolus`), exposed via `TandemPumpManager.swift:119-121`.
- **Failure mode:** On cancel, the code sends `CancelBolusRequest` and immediately calls `completion(.success(nil))` without (a) awaiting `CancelBolusResponse`, (b) querying `LastBolusStatusV2` for the partially-delivered volume, or (c) constructing a `DoseEntry` for what was actually delivered. The `.success(nil)` contract tells Loop "nothing was delivered by this dose." If `activeBolusId` is `nil` (which it always is after `enactBolus`, see TK-C3), it returns `.success(nil)` having sent **no cancel at all**.
- **Clinical consequence:** A partially delivered bolus (e.g. user/Loop cancels a 6 U bolus after 4 U) is reported as zero delivered. Loop under-counts IOB by the delivered amount → stacks more insulin → **hypoglycemia.** Additionally, when `activeBolusId` is nil the bolus is *not actually cancelled on the pump*, so the full bolus continues delivering while the app believes it stopped → divergent over-delivery vs. Loop's model.
- **Proposed fix (prose):** Await `CancelBolusResponse` and verify `success`. Then fetch `LastBolusStatusV2` to read `deliveredVolumeMU` and return `.success(DoseEntry(type: .bolus, ... deliveredUnits: delivered, isMutable: false))`. Never short-circuit to `.success(nil)` on a cancel that may have delivered insulin; if the delivered amount cannot be read, surface an error/`.failure` so Loop treats IOB as uncertain rather than zero.
- **Confidence:** CONFIRMED-BY-READING (delivered-amount reporting). Exact partial-volume field SUSPECTED-NEEDS-ON-DEVICE-CONFIRMATION.

### TK-C3 — Active-bolus state is never set on enact, so cancel and live-state are blind
- **Severity:** Critical
- **Location:** `TandemKit/TandemKit/BLE/TandemPeripheralManager.swift:334-357` (`enactBolus`). No assignment to `state.activeBolusId`, `state.activeBolusUnits`, `state.activeBolusStartDate`, or `state.bolusState`. Compare with `fetchStatus` (`:247-255`) which is the only place these are set.
- **Failure mode:** After a successful `enactBolus`, in-memory state still has `activeBolusId == nil` and `bolusState == .noBolus` until the *next* status poll happens to run. During that window: `cancelBolus` (`:398`) reads `activeBolusId == nil` → returns `.success(nil)` and sends no cancel (couples into TK-C2); `bolusDeliveryState` (`TandemPumpState.swift:167`) reports `.noBolus`; `createBolusProgressReporter` shows zero progress.
- **Clinical consequence:** A freshly enacted bolus cannot be cancelled by the app/Loop until an async poll lands — an uncancellable-bolus window on a device actively delivering insulin. If the user hits cancel during this window, the UI confirms "cancelled" but the pump keeps delivering → **over-delivery / hypoglycemia.**
- **Proposed fix (prose):** On a confirmed `InitiateBolusResponse.success`, immediately `updateState` to set `activeBolusId = resp.bolusId`, `activeBolusUnits = units`, `activeBolusStartDate = Date()`, `bolusState = .inProgress`. Clear them only on confirmed completion/cancel.
- **Confidence:** CONFIRMED-BY-READING.

### TK-C4 — No clamp/validation on commanded bolus volume; `UInt32(units * 1000)` can crash or wrap
- **Severity:** Critical
- **Location:** `TandemKit/TandemKit/Protocol/Messages/Request/BolusMessages.swift:72-83` (`InitiateBolusRequest.init`, `totalVolume = UInt32(units * 1000)`). No check against `state.maximumBolusUnits` anywhere in `enactBolus` (`TandemPeripheralManager.swift:334`) or `TandemPumpManager.enactBolus` (`:111`).
- **Failure mode:** `units` flows straight from caller to `UInt32(units * 1000)`. A negative, NaN, or very large `units` value traps at runtime (`UInt32` conversion of out-of-range/NaN `Double` is a fatal error in Swift) — crashing the app mid-dose. The configured `maximumBolusUnits` (default 25, `TandemPumpState.swift:85`) is never enforced before encoding. The `modifiesInsulinDelivery` safety flag exists (`Message.swift:13`) but is read nowhere (see TK-H5).
- **Clinical consequence:** Either a hard crash during the bolus command path (delivery state then unknown/desynced), or — if firmware accepts it — a bolus far above the configured max. Both are patient-safety events; an unbounded bolus is a direct **over-delivery / severe hypoglycemia** hazard.
- **Proposed fix (prose):** Before encoding, guard `units.isFinite && units > 0 && units <= state.maximumBolusUnits` and round to the pump's 0.05 U resolution; reject out-of-range with a `PumpManagerError.deviceState`/`.configuration` rather than constructing the message. Encode via a checked conversion.
- **Confidence:** CONFIRMED-BY-READING.

### TK-C5 — Bolus permission is never released; second bolus can be silently rejected
- **Severity:** Critical
- **Location:** `TandemKit/TandemKit/BLE/TandemPeripheralManager.swift:334-357` (`enactBolus`) never sends `BolusPermissionReleaseRequest`. The request type exists and documents the requirement: `LastBolusStatusMessages.swift:120-152` ("MUST be sent after a bolus sequence completes or fails ... TandemKit never released it ... second bolus silently rejected").
- **Failure mode:** Each bolus acquires a pump-side permission lock (`BolusPermissionRequest` → `bolusId`). The lock is never released on success or failure. Per the in-code documentation, the pump can then refuse the next bolus.
- **Clinical consequence:** A subsequent (possibly clinically needed, e.g. correction) bolus is **silently rejected** — under-delivery → hyperglycemia/DKA risk — and, combined with TK-C1, Loop is not even told the bolus failed, so it believes insulin is on board that never delivered.
- **Proposed fix (prose):** Wrap the initiate step in a `defer`/`finally` that always sends `BolusPermissionReleaseRequest(bolusId:)` and awaits `BolusPermissionReleaseResponse`, regardless of success/failure/throw.
- **Confidence:** CONFIRMED-BY-READING (release omitted). Rejection-of-next-bolus behavior SUSPECTED-NEEDS-ON-DEVICE-CONFIRMATION.

---

## HIGH

### TK-H1 — `currentBasalRate()` midnight/timezone boundary selects the wrong schedule entry
- **Severity:** High
- **Location:** `TandemKit/TandemKit/PumpManager/TandemPumpState.swift:188-195` (`BasalRateSchedule.currentBasalRate()`).
- **Failure mode:** Uses `Date()` and `Calendar.current.startOfDay` to compute seconds-since-midnight, then `items.last(where: { $0.startTime <= elapsed })`. `BasalRateSchedule` stores `startTime` relative to its own reference/timezone; comparing against `Calendar.current` local midnight can be off by the schedule's UTC offset. Near midnight, DST transitions, or when the pump/phone timezone differs from the schedule's, this selects the wrong segment. This rate is then the **denominator** for temp-basal percentage (`TandemPeripheralManager.swift:422-425`).
- **Clinical consequence:** Temp-basal percentage is computed against the wrong scheduled rate → the absolute U/hr the pump runs differs from what Loop intended. Over- or under-delivery of basal insulin, worst around midnight/DST. Also corrupts the `basalDeliveryState` dose shown to Loop (`TandemPumpState.swift:152`).
- **Proposed fix (prose):** Use LoopKit's schedule lookup that is timezone-aware (`BasalRateSchedule.value(at:)` / `between(start:end:)` semantics with the schedule's own timeZone), not a hand-rolled `startOfDay` subtraction. Evaluate at the dose's effective date, not `Date()`.
- **Confidence:** CONFIRMED-BY-READING.

### TK-H2 — Temp-basal percentage silently saturates at 250 (and floor at 0)
- **Severity:** High
- **Location:** `TandemKit/TandemKit/BLE/TandemPeripheralManager.swift:425` — `let percent = UInt16(min(250, max(0, (unitsPerHour / currentRate) * 100)))`.
- **Failure mode:** A requested rate above 2.5× the scheduled rate is clamped to 250% with **no error surfaced** and **no adjustment reported back**. The completion still returns `nil` (success). Loop believes its requested temp basal was enacted at full value.
- **Clinical consequence:** Under-delivery of basal whenever Loop asks for a high temp basal (e.g. during hyperglycemia correction) → sustained hyperglycemia. Because it is silent, neither the user nor Loop's model learns the actual rate, compounding model drift. (Also see TK-H3: even the clamped value is never reported.)
- **Proposed fix (prose):** If the computed percentage exceeds the pump ceiling, either reject with an error or — preferably — proceed but report the *actual* enacted absolute rate back to Loop as the temp-basal `DoseEntry.value`, so IOB math reflects reality. Never return success with a silently reduced rate.
- **Confidence:** CONFIRMED-BY-READING.

### TK-H3 — Temp basal & suspend/resume are not reported as dose events, and temp-basal state is never updated
- **Severity:** High
- **Location:** `TandemKit/TandemKit/BLE/TandemPeripheralManager.swift:413-437` (`enactTempBasal`) — no `updateState` of `basalState`, `activeTempRatePercent`, `activeTempRateEndDate`; no dose event. `suspendDelivery`/`resumeDelivery` in `TandemPumpManager.swift:140-156` update `basalState` but emit no suspend/resume `DoseEntry`.
- **Failure mode:** After a temp basal, in-memory state still shows `basalState == .active` with no temp-rate fields, so `basalDeliveryState` (`TandemPumpState.swift:144-165`) reports plain `.active` — the temp basal is invisible to status. No `NewPumpEvent` is emitted for temp basal, suspend, or resume (compounds TK-C1).
- **Clinical consequence:** Loop's IOB/basal accounting omits temp-basal deviations and suspend gaps entirely. Net basal insulin delivered diverges from Loop's model in both directions → mis-dosing. Suspend periods (zero delivery) are not subtracted from IOB → over-estimation of IOB during suspend, then under-dosing.
- **Proposed fix (prose):** On confirmed temp-basal/suspend/resume, `updateState` the corresponding fields AND emit the matching `DoseEntry` (`makeTempBasalEvent`/`makeSuspendEvent`/`makeResumeEvent` already exist in `TandemDoseReporter`).
- **Confidence:** CONFIRMED-BY-READING.

### TK-H4 — Temp-basal / suspend / resume report success without awaiting the pump's response
- **Severity:** High
- **Location:** `TandemKit/TandemKit/BLE/TandemPeripheralManager.swift:413-437` (`enactTempBasal`: `try await self.send(...)` then `completion(nil)` with no `sendAndReceive`). Contrast suspend/resume (`:359-395`) which *do* await `SetTempRateResponse`/`StopTempRateResponse`. Cancel (`:405`) also only `send`s.
- **Failure mode:** `enactTempBasal` and `cancelBolus` fire-and-forget: they report `nil`/`.success` once the BLE write is queued, never confirming the pump accepted the command (`status == 0`) or rejected it. A pump NACK or dropped command is reported to Loop as success.
- **Clinical consequence:** Loop believes a temp basal (or bolus cancel) took effect when the pump rejected/ignored it → app-vs-pump delivery desync. For temp basal, Loop's model assumes a rate the pump isn't running; for cancel, the bolus keeps delivering. Both → mis-dosing.
- **Proposed fix (prose):** Route `enactTempBasal` and `cancelBolus` through `sendAndReceive(...)` and check `resp.success` before reporting completion, mirroring suspend/resume.
- **Confidence:** CONFIRMED-BY-READING.

### TK-H5 — `modifiesInsulinDelivery` safety gate is declared but never enforced
- **Severity:** High
- **Location:** `TandemKit/TandemKit/Protocol/Messages/Message.swift:13` (protocol requirement) and `:18` (default `false`); set `true` on `InitiateBolusRequest`/`CancelBolusRequest`/`SetTempRateRequest`/`StopTempRateRequest`. Grep confirms **no read site** anywhere in the module.
- **Failure mode:** The flag that is supposed to gate delivery-modifying commands (e.g. require auth/confirmation/connection-verified state) is dead metadata. Nothing checks it before sending.
- **Clinical consequence:** There is no central enforcement point ensuring delivery commands only go out under safe preconditions (authenticated, not mid-handshake, within limits). Increases the blast radius of every other bug here. Defense-in-depth that is silently absent.
- **Proposed fix (prose):** In `send(...)`/`sendAndReceive(...)`, when `type(of: request).modifiesInsulinDelivery` is true, assert connection==`.connected`, auth key present, and delivery limits validated; otherwise refuse to send.
- **Confidence:** CONFIRMED-BY-READING.

### TK-H6 — `TandemPumpState.lastReportedBolusId` does not exist; dedupe state cannot persist
- **Severity:** High
- **Location:** Referenced as persisted in `TandemDoseReporter.swift:45` ("Persisted via TandemPumpState.lastReportedBolusId") and exercised by `TandemDoseReporterTests.swift:94-95`, but **absent** from `TandemPumpState` (`TandemPumpState.swift:25-56` persisted fields; not in `init(rawValue:)` `:91` or `rawValue` `:117`).
- **Failure mode:** When the reporter is eventually wired in (TK-C1), there is no persisted `lastReportedBolusId`. Across app restarts/reconnects it resets to 0, so `makeBolusEvent` (`:60`) re-emits previously reported boluses.
- **Clinical consequence:** Double-counting of completed boluses in Loop's history → inflated IOB → under-dosing (hyperglycemia). (Inverse of TK-C1 but same class of IOB corruption.)
- **Proposed fix (prose):** Add `lastReportedBolusId: UInt16` to `TandemPumpState` with round-tripping in `init(rawValue:)`/`rawValue`, and persist it whenever the reporter advances.
- **Confidence:** CONFIRMED-BY-READING.

---

## MEDIUM

### TK-M1 — Pairing code and derived secret stored in plaintext `rawState`, not Keychain
- **Severity:** Medium (security, not delivery-correctness — per task framing)
- **Location:** `TandemKit/TandemKit/PumpManager/TandemPumpState.swift:30-32` (`pairingCode`, `derivedSecretHex`, `serverNonce3Hex`), serialized in `rawValue` (`:122-124`); the comment at `:30` itself says "stored only in keychain in production." Grep confirms no `Keychain`/`SecItem` usage for these. Set from UI at `TandemKitUI/TandemUICoordinator.swift:87`.
- **Failure mode:** Secrets that gate the authenticated/signed command channel are persisted in Loop's plist-backed `rawState` in cleartext.
- **Clinical consequence:** Indirect. Exfiltration of `derivedSecretHex` + pairing code could let an attacker forge signed delivery commands. Not a delivery-correctness bug but a path to unauthorized dosing.
- **Proposed fix (prose):** Store `pairingCode`/`derivedSecretHex`/`serverNonce3Hex` in the iOS Keychain keyed by pump serial; keep only a non-sensitive reference in `rawState`.
- **Confidence:** CONFIRMED-BY-READING.

### TK-M2 — `notifyStatusDidChange` passes identical old/new status to observers
- **Severity:** Medium
- **Location:** `TandemKit/TandemKit/PumpManager/TandemPumpManager.swift:78-84`.
- **Failure mode:** `observer.pumpManager(self, didUpdate: currentStatus, oldStatus: currentStatus)` — old and new are the same value. Also, `notifyStatusDidChange()` is never actually called from anywhere in the file (state changes go through `updateState`, which calls `pumpManagerDidUpdateState` but not the status-observer fan-out).
- **Clinical consequence:** UI/consumers relying on old→new status diffs (e.g. detecting bolus start/stop, suspend transitions) won't see transitions. Mostly UX/observability, but can mask delivery-state changes from any consumer that diffs.
- **Proposed fix (prose):** Track the previous `PumpManagerStatus`, pass the real prior value, and invoke the observer fan-out from `updateState` when status-affecting fields change.
- **Confidence:** CONFIRMED-BY-READING.

### TK-M3 — `fetchStatus` reports REQUESTED volume as active bolus units
- **Severity:** Medium
- **Location:** `TandemKit/TandemKit/BLE/TandemPeripheralManager.swift:249` — `state.activeBolusUnits = Double(r.requestedVolumeMU) / 1000.0` from `CurrentBolusStatusResponse`.
- **Failure mode:** Active-bolus units are populated from the requested volume (the only field `CurrentBolusStatusResponse` exposes — it has no delivered field, `StatusMessages.swift:53-83`). For an in-progress bolus this is acceptable for a *mutable* in-progress entry, but if this value ever feeds final reconciliation it overstates delivery for an interrupted bolus.
- **Clinical consequence:** If used as the authoritative delivered amount (e.g. on disconnect before `LastBolusStatusV2` is fetched), overstates IOB → under-dosing. Bounded because it's the in-progress estimate, hence Medium.
- **Proposed fix (prose):** Treat `CurrentBolusStatus` requested volume only as the in-progress *programmed* value; always reconcile the final delivered amount from `LastBolusStatusV2.deliveredVolumeMU`.
- **Confidence:** CONFIRMED-BY-READING.

### TK-M4 — `send()` runs off the serial queue; transaction IDs and writes can race
- **Severity:** Medium
- **Location:** `TandemKit/TandemKit/BLE/TandemPeripheralManager.swift:141-172` (`send`) is `async` and invoked from detached `Task {}` blocks (`:128`, `:197`, `:310`, `:335`, `:362`, `:381`, `:402`, `:428`). It reads `txID.next()` (`TransactionID.swift`, "Must be accessed from a single serial queue") and calls `peripheral.writeValue` outside `queue`.
- **Failure mode:** The module's `@unchecked Sendable` soundness argument (`TandemPeripheralManager.swift:16-21`) rests on everything running on `queue`. `send` violates that: concurrent `Task`s can interleave `txID.next()` (non-atomic `&+`) and BLE writes. Two in-flight requests could collide on a transaction id or interleave chunk writes of two messages on the same characteristic.
- **Clinical consequence:** Interleaved chunk writes corrupt a delivery command on the wire (CRC would reject, so likely failed delivery rather than wrong dose), and duplicate txIDs can misattribute responses. Mostly a reliability/desync hazard; bounded by CRC, hence Medium.
- **Proposed fix (prose):** Make `send` hop all of its body (txID, serialization, chunk writes) onto `queue` (e.g. `queue.async`/an actor), and serialize outstanding control-characteristic writes so chunks of different messages never interleave.
- **Confidence:** CONFIRMED-BY-READING (structural); runtime race SUSPECTED-NEEDS-ON-DEVICE-CONFIRMATION.

### TK-M5 — Auto-reconnect loop on disconnect with no backoff or auth-state reset guard
- **Severity:** Medium
- **Location:** `TandemKit/TandemKit/BLE/TandemBLEManager.swift:183-196` (`didDisconnectPeripheral`) calls `central.connect(peripheral)` unconditionally when no `connectCompletion` is pending. `TransactionID.reset()` is never called on disconnect (`TransactionID.swift:15` exists but unused).
- **Failure mode:** Tight reconnect with no backoff; on reconnect the transaction counter is not reset while the pump's expectation may have, and stale `authState`/`pending` interplay is not re-established cleanly. `peripheralManager` is nilled but `txID` lives on the new peripheral manager (fresh) — acceptable — yet the unbounded reconnect can spin.
- **Clinical consequence:** Battery drain and connection thrash; during thrash, delivery commands may be issued against a not-yet-authenticated link and fail silently (couples with TK-H5). Indirect delivery reliability.
- **Proposed fix (prose):** Add exponential backoff and a max-retry policy; ensure auth is fully re-completed before any delivery command is allowed post-reconnect.
- **Confidence:** CONFIRMED-BY-READING.

### TK-M6 — `DoseProgressReporter` is a non-updating stub
- **Severity:** Medium
- **Location:** `TandemKit/TandemKit/PumpManager/TandemDoseProgressReporter.swift:1-26` — `progress` is fixed at `(0,0)`; no observer notification, no polling.
- **Failure mode:** `createBolusProgressReporter` (`TandemPumpManager.swift:103`) returns a reporter that always shows 0% / 0 U delivered.
- **Clinical consequence:** During a bolus the user/UI sees no progress and "0 delivered." If a user, seeing no progress, re-initiates, that risks a duplicate bolus (over-delivery). Primarily UX but with a re-dose hazard.
- **Proposed fix (prose):** Poll `CurrentBolusStatus`/`LastBolusStatusV2` and publish `DoseProgress` updates to the observer until completion.
- **Confidence:** CONFIRMED-BY-READING.

---

## LOW

### TK-L1 — `serialize`/`serializeSigned` encode `cargo.count` as a single `UInt8`
- **Severity:** Low
- **Location:** `TandemKit/TandemKit/Protocol/Framing/PacketFramer.swift:68` and `:87` — `out.append(UInt8(cargo.count))`.
- **Failure mode:** Cargo length is written as one byte; a cargo ≥ 256 bytes would trap. Current delivery messages are ≤ 37 bytes, so unreachable today, but it's an unchecked conversion on the command path.
- **Clinical consequence:** None today; latent crash risk if a larger message type is added. Low.
- **Proposed fix (prose):** Guard `cargo.count <= 255` (or use the protocol's real length field width) and fail explicitly.
- **Confidence:** CONFIRMED-BY-READING.

### TK-L2 — `reassemble` trusts chunk structure; no transactionId/opcode consistency check
- **Severity:** Low
- **Location:** `TandemKit/TandemKit/Protocol/Framing/PacketFramer.swift:49-61`; `receive` at `TandemPeripheralManager.swift:174-192`.
- **Failure mode:** Reassembly concatenates `dropFirst(2)` of each buffered chunk and checks only CRC. It does not verify all chunks share one transactionId, nor that `packetsRemaining` counts down monotonically. Interleaved notifications on the same characteristic (see TK-M4) could be stitched into one buffer; CRC would usually reject, but a coincidental pass is theoretically possible.
- **Clinical consequence:** Very low (CRC-guarded); a malformed reassembly is far more likely to fail than to silently corrupt a delivery response. Low.
- **Proposed fix (prose):** Validate transactionId equality across chunks and the remaining-count sequence before accepting; drop the buffer on mismatch.
- **Confidence:** CONFIRMED-BY-READING.

### TK-L3 — `hasActiveBolus` treats `bolusId != 0` as active even when `deliveryStatus == .done`
- **Severity:** Low
- **Location:** `TandemKit/TandemKit/Protocol/Messages/Request/StatusMessages.swift:68-70` — `deliveryStatus != .done || bolusId != 0`.
- **Failure mode:** After a bolus completes, the pump may still report the last `bolusId` while `deliveryStatus == .done`; this predicate then keeps `hasActiveBolus == true`, so `fetchStatus` (`TandemPeripheralManager.swift:246`) leaves `bolusState == .inProgress` indefinitely.
- **Clinical consequence:** Status stuck showing a bolus in progress can block new boluses or mislead the UI; bounded because completion reconciliation (once TK-C1 is wired) would correct history. Low-to-Medium depending on UI gating — listed Low.
- **Proposed fix (prose):** Use only `deliveryStatus` (`.delivering`/`.requesting`) to determine activity; use `bolusId` for identity, not liveness.
- **Confidence:** CONFIRMED-BY-READING (logic); firmware's done-state `bolusId` behavior SUSPECTED-NEEDS-ON-DEVICE-CONFIRMATION.

---

## Cross-cutting observations
- **The dose-reporting pipeline is built but unplugged.** `TandemDoseReporter` (well-structured, with delivered-vs-requested discipline and dedupe) is connected to nothing (TK-C1), its persistence field is missing (TK-H6), and the delivery commands that should feed it do not (TK-C3, TK-H3). This is the dominant theme: the *intent* is correct, the *wiring* is absent.
- **Fire-and-forget delivery commands** (TK-H4, TK-C2) mean Loop is told "success" before the pump confirms — the most systemic desync risk.
- **Declared-but-unenforced safety affordances** (`modifiesInsulinDelivery` TK-H5, `lastReportedBolusId` TK-H6, `TransactionID.reset` TK-M5) indicate the safety scaffolding was scoped but not finished.

## Bench-test gating (recommendation)
Given TK-C1–TK-C5, a live-pump bench test would deliver insulin that Loop does not account for (TK-C1), cannot reliably cancel (TK-C2/C3), may exceed configured limits or crash mid-dose (TK-C4), and may silently fail follow-up boluses (TK-C5). **Do not authorize a live-pump dosing bench test until all Critical findings are resolved and TK-H1–H4 are at minimum mitigated.** Non-dosing read-only tests (status/battery/reservoir fetch) are comparatively low-risk and could proceed earlier, but note TK-M4's concurrency hazard applies to all command/response traffic.

---
*End of report. No code was modified; no fixes were applied; no PR was opened.*
