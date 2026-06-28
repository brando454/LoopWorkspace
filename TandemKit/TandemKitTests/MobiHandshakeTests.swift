import XCTest
import Foundation
@testable import TandemKit

// Byte-compatibility tests against a REAL Tandem Mobi pairing handshake.
//
// Source: a full J-PAKE pairing captured from a physical Tandem Mobi (backup
// pump, empty of insulin) via Android btsnoop. The two round-1 SERVER proofs
// below are the pump's own genuine zero-knowledge proofs, decoded from that
// capture and independently re-verified in a separate P-256 reference
// implementation. If our Fiat-Shamir challenge layout disagrees with the pump
// by a single byte, verification of these genuine proofs fails — the exact
// failure mode that internal round-trip tests cannot catch.
//
// Unlike ECJPAKEZKPTests (which uses jwoglom's published t:slim test vectors),
// these bytes come from THIS user's actual Mobi, confirming our code is
// byte-compatible with the device it will pair with.
final class MobiHandshakeTests: XCTestCase {

    // --- Pump round-1a server proof (X3 + ZKP), generator G, prover id="server" ---
    private let mobiServerR1aHex =
        "4104ac16562d3115387cb6ef9c633ea5d6d2bc323fffa76971210d4dc19ed29629b6" +
        "75d6c0d6747947b69780eedc297b54511145b6fad563d2c60531af390c2794894104" +
        "c497d46566a0eea9a70d05d0bfdc68bcb7e559b2febbbc450408cf2302d5ce56cfe3" +
        "cbf4270fc373703fda8c297bb2e6c628d7be764ad06f9d28a85f801d063b201baf84" +
        "15afd1a2e7bacdbf1a87746d5ca642280936bd9b6dc0652b99c9037310"

    // --- Pump round-1b server proof (X4 + ZKP), generator G, prover id="server" ---
    private let mobiServerR1bHex =
        "4104a510bf48a1d524558216715e938a7db5107e380b94b2247c9f7c675dc5f3d3223" +
        "1b6e7379024b53b94524065287daba7bbdefc0affbc229504b5049814c0505541041" +
        "ba32555702dcfc081555ad04115c883b357c5325b6cfb7c9dddc9f7fcacb1cf4d571" +
        "006faf478747cf934c8b5805d3c3f2563b0d2e3079e53d145493162eef320d36bef9" +
        "014f7f0c0ba22f18ce5626c1e60b00f86674c9f000fe09cc65327aa67"

    private func hexToData(_ hex: String) -> Data {
        var d = Data(); var i = hex.startIndex
        while i < hex.endIndex {
            let j = hex.index(i, offsetBy: 2)
            d.append(UInt8(hex[i..<j], radix: 16)!)
            i = j
        }
        return d
    }

    private func decodeChunk(_ data: Data) -> (Data, Data, Data) {
        var c = data.startIndex
        func read() -> Data {
            let n = Int(data[c]); c = data.index(after: c)
            let end = data.index(c, offsetBy: n)
            defer { c = end }
            return Data(data[c..<end])
        }
        return (read(), read(), read())
    }

