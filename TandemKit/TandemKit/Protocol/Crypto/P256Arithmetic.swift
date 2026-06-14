import CryptoKit
import Foundation

// Pure-Swift P-256 arithmetic for EC-JPAKE.
// All integers are 8 × UInt32, stored LITTLE-endian (w[0] = least-significant word).
// This avoids any dependency on private Apple APIs or external libraries.

// MARK: - 256-bit integer helpers

typealias W8 = [UInt32]  // exactly 8 elements, little-endian

private func w8From(bigEndianHex hex: String) -> W8 {
    var result = W8(repeating: 0, count: 8)
    let clean = hex.filter { $0.isHexDigit }
    let padded = String(repeating: "0", count: max(0, 64 - clean.count)) + clean
    for i in 0..<8 {
        let start = padded.index(padded.startIndex, offsetBy: (7 - i) * 8)
        let end   = padded.index(start, offsetBy: 8)
        result[i] = UInt32(padded[start..<end], radix: 16)!
    }
    return result
}

// Compare a and b: returns -1, 0, +1
private func cmp(_ a: W8, _ b: W8) -> Int {
    for i in (0..<8).reversed() {
        if a[i] < b[i] { return -1 }
        if a[i] > b[i] { return  1 }
    }
    return 0
}

// a + b, returns (result, carry)
private func add256(_ a: W8, _ b: W8) -> (W8, UInt32) {
    var r = W8(repeating: 0, count: 8)
    var carry: UInt64 = 0
    for i in 0..<8 {
        let s = UInt64(a[i]) + UInt64(b[i]) + carry
        r[i] = UInt32(truncatingIfNeeded: s)
        carry = s >> 32
    }
    return (r, UInt32(carry))
}

// a - b, returns (result, borrow). Caller must ensure a >= b.
private func sub256(_ a: W8, _ b: W8) -> W8 {
    var r = W8(repeating: 0, count: 8)
    var borrow: Int64 = 0
    for i in 0..<8 {
        let diff = Int64(a[i]) - Int64(b[i]) - borrow
        r[i] = UInt32(bitPattern: Int32(truncatingIfNeeded: diff))
        borrow = diff < 0 ? 1 : 0
    }
    return r
}

// a * b → 16-limb result (little-endian)
func mul256(_ a: W8, _ b: W8) -> [UInt32] {
    var r = [UInt32](repeating: 0, count: 16)
    for i in 0..<8 {
        var carry: UInt64 = 0
        for j in 0..<8 {
            let prod = UInt64(a[i]) * UInt64(b[j]) + UInt64(r[i+j]) + carry
            r[i+j] = UInt32(truncatingIfNeeded: prod)
            carry   = prod >> 32
        }
        r[i+8] = UInt32(truncatingIfNeeded: UInt64(r[i+8]) + carry)
    }
    return r
}

// MARK: - P-256 prime field Fp

// p = FFFFFFFF 00000001 00000000 00000000 00000000 FFFFFFFF FFFFFFFF FFFFFFFF
private let p256_p: W8 = [0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF, 0x00000000,
                           0x00000000, 0x00000000, 0x00000001, 0xFFFFFFFF]

// a3 = curve constant a = p - 3 = FFFFFFFC FFFFFFFF FFFFFFFF 00000000 00000000 00000000 00000001 FFFFFFFF
// (stored LE)
private let p256_a: W8 = [0xFFFFFFFC, 0xFFFFFFFF, 0xFFFFFFFF, 0x00000000,
                           0x00000000, 0x00000000, 0x00000001, 0xFFFFFFFF]

