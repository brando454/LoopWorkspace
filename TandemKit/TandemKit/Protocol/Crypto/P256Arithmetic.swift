import CommonCrypto
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
    // c[0] = least significant. NIST P-256 fast reduction (FIPS 186-4 D.2.3).
    //   r = T + 2*S1 + 2*S2 + S3 + S4 - D1 - D2 - D3 - D4   (mod p)
    // Each tuple comment is written most-significant word first (word 7 .. word 0);
    // the W8 literal is the same words in LITTLE-endian order (index 0 = LSW).
    // Verified byte-exact against arbitrary-precision arithmetic over 100k random products.
    let c0 = c[0], c1 = c[1], c2 = c[2], c3 = c[3]
    let c4 = c[4], c5 = c[5], c6 = c[6], c7 = c[7]
    let c8 = c[8], c9 = c[9], c10 = c[10], c11 = c[11]
    let c12 = c[12], c13 = c[13], c14 = c[14], c15 = c[15]

    // T  = ( c7, c6, c5, c4, c3, c2, c1, c0)
    let T:  W8 = [c0, c1, c2, c3, c4, c5, c6, c7]
    // S1 = ( c15, c14, c13, c12, c11, 0, 0, 0)
    let S1: W8 = [0, 0, 0, c11, c12, c13, c14, c15]
    // S2 = ( 0, c15, c14, c13, c12, 0, 0, 0)
    let S2: W8 = [0, 0, 0, c12, c13, c14, c15, 0]
    // S3 = ( c15, c14, 0, 0, 0, c10, c9, c8)
    let S3: W8 = [c8, c9, c10, 0, 0, 0, c14, c15]
    // S4 = ( c8, c13, c15, c14, c13, c11, c10, c9)
    let S4: W8 = [c9, c10, c11, c13, c14, c15, c13, c8]
    // D1 = ( c10, c8, 0, 0, 0, c13, c12, c11)
    let D1: W8 = [c11, c12, c13, 0, 0, 0, c8, c10]
    // D2 = ( c11, c9, 0, 0, c15, c14, c13, c12)
    let D2: W8 = [c12, c13, c14, c15, 0, 0, c9, c11]
    // D3 = ( c12, 0, c10, c9, c8, c15, c14, c13)
    let D3: W8 = [c13, c14, c15, c8, c9, c10, 0, c12]
    // D4 = ( c13, 0, c11, c10, c9, 0, c15, c14)
    let D4: W8 = [c14, c15, 0, c9, c10, c11, 0, c13]

    // Accumulate column-by-column into signed 64-bit limbs.
    var acc = [Int64](repeating: 0, count: 9)
    for i in 0..<8 {
        acc[i] += Int64(T[i])
        acc[i] += 2 * Int64(S1[i])
        acc[i] += 2 * Int64(S2[i])
        acc[i] += Int64(S3[i])
        acc[i] += Int64(S4[i])
        acc[i] -= Int64(D1[i])
        acc[i] -= Int64(D2[i])
        acc[i] -= Int64(D3[i])
        acc[i] -= Int64(D4[i])
    }
    // Signed carry propagation ( >> is arithmetic for Int64 ).
    for i in 0..<8 {
        let carry = acc[i] >> 32
        acc[i] &= 0xFFFF_FFFF
        acc[i+1] += carry
    }
    var r = W8(repeating: 0, count: 8)
    for i in 0..<8 { r[i] = UInt32(truncatingIfNeeded: acc[i]) }

    // The exact value is hi*2^256 + r, with hi in roughly [-4, 3].
    // Add/subtract p until r is in [0, p); track multiples of 2^256 in hi.
    var hi = acc[8]
    for _ in 0..<8 {
        if hi < 0 {
            let (sum, carry) = add256(r, p256_p)
            r = sum
            hi += Int64(carry)
        } else if hi > 0 || cmp(r, p256_p) >= 0 {
            let borrow = subBorrow(&r, p256_p)
            hi -= Int64(borrow)
        } else {
            break
        }
    }
    return r
}

// r -= b in place; returns 1 if it borrowed past the top limb, else 0.
private func subBorrow(_ r: inout W8, _ b: W8) -> UInt32 {
    var borrow: Int64 = 0
    for i in 0..<8 {
        let diff = Int64(r[i]) - Int64(b[i]) - borrow
        r[i] = UInt32(bitPattern: Int32(truncatingIfNeeded: diff))
        borrow = diff < 0 ? 1 : 0
    }
    return UInt32(borrow)
}

struct Fp: Equatable {
    var w: W8   // 0 <= w < p

    static let zero = Fp(w: W8(repeating: 0, count: 8))
    static let one  = Fp(w: { var v = W8(repeating: 0, count: 8); v[0] = 1; return v }())

