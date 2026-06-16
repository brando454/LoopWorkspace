import XCTest
import Foundation
@testable import TandemKit

// Deterministic byte-compatibility tests for the J-PAKE key-derivation and
// key-confirmation path (rounds 3 and 4), independent of the EC point math.
//
// The EC-JPAKE round-1/round-2 exchange uses fresh random scalars per session,
// so the shared point K (and thus derivedSecret) cannot be asserted from a
// single captured server chunk. What CAN be asserted deterministically is the
// chain that runs AFTER the secret is derived:
//
//   authKey            = Hkdf.build(nonce: serverNonce3, keyMaterial: derivedSecret)
//   clientHashDigest   = HMAC-SHA256(key: authKey, data: clientNonce4)
//   serverHashDigest   = HMAC-SHA256(key: authKey, data: serverNonce4)
//
// Every value below is reproduced byte-for-byte from the jwoglom/pumpX2
// SimulatedJpakeAuthBuilderIntegrationTest (pairingCode "passw0rd"). These are
// the same vectors verified out-of-band against the reference Java
// implementation. A single-byte disagreement in the HKDF construction, the
// HMAC argument order, or the mod255 normalization will fail one of these.
//
// These tests exercise the SAME production helpers used by TandemAuthState
// (TandemHKDF.build, HmacUtils.hmacSHA256) so a regression in the shipped path
// is caught here, not just in a parallel re-implementation.
final class TandemKDFConfirmationTests: XCTestCase {

    private func hex(_ s: String) -> Data { Data(hexString: s)! }

    // MARK: - Fixed reference vectors (pairingCode = "passw0rd")

    private let derivedSecret = "45d66d65aedfd39ce50be0eacca491ff183b7e1c22bf722b8dfb20408e0c78d4"
    private let serverNonce3  = "e734344901549417"
    private let clientNonce4  = "998c182c9d70a375"
    private let serverNonce4  = "ad08275f109e41b0"
    private let hkdfKey       = "da33f5476b06ca992b3360784aa3688e635e05da5b5ada746dc04763ae4ecc94"
    private let clientDigest  = "78277ee13aff3fbe0587a6666445eb329b03be0cacfbc7da6f6213765f31371b"
    private let serverDigest  = "6e7a179c5a601572a2b91251e577454c8b32ebeafae5bc87209cced02fa7b358"

    // MARK: - HKDF (auth key) derivation

    // authKey = Hkdf.build(serverNonce3, derivedSecret). Confirms the
    // non-standard one-block HKDF (nonce used as the HMAC extract key, expand
    // over the single byte 0x01) matches the pump byte-for-byte.
    func testAuthKeyDerivation() {
        let authKey = TandemHKDF.build(nonce: hex(serverNonce3),
                                       keyMaterial: hex(derivedSecret))
        XCTAssertEqual(authKey.hexString, hkdfKey,
                       "Hkdf.build(serverNonce3, derivedSecret) must equal the reference auth key")
    }

    // MARK: - Round 4 client confirmation digest

    // The digest the client sends to the pump in Jpake4KeyConfirmationRequest.
    func testClientConfirmationDigest() {
        let authKey = TandemHKDF.build(nonce: hex(serverNonce3),
                                       keyMaterial: hex(derivedSecret))
        let digest = HmacUtils.hmacSHA256(key: authKey, data: hex(clientNonce4))
        XCTAssertEqual(digest.hexString, clientDigest,
                       "client hashDigest = HMAC-SHA256(authKey, clientNonce4)")
    }

    // MARK: - Round 4 server confirmation verification

    // The digest the pump returns in Jpake4KeyConfirmationResponse, which the
    // client recomputes from serverNonce4 to authenticate the pump. This is the
    // gate that proves both sides derived the same secret.
    func testServerConfirmationDigest() {
        let authKey = TandemHKDF.build(nonce: hex(serverNonce3),
                                       keyMaterial: hex(derivedSecret))
        let digest = HmacUtils.hmacSHA256(key: authKey, data: hex(serverNonce4))
        XCTAssertEqual(digest.hexString, serverDigest,
                       "server hashDigest = HMAC-SHA256(authKey, serverNonce4)")
    }

    // MARK: - End-to-end confirmation through TandemAuthState

    // Drive the actual auth-state seam: seed the secret + serverNonce3 so the
    // initializer derives authKey exactly as it would mid-handshake, then check
    // both the derived key and that a server digest built from serverNonce4
    // verifies against the reference. This catches integration drift between the
    // helpers and the orchestration layer.
    func testAuthStateDerivesReferenceKey() {
        let state = TandemAuthState(pairingCode: "passw0rd",
                                    derivedSecretHex: derivedSecret,
                                    serverNonce3Hex: serverNonce3)
        XCTAssertEqual(state.authKey?.hexString, hkdfKey,
                       "TandemAuthState must derive the reference auth key from secret + serverNonce3")

        guard let authKey = state.authKey else {
            XCTFail("authKey was not derived"); return
        }
        let recomputedServer = HmacUtils.hmacSHA256(key: authKey, data: hex(serverNonce4))
        XCTAssertEqual(recomputedServer.hexString, serverDigest,
                       "server confirmation recomputed via auth-state key must match reference")
    }

    // MARK: - Negative control

    // A wrong pairing code yields a different derivedSecret upstream; here we
    // confirm the confirmation digest is sensitive to the secret by perturbing
    // one byte of the auth key input and asserting the digest changes.
    func testConfirmationIsSecretSensitive() {
        var tampered = hex(derivedSecret)
        tampered[tampered.startIndex] ^= 0x01
        let badKey = TandemHKDF.build(nonce: hex(serverNonce3), keyMaterial: tampered)
        let digest = HmacUtils.hmacSHA256(key: badKey, data: hex(clientNonce4))
        XCTAssertNotEqual(digest.hexString, clientDigest,
                          "perturbing the derived secret must change the confirmation digest")
    }
}
