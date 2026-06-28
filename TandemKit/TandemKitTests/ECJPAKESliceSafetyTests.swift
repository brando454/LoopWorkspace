import XCTest
import Foundation
@testable import TandemKit

// Regression tests for the EC-JPAKE handshake crash (EXC_BREAKPOINT inside
// Data._Representation.subscript.getter, reported from ECJPAKEContext.readRound1
// via TandemAuthState.handleResponse).
//
// Root cause: Swift `Data` slices retain the parent buffer's index range — they
// are NOT rebased to 0. The handshake parsers subscript with absolute literal
// indices (`data[0..<165]`, `cargo[2..<167]`, `cargo[0]`, ...). The `count`
// guards pass for a slice because `count` is length-based, then the literal
// subscript reads below `startIndex` and the runtime bounds-check traps.
//
// These tests feed the exact same bytes both as a zero-based `Data` and as a
// non-zero-based slice (startIndex != 0). Before the fix the slice cases trap;
// after the boundary-normalization fix they must succeed and produce results
// byte-identical to the zero-based path.
final class ECJPAKESliceSafetyTests: XCTestCase {

    // Fixed client scalars + pairing code matching the independent reference
    // handshake (jpake_reference.py, also used by MobiHandshakeTests), so the
    // server round-1/round-2 vectors below are genuine, verifiable proofs. A
    // malformed body would throw inside decodeAndVerifyChunk *before* reaching
    // the index-base defect we are probing, so valid vectors are required to
    // prove the subscript path itself is safe.
    private let x1Hex = "1111111111111111111111111111111111111111111111111111111111111111"
    private let x2Hex = "2222222222222222222222222222222222222222222222222222222222222222"
    private let pairingCode = "482163"

    // Server round-1 (330B: part1[0..<165] + part2[165..<330]) and round-2 (165B)
    // produced by the reference implementation.
    private let refServerRound1Hex =
        "410451a7580833898ea1b183cbd7350a4099078c6ef1c1e18e970cd7683035f25e7d0110522712b0b5a7cff081685486984a94e6831edac46e7360fa9d834a7a81a14104e004562ae423e396098d1361fbd9756a6d0d4a9ab5f7c7b8e137b472f6c30a5a390d4929f8e54009f295ed86e9fa88eb0526e8a9cf9e699493d222c70a6e8876206386a6beac7d79af215dbd773d50ac9080d4bd14e686ae8abda87ba79335987e41045b36890dacbd7c9a96bb74a1ee28b3d2d75b72e09a20ef25cf8e6fd8a9f0350d0e14bed8d4682a34d83538bdff5b96e89a6666ec0db5745d02fa1210072df75a41046253e2e0ed07da23d6aaeffc70442717e3e4e1e7f58e5a0fba4f043316720d2f44caf8ef2e777f193b76d8145c90944906bd884cd73c8526786a37388e7837852025c9ca1103f8dc4dbf87427e3fdab5f4e24042b46c16cf9d11520c725623797c"
    private let refServerRound2Hex =
        "03001741044698a4bdde94c94f072586329896dec16551293806e4646dddb68d075eb035caea26c71b5e19bad24df5a09464d8a6dd0e447cf9b601d3b4982ebea0ab8fdcfa4104b4270f81fc76c60f6f10ad48fdc2df71df110cbfc3b9288e0d01d19e59270b1ececf696ef08844f207bbebfc113b9cc3a4d8e429f873ff1a28e04aeacf19509e207c852c7ebccaa2bf34105bc4dfe4458b4c008b79551b1ba4f23b50489d7746c3"
    private let refDerivedSecretHex =
        "87cff2cb90b24417eec26ed1e801904c82949d8b3d5f3218f122a4ced391daa7"

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

    // Return a copy of `d` as a slice whose startIndex != 0, by prepending
    // `pad` filler bytes and re-slicing past them. `count` is preserved.
    private func nonZeroBasedSlice(_ d: Data, pad: Int = 3) -> Data {
        let s = (Data(repeating: 0, count: pad) + d)[pad...]
        return s
    }

    // First length-prefixed field of a 165-byte chunk = the x963 point bytes.
    private func chunkPoint(_ chunk: Data) -> Data {
        var c = chunk.startIndex
        let n = Int(chunk[c]); c = chunk.index(after: c)
        let end = chunk.index(c, offsetBy: n)
        return Data(chunk[c..<end])
    }

    private func makeContext() -> ECJPAKEContext {
        let x1 = Fq(bytes: hexToData(x1Hex))!
        let x2 = Fq(bytes: hexToData(x2Hex))!
        return ECJPAKEContext(testingPassword: Data(pairingCode.utf8),
                              appInstanceId: 0, x1: x1, x2: x2)
    }

    // MARK: - Test 1: readRound1 with a zero-based Data AND a non-zero-based slice

