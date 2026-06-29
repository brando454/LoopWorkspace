import Foundation
import LoopKit

// WP6 / M1 (security): secret persistence seam.
//
// The three EC-JPAKE pairing secrets — pairingCode, derivedSecretHex,
// serverNonce3Hex — must not live in the plaintext PumpManager rawState
// dictionary, which is persisted unencrypted. This protocol abstracts a
// per-service secret store so the migration logic in TandemPumpManager can
// be exercised offline against an in-memory fake, while production routes
// through LoopKit's KeychainManager (the iOS Keychain).
//
// Service keys are scoped per pump by the BLE peripheral identifier UUID —
// see TandemPumpManager.secretServiceKey(_:field:). The peripheral UUID is
// known at connect time, stable per pump per device, and re-derives a fresh
// handshake if the pairing is torn down at the iOS level, which is the
// correct behavior for these per-pairing secrets. pumpSerialNumber would be
// the portable key, but it is not populated from DIS today (tracked as a
// WP6 status-fidelity follow-up), so the UUID is the reliable scope now.
public protocol SecretStore {
    /// Returns the stored secret for `service`, or nil if absent.
    func secret(forService service: String) -> String?
    /// Stores `value` for `service`, replacing any existing value. A nil
    /// `value` deletes the entry.
    func setSecret(_ value: String?, forService service: String)
}

// Production store backed by the iOS Keychain via LoopKit's KeychainManager.
// Failures are swallowed to nil on read and ignored on write: a Keychain
// miss must degrade to "no stored secret" (forcing a fresh handshake), never
// crash the pump manager. The handshake path re-derives on absence, so a
// transient Keychain failure costs a re-pair, not a delivery fault.
public struct KeychainSecretStore: SecretStore {
    private let keychain = KeychainManager()

    public init() {}

    public func secret(forService service: String) -> String? {
        do {
            return try keychain.getGenericPasswordForService(service)
        } catch {
            return nil
        }
    }

    public func setSecret(_ value: String?, forService service: String) {
        try? keychain.replaceGenericPassword(value, forService: service)
    }
}

// Offline test double: a plain in-memory dictionary. Lets the migration
// suite assert read-through, write-back, and per-UUID isolation without the
// real Security framework, which is unavailable in a bare xctest host.
public final class InMemorySecretStore: SecretStore {
    private var storage: [String: String] = [:]
    private let lock = NSLock()

    public init() {}

    public func secret(forService service: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return storage[service]
    }

    public func setSecret(_ value: String?, forService service: String) {
        lock.lock(); defer { lock.unlock() }
        if let value = value {
            storage[service] = value
        } else {
            storage.removeValue(forKey: service)
        }
    }
}