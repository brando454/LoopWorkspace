import CommonCrypto
import Foundation

// HMAC utilities ported from pumpX2 HmacSha256.java and Packetize.java.
//
// IMPORTANT: pumpX2 applies a mod255 normalization to both key and data
// before computing HMAC-SHA256. Any byte b where b < 0 (i.e., the high bit
// is set when treated as signed) is replaced with (b + 255 + 1) & 0xFF = b.
// In practice this is a no-op for unsigned bytes — Swift's UInt8 is always
// 0..255, so no transformation is needed. The function is kept explicit for
// parity with the Java source.
enum HmacUtils {

    // HMAC-SHA256 used for J-PAKE key confirmation (step 4) and HKDF.
    // Applies pumpX2's mod255 normalization (no-op for Swift UInt8).
    static func hmacSHA256(key: Data, data: Data) -> Data {
        let normalizedKey  = mod255(key)
        let normalizedData = mod255(data)
        var result = Data(count: Int(CC_SHA256_DIGEST_LENGTH))
        result.withUnsafeMutableBytes { outPtr in
            normalizedKey.withUnsafeBytes { keyPtr in
                normalizedData.withUnsafeBytes { dataPtr in
                    CCHmac(CCHmacAlgorithm(kCCHmacAlgSHA256),
                           keyPtr.baseAddress, normalizedKey.count,
                           dataPtr.baseAddress, normalizedData.count,
                           outPtr.baseAddress)
                }
            }
        }
        return result
    }

    // HMAC-SHA1 used for signing CONTROL characteristic messages.
    // key is the runtime authKey derived after successful auth.
    static func hmacSHA1(key: Data, data: Data) -> Data {
        var result = Data(count: Int(CC_SHA1_DIGEST_LENGTH))
        key.withUnsafeBytes { keyPtr in
            data.withUnsafeBytes { dataPtr in
                result.withUnsafeMutableBytes { outPtr in
                    CCHmac(
                        CCHmacAlgorithm(kCCHmacAlgSHA1),
                        keyPtr.baseAddress, key.count,
                        dataPtr.baseAddress, data.count,
                        outPtr.baseAddress
                    )
                }
            }
        }
        return result
    }

    // pumpX2 mod255: replace any signed-negative byte with (b+256).
    // For Swift UInt8 this is always a no-op, but kept explicit for clarity.
    private static func mod255(_ data: Data) -> Data {
        Data(data.map { $0 })
    }
}