    private func decodeProof(_ hex: String, file: StaticString = #file, line: UInt = #line)
        -> (TandemP256Point, TandemP256Point, Fq)?
    {
        let chunk = hexToData(hex)
        XCTAssertEqual(chunk.count, 165, "Mobi server chunk must be 165 bytes", file: file, line: line)
        let (xB, vB, rB) = decodeChunk(chunk)
        guard let X = TandemP256Point(validatedX963: xB) else {
            XCTFail("Mobi X failed on-curve validation", file: file, line: line); return nil
        }
        guard let V = TandemP256Point(validatedX963: vB) else {
            XCTFail("Mobi V failed on-curve validation", file: file, line: line); return nil
        }
        guard let r = Fq(bytes: rB) else {
            XCTFail("Mobi r scalar failed to decode", file: file, line: line); return nil
        }
        return (X, V, r)
    }

    // HEADLINE: both genuine Mobi round-1 server proofs must verify with id="server".
    func testMobiServerRound1aProofVerifies() {
        guard let (X, V, r) = decodeProof(mobiServerR1aHex) else { return }
        XCTAssertTrue(
            ECJPAKEContext.verifyZKPForTesting(ECJPAKEContext.ZKP(V: V, b: r), X: X,
                                               generator: .generator, signerID: Data("server".utf8)),
            "genuine Mobi round-1a proof must verify — challenge layout mismatch if this fails")
    }

    func testMobiServerRound1bProofVerifies() {
        guard let (X, V, r) = decodeProof(mobiServerR1bHex) else { return }
        XCTAssertTrue(
            ECJPAKEContext.verifyZKPForTesting(ECJPAKEContext.ZKP(V: V, b: r), X: X,
                                               generator: .generator, signerID: Data("server".utf8)),
            "genuine Mobi round-1b proof must verify — challenge layout mismatch if this fails")
    }

    // Negative: the Mobi proofs must FAIL under the wrong prover id (catches a
    // verifier that ignores the role-id field in the challenge hash).
    func testMobiServerProofsFailWithClientID() {
        for hex in [mobiServerR1aHex, mobiServerR1bHex] {
            guard let (X, V, r) = decodeProof(hex) else { return }
            XCTAssertFalse(
                ECJPAKEContext.verifyZKPForTesting(ECJPAKEContext.ZKP(V: V, b: r), X: X,
                                                   generator: .generator, signerID: Data("client".utf8)),
                "Mobi proof must not verify under the wrong role id")
        }
    }

    // Negative: tamper one byte of r — verification must fail.
    func testMobiServerProofTamperedFails() {
        let chunk = hexToData(mobiServerR1aHex)
        let (xB, vB, rB) = decodeChunk(chunk)
        guard let X = TandemP256Point(validatedX963: xB),
              let V = TandemP256Point(validatedX963: vB) else { return XCTFail("decode") }
        var bad = rB; bad[bad.startIndex] ^= 0x01
        guard let r = Fq(bytes: bad) else { return }  // if reduced away, fine
        XCTAssertFalse(
            ECJPAKEContext.verifyZKPForTesting(ECJPAKEContext.ZKP(V: V, b: r), X: X,
                                               generator: .generator, signerID: Data("server".utf8)),
            "tampered Mobi proof must not verify")
    }

    // The two server points are distinct (sanity: we decoded two real proofs, not one twice).
    func testMobiServerPointsDistinct() {
        guard let (X3, _, _) = decodeProof(mobiServerR1aHex),
              let (X4, _, _) = decodeProof(mobiServerR1bHex) else { return }
        guard let (a, _) = X3.toAffine(), let (c, _) = X4.toAffine() else {
            return XCTFail("affine conversion failed")
        }
        XCTAssertNotEqual(a, c, "X3 and X4 must be distinct points")
    }

    // ============================================================
    // SELF-CONSISTENCY: full handshake (round 1 -> key confirmation)
    // ============================================================
    //
    // Drives our production client through the entire pairing against an
    // independent P-256 EC-JPAKE reference (jpake_reference.py). The reference
    // computes a deterministic, self-consistent handshake: both client and
    // server derive the identical point K, so the expected derived secret is
    // not a hardcoded magic number but the output of an independent
    // implementation of the same protocol.
    //
    // This exercises the paths the ZKP-only and KDF-only tests cannot:
    //   - clientRound2 (generator G' = X1+X3+X4, key share A = G'*(x2*s))
    //   - processRound2AndDeriveSecret (K derivation + SHA256(K.x) fix)
    //   - the round-3/4 HKDF + HMAC key-confirmation chain on a secret OUR
    //     code derived, not a literal.
    //
    // Client scalars are injected via the DEBUG-only testing initializer so the
    // handshake is reproducible. makeZKP still uses a random commitment, so the
    // V/r portion of clientRound2 varies per run; we assert on the derived
    // secret and the round-2 point A (both deterministic), not the full chunk.

    // Fixed client scalars (must match jpake_reference.py x1/x2).
    private let x1Hex = "1111111111111111111111111111111111111111111111111111111111111111"
    private let x2Hex = "2222222222222222222222222222222222222222222222222222222222222222"
    private let pairingCode = "482163"

    // Server round-1 (330B) and round-2 (165B) produced by the reference.
    private let refServerRound1Hex =
        "410451a7580833898ea1b183cbd7350a4099078c6ef1c1e18e970cd7683035f25e7d0110522712b0b5a7cff081685486984a94e6831edac46e7360fa9d834a7a81a14104e004562ae423e396098d1361fbd9756a6d0d4a9ab5f7c7b8e137b472f6c30a5a390d4929f8e54009f295ed86e9fa88eb0526e8a9cf9e699493d222c70a6e8876206386a6beac7d79af215dbd773d50ac9080d4bd14e686ae8abda87ba79335987e41045b36890dacbd7c9a96bb74a1ee28b3d2d75b72e09a20ef25cf8e6fd8a9f0350d0e14bed8d4682a34d83538bdff5b96e89a6666ec0db5745d02fa1210072df75a41046253e2e0ed07da23d6aaeffc70442717e3e4e1e7f58e5a0fba4f043316720d2f44caf8ef2e777f193b76d8145c90944906bd884cd73c8526786a37388e7837852025c9ca1103f8dc4dbf87427e3fdab5f4e24042b46c16cf9d11520c725623797c"
    private let refServerRound2Hex =
        "03001741044698a4bdde94c94f072586329896dec16551293806e4646dddb68d075eb035caea26c71b5e19bad24df5a09464d8a6dd0e447cf9b601d3b4982ebea0ab8fdcfa4104b4270f81fc76c60f6f10ad48fdc2df71df110cbfc3b9288e0d01d19e59270b1ececf696ef08844f207bbebfc113b9cc3a4d8e429f873ff1a28e04aeacf19509e207c852c7ebccaa2bf34105bc4dfe4458b4c008b79551b1ba4f23b50489d7746c3"

    // Expected outputs from the reference.
    private let refDerivedSecretHex = "87cff2cb90b24417eec26ed1e801904c82949d8b3d5f3218f122a4ced391daa7"
    private let refClientR2PointHex = "04698e968e54001eadee020c8dc23887725336ec5a1dff7c8e153e6430953a2a28e683800f33fc9a7a8dff64ee68cb77f9561dfc4713297fbf2097f99cf024d010"

    // Round-3/4 fixed nonces and expected digests (reference, derived from the secret).
    private let refServerNonce3Hex = "a1b2c3d4e5f60718"
    private let refServerNonce4Hex = "99aabbccddeeff00"
    private let refAuthKeyHex      = "9870b1efe8ee4d708f5ae1536cce2984874f77f3d2559d05d5211811982dd159"
    private let refServerDigestHex = "e806f2c5587e309f4ddde49f2c6f6fae19386e403804b6ce0a564605c49be8ed"

    func testFullHandshakeMatchesReference() {
        guard let x1 = Fq(bytes: hexToData(x1Hex)),
              let x2 = Fq(bytes: hexToData(x2Hex)) else { return XCTFail("scalar decode") }

        let ctx = ECJPAKEContext(testingPassword: Data(pairingCode.utf8),
                                 appInstanceId: 0, x1: x1, x2: x2)

        // Round 1: our client emits its own 330B (not asserted here — random
        // commitments). Consume the reference server's round 1.
        _ = try? ctx.clientRound1()
        XCTAssertNoThrow(try ctx.readRound1(hexToData(refServerRound1Hex)),
                         "client must accept the reference server round-1 proofs")

        // Round 2: our client's key-share point A must be deterministic.
        guard let r2 = try? ctx.clientRound2() else { return XCTFail("clientRound2 threw") }
        let (aBytes, _, _) = decodeChunk(r2)
        XCTAssertEqual(aBytes.map { String(format: "%02x", $0) }.joined(),
                       refClientR2PointHex,
                       "client round-2 key-share point A must match the reference")

        // Derive the shared secret from the reference server's round 2.
        guard let secret = try? ctx.processRound2AndDeriveSecret(hexToData(refServerRound2Hex)) else {
            return XCTFail("processRound2AndDeriveSecret threw")
        }
        let secretHex = secret.map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(secretHex, refDerivedSecretHex,
                       "derived secret must equal the independent reference (validates K derivation + SHA256(K.x))")

        // Round 3/4 key confirmation, chained on the secret OUR code derived.
        let authKey = TandemHKDF.build(nonce: hexToData(refServerNonce3Hex), keyMaterial: secret)
        XCTAssertEqual(authKey.map { String(format: "%02x", $0) }.joined(), refAuthKeyHex,
                       "Hkdf.build(serverNonce3, derivedSecret) must match the reference")

        let serverDigest = HmacUtils.hmacSHA256(key: authKey, data: hexToData(refServerNonce4Hex))
        XCTAssertEqual(serverDigest.map { String(format: "%02x", $0) }.joined(), refServerDigestHex,
                       "server confirmation digest over serverNonce4 must match — full chain verified")
    }
}
