import XCTest
import Foundation
@testable import TandemKit

// Byte-compatibility tests for the EC-JPAKE zero-knowledge-proof path.
//
// The headline test (testCapturedServerProofVerifies) uses a REAL round-1
// server proof captured from a Tandem pump (from jwoglom/pumpX2
// Jpake1aResponseTest, android-2024-02-29-6char2 capture). If our Fiat-Shamir
// challenge layout disagrees with the pump by a single byte, verification of a
// genuine pump proof fails — which is the failure mode that internal
// round-trip tests cannot catch.
final class ECJPAKEZKPTests: XCTestCase {

    // One 165-byte server round-1 chunk (1a), structure:
    //   U8(65) || X(65) || U8(65) || V(65) || U8(32) || r(32)
    // Verified against generator G with prover id = "server".
    private let capturedServerChunkHex =
        "41048139ce7f5012e2c32c8be4a3eb4511f9bd1c471bed0f1ccf623a2a0399e4f7de" +
        "35e00c2ae0d8b42d173183ed624b276caf83bb68ce665f1acab03b758056dbca4104" +
        "7a0e04939c0089e44de6268e0018c390c5fb1d4d832a52fd67dcd003d31fd576ff3e" +
        "b7a838d0b389a0d2544fc740119aced931ac6385ab8ca620e0756d17f5fb20b570ea" +
        "8e5460cc45b1b733c2edb2bc32a206f1aab956da044e01ba1be6d09913"

    private func hexToData(_ hex: String) -> Data {
        var d = Data(); var i = hex.startIndex
        while i < hex.endIndex {
            let j = hex.index(i, offsetBy: 2)
            d.append(UInt8(hex[i..<j], radix: 16)!)
            i = j
        }
        return d
    }

    // Decode the three length-prefixed fields of a chunk into (X, V, r).
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

    // HEADLINE: a genuine pump round-1 proof must verify against id="server".
    // This proves our challenge hash (U32BE length prefixes, uncompressed
    // points, role string, mod n) is byte-identical to the pump's.
    func testCapturedServerProofVerifies() {
        let chunk = hexToData(capturedServerChunkHex)
        XCTAssertEqual(chunk.count, 165)
        let (xBytes, vBytes, rBytes) = decodeChunk(chunk)

        guard let X = TandemP256Point(validatedX963: xBytes) else {
            return XCTFail("captured X failed on-curve validation")
        }
        guard let V = TandemP256Point(validatedX963: vBytes) else {
            return XCTFail("captured V failed on-curve validation")
        }
        guard let r = Fq(bytes: rBytes) else { return XCTFail("bad r scalar") }

        let zkp = ECJPAKEContext.ZKP(V: V, b: r)
        let serverID = Data("server".utf8)

        XCTAssertTrue(
            ECJPAKEContext.verifyZKPForTesting(zkp, X: X, generator: .generator, signerID: serverID),
            "genuine pump proof must verify with id=server — challenge layout mismatch if this fails"
        )
    }

    // Negative: same proof must FAIL with the wrong role id (would catch a
    // verifier that ignores the id field).
    func testCapturedServerProofFailsWithClientID() {
        let chunk = hexToData(capturedServerChunkHex)
        let (xBytes, vBytes, rBytes) = decodeChunk(chunk)
        guard let X = TandemP256Point(validatedX963: xBytes),
              let V = TandemP256Point(validatedX963: vBytes),
              let r = Fq(bytes: rBytes) else { return XCTFail("captured point/scalar failed to decode") }
        let zkp = ECJPAKEContext.ZKP(V: V, b: r)
        XCTAssertFalse(
            ECJPAKEContext.verifyZKPForTesting(zkp, X: X, generator: .generator, signerID: Data("client".utf8)),
            "proof must not verify under the wrong role id"
        )
    }

    // Negative: tamper one byte of r — verification must fail.
    func testTamperedProofFails() {
        let chunk = hexToData(capturedServerChunkHex)
        let (xBytes, vBytes, rBytes) = decodeChunk(chunk)
        guard let X = TandemP256Point(validatedX963: xBytes),
              let V = TandemP256Point(validatedX963: vBytes) else { return XCTFail("captured point failed to decode") }
        var bad = rBytes; bad[bad.startIndex] ^= 0x01
        guard let r = Fq(bytes: bad) else { return } // if reduced away, fine
        let zkp = ECJPAKEContext.ZKP(V: V, b: r)
        XCTAssertFalse(
            ECJPAKEContext.verifyZKPForTesting(zkp, X: X, generator: .generator, signerID: Data("server".utf8)),
            "tampered proof must not verify"
        )
    }

    // Off-curve point must be rejected at decode (invalid-curve attack guard).
    func testOffCurvePointRejected() {
        // Valid X but flip a low byte of the y-coordinate so (x,y) is off-curve.
        let chunk = hexToData(capturedServerChunkHex)
        let (xBytes, _, _) = decodeChunk(chunk)
        var bad = xBytes
        bad[bad.index(before: bad.endIndex)] ^= 0x01   // perturb last y byte
        XCTAssertNil(TandemP256Point(validatedX963: bad),
                     "off-curve point must be rejected")
    }

    // Identity / all-zero encoding rejected.
    func testInfinityRejected() {
        var z = Data([0x04]); z.append(Data(count: 64))
        XCTAssertNil(TandemP256Point(validatedX963: z))
    }

    // Internal round-trip: our own client proof verifies against our verifier.
    func testClientRoundTripProof() {
        // clientRound1 produces two chunks (id="client"); verify each with id="client".
        let ctx = ECJPAKEContext(password: Data("123456".utf8), appInstanceId: 0)
        let round1 = try! ctx.clientRound1()
        XCTAssertEqual(round1.count, 330)
        for offset in [0, 165] {
            let chunk = Data(round1[round1.index(round1.startIndex, offsetBy: offset)..<round1.index(round1.startIndex, offsetBy: offset + 165)])
            let (xB, vB, rB) = decodeChunk(chunk)
            guard let X = TandemP256Point(validatedX963: xB),
                  let V = TandemP256Point(validatedX963: vB),
                  let r = Fq(bytes: rB) else { return XCTFail("client round1 point/scalar failed to decode") }
            XCTAssertTrue(
                ECJPAKEContext.verifyZKPForTesting(ECJPAKEContext.ZKP(V: V, b: r), X: X, generator: .generator, signerID: Data("client".utf8)),
                "our own client proof must verify under id=client"
            )
        }
    }
}
