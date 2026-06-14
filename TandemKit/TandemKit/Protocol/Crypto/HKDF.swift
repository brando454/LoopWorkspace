import Foundation

// Single-block HKDF as used by pumpX2 Hkdf.java for J-PAKE auth key derivation.
//
// This is a simplified (one-block, no-info) HKDF using HMAC-SHA256:
//   prk = HMAC-SHA256(key=nonce, data=keyMaterial)   // extract
//   okm = HMAC-SHA256(key=prk,   data=[0x01])[0..<32] // expand, one block
//
// The nonce is used as the HMAC key in the extract step (not the usual salt role).
// This exactly mirrors the Java Hkdf.build(nonce, keyMaterial) implementation.
enum TandemHKDF {
    static func build(nonce: Data, keyMaterial: Data) -> Data {
        let prk = HmacUtils.hmacSHA256(key: nonce, data: keyMaterial)
        let okm = HmacUtils.hmacSHA256(key: prk, data: Data([0x01]))
        return okm.prefix(32)
    }
}
