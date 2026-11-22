import Foundation

/// Minimal dependency-free Protobuf wire encoder & decoder tailored to the G2 BLE protocol.
public enum ProtobufLite {
    public struct Field {
        public let number: Int
        public let wireType: Int
        public let varintValue: UInt64
        public let bytesValue: Data
    }

    public static func encodeVarint(_ value: UInt64) -> Data {
        var out = Data()
        var v = value
        while v >= 0x80 {
            out.append(UInt8((v & 0x7F) | 0x80))
            v >>= 7
        }
        out.append(UInt8(v & 0x7F))
        return out
    }

    public static func encodeSignedVarint(_ value: Int64) -> Data {
        encodeVarint(UInt64(bitPattern: value))
    }

    public static func encodeKey(field: Int, wireType: Int) -> Data {
        encodeVarint(UInt64((field << 3) | (wireType & 0x07)))
    }

    public static func encodeUInt64Field(_ field: Int, _ value: UInt64) -> Data {
        var d = encodeKey(field: field, wireType: 0)
        d.append(encodeVarint(value))
        return d
    }

    public static func encodeVarintField(_ field: Int, _ value: Int) -> Data {
        encodeUInt64Field(field, UInt64(bitPattern: Int64(value)))
    }

    public static func encodeBytesField(_ field: Int, _ bytes: Data) -> Data {
        var d = encodeKey(field: field, wireType: 2)
        d.append(encodeVarint(UInt64(bytes.count)))
        d.append(bytes)
        return d
    }

    public static func encodeStringField(_ field: Int, _ string: String) -> Data {
        encodeBytesField(field, Data(string.utf8))
    }

    public static func encodeMessageField(_ field: Int, _ inner: Data) -> Data {
        encodeBytesField(field, inner)
    }

    /// Truncates a string to fit within `maxBytes` UTF-8 bytes without splitting multi-byte characters.
    public static func utf8Fit(_ text: String, maxBytes: Int) -> String {
        let bytes = Array(text.utf8)
        guard bytes.count > maxBytes else { return text }
        var cut = max(0, maxBytes)
        while cut > 0 && (bytes[cut] & 0xC0) == 0x80 {
            cut -= 1
        }
        return String(decoding: bytes[0..<cut], as: UTF8.self)
    }

    // MARK: - Decoding

    public static func decodeVarint(in data: Data, at start: Int) -> (value: UInt64, nextIndex: Int)? {
        let bytes = Array(data)
        var result: UInt64 = 0
        var shift: UInt64 = 0
        var index = start
        while index < bytes.count {
            let b = bytes[index]
            if shift < 64 {
                result |= UInt64(b & 0x7F) << shift
            }
            index += 1
            if (b & 0x80) == 0 {
                return (result, index)
            }
            shift += 7
            if shift > 70 { return nil }
        }
        return nil
    }

    public static func parseFields(_ pb: Data) -> [Field] {
        let bytes = Array(pb)
        let norm = Data(bytes)
        var fields: [Field] = []
        var i = 0
        let n = bytes.count
        while i < n {
            guard let (key, i1) = decodeVarint(in: norm, at: i) else { break }
            i = i1
            let fieldNum = Int(key >> 3)
            let wireType = Int(key & 0x07)
            switch wireType {
            case 0:
                guard let (v, i2) = decodeVarint(in: norm, at: i) else { return fields }
                i = i2
                fields.append(Field(number: fieldNum, wireType: wireType, varintValue: v, bytesValue: Data()))
            case 1:
                let end = min(n, i + 8)
                let slice = Data(bytes[i..<end])
                i += 8
                fields.append(Field(number: fieldNum, wireType: wireType, varintValue: 0, bytesValue: slice))
            case 2:
                guard let (len64, i2) = decodeVarint(in: norm, at: i) else { return fields }
                i = i2
                let len = Int(min(len64, UInt64(max(0, n - i))))
                let slice = Data(bytes[i..<(i + len)])
                i += len
                fields.append(Field(number: fieldNum, wireType: wireType, varintValue: 0, bytesValue: slice))
            case 5:
                let end = min(n, i + 4)
                let slice = Data(bytes[i..<end])
                i += 4
                fields.append(Field(number: fieldNum, wireType: wireType, varintValue: 0, bytesValue: slice))
            default:
                return fields
            }
        }
        return fields
    }

    public static func readVarintField(_ pb: Data, field: Int, default defaultValue: Int = -1) -> Int {
        for f in parseFields(pb) where f.number == field && f.wireType == 0 {
            return Int(Int64(bitPattern: f.varintValue))
        }
        return defaultValue
    }

    public static func readBytesField(_ pb: Data, field: Int) -> Data? {
        for f in parseFields(pb) where f.number == field && f.wireType == 2 {
            return f.bytesValue
        }
        return nil
    }

    public static func readStringField(_ pb: Data, field: Int, default defaultValue: String = "") -> String {
        guard let bytes = readBytesField(pb, field: field) else { return defaultValue }
        return String(decoding: bytes, as: UTF8.self)
    }

    public static func readFloatField(_ pb: Data, field: Int, default defaultValue: Float = 0) -> Float {
        for f in parseFields(pb) where f.number == field && f.wireType == 5 && f.bytesValue.count == 4 {
            let bits = f.bytesValue.withUnsafeBytes { $0.load(as: UInt32.self) }
            return Float(bitPattern: UInt32(littleEndian: bits))
        }
        return defaultValue
    }
}

/// Fluent builder for composing nested protobuf messages cleanly.
public final class PbBuilder {
    private var buffer = Data()

    public init() {}

    @discardableResult
    public func varint(_ field: Int, _ value: Int) -> PbBuilder {
        buffer.append(ProtobufLite.encodeVarintField(field, value))
        return self
    }

    @discardableResult
    public func uint64(_ field: Int, _ value: UInt64) -> PbBuilder {
        buffer.append(ProtobufLite.encodeUInt64Field(field, value))
        return self
    }

    @discardableResult
    public func string(_ field: Int, _ value: String) -> PbBuilder {
        buffer.append(ProtobufLite.encodeStringField(field, value))
        return self
    }

    @discardableResult
    public func bytes(_ field: Int, _ value: Data) -> PbBuilder {
        buffer.append(ProtobufLite.encodeBytesField(field, value))
        return self
    }

    @discardableResult
    public func message(_ field: Int, _ inner: Data) -> PbBuilder {
        buffer.append(ProtobufLite.encodeMessageField(field, inner))
        return self
    }

    public func build() -> Data { buffer }
}
