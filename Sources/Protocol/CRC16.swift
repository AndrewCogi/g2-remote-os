import Foundation

/// CRC-16/CCITT-FALSE (poly 0x1021, init 0xFFFF, no reflection, no final XOR)
/// Used by the Even Realities G2 BLE frame layer (appended little-endian).
public enum CRC16 {
    public static func ccittFalse(_ data: Data, initial: UInt16 = 0xFFFF) -> UInt16 {
        var crc = initial
        for byte in data {
            crc ^= UInt16(byte) << 8
            for _ in 0..<8 {
                if (crc & 0x8000) != 0 {
                    crc = (crc << 1) ^ 0x1021
                } else {
                    crc = crc << 1
                }
            }
        }
        return crc
    }

    public static func ccittFalseBytes(_ data: Data) -> Data {
        let c = ccittFalse(data)
        return Data([UInt8(c & 0xFF), UInt8((c >> 8) & 0xFF)])
    }
}
