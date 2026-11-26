import Foundation

/// G2 BLE transport framing and multi-packet reassembly.
/// Wire layout: AA <dir> <seq> <len> <total> <num> <SID> <flag> <payload...> [crc_lo crc_hi]
public enum G2Frame {
    public static let headByte: UInt8 = 0xAA
    public static let dirAppToGlasses: UInt8 = 0x21
    public static let dirGlassesToApp: UInt8 = 0x12

    public static let flagRequest: UInt8 = 0x20
    public static let flagPlain: UInt8 = 0x00

    /// Max bytes per packet body (MTU 247 - 3 ATT - 8 header = 236, capped at 232 for safety).
    public static let defaultChunkSize = 232
    public static let assembledLenMarker: UInt8 = 0xFF

    public struct ParsedFrame: Equatable {
        public let sid: UInt8
        public let flag: UInt8
        public let payload: Data

        public init(sid: UInt8, flag: UInt8, payload: Data) {
            self.sid = sid
            self.flag = flag
            self.payload = payload
        }
    }

    /// Wraps a protobuf payload in one or more AA 21 frames with a single trailing little-endian CRC-16
    /// placed on the final packet only (byte-exact with official Even App BTSnoop multi-packet framing).
    /// Every fragment of one logical message shares the same `seq` byte.
    public static func framePb(
        _ pb: Data,
        sid: UInt8,
        flag: UInt8,
        seq: UInt8,
        maxWrite: Int = 244
    ) -> [Data] {
        // Reserve 8 bytes AA header + 2 bytes trailing CRC on the final packet so no packet exceeds maxWrite.
        let maxChunk = max(16, min(maxWrite - 10, defaultChunkSize))
        let crc = CRC16.ccittFalseBytes(pb)

        let total = max(1, (pb.count + maxChunk - 1) / maxChunk)
        var frames: [Data] = []
        frames.reserveCapacity(total)

        for i in 0..<total {
            let start = i * maxChunk
            let end = min(start + maxChunk, pb.count)
            let chunk = pb[start..<end]
            let isFinal = (i == total - 1)
            let lenByte = chunk.count + (isFinal ? 2 : 0)

            var pkt = Data(capacity: 8 + lenByte)
            pkt.append(headByte)
            pkt.append(dirAppToGlasses)
            pkt.append(seq)
            pkt.append(UInt8(lenByte & 0xFF))
            pkt.append(UInt8(total & 0xFF))
            pkt.append(UInt8((i + 1) & 0xFF))
            pkt.append(sid)
            pkt.append(flag)
            pkt.append(chunk)
            if isFinal {
                pkt.append(crc)
            }
            frames.append(pkt)
        }
        return frames
    }

    /// LIVE-CONFIRMED single-packet authentication frame (SID 0x80, cmd 4, flag 0x00).
    /// Keep `magic` in 1...127 so the single-byte varint matches the captured wire frame byte-for-byte.
    public static func authFrame(magic: UInt8) -> Data {
        let safeMagic = max(1, min(127, magic))
        let pb = Data([0x08, 0x04, 0x10, safeMagic, 0x1A, 0x04, 0x08, 0x01, 0x10, 0x04])
        var pkt = Data([headByte, dirAppToGlasses, safeMagic, UInt8(pb.count + 2), 0x01, 0x01, 0x80, flagPlain])
        pkt.append(pb)
        pkt.append(CRC16.ccittFalseBytes(pb))
        return pkt
    }

    /// Splits a single (or assembled) AA frame into (sid, flag, protobuf payload without CRC).
    public static func parseFrame(_ frame: Data) -> ParsedFrame? {
        let bytes = Array(frame)
        guard bytes.count >= 10, bytes[0] == headByte else { return nil }
        let lenByte = bytes[3]
        let payloadEnd: Int
        if lenByte == assembledLenMarker {
            payloadEnd = max(8, bytes.count - 2)
        } else {
            let bodyLen = max(0, Int(lenByte) - 2)
            payloadEnd = min(bytes.count, 8 + bodyLen)
        }
        let payload = Data(bytes[8..<payloadEnd])
        return ParsedFrame(sid: bytes[6], flag: bytes[7], payload: payload)
    }

    /// Extracts field 2 (`magicRandom`) from a standard G2 ack protobuf.
    public static func readAckMagic(_ pb: Data) -> Int? {
        let norm = Data(pb)
        guard norm.count >= 2 else { return nil }
        if norm[0] == 0x10 {
            return ProtobufLite.decodeVarint(in: norm, at: 1).map { Int($0.value) }
        }
        guard norm[0] == 0x08,
              let (_, nextIdx) = ProtobufLite.decodeVarint(in: norm, at: 1),
              nextIdx < norm.count,
              norm[nextIdx] == 0x10,
              let (magic, _) = ProtobufLite.decodeVarint(in: norm, at: nextIdx + 1)
        else { return nil }
        return Int(magic)
    }
}

/// Reassembles multi-packet BLE notifications arriving on 0x5402.
public final class G2FrameAssembler {
    private struct Key: Hashable {
        let seq: UInt8
        let sid: UInt8
    }

    private struct Pending {
        let header: Data
        let total: Int
        var parts: [Int: Data]
        let createdAt: Date
    }

    private var buckets: [Key: Pending] = [:]

    public init() {}

    /// Feeds one raw BLE notification. Returns a complete frame when ready, or `nil` while waiting for fragments.
    public func feed(_ packet: Data) -> Data? {
        let bytes = Array(packet)
        guard bytes.count >= 10, bytes[0] == G2Frame.headByte else { return nil }
        let seq = bytes[2]
        let total = Int(bytes[4])
        let num = Int(bytes[5])
        let sid = bytes[6]

        if total <= 1 {
            return Data(bytes)
        }
        guard num >= 1, num <= total else { return nil }

        // Expire stale incomplete frames older than 5 seconds.
        let now = Date()
        buckets = buckets.filter { now.timeIntervalSince($0.value.createdAt) < 5.0 }

        let key = Key(seq: seq, sid: sid)
        let body = Data(bytes[8..<bytes.count])

        if var existing = buckets[key], existing.total == total {
            existing.parts[num] = body
            buckets[key] = existing
        } else {
            var header = Data(bytes[0..<8])
            header[3] = G2Frame.assembledLenMarker
            header[4] = 1
            header[5] = 1
            buckets[key] = Pending(header: header, total: total, parts: [num: body], createdAt: now)
        }

        guard let bucket = buckets[key], bucket.parts.count == total else { return nil }
        buckets.removeValue(forKey: key)

        var assembled = bucket.header
        for idx in 1...total {
            if let part = bucket.parts[idx] {
                assembled.append(part)
            }
        }
        return assembled
    }

    public func reset() {
        buckets.removeAll()
    }
}
