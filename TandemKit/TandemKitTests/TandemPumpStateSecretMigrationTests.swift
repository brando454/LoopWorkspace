import XCTest
import LoopKit
@testable import TandemKit

// WP6 / M1 (security): proves the three EC-JPAKE pairing secrets migrate out of
// the plaintext PumpManager rawState into the SecretStore (Keychain in
// production, in-memory here), keyed by the BLE peripheral UUID. Drives the
// synchronous migration core through a TandemPumpManager built with an injected
// InMemorySecretStore — no Keychain, no live CoreBluetooth.
final class TandemPumpStateSecretMigrationTests: XCTestCase {

    private let uuidA = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    private let uuidB = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!

    private func keyFor(_ uuid: UUID, _ field: String) -> String {
        "com.loopandlearn.TandemKit.\(uuid.uuidString).\(field)"
    }

    // A state carrying legacy plaintext secrets, as an install paired under the
    // old scheme would hydrate from rawState.
    private func legacyState(code: String, secret: String?, nonce: String?) -> TandemPumpState {
        let s = TandemPumpState(basalRateSchedule: nil)
        s.pairingCode = code
        s.derivedSecretHex = secret
        s.serverNonce3Hex = nonce
        return s
    }

    // 1. Lossless upgrade: legacy plaintext secrets survive migration into the
    //    store and remain readable in state.
    func testLegacyPlaintextMigratesLosslessly() {
        let store = InMemorySecretStore()
        let state = legacyState(code: "482163", secret: "87cff2cbdeadbeef", nonce: "a1b2c3d4")
        let pm = TandemPumpManager(state: state, secretStore: store)

        pm.runSecretMigration(uuid: uuidA)

        XCTAssertEqual(store.secret(forService: keyFor(uuidA, "pairingCode")), "482163")
        XCTAssertEqual(store.secret(forService: keyFor(uuidA, "derivedSecretHex")), "87cff2cbdeadbeef")
        XCTAssertEqual(store.secret(forService: keyFor(uuidA, "serverNonce3Hex")), "a1b2c3d4")
        XCTAssertEqual(pm.state.pairingCode, "482163")
        XCTAssertEqual(pm.state.derivedSecretHex, "87cff2cbdeadbeef")
        XCTAssertEqual(pm.state.serverNonce3Hex, "a1b2c3d4")
    }

    // 2. Write-through: after migration, the secrets are present in the store
    //    even though the source was only plaintext state (no prior store entry).
    func testMigrationWritesThroughToStore() {
        let store = InMemorySecretStore()
        XCTAssertNil(store.secret(forService: keyFor(uuidA, "derivedSecretHex")))
        let pm = TandemPumpManager(state: legacyState(code: "111111", secret: "cafe", nonce: "babe"),
                                   secretStore: store)
        pm.runSecretMigration(uuid: uuidA)
        XCTAssertNotNil(store.secret(forService: keyFor(uuidA, "derivedSecretHex")))
    }

    // 3. Store wins over plaintext on a subsequent launch: if the store already
    //    holds a value, the migration adopts it rather than the stale plaintext.
    func testStoredValueTakesPrecedenceOverLegacyPlaintext() {
        let store = InMemorySecretStore()
        store.setSecret("STORED_SECRET", forService: keyFor(uuidA, "derivedSecretHex"))
        let pm = TandemPumpManager(state: legacyState(code: "111111", secret: "STALE_PLAINTEXT", nonce: nil),
                                   secretStore: store)
        pm.runSecretMigration(uuid: uuidA)
        XCTAssertEqual(pm.state.derivedSecretHex, "STORED_SECRET")
    }

    // 4. Plaintext-absence: the secrets never appear in rawValue, so the
    //    persisted PumpManager rawState carries no plaintext secret.
    func testSecretsNeverSerializedIntoRawValue() {
        let state = legacyState(code: "482163", secret: "deadbeef", nonce: "feed")
        let raw = state.rawValue
        XCTAssertNil(raw["pairingCode"])
        XCTAssertNil(raw["derivedSecretHex"])
        XCTAssertNil(raw["serverNonce3Hex"])
        // Non-secret fields still round-trip.
        XCTAssertNotNil(raw["pumpSerialNumber"])
    }

    // 5. Round-trip safety: because the rawValue getter no longer serializes the
    //    secrets, a save/load cycle (rawValue -> init(rawValue:)) cannot carry
    //    them. init(rawValue:) still READS the plaintext keys (the legacy-
    //    migration fallback), but a freshly serialized rawValue has none, so the
    //    restored state falls back to blank/nil. This proves the plaintext store
    //    is secret-free going forward without breaking legacy recovery.
    func testRawStateRoundTripCarriesNoSecrets() {
        let original = legacyState(code: "482163", secret: "deadbeef", nonce: "feed")
        let restored = TandemPumpState(rawValue: original.rawValue)
        XCTAssertEqual(restored.pairingCode, "")        // not persisted -> blank default
        XCTAssertNil(restored.derivedSecretHex)
        XCTAssertNil(restored.serverNonce3Hex)
    }