// NIST P-256 fast reduction. c is a 16-limb little-endian product c[0..15].
// Returns c mod p. Based on FIPS 186-4 D.2.3.
private func p256Reduce(_ c: [UInt32]) -> W8 {
    // c[0] = least significant
    let c0 = c[0], c1 = c[1], c2 = c[2], c3 = c[3]
    let c4 = c[4], c5 = c[5], c6 = c[6], c7 = c[7]
    let c8 = c[8], c9 = c[9], c10 = c[10], c11 = c[11]
    let c12 = c[12], c13 = c[13], c14 = c[14], c15 = c[15]

    // s1 = (c7, c6, c5, c4, c3, c2, c1, c0)  ← already in our LE format
    let s1: W8 = [c0, c1, c2, c3, c4, c5, c6, c7]
    // s2 = (c15, c14, c13, c12, c11, 0, 0, 0)
    let s2: W8 = [0, 0, 0, c11, c12, c13, c14, c15]
    // s3 = (0, c15, c14, c13, c12, 0, 0, 0)
    let s3: W8 = [0, 0, 0, c12, c13, c14, c15, 0]
    // s4 = (c15, c14, 0, 0, 0, c10, c9, c8)
    let s4: W8 = [c8, c9, c10, 0, 0, 0, c14, c15]
    // s5 = (c8, c13, c15, c14, c13, c11, c10, c9)
    let s5: W8 = [c9, c10, c11, c13, c14, c15, c13, c8]
    // s6 = (c10, c8, 0, 0, 0, c13, c12, c11)
    let s6: W8 = [c11, c12, c13, 0, 0, 0, c8, c10]
    // s7 = (c11, c9, 0, 0, c15, c14, c13, c12)
    let s7: W8 = [c12, c13, c14, c15, 0, 0, c9, c11]
    // s8 = (c12, 0, c10, c9, c8, c15, c14, c13)
    let s8: W8 = [c13, c14, c15, c8, c9, c10, 0, c12]

    // r = s1 + 2*s2 + 2*s3 + s4 + s5 - s6 - s7 - s8  (mod p)
    // Work with signed 64-bit accumulators, column by column.
    var acc = [Int64](repeating: 0, count: 9)
    for i in 0..<8 {
        acc[i] += Int64(s1[i])
        acc[i] += 2 * Int64(s2[i])
        acc[i] += 2 * Int64(s3[i])
        acc[i] += Int64(s4[i])
        acc[i] += Int64(s5[i])
        acc[i] -= Int64(s6[i])
        acc[i] -= Int64(s7[i])
        acc[i] -= Int64(s8[i])
    }
    // Propagate carries (signed)
    for i in 0..<8 {
        let carry = acc[i] >> 32
        acc[i] &= 0xFFFF_FFFF
        acc[i+1] += carry
    }
    // Convert to UInt32 array; may be slightly negative after reduction
    var r = W8(repeating: 0, count: 8)
    for i in 0..<8 { r[i] = UInt32(bitPattern: Int32(truncatingIfNeeded: acc[i])) }

    // Final conditional add/sub to bring into [0, p)
    // Could need up to a few passes
    for _ in 0..<4 {
        if acc[8] < 0 || cmp(r, p256_p) >= 0 {
            if acc[8] < 0 {
                let (added, _) = add256(r, p256_p); r = added; acc[8] += 1
            } else {
                r = sub256(r, p256_p); acc[8] -= 1
            }
        } else { break }
    }
    return r
}

struct Fp: Equatable {
    var w: W8   // 0 <= w < p

    static let zero = Fp(w: W8(repeating: 0, count: 8))
    static let one  = Fp(w: { var v = W8(repeating: 0, count: 8); v[0] = 1; return v }())

    init(w: W8) { self.w = w }
    init?(bytes: Data) {  // big-endian 32 bytes
        guard bytes.count == 32 else { return nil }
        var ww = W8(repeating: 0, count: 8)
        for i in 0..<8 {
            let idx = 28 - i * 4
            ww[i] = UInt32(bytes[idx]) << 24 | UInt32(bytes[idx+1]) << 16 |
                    UInt32(bytes[idx+2]) << 8  | UInt32(bytes[idx+3])
        }
        if cmp(ww, p256_p) >= 0 { return nil }
        self.w = ww
    }

    var bytes: Data {  // big-endian 32 bytes
        var d = Data(count: 32)
        for i in 0..<8 {
            let idx = 28 - i * 4
            d[idx]   = UInt8((w[i] >> 24) & 0xFF)
            d[idx+1] = UInt8((w[i] >> 16) & 0xFF)
            d[idx+2] = UInt8((w[i] >>  8) & 0xFF)
            d[idx+3] = UInt8( w[i]        & 0xFF)
        }
        return d
    }

    static func + (lhs: Fp, rhs: Fp) -> Fp {
        var (r, carry) = add256(lhs.w, rhs.w)
        if carry > 0 || cmp(r, p256_p) >= 0 { r = sub256(r, p256_p) }
        return Fp(w: r)
    }

    static func - (lhs: Fp, rhs: Fp) -> Fp { Fp.sub(lhs, rhs) }

    static func * (lhs: Fp, rhs: Fp) -> Fp {
        Fp(w: p256Reduce(mul256(lhs.w, rhs.w)))
    }

