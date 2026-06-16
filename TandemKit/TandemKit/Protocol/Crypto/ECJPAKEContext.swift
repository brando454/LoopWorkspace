import Foundation

// EC-JPAKE (RFC 8236) over P-256 for Tandem Mobi initial pairing.
//
// Wire format per round (matches pumpX2 writePoint/writeZkp, confirmed against
// captured pump bytes): each 165-byte chunk is
//   U8(65) || point_x963(65) || U8(65) || zkp_V(65) || U8(32) || zkp_b(32)
// There is NO signerID on the wire. The Fiat-Shamir challenge hashes a fixed
// role identity ("client"/"server") that is never transmitted.
// Round 1 has two such chunks (1a = X1+ZKP1, 1b = X2+ZKP2).
// Round 2 has one chunk (A + ZKP_A) with generator G' = X1+X3+X4.
// The 2-byte little-endian appInstanceId is a SEPARATE field that prefixes the
// 165-byte challenge to form the request cargo; it is not part of JPAKE.

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

    // The 2-byte LE appInstanceId that prefixes the request cargo. Stored for
    // the message layer; it is NOT used inside the JPAKE proofs.
    let appInstanceIdLE: Data

    init(password: Data, appInstanceId: UInt16) {
        self.x1 = Fq.random()
        self.x2 = Fq.random()
        self.password = passwordToScalar(password)
        self.appInstanceIdLE = Data([UInt8(appInstanceId & 0xFF), UInt8((appInstanceId >> 8) & 0xFF)])
    }

    #if DEBUG
    // Test-only initializer that injects fixed client scalars so a full
    // handshake can be replayed deterministically against an independent
    // reference. Compiled out of release builds. Mirrors the production init
    // exactly except x1/x2 are supplied rather than randomly generated.
    init(testingPassword password: Data, appInstanceId: UInt16, x1: Fq, x2: Fq) {
        self.x1 = x1
        self.x2 = x2
        self.password = passwordToScalar(password)
        self.appInstanceIdLE = Data([UInt8(appInstanceId & 0xFF), UInt8((appInstanceId >> 8) & 0xFF)])
    }
    #endif

    // MARK: - Round 1

    // Returns 330 bytes: bytes[0..<165] = part1, bytes[165..<330] = part2
    func clientRound1() throws -> Data {
        let X1 = TandemP256Point.generator.multiplied(by: x1)
        let X2 = TandemP256Point.generator.multiplied(by: x2)
        let zkp1 = makeZKP(x: x1, X: X1, generator: .generator, id: Self.clientID)
        let zkp2 = makeZKP(x: x2, X: X2, generator: .generator, id: Self.clientID)
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
        let (X3p, _) = try decodeAndVerifyChunk(data[0..<165], generator: .generator, peerID: Self.serverID)
        let (X4p, _) = try decodeAndVerifyChunk(data[165..<330], generator: .generator, peerID: Self.serverID)
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
        let zkp = makeZKP(x: x2s, X: A, generator: Gprime, id: Self.clientID)
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
        let (B, _) = try decodeAndVerifyChunk(data, generator: Gprime2, peerID: Self.serverID)

        // K = (B - X4 * x2 * password) * x2
        let x2s  = Fq(w: modQ(mul256(x2.w, password.w)))
        let X4x2s = X4.multiplied(by: x2s)
        let KPoint = B.adding(X4x2s.negated()).multiplied(by: x2)

        guard let (Kx, _) = KPoint.toAffine() else { throw ECJPAKEError.invalidServerPoint }
        // The shared secret is SHA-256 of the X-coordinate of K, NOT the raw
        // X-coordinate. The reference (pumpX2 EcJpake.deriveSecret) hashes
        // BigInteger.asUnsignedByteArray(K.x), i.e. the MINIMAL big-endian
        // encoding with any leading zero bytes stripped, so we strip leading
        // zeros from the fixed 32-byte encoding before hashing to stay
        // byte-identical to the pump. Verified against the jwoglom deterministic
        // vector (derivedSecret 45d66d65…0c78d4).
        var xMinimal = Kx.bytes
        while xMinimal.first == 0 { xMinimal.removeFirst() }
        let km = sha256(xMinimal)   // 32-byte session secret
        derivedKeyMaterial = km
        return km
    }

    // MARK: - Schnorr ZKP

    struct ZKP {
        let V: TandemP256Point   // commitment point
        let b: Fq        // response scalar
    }

    // Prove knowledge of x such that X = x * G. `id` is the prover role string
    // ("client" for our proofs); it is hashed into the challenge, never sent.
    private func makeZKP(x: Fq, X: TandemP256Point, generator: TandemP256Point, id: Data) -> ZKP {
        let v = Fq.random()
        let V = generator.multiplied(by: v)
        let h = zkpChallenge(generator: generator, V: V, X: X, signerID: id)
        // b = v - x*h mod q
        let xh = Fq(w: modQ(mul256(x.w, h.w)))
        let b  = Fq.sub(v, xh)
        return ZKP(V: V, b: b)
    }

    // Internal hook so tests can verify proofs against captured pump bytes
    // without exposing the private implementation surface.
    #if DEBUG
    static func verifyZKPForTesting(_ zkp: ZKP, X: TandemP256Point, generator: TandemP256Point, signerID: Data) -> Bool {
        verifyZKP(zkp, X: X, generator: generator, signerID: signerID)
    }
    #endif

    // Verify ZKP: check V == b*G + h*X
    private static func verifyZKP(_ zkp: ZKP, X: TandemP256Point, generator: TandemP256Point, signerID: Data) -> Bool {
        let h = zkpChallenge(generator: generator, V: zkp.V, X: X, signerID: signerID)
        // Expected: V == b*G + h*X
        let bG  = generator.multiplied(by: zkp.b)
        let hX  = X.multiplied(by: h)
        let expected = bG.adding(hX)
        guard let (ex, ey) = expected.toAffine(), let (vx, vy) = zkp.V.toAffine() else {
            return false
        }
        return ex == vx && ey == vy
    }

    // Fiat-Shamir challenge, byte-for-byte compatible with the Tandem pump
    // (mbedTLS-style EC-JPAKE, per jwoglom/pumpX2 io.particle.crypto.EcJpake).
    //
    //   h = SHA256( F(G) || F(V) || F(X) || U32BE(len(id)) || id ) mod n
    //   F(P) = U32BE(len(P_enc)) || P_enc,  P_enc = uncompressed 65-byte point.
    //
    // `id` is the PROVER role string: "client" for our own proofs, "server"
    // when verifying the pump. It is NOT transmitted on the wire; it exists
    // only inside this hash. The earlier implementation omitted every length
    // prefix and hashed the 2-byte appInstanceId here, so neither our proofs
    // nor our verification matched what the pump computes.
    private static func zkpChallenge(generator: TandemP256Point, V: TandemP256Point, X: TandemP256Point, signerID: Data) -> Fq {
        var data = Data()
        appendHashPoint(&data, generator)
        appendHashPoint(&data, V)
        appendHashPoint(&data, X)
        data.append(u32be(UInt32(signerID.count)))
        data.append(signerID)
        let digest = sha256(data)
        // Reduce the 256-bit digest mod the curve order n.
        return Fq(bytes: digest) ?? .zero
    }

    // F(P) = U32BE(len) || uncompressed-point-bytes, matching writeZkpHashPoint.
    private static func appendHashPoint(_ out: inout Data, _ p: TandemP256Point) {
        let enc = p.x963Bytes() ?? Data([0x00])
        out.append(u32be(UInt32(enc.count)))
        out.append(enc)
    }

    // 4-byte big-endian length, matching Streams.writeUint32Be.
    private static func u32be(_ v: UInt32) -> Data {
        Data([UInt8((v >> 24) & 0xFF), UInt8((v >> 16) & 0xFF),
              UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)])
    }

    // Fixed JPAKE role identities (hashed into the ZKP challenge only).
    private static let clientID = Data("client".utf8)
    private static let serverID = Data("server".utf8)

    // Non-static version forwarding to static (for makeZKP)
    private func zkpChallenge(generator: TandemP256Point, V: TandemP256Point, X: TandemP256Point, signerID: Data) -> Fq {
        ECJPAKEContext.zkpChallenge(generator: generator, V: V, X: X, signerID: signerID)
    }

    // MARK: - Wire encoding/decoding

    // Encode one chunk exactly as the pump expects (per pumpX2 writePoint/writeZkp):
    //   U8(len=65) || point(65) || U8(len=65) || V(65) || U8(len=32) || b(32)  = 165 bytes
    // There is NO signerID field on the wire; the role id is hashed into the
    // challenge only. The earlier encoder omitted the length prefixes and
    // appended the appInstanceId, producing chunks the pump would reject.
    private func encodeChunk(point: TandemP256Point, zkp: ZKP) -> Data {
        var d = Data()
        let p = point.x963Bytes()!
        let v = zkp.V.x963Bytes()!
        let b = zkp.b.bytes
        d.append(UInt8(p.count)); d.append(p)
        d.append(UInt8(v.count)); d.append(v)
        d.append(UInt8(b.count)); d.append(b)
        return d
    }

    // Decode and verify one length-prefixed chunk. `peerID` is the prover role
    // id to verify against ("server" for the pump). It is REQUIRED: there is no
    // longer a path that skips verification. Points are validated on-curve and
    // rejected if at infinity before any proof check.
    private func decodeAndVerifyChunk(_ data: Data, generator: TandemP256Point, peerID: Data) throws -> (TandemP256Point, ZKP) {
        var cursor = data.startIndex

        func readLenPrefixed() throws -> Data {
            guard cursor < data.endIndex else { throw ECJPAKEError.invalidServerPoint }
            let len = Int(data[cursor])
            cursor = data.index(after: cursor)
            guard len > 0, data.distance(from: cursor, to: data.endIndex) >= len else {
                throw ECJPAKEError.invalidServerPoint
            }
            let end = data.index(cursor, offsetBy: len)
            let slice = Data(data[cursor..<end])
            cursor = end
            return slice
        }

        let pointBytes = try readLenPrefixed()
        let vBytes     = try readLenPrefixed()
        let bBytes     = try readLenPrefixed()

        guard let X = TandemP256Point(validatedX963: pointBytes),
              let V = TandemP256Point(validatedX963: vBytes),
              let b = Fq(bytes: bBytes) else { throw ECJPAKEError.invalidServerPoint }

        let zkp = ZKP(V: V, b: b)
        guard ECJPAKEContext.verifyZKP(zkp, X: X, generator: generator, signerID: peerID) else {
            throw ECJPAKEError.zkpVerificationFailed
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