    // 6. Per-UUID isolation: two pumps keep independent secrets; migrating one
    //    does not leak into the other's keys.
    func testPerUUIDIsolation() {
        let store = InMemorySecretStore()
        let pmA = TandemPumpManager(state: legacyState(code: "111111", secret: "SECRET_A", nonce: "NA"),
                                    secretStore: store)
        let pmB = TandemPumpManager(state: legacyState(code: "222222", secret: "SECRET_B", nonce: "NB"),
                                    secretStore: store)
        pmA.runSecretMigration(uuid: uuidA)
        pmB.runSecretMigration(uuid: uuidB)
        XCTAssertEqual(store.secret(forService: keyFor(uuidA, "derivedSecretHex")), "SECRET_A")
        XCTAssertEqual(store.secret(forService: keyFor(uuidB, "derivedSecretHex")), "SECRET_B")
        XCTAssertNotEqual(store.secret(forService: keyFor(uuidA, "derivedSecretHex")),
                          store.secret(forService: keyFor(uuidB, "derivedSecretHex")))
    }

    // MARK: - Deactivation purge (best-effort, live-UUID)

    // 7. Purge on deactivation: all three UUID_A secrets are deleted; UUID_B's
    //    survive (per-UUID isolation on the delete path too). Drives the
    //    synchronous purge core (factored out of purgePairingSecrets() the same
    //    way runSecretMigration is factored out of migrateSecretsSync) with a
    //    known UUID — the public entry reads the UUID from the live peripheral,
    //    which an offline manager never has.
    func testPurgeDeletesAllThreeSecretsForUUIDOnly() {
        let store = InMemorySecretStore()
        let pm = TandemPumpManager(state: legacyState(code: "482163", secret: "SECRET_A", nonce: "NA"),
                                   secretStore: store)
        pm.runSecretMigration(uuid: uuidA)
        store.setSecret("SECRET_B", forService: keyFor(uuidB, "derivedSecretHex"))
        XCTAssertNotNil(store.secret(forService: keyFor(uuidA, "pairingCode")))
        XCTAssertNotNil(store.secret(forService: keyFor(uuidA, "derivedSecretHex")))
        XCTAssertNotNil(store.secret(forService: keyFor(uuidA, "serverNonce3Hex")))

        pm.purgePairingSecrets(uuid: uuidA)

        XCTAssertNil(store.secret(forService: keyFor(uuidA, "pairingCode")))
        XCTAssertNil(store.secret(forService: keyFor(uuidA, "derivedSecretHex")))
        XCTAssertNil(store.secret(forService: keyFor(uuidA, "serverNonce3Hex")))
        XCTAssertEqual(store.secret(forService: keyFor(uuidB, "derivedSecretHex")), "SECRET_B",
                       "purging one pump's secrets must not touch another's")
    }

    // 8. Idempotence: a second purge of already-absent keys is a clean no-op.
    func testPurgeIsIdempotent() {
        let store = InMemorySecretStore()
        let pm = TandemPumpManager(state: legacyState(code: "482163", secret: "S", nonce: "N"),
                                   secretStore: store)
        pm.runSecretMigration(uuid: uuidA)
        pm.purgePairingSecrets(uuid: uuidA)
        pm.purgePairingSecrets(uuid: uuidA)
        XCTAssertNil(store.secret(forService: keyFor(uuidA, "pairingCode")))
        XCTAssertNil(store.secret(forService: keyFor(uuidA, "derivedSecretHex")))
        XCTAssertNil(store.secret(forService: keyFor(uuidA, "serverNonce3Hex")))
    }

    // 9. Best-effort limitation, pinned: with no resident peripheral (the
    //    offline manager's central factory is nil, so no peripheral ever
    //    exists), the public purge is a no-op and the secrets survive. This is
    //    the documented Delete-Pump-while-disconnected gap the deferred
    //    persist-the-UUID follow-up will close.
    func testPurgeWithoutResidentPeripheralIsNoOp() {
        let store = InMemorySecretStore()
        let pm = TandemPumpManager(state: legacyState(code: "482163", secret: "S", nonce: "N"),
                                   secretStore: store)
        pm.runSecretMigration(uuid: uuidA)

        pm.purgePairingSecrets()

        XCTAssertEqual(store.secret(forService: keyFor(uuidA, "derivedSecretHex")), "S",
                       "no live peripheral UUID -> purge must be a no-op, not a guess")
    }
}