    func negated() -> Fp {
        if w == Fp.zero.w { return .zero }
        return Fp(w: sub256(p256_p, w))
    }

    func squared() -> Fp { self * self }

    // a^e mod p via square-and-multiply; e is big-endian bytes
    func pow(_ e: W8) -> Fp {
        var result = Fp.one
        var base   = self
        for limb in e {  // little-endian: start from least significant
            var bits = limb
            for _ in 0..<32 {
                if bits & 1 != 0 { result = result * base }
                base = base.squared()
                bits >>= 1
            }
        }
        return result
    }

    // Modular inverse: a^(p-2) mod p
    func inverse() -> Fp {
        // p - 2 in little-endian W8
        var pm2 = p256_p
        pm2[0] -= 2
        return pow(pm2)
    }
}

// Fix the subtraction: when lhs < rhs, we need to wrap via two's-complement + p
extension Fp {
    // Corrected - operator (replace the broken one above)
    static func sub(_ lhs: Fp, _ rhs: Fp) -> Fp {
        if cmp(lhs.w, rhs.w) >= 0 { return Fp(w: sub256(lhs.w, rhs.w)) }
        // lhs < rhs: compute (p - rhs) + lhs
        let neg_rhs = sub256(p256_p, rhs.w)
        let (r, carry) = add256(neg_rhs, lhs.w)
        return Fp(w: carry > 0 ? sub256(r, p256_p) : r)
    }
}

// Re-define - to use the corrected version
// (We overwrite the broken one by redefining at the call sites below)

// MARK: - P-256 group order Fq

// q = FFFFFFFF 00000000 FFFFFFFF FFFFFFFF BCE6FAAD A7179E84 F3B9CAC2 FC632551
let p256_q: W8 = [0xFC632551, 0xF3B9CAC2, 0xA7179E84, 0xBCE6FAAD,
                           0xFFFFFFFF, 0xFFFFFFFF, 0x00000000, 0xFFFFFFFF]

// General modular reduction for mod q using repeated subtraction (fast enough for our needs).
// For a 512-bit value represented as 16 limbs.
func modQ(_ c: [UInt32]) -> W8 {
    // Work with a 9-limb accumulator for the top part and subtract q*shifted
    // Simple approach: long subtraction. Not fast but correct.
    var rem = c  // 16 limbs
    // Bring high bits down by subtracting q << (32 * shift) while rem >= q << shift
    for shift in (0...8).reversed() {
        while true {
            // Check if rem[shift..shift+8] >= q
            var ge = false
            for i in (0..<8).reversed() {
                let ri = rem[shift + i]
                let qi = (i < 8 ? p256_q[i] : 0)
                if ri > qi { ge = true; break }
                if ri < qi { break }
                if i == 0 { ge = true }
            }
            if !ge { break }
            // Subtract q << (32 * shift)
            var borrow: Int64 = 0
            for i in 0..<8 {
                let diff = Int64(rem[shift + i]) - Int64(p256_q[i]) - borrow
                rem[shift + i] = UInt32(bitPattern: Int32(truncatingIfNeeded: diff))
                borrow = diff < 0 ? 1 : 0
            }
            if borrow != 0 && shift + 8 < 16 {
                rem[shift + 8] = UInt32(bitPattern: Int32(rem[shift + 8]) - Int32(borrow))
            }
        }
    }
    return W8(rem[0..<8])
}

struct Fq: Equatable {
    var w: W8

    static let zero = Fq(w: W8(repeating: 0, count: 8))
    static let one  = Fq(w: { var v = W8(repeating: 0, count: 8); v[0] = 1; return v }())

    init(w: W8) { self.w = w }
    init?(bytes: Data) {
        guard bytes.count == 32 else { return nil }
        var ww = W8(repeating: 0, count: 8)
        for i in 0..<8 {
            let idx = 28 - i * 4
            ww[i] = UInt32(bytes[idx]) << 24 | UInt32(bytes[idx+1]) << 16 |
                    UInt32(bytes[idx+2]) << 8  | UInt32(bytes[idx+3])
        }
        self.w = modQ(ww.map { $0 } + W8(repeating: 0, count: 8))
    }

    var bytes: Data {
        var d = Data(count: 32)
        for i in 0..<8 {
            let idx = 28 - i * 4
            d[idx]   = UInt8((w[i] >> 24) & 0xFF)
            d[idx+1] = UInt8((w[i] >> 16) & 0xFF)
            d[idx+2] = UInt8((w[i] >>  8) & 0xFF)
            d[idx+3] = UInt8( w[i]        & 0xFF)
        }
        return d
    }

