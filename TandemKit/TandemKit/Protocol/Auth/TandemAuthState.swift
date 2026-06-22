import Foundation

// J-PAKE authentication state machine for the Tandem Mobi (API > 3.2, 6-digit pairing code).
//
// Usage:
//   1. Create TandemAuthState(pairingCode: "123456")
//   2. If derivedSecretHex is already stored from a prior session, pass it in —
//      the handshake skips to step 3 (fast reconnect).
//   3. Call nextRequest() to get the next message to send.
//   4. Feed each pump response to handleResponse(_:).
//   5. When state == .authenticated, use authKey for signing CONTROL messages.
//
// EC-JPAKE (RFC 8236) is implemented in ECJPAKEContext.swift using pure-Swift P-256 arithmetic.

final class TandemAuthState {

    enum State {
        case idle
        case jpake1aPending
        case jpake1bPending
        case jpake2Pending
        case sessionKeyPending
        case keyConfirmationPending
        case authenticated
        case failed(Error)
    }

    enum AuthError: Error {
        case keyConfirmationFailed
        case unexpectedResponse
        case pairingCodeInvalid
    }

    private let pairingCode: String
    private let appInstanceId: UInt16

    // Persisted across reconnects
    private(set) var derivedSecretHex: String?
    private(set) var serverNonce3Hex: String?

    // Runtime — not persisted
    private(set) var authKey: Data?
    private(set) var state: State = .idle
    private var clientNonce4: Data?

    private var jpakeContext: ECJPAKEContext?
    private var _storedServerPart1: Data?   // server's round-1a payload, held until 1b arrives
    private var _cachedRound1Output: Data?  // client round-1 output (reused for part2 send)

    init(pairingCode: String, derivedSecretHex: String? = nil, serverNonce3Hex: String? = nil) {
        self.pairingCode = pairingCode
        self.appInstanceId = UInt16.random(in: 1...UInt16.max)
        self.derivedSecretHex = derivedSecretHex
        self.serverNonce3Hex = serverNonce3Hex

        if let secretHex = derivedSecretHex, let nonceHex = serverNonce3Hex,
           let secret = Data(hexString: secretHex), let nonce = Data(hexString: nonceHex) {
            authKey = TandemHKDF.build(nonce: nonce, keyMaterial: secret)
        }
    }

    // Start or restart the handshake.
    // Returns the first request to send.
    func begin() throws -> any TandemRequest {
        if let secretHex = derivedSecretHex, let nonceHex = serverNonce3Hex,
           let secret = Data(hexString: secretHex), let nonce = Data(hexString: nonceHex) {
            if authKey == nil {
                authKey = TandemHKDF.build(nonce: nonce, keyMaterial: secret)
            }
            state = .sessionKeyPending
            return Jpake3SessionKeyRequest()
        }

        jpakeContext = ECJPAKEContext(password: pairingCodeBytes(), appInstanceId: appInstanceId)
        let round1 = try jpakeContext!.clientRound1()
        _cachedRound1Output = round1
        state = .jpake1aPending
        return Jpake1aRequest(appInstanceId: appInstanceId, clientRound1Part1: Data(round1[0..<165]))
    }

    // Feed a received cargo (after stripping opCode/txId/length/CRC) to advance the state machine.
    func handleResponse(opCode: UInt8, cargo: Data) throws -> (any TandemRequest)? {
        switch state {
        case .jpake1aPending:
            guard opCode == Jpake1aResponse.opCode,
                  let resp = Jpake1aResponse(cargo: cargo) else { throw AuthError.unexpectedResponse }
            _storedServerPart1 = resp.serverRound1Part1
            state = .jpake1bPending
            guard let round1 = _cachedRound1Output else { throw AuthError.unexpectedResponse }
            return Jpake1bRequest(appInstanceId: appInstanceId, clientRound1Part2: Data(round1[165..<330]))

        case .jpake1bPending:
            guard opCode == Jpake1bResponse.opCode,
                  let resp = Jpake1bResponse(cargo: cargo) else { throw AuthError.unexpectedResponse }
            let serverRound1 = (_storedServerPart1 ?? Data()) + resp.serverRound1Part2
            try jpakeContext?.readRound1(serverRound1)
            let round2 = try jpakeContext!.clientRound2()
            state = .jpake2Pending
            return Jpake2Request(appInstanceId: appInstanceId, clientRound2: round2)

        case .jpake2Pending:
            guard opCode == Jpake2Response.opCode,
                  let resp = Jpake2Response(cargo: cargo) else { throw AuthError.unexpectedResponse }
            let secret = try jpakeContext!.processRound2AndDeriveSecret(resp.serverRound2)
            derivedSecretHex = secret.hexString
            state = .sessionKeyPending
            return Jpake3SessionKeyRequest()

        case .sessionKeyPending:
            guard opCode == Jpake3SessionKeyResponse.opCode,
                  let resp = Jpake3SessionKeyResponse(cargo: cargo) else { throw AuthError.unexpectedResponse }
            serverNonce3Hex = resp.serverNonce3.hexString
            authKey = TandemHKDF.build(nonce: resp.serverNonce3, keyMaterial: Data(hexString: derivedSecretHex!)!)
            clientNonce4 = Data.randomBytes(count: 8)
            let hashDigest = HmacUtils.hmacSHA256(key: authKey!, data: clientNonce4!)
            state = .keyConfirmationPending
            return Jpake4KeyConfirmationRequest(
                appInstanceId: appInstanceId,
                clientNonce4: clientNonce4!,
                hashDigest: hashDigest
            )

        case .keyConfirmationPending:
            guard opCode == Jpake4KeyConfirmationResponse.opCode,
                  let resp = Jpake4KeyConfirmationResponse(cargo: cargo) else { throw AuthError.unexpectedResponse }
            let expectedHash = HmacUtils.hmacSHA256(key: authKey!, data: resp.serverNonce4)
            guard expectedHash == resp.serverHashDigest4 else {
                state = .failed(AuthError.keyConfirmationFailed)
                throw AuthError.keyConfirmationFailed
            }
            state = .authenticated
            return nil

        default:
            throw AuthError.unexpectedResponse
        }
    }

    private func pairingCodeBytes() -> Data {
        Data(pairingCode.utf8)  // each ASCII digit: '0'=48 ... '9'=57
    }
}

// MARK: - Helpers

extension Data {
    init?(hexString: String) {
        let clean = hexString.replacingOccurrences(of: " ", with: "")
        guard clean.count % 2 == 0 else { return nil }
        var result = Data()
        var i = clean.startIndex
        while i < clean.endIndex {
            let next = clean.index(i, offsetBy: 2)
            guard let byte = UInt8(clean[i..<next], radix: 16) else { return nil }
            result.append(byte)
            i = next
        }
        self = result
    }

    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }

    static func randomBytes(count: Int) -> Data {
        var data = Data(count: count)
        _ = data.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, count, $0.baseAddress!) }
        return data
    }
}