    func testReadRound1AcceptsNonZeroBasedSliceIdenticalToZeroBased() throws {
        let body = hexToData(refServerRound1Hex)
        XCTAssertEqual(body.count, 330)
        XCTAssertEqual(body.startIndex, 0, "baseline body must be zero-based")

        // startIndex == 3, count == 330 — the precise runtime shape that traps
        // before the fix (count guard passes, literal subscript reads below 3).
        let slice = nonZeroBasedSlice(body, pad: 3)
        XCTAssertEqual(slice.count, 330)
        XCTAssertEqual(slice.startIndex, 3,
                       "precondition: slice must be non-zero-based to exercise the bug")

        // Zero-based baseline.
        let ctxZero = makeContext()
        XCTAssertNoThrow(try ctxZero.readRound1(body),
                         "zero-based 330-byte round-1 must be accepted")
        let aZero = chunkPoint(try ctxZero.clientRound2())

        // Non-zero-based slice — must NOT trap and must derive the same X3/X4,
        // hence the same deterministic round-2 key-share point A.
        let ctxSlice = makeContext()
        XCTAssertNoThrow(try ctxSlice.readRound1(slice),
                         "non-zero-based 330-byte slice must be accepted (was EXC_BREAKPOINT before fix)")
        let aSlice = chunkPoint(try ctxSlice.clientRound2())

        XCTAssertEqual(aZero, aSlice,
                       "slice and zero-based inputs must yield identical round-2 results")
    }

    // MARK: - Test 2: full TandemAuthState 1a -> 1b path with sliced 167-byte cargos

    func testAuthState1aTo1bWithSlicedCargosReturnsJpake2Request() throws {
        let body = hexToData(refServerRound1Hex)
        let part1 = Data(body[0..<165])
        let part2 = Data(body[165..<330])

        // Realistic cargo = 2-byte LE appInstanceId + 165-byte server part.
        func cargo(_ part: Data) -> Data {
            var c = Data([0xAB, 0xCD]); c.append(part); return c   // 167 bytes
        }
        let cargo1a = nonZeroBasedSlice(cargo(part1))
        let cargo1b = nonZeroBasedSlice(cargo(part2))
        XCTAssertEqual(cargo1a.count, 167)
        XCTAssertNotEqual(cargo1a.startIndex, 0,
                          "precondition: 1a cargo must be a non-zero-based slice")
        XCTAssertNotEqual(cargo1b.startIndex, 0,
                          "precondition: 1b cargo must be a non-zero-based slice")

        let auth = TandemAuthState(pairingCode: pairingCode)
        let first = try auth.begin()
        XCTAssertTrue(first is Jpake1aRequest)

        // 0x21 (Jpake1aResponse): parses cargo[0], cargo[2..<167] — traps on a
        // slice before the fix.
        let req1b = try XCTUnwrap(try auth.handleResponse(opCode: Jpake1aResponse.opCode, cargo: cargo1a))
        XCTAssertTrue(req1b is Jpake1bRequest, "1a response must advance to a Jpake1bRequest")

        // 0x23 (Jpake1bResponse): parses the slice, concatenates the stored
        // part1, and calls ECJPAKEContext.readRound1 — the reported crash site.
        let req2 = try XCTUnwrap(try auth.handleResponse(opCode: Jpake1bResponse.opCode, cargo: cargo1b))
        XCTAssertTrue(req2 is Jpake2Request,
                      "1b response must drive readRound1 + clientRound2 and return a Jpake2Request, not crash")
    }

    // MARK: - Test 3: end-to-end reference vector delivered entirely as slices

    func testFullDeriveFromSlicedReferenceVectorsMatchesReferenceSecret() throws {
        let ctx = makeContext()

        let round1Slice = nonZeroBasedSlice(hexToData(refServerRound1Hex))
        let round2Slice = nonZeroBasedSlice(hexToData(refServerRound2Hex))
        XCTAssertNotEqual(round1Slice.startIndex, 0)
        XCTAssertNotEqual(round2Slice.startIndex, 0)

        XCTAssertNoThrow(try ctx.readRound1(round1Slice))
        let secret = try ctx.processRound2AndDeriveSecret(round2Slice)
        let secretHex = secret.map { String(format: "%02x", $0) }.joined()

        XCTAssertEqual(secretHex, refDerivedSecretHex,
                       "deriving from non-zero-based slices must match the independent reference secret")
    }

    // MARK: - response-parser slice safety (the same defect at the message layer)

    func testResponseParsersAcceptSlicesIdenticalToZeroBased() throws {
        let body = hexToData(refServerRound1Hex)
        let part1 = Data(body[0..<165])
        var c = Data([0x12, 0x34]); c.append(part1)          // 167-byte zero-based cargo

        let fromZero = Jpake1aResponse(cargo: c)
        let fromSlice = Jpake1aResponse(cargo: nonZeroBasedSlice(c))
        XCTAssertNotNil(fromZero)
        XCTAssertNotNil(fromSlice, "parser must accept a non-zero-based slice (was a trap before fix)")
        XCTAssertEqual(fromZero?.appInstanceId, fromSlice?.appInstanceId)
        XCTAssertEqual(Data(fromZero!.serverRound1Part1), Data(fromSlice!.serverRound1Part1),
                       "parsed server part must be byte-identical for slice and zero-based cargo")
    }
}