    static func + (lhs: Fq, rhs: Fq) -> Fq {
        var (r, carry) = add256(lhs.w, rhs.w)
        if carry > 0 || cmp(r, p256_q) >= 0 { r = sub256(r, p256_q) }
        return Fq(w: r)
    }

    static func sub(_ lhs: Fq, _ rhs: Fq) -> Fq {
        if cmp(lhs.w, rhs.w) >= 0 { return Fq(w: sub256(lhs.w, rhs.w)) }
        let neg = sub256(p256_q, rhs.w)
        let (r, carry) = add256(neg, lhs.w)
        return Fq(w: carry > 0 ? sub256(r, p256_q) : r)
    }

    static func * (lhs: Fq, rhs: Fq) -> Fq {
        Fq(w: modQ(mul256(lhs.w, rhs.w)))
    }

    static func random() -> Fq {
        // Rejection-sample from [1, q-1]
        while true {
            var bytes = Data(count: 32)
            _ = bytes.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) }
            var ww = W8(repeating: 0, count: 8)
            for i in 0..<8 {
                let idx = 28 - i * 4
                ww[i] = UInt32(bytes[idx]) << 24 | UInt32(bytes[idx+1]) << 16 |
                        UInt32(bytes[idx+2]) << 8  | UInt32(bytes[idx+3])
            }
            // Ensure in [1, q-1]
            if cmp(ww, p256_q) < 0 && cmp(ww, Fq.zero.w) != 0 {
                return Fq(w: ww)
            }
        }
    }
}

// MARK: - Jacobian P-256 point

// Affine (x, y) → Jacobian (X:Y:Z) where x = X/Z², y = Y/Z³
// P-256: y² = x³ + ax + b   (a = -3 mod p)

private let p256_b = Fp(w: w8From(bigEndianHex:
    "5AC635D8AA3A93E7B3EBBD55769886BC651D06B0CC53B0F63BCE3C3E27D2604B"))
private let p256_Gx = Fp(w: w8From(bigEndianHex:
    "6B17D1F2E12C4247F8BCE6E563A440F277037D812DEB33A0F4A13945D898C296"))
private let p256_Gy = Fp(w: w8From(bigEndianHex:
    "4FE342E2FE1A7F9B8EE7EB4A7C0F9E162BCE33576B315ECECBB6406837BF51F5"))

struct P256Point: Equatable {
    var x: Fp
    var y: Fp
    var z: Fp   // z == zero means point at infinity

    static let infinity = P256Point(x: .one, y: .one, z: .zero)
    static let generator = P256Point(x: p256_Gx, y: p256_Gy, z: .one)

    var isInfinity: Bool { z == .zero }

    // Jacobian doubling: 2P
    func doubled() -> P256Point {
        if isInfinity { return .infinity }
        // Algorithm from https://hyperelliptic.org/EFD/g1p/auto-shortw-jacobian-3.html#doubling-dbl-2001-b
        let a_coeff = Fp(w: p256_a)
        // Using dbl-2001-b for a = -3:
        let delta = z.squared()
        let gamma = y.squared()
        let beta  = x * gamma
        // alpha = 3*(x - delta)*(x + delta)  [using a = -3 shortcut]
        let xmd = Fp.sub(x, delta)
        let xpd = x + delta
        let alpha = Fp(w: { var v = W8(repeating: 0, count: 8)
            // 3 * xmd * xpd
            let t = xmd * xpd
            var (r, c) = add256(t.w, t.w); if c > 0 || cmp(r, p256_p) >= 0 { r = sub256(r, p256_p) }
            var (r2, c2) = add256(r, t.w); if c2 > 0 || cmp(r2, p256_p) >= 0 { r2 = sub256(r2, p256_p) }
            return r2
        }())
        let X3 = Fp.sub(alpha.squared(), {
            var (r, c) = add256(beta.w, beta.w); if c > 0 || cmp(r, p256_p) >= 0 { r = sub256(r, p256_p) }
            var (r2, c2) = add256(r, r); if c2 > 0 || cmp(r2, p256_p) >= 0 { r2 = sub256(r2, p256_p) }
            var (r3, c3) = add256(r2, r2); if c3 > 0 || cmp(r3, p256_p) >= 0 { r3 = sub256(r3, p256_p) }
            return Fp(w: r3)  // 8*beta
        }())
        let Z3 = (y + z).squared()
        let Z3f = Fp.sub(Fp.sub(Z3, gamma), delta)
        let four_beta: Fp = {
            var r = beta.w
            for _ in 0..<2 {
                var (rr, c) = add256(r, r); if c > 0 || cmp(rr, p256_p) >= 0 { rr = sub256(rr, p256_p) }
                r = rr
            }
            return Fp(w: r)
        }()
        let Y3_clean = Fp.sub(alpha * Fp.sub(four_beta, X3), {
            let g2 = gamma.squared()
            var (r, c) = add256(g2.w, g2.w); if c > 0 || cmp(r, p256_p) >= 0 { r = sub256(r, p256_p) }
            var (r2, c2) = add256(r, r); if c2 > 0 || cmp(r2, p256_p) >= 0 { r2 = sub256(r2, p256_p) }
            var (r3, c3) = add256(r2, r2); if c3 > 0 || cmp(r3, p256_p) >= 0 { r3 = sub256(r3, p256_p) }
            return Fp(w: r3)  // 8 * gamma²
        }())
        return P256Point(x: X3, y: Y3_clean, z: Z3f)
    }