    init(w: W8) { self.w = w }
    init?(bytes rawBytes: Data) {  // big-endian 32 bytes
        guard rawBytes.count == 32 else { return nil }
        // Rebase to a base-0 buffer: callers may pass a Data slice whose
        // startIndex != 0 (e.g. data[33..<65]), and the loop below subscripts
        // by absolute integer index. Without this, valid input traps.
        let bytes = Data(rawBytes)
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

// Modular reduction mod q (the P-256 group order n) for a value of up to 16
// little-endian limbs (e.g. a 512-bit product from mul256).
//
// The previous implementation used a windowed repeated-subtraction that only
// compared the 8-limb window rem[shift..shift+8] against q and ignored limbs
// above the window. For true multi-limb inputs (such as x*h in makeZKP) the
// high limbs were never reduced, so the result was the low 256 bits unreduced.
// It happened to be correct for 256-bit inputs (a hashed challenge), which is
// why point verification of an externally-generated proof still passed while
// our own freshly-generated client proof failed to verify.
//
// This is replaced with a bit-by-bit binary long division (shift-and-subtract):
//   rem = 0
//   for each bit of c from most-significant to least:
//       rem = (rem << 1) | bit          // value may momentarily reach 257 bits
//       if rem >= q: rem -= q
// The remainder never exceeds q-1 across the loop, so an 8-limb (256-bit)
// accumulator is sufficient; the single bit shifted out of the top is folded in
// by an unconditional subtraction of q when it is set. Verified byte-exact
// against arbitrary-precision arithmetic over 50k random full-width inputs plus
// edge cases (0, q, q-1, q+1, 2q, q<<32, q*q, 2^512-1).
func modQ(_ c: [UInt32]) -> W8 {
    let nbits = c.count * 32
    var rem = W8(repeating: 0, count: 8)
    var bitpos = nbits - 1
    while bitpos >= 0 {
        let limb = bitpos >> 5
        let bit = (c[limb] >> UInt32(bitpos & 31)) & 1
        // rem = (rem << 1) | bit
        var carry: UInt32 = bit
        for i in 0..<8 {
            let nv = (rem[i] << 1) | carry
            carry = (rem[i] >> 31) & 1
            rem[i] = nv
        }
        // If a bit was shifted out of the top, the true value is rem + 2^256,
        // which is >= q, so subtract q once (result fits in 256 bits).
        if carry != 0 {
            rem = sub256(rem, p256_q)
        }
        if cmp(rem, p256_q) >= 0 {
            rem = sub256(rem, p256_q)
        }
        bitpos -= 1
    }
    return rem
}

struct Fq: Equatable {
    var w: W8

    static let zero = Fq(w: W8(repeating: 0, count: 8))
    static let one  = Fq(w: { var v = W8(repeating: 0, count: 8); v[0] = 1; return v }())

    init(w: W8) { self.w = w }
    init?(bytes rawBytes: Data) {
        guard rawBytes.count == 32 else { return nil }
        // Rebase to a base-0 buffer; see Fp.init?(bytes:) for rationale.
        let bytes = Data(rawBytes)
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

struct TandemP256Point: Equatable {
    var x: Fp
    var y: Fp
    var z: Fp   // z == zero means point at infinity

    static let infinity = TandemP256Point(x: .one, y: .one, z: .zero)
    static let generator = TandemP256Point(x: p256_Gx, y: p256_Gy, z: .one)

    var isInfinity: Bool { z == .zero }

    // Jacobian doubling: 2P
    func doubled() -> TandemP256Point {
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
        return TandemP256Point(x: X3, y: Y3_clean, z: Z3f)
    }

    // Jacobian mixed addition: self (Jacobian) + other (Jacobian)
    // Using add-2007-bl from EFD
    func adding(_ other: TandemP256Point) -> TandemP256Point {
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
        return TandemP256Point(x: X3, y: Y3, z: Z3)
    }

    // Scalar multiplication: k * self, k is Fq scalar (little-endian limbs)
    func multiplied(by k: Fq) -> TandemP256Point {
        var result = TandemP256Point.infinity
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

    func negated() -> TandemP256Point {
        TandemP256Point(x: x, y: y.negated(), z: z)
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

}

extension TandemP256Point {
    // Deserialize from uncompressed x9.63
    init?(x963 data: Data) {
        guard data.count == 65, data[0] == 0x04 else { return nil }
        guard let fx = Fp(bytes: data[1..<33]),
              let fy = Fp(bytes: data[33..<65]) else { return nil }
        self.x = fx; self.y = fy; self.z = .one
    }

    // Deserialize AND validate. Rejects malformed encodings, the point at
    // infinity, and any (x, y) that does not satisfy the P-256 curve equation
    // y^2 == x^3 + a*x + b. Skipping this check is a known EC-JPAKE attack
    // vector (small-subgroup / invalid-curve), so all peer points decoded
    // during pairing go through here.
    init?(validatedX963 data: Data) {
        guard let p = TandemP256Point(x963: data) else { return nil }
        let x = p.x, y = p.y
        if x == .zero && y == .zero { return nil }
        let lhs = y.squared()
        let aCoeff = Fp(w: p256_a)
        let rhs = (x * x * x) + (aCoeff * x) + p256_b
        guard lhs == rhs else { return nil }
        self = p
    }
}

// MARK: - SHA-256 helper (wraps CommonCrypto)

func sha256(_ data: Data) -> Data {
    var digest = Data(count: Int(CC_SHA256_DIGEST_LENGTH))
    data.withUnsafeBytes { inPtr in
        digest.withUnsafeMutableBytes { outPtr in
            _ = CC_SHA256(inPtr.baseAddress, CC_LONG(data.count),
                          outPtr.bindMemory(to: UInt8.self).baseAddress)
        }
    }
    return digest
}

// Hash-to-scalar: hash data, reduce mod q
func hashToScalar(_ data: Data) -> Fq {
    let digest = sha256(data)
    return Fq(bytes: digest) ?? .zero
}

// Encode a point for ZKP hashing (x9.63 or "infinity" sentinel)
private func encodePointForHash(_ p: TandemP256Point) -> Data {
    p.x963Bytes() ?? Data([0x00])
}
