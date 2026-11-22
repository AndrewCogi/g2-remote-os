import Foundation

/// Parses raw 205-byte LC3 microphone notifications arriving on characteristic 0x6402 (service 0x6450).
/// Layout:
///   bytes   0..199 : 5 x 40-byte LC3 frames (10 ms each, 16 kHz mono, 32 kbps)
///   bytes 200..201 : Int16 LE signal-strength ratio
///   bytes 202..203 : Int16 LE direction of arrival (degrees)
///   byte  204      : UInt8 packet sequence counter (wraps at 256)
public struct G2MicPacket: Equatable {
    public static let sampleRate = 16_000
    public static let frameBytes = 40
    public static let framesPerPacket = 5
    public static let audioBytes = frameBytes * framesPerPacket // 200
    public static let fullPacketBytes = audioBytes + 5          // 205

    public let lc3Frames: [Data]
    public let rawAudioBytes: Data
    public let signalRatio: Int16?
    public let directionDegrees: Int16?
    public let counter: UInt8?

    public static func parse(_ data: Data) -> G2MicPacket? {
        let bytes = Array(data)
        guard bytes.count >= audioBytes else { return nil }
        var frames: [Data] = []
        frames.reserveCapacity(framesPerPacket)
        for i in 0..<framesPerPacket {
            let start = i * frameBytes
            frames.append(Data(bytes[start..<(start + frameBytes)]))
        }
        let rawAudio = Data(bytes[0..<audioBytes])

        if bytes.count < fullPacketBytes {
            return G2MicPacket(
                lc3Frames: frames,
                rawAudioBytes: rawAudio,
                signalRatio: nil,
                directionDegrees: nil,
                counter: nil
            )
        }

        let sigLo = UInt16(bytes[200])
        let sigHi = UInt16(bytes[201]) << 8
        let signal = Int16(bitPattern: sigLo | sigHi)

        let doaLo = UInt16(bytes[202])
        let doaHi = UInt16(bytes[203]) << 8
        let doa = Int16(bitPattern: doaLo | doaHi)

        return G2MicPacket(
            lc3Frames: frames,
            rawAudioBytes: rawAudio,
            signalRatio: signal,
            directionDegrees: doa,
            counter: bytes[204]
        )
    }
}