    // Jacobian mixed addition: self (Jacobian) + other (Jacobian)
    // Using add-2007-bl from EFD
    func adding(_ other: P256Point) -> P256Point {
        if isInfinity { return other }
        if other.isInfinity { return self }

        // Z1² and Z2²
        let Z1Z1 = z.squared()
        let Z2Z2 = other.z.squared()
        let U1 = x * Z2Z2
        let U2 = other.x * Z1Z1
        let S1 = y * other.z * Z2Z2
        let S2 = other.y * z * Z1Z1
        let H  = Fp.sub(U2, U1)
        let R  = Fp.sub(S2, S1)

        if H == .zero {
            if R == .zero { return doubled() }  // same point
            return .infinity  // point + (-point)
        }

        let H2 = H.squared()
        let H3 = H * H2
        let X3 = Fp.sub(Fp.sub(R.squared(), H3),
                        { var (r, c) = add256(U1.w, U1.w);
                          if c > 0 || cmp(r, p256_p) >= 0 { r = sub256(r, p256_p) }
                          return Fp(w: r) }() * H2)
        let Y3 = Fp.sub(R * Fp.sub(U1 * H2, X3), S1 * H3)
        let Z3 = H * z * other.z
        return P256Point(x: X3, y: Y3, z: Z3)
    }

    // Scalar multiplication: k * self, k is Fq scalar (little-endian limbs)
    func multiplied(by k: Fq) -> P256Point {
        var result = P256Point.infinity
        var addend = self
        for limb in k.w {  // little-endian: w[0] first
            var bits = limb
            for _ in 0..<32 {
                if bits & 1 != 0 { result = result.adding(addend) }
                addend = addend.doubled()
                bits >>= 1
            }
        }
        return result
    }

    func negated() -> P256Point {
        P256Point(x: x, y: y.negated(), z: z)
    }

    // Convert to affine (x, y). Returns nil for point at infinity.
    func toAffine() -> (Fp, Fp)? {
        if isInfinity { return nil }
        let zInv  = z.inverse()
        let zInv2 = zInv.squared()
        let zInv3 = zInv2 * zInv
        return (x * zInv2, y * zInv3)
    }

    // Serialize as uncompressed x9.63: 0x04 || x(32BE) || y(32BE)
    func x963Bytes() -> Data? {
        guard let (ax, ay) = toAffine() else { return nil }
        var d = Data([0x04])
        d.append(ax.bytes)
        d.append(ay.bytes)
        return d
    }

    // Deserialize from uncompressed x9.63
    init?(x963 data: Data) {
        guard data.count == 65, data[0] == 0x04 else { return nil }
        guard let fx = Fp(bytes: data[1..<33]),
              let fy = Fp(bytes: data[33..<65]) else { return nil }
        self.x = fx; self.y = fy; self.z = .one
    }
}

// MARK: - SHA-256 helper (wraps CryptoKit)

func sha256(_ data: Data) -> Data {
    Data(SHA256.hash(data: data))
}

// Hash-to-scalar: hash data, reduce mod q
func hashToScalar(_ data: Data) -> Fq {
    let digest = sha256(data)
    return Fq(bytes: digest) ?? .zero
}

// Encode a point for ZKP hashing (x9.63 or "infinity" sentinel)
private func encodePointForHash(_ p: P256Point) -> Data {
    p.x963Bytes() ?? Data([0x00])
}
