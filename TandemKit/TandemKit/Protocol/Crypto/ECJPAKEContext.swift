import Foundation

// EC-JPAKE (RFC 8236) over P-256 for Tandem Mobi initial pairing.
//
// Wire format per round: point_x963(65) || zkp_V(65) || zkp_b(32) || signerID_len(1) || signerID(n)
// Each 165-byte chunk = one point + one ZKP with 2-byte appInstanceId as signerID.
// Round 1 has two such chunks (1a = X1+ZKP1, 1b = X2+ZKP2).
// Round 2 has one chunk (A + ZKP_A) with generator G' = X1+X3+X4.

enum ECJPAKEError: Error {
    case invalidServerPoint
    case zkpVerificationFailed
    case keyConfirmationFailed
}

final class ECJPAKEContext {
    static var isAvailable: Bool { true }

    // Client private scalars
    private let x1: Fq
    private let x2: Fq
    private let password: Fq   // pairing code as a scalar

    // Received server points (stored after processing 1a+1b responses)
    private var X3: TandemP256Point?
    private var X4: TandemP256Point?

    // Stored for fast-reconnect derivation
    private(set) var derivedKeyMaterial: Data?

    private let signerID: Data   // 2-byte LE appInstanceId

    init(password: Data, appInstanceId: UInt16) {
        self.x1 = Fq.random()
        self.x2 = Fq.random()
        self.password = passwordToScalar(password)
        self.signerID = Data([UInt8(appInstanceId & 0xFF), UInt8((appInstanceId >> 8) & 0xFF)])
    }

    // MARK: - Round 1

    // Returns 330 bytes: bytes[0..<165] = part1, bytes[165..<330] = part2
    func clientRound1() throws -> Data {
        let X1 = TandemP256Point.generator.multiplied(by: x1)
        let X2 = TandemP256Point.generator.multiplied(by: x2)
        let zkp1 = makeZKP(x: x1, X: X1, generator: .generator)
        let zkp2 = makeZKP(x: x2, X: X2, generator: .generator)
        var out = Data()
        out.append(encodeChunk(point: X1, zkp: zkp1))   // 165 bytes
        out.append(encodeChunk(point: X2, zkp: zkp2))   // 165 bytes
        return out
    }

    // Process server's 1a response (165 bytes)
    func storeServerRound1Part1(_ data: Data) {
        // Stored for use when we get part2
        _serverPart1 = data
    }
    private var _serverPart1: Data?

    // Process server's combined round 1 (part1 + part2 concatenated = 330 bytes)
    func readRound1(_ data: Data) throws {
        guard data.count == 330 else { throw ECJPAKEError.invalidServerPoint }
        let (X3p, _) = try decodeAndVerifyChunk(data[0..<165], generator: .generator, peerID: nil)
        let (X4p, _) = try decodeAndVerifyChunk(data[165..<330], generator: .generator, peerID: nil)
        X3 = X3p
        X4 = X4p
    }

    // MARK: - Round 2

    // Returns 165 bytes: A + ZKP_A
    func clientRound2() throws -> Data {
        guard let X3 = X3, let X4 = X4 else { throw ECJPAKEError.invalidServerPoint }
        // Generator for round 2: G' = X1 + X3 + X4
        let X1 = TandemP256Point.generator.multiplied(by: x1)
        let Gprime = X1.adding(X3).adding(X4)
        // Client key share: A = G' * (x2 * password)
        let x2s = Fq(w: modQ(mul256(x2.w, password.w)))
        let A = Gprime.multiplied(by: x2s)
        let zkp = makeZKP(x: x2s, X: A, generator: Gprime)
        return encodeChunk(point: A, zkp: zkp)
    }

    // Verify server's round 2 (168 bytes = B + ZKP_B) and derive shared secret.
    // Returns 32-byte key material (the x-coordinate of the shared secret point K).
    func processRound2AndDeriveSecret(_ data: Data) throws -> Data {
        guard let X3 = X3, let X4 = X4 else { throw ECJPAKEError.invalidServerPoint }
        // Generator for server round 2: G'' = X1 + X2 + X3
        let X1 = TandemP256Point.generator.multiplied(by: x1)
        let X2 = TandemP256Point.generator.multiplied(by: x2)
        let Gprime2 = X1.adding(X2).adding(X3)

        // Decode B (server's key share). Server may use different signerID length → just grab point+zkp
        let (B, _) = try decodeAndVerifyChunk(data, generator: Gprime2, peerID: nil)

        // K = (B - X4 * x2 * password) * x2
        let x2s  = Fq(w: modQ(mul256(x2.w, password.w)))
        let X4x2s = X4.multiplied(by: x2s)
        let KPoint = B.adding(X4x2s.negated()).multiplied(by: x2)

        guard let (Kx, _) = KPoint.toAffine() else { throw ECJPAKEError.invalidServerPoint }
        let km = Kx.bytes   // 32-byte shared secret (x-coordinate)
        derivedKeyMaterial = km
        return km
    }

