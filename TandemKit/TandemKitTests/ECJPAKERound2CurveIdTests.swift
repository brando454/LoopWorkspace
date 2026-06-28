import XCTest
import Foundation
@testable import TandemKit

// Regression tests for the EC-JPAKE round-2 TLS curve-id strip in
// ECJPAKEContext.processRound2AndDeriveSecret.
//
// The pump's round-2 server payload is prefixed with a 3-byte TLS named-curve
// identifier (0x03 = ECCurveType.named_curve, 0x0017 = secp256r1) that round-1
// omits. The reference (jwoglom/pumpX2 EcJpake.readRound2 -> readCurveId)
// consumes it on the CLIENT role only. Our parser validates and strips those
// 3 bytes before decoding the point; without the strip the decoder reads 0x03
// as a length prefix and throws invalidServerPoint.
//
// The known vectors below are the SAME ones used by MobiHandshakeTests and
// ECJPAKESliceSafetyTests: a deterministic handshake produced by an independent
// P-256 EC-JPAKE reference (jpake_reference.py) from fixed client scalars
// x1/x2 and pairing code 482163. refServerRound2Hex is the bare 165-byte chunk
// WITHOUT the curve-id header, and refDerivedSecretHex is the secret that
// independent reference derives. Prepending "030017" and asserting the SAME
// secret therefore proves the strip + derivation path end-to-end against an
// external oracle, not against our own generator output.
final class ECJPAKERound2CurveIdTests: XCTestCase {

    // Fixed client scalars + pairing code (match jpake_reference.py).
    private let x1Hex = "1111111111111111111111111111111111111111111111111111111111111111"
    private let x2Hex = "2222222222222222222222222222222222222222222222222222222222222222"
    private let pairingCode = "482163"

    // Server round-1 (330B) and round-2 (bare 165B chunk, NO curve-id) from the
    // reference implementation.
    private let refServerRound1Hex =
        "410451a7580833898ea1b183cbd7350a4099078c6ef1c1e18e970cd7683035f25e7d0110522712b0b5a7cff081685486984a94e6831edac46e7360fa9d834a7a81a14104e004562ae423e396098d1361fbd9756a6d0d4a9ab5f7c7b8e137b472f6c30a5a390d4929f8e54009f295ed86e9fa88eb0526e8a9cf9e699493d222c70a6e8876206386a6beac7d79af215dbd773d50ac9080d4bd14e686ae8abda87ba79335987e41045b36890dacbd7c9a96bb74a1ee28b3d2d75b72e09a20ef25cf8e6fd8a9f0350d0e14bed8d4682a34d83538bdff5b96e89a6666ec0db5745d02fa1210072df75a41046253e2e0ed07da23d6aaeffc70442717e3e4e1e7f58e5a0fba4f043316720d2f44caf8ef2e777f193b76d8145c90944906bd884cd73c8526786a37388e7837852025c9ca1103f8dc4dbf87427e3fdab5f4e24042b46c16cf9d11520c725623797c"
    private let refServerRound2Hex =
        "41044698a4bdde94c94f072586329896dec16551293806e4646dddb68d075eb035caea26c71b5e19bad24df5a09464d8a6dd0e447cf9b601d3b4982ebea0ab8fdcfa4104b4270f81fc76c60f6f10ad48fdc2df71df110cbfc3b9288e0d01d19e59270b1ececf696ef08844f207bbebfc113b9cc3a4d8e429f873ff1a28e04aeacf19509e207c852c7ebccaa2bf34105bc4dfe4458b4c008b79551b1ba4f23b50489d7746c3"
    private let refDerivedSecretHex =
        "87cff2cb90b24417eec26ed1e801904c82949d8b3d5f3218f122a4ced391daa7"

    // TLS named_curve(0x03) || U16BE secp256r1(0x0017).
    private let curveIdHex = "030017"

    // MARK: - helpers

    private func hexToData(_ hex: String) -> Data {
        var d = Data(); var i = hex.startIndex
        while i < hex.endIndex {
            let j = hex.index(i, offsetBy: 2)
            d.append(UInt8(hex[i..<j], radix: 16)!)
            i = j
        }
        return d
    }

