import Foundation

// CRC-16/CCITT-FALSE as used by pumpX2 (Bytes.calculateCRC16).
// Polynomial: 0x1021, initial value: 0xFFFF, no input/output reflection.
enum CRC16 {
    static func calculate(_ data: Data) -> UInt16 {
        var crc: UInt16 = 0xFFFF
        for byte in data {
            crc ^= UInt16(byte) << 8
            for _ in 0..<8 {
                if crc & 0x8000 != 0 {
                    crc = (crc << 1) ^ 0x1021
                } else {
                    crc <<= 1
                }
            }
        }
        return crc
    }

    // Append the two CRC bytes (little-endian) to data and return the result.
    // The pump puts the CRC trailer on the wire low byte first, matching pumpX2
    // Bytes.calculateCRC16, which returns { i2 & 255, (i2 >>> 8) & 255 }. Captured
    // real-pump frames verify only under this order; an earlier big-endian trailer
    // was internally self-consistent (append/verify mirrored) but wrong on the wire.
    static func appending(to data: Data) -> Data {
        let crc = calculate(data)
        var out = data
        out.append(UInt8(crc & 0xFF))
        out.append(UInt8(crc >> 8))
        return out
    }

    // Verify: the last two bytes of data are the CRC (little-endian) of the
    // preceding bytes.
    static func verify(_ data: Data) -> Bool {
        guard data.count >= 2 else { return false }
        let payload = data.dropLast(2)
        let expected = calculate(payload)
        let lo = UInt16(data[data.count - 2])
        let hi = UInt16(data[data.count - 1])
        return expected == (hi << 8 | lo)
    }
}