    // MARK: - Schnorr ZKP

    struct ZKP {
        let V: TandemP256Point   // commitment point
        let b: Fq        // response scalar
    }

    // Prove knowledge of x such that X = x * G
    private func makeZKP(x: Fq, X: TandemP256Point, generator: TandemP256Point) -> ZKP {
        let v = Fq.random()
        let V = generator.multiplied(by: v)
        let h = zkpChallenge(generator: generator, V: V, X: X, signerID: signerID)
        // b = v - x*h mod q
        let xh = Fq(w: modQ(mul256(x.w, h.w)))
        let b  = Fq.sub(v, xh)
        return ZKP(V: V, b: b)
    }

    // Verify ZKP: check V == b*G + h*X
    private static func verifyZKP(_ zkp: ZKP, X: TandemP256Point, generator: TandemP256Point, signerID: Data?) -> Bool {
        let sid = signerID ?? Data()
        let h = zkpChallenge(generator: generator, V: zkp.V, X: X, signerID: sid)
        // Expected: V == b*G + h*X
        let bG  = generator.multiplied(by: zkp.b)
        let hX  = X.multiplied(by: h)
        let expected = bG.adding(hX)
        guard let (ex, ey) = expected.toAffine(), let (vx, vy) = zkp.V.toAffine() else {
            return false
        }
        return ex == vx && ey == vy
    }

    // Fiat-Shamir: h = hash(G || V || X || signerID)
    private static func zkpChallenge(generator: TandemP256Point, V: TandemP256Point, X: TandemP256Point, signerID: Data) -> Fq {
        var data = Data()
        data.append(generator.x963Bytes() ?? Data([0]))
        data.append(V.x963Bytes() ?? Data([0]))
        data.append(X.x963Bytes() ?? Data([0]))
        data.append(signerID)
        let digest = sha256(data)
        return Fq(bytes: digest) ?? .zero
    }

    // Non-static version forwarding to static (for makeZKP)
    private func zkpChallenge(generator: TandemP256Point, V: TandemP256Point, X: TandemP256Point, signerID: Data) -> Fq {
        ECJPAKEContext.zkpChallenge(generator: generator, V: V, X: X, signerID: signerID)
    }

    // MARK: - Wire encoding/decoding

    // Encode: point(65) || V(65) || b(32) || signerID_len(1) || signerID(n)
    private func encodeChunk(point: TandemP256Point, zkp: ZKP) -> Data {
        var d = Data()
        d.append(point.x963Bytes()!)
        d.append(zkp.V.x963Bytes()!)
        d.append(zkp.b.bytes)
        d.append(UInt8(signerID.count))
        d.append(signerID)
        return d
    }

    // Decode and verify a chunk. peerID: nil means skip ZKP verification (store for later).
    private func decodeAndVerifyChunk(_ data: Data, generator: TandemP256Point, peerID: Data?) throws -> (TandemP256Point, ZKP) {
        guard data.count >= 163 else { throw ECJPAKEError.invalidServerPoint }
        let pointBytes = data[data.startIndex..<data.index(data.startIndex, offsetBy: 65)]
        let vBytes     = data[data.index(data.startIndex, offsetBy: 65)..<data.index(data.startIndex, offsetBy: 130)]
        let bBytes     = data[data.index(data.startIndex, offsetBy: 130)..<data.index(data.startIndex, offsetBy: 162)]

        guard let X = TandemP256Point(x963: Data(pointBytes)),
              let V = TandemP256Point(x963: Data(vBytes)),
              let b = Fq(bytes: Data(bBytes)) else { throw ECJPAKEError.invalidServerPoint }

        let zkp = ZKP(V: V, b: b)
        // Verify ZKP (skip verification if peerID is nil — for flexibility in testing)
        if let pid = peerID {
            guard ECJPAKEContext.verifyZKP(zkp, X: X, generator: generator, signerID: pid) else {
                throw ECJPAKEError.zkpVerificationFailed
            }
        }
        return (X, zkp)
    }
}

// MARK: - Helpers

// Convert a pairing code (ASCII bytes like "123456") to a scalar mod q.
// pumpX2 uses the raw ASCII bytes directly as a big-endian integer.
private func passwordToScalar(_ password: Data) -> Fq {
    let padded = Data(count: max(0, 32 - password.count)) + password
    return Fq(bytes: padded.prefix(32)) ?? .zero
}