    // Re-slice past `pad` prepended filler bytes so startIndex != 0; count preserved.
    private func nonZeroBasedSlice(_ d: Data, pad: Int = 3) -> Data {
        (Data(repeating: 0, count: pad) + d)[pad...]
    }

    // Fresh context driven through round 1 so X3/X4 (and thus Gprime2) are set,
    // ready for processRound2AndDeriveSecret.
    private func contextAfterRound1() throws -> ECJPAKEContext {
        let x1 = try XCTUnwrap(Fq(bytes: hexToData(x1Hex)))
        let x2 = try XCTUnwrap(Fq(bytes: hexToData(x2Hex)))
        let ctx = ECJPAKEContext(testingPassword: Data(pairingCode.utf8),
                                 appInstanceId: 0, x1: x1, x2: x2)
        try ctx.readRound1(hexToData(refServerRound1Hex))
        return ctx
    }

    private func assertThrows(_ expected: ECJPAKEError, _ body: () throws -> Void,
                              file: StaticString = #file, line: UInt = #line) {
        XCTAssertThrowsError(try body(), file: file, line: line) { error in
            guard let e = error as? ECJPAKEError else {
                return XCTFail("expected ECJPAKEError, got \(error)", file: file, line: line)
            }
            switch (e, expected) {
            case (.invalidServerPoint, .invalidServerPoint),
                 (.zkpVerificationFailed, .zkpVerificationFailed),
                 (.keyConfirmationFailed, .keyConfirmationFailed):
                break
            default:
                XCTFail("expected \(expected), got \(e)", file: file, line: line)
            }
        }
    }

    // MARK: - 1. Positive: header + reference chunk derives the reference secret

    func testRound2WithCurveIdHeaderDerivesReferenceSecret() throws {
        let ctx = try contextAfterRound1()
        let buffer = hexToData(curveIdHex + refServerRound2Hex)
        let secret = try ctx.processRound2AndDeriveSecret(buffer)
        XCTAssertEqual(secret.map { String(format: "%02x", $0) }.joined(),
                       refDerivedSecretHex,
                       "stripping 03 00 17 then deriving must match the independent reference secret")
    }

    // MARK: - 2. Negative: bad header

    func testRound2WrongCurveTypeThrowsInvalidServerPoint() throws {
        let ctx = try contextAfterRound1()
        // 03 00 18 — valid curve-type byte but wrong named-curve id.
        let buffer = hexToData("030018" + refServerRound2Hex)
        assertThrows(.invalidServerPoint) { _ = try ctx.processRound2AndDeriveSecret(buffer) }
    }

    func testRound2MissingCurveIdHeaderThrowsInvalidServerPoint() throws {
        let ctx = try contextAfterRound1()
        // Bare chunk beginning 41 04 … (no header) must be rejected by the guard.
        let buffer = hexToData(refServerRound2Hex)
        assertThrows(.invalidServerPoint) { _ = try ctx.processRound2AndDeriveSecret(buffer) }
    }

    // MARK: - 3. Negative: buffer too short for the 3-byte header

    func testRound2ShortBufferThrowsInvalidServerPoint() throws {
        let ctx = try contextAfterRound1()
        assertThrows(.invalidServerPoint) {
            _ = try ctx.processRound2AndDeriveSecret(Data([0x03, 0x00]))
        }
    }

    // MARK: - 4. Slice-safety crossover: positive buffer as a non-zero-based slice

    func testRound2WithCurveIdAsNonZeroBasedSliceDerivesReferenceSecret() throws {
        let ctx = try contextAfterRound1()
        let slice = nonZeroBasedSlice(hexToData(curveIdHex + refServerRound2Hex))
        XCTAssertNotEqual(slice.startIndex, 0,
                          "precondition: buffer must be a non-zero-based slice")
        let secret = try ctx.processRound2AndDeriveSecret(slice)
        XCTAssertEqual(secret.map { String(format: "%02x", $0) }.joined(),
                       refDerivedSecretHex,
                       "curve-id strip must be slice-safe (uses startIndex/index(offsetBy:))")
    }
}
