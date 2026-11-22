import AVFoundation
import Foundation

/// Optional background keep-alive helper for personal SideStore builds.
/// When enabled, plays an inaudible 1-second silent WAV loop mixed with other audio
/// so iOS does not suspend the 4-second G2 EvenHub heartbeat timer while the screen is locked.
public final class BackgroundKeeper: ObservableObject {
    @Published public private(set) var isActive: Bool = false

    private var player: AVAudioPlayer?
    private var logHandler: ((String) -> Void)?

    public init(onLog: ((String) -> Void)? = nil) {
        self.logHandler = onLog
    }

    public func setEnabled(_ enabled: Bool) {
        if enabled {
            start()
        } else {
            stop()
        }
    }

    public func start() {
        guard !isActive else { return }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)

            let wavData = Self.makeSilentWav(durationSeconds: 1, sampleRate: 8000)
            let p = try AVAudioPlayer(data: wavData)
            p.numberOfLoops = -1
            p.volume = 0.0
            p.prepareToPlay()
            p.play()

            self.player = p
            DispatchQueue.main.async { self.isActive = true }
            logHandler?("[BG] 백그라운드 상시 유지(무음 오디오 믹스) 활성화")
        } catch {
            logHandler?("[BG] 상시 유지 시작 실패: \(error.localizedDescription)")
        }
    }

    public func stop() {
        player?.stop()
        player = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        DispatchQueue.main.async { self.isActive = false }
        logHandler?("[BG] 백그라운드 상시 유지 비활성화")
    }

    /// Generates a minimal 16-bit mono PCM silent WAV file in memory (zero disk I/O).
    private static func makeSilentWav(durationSeconds: Int, sampleRate: UInt32) -> Data {
        let numChannels: UInt16 = 1
        let bitsPerSample: UInt16 = 16
        let numSamples = Int(sampleRate) * max(1, durationSeconds)
        let dataSize = UInt32(numSamples * Int(bitsPerSample / 8))
        let byteRate = sampleRate * UInt32(numChannels) * UInt32(bitsPerSample / 8)
        let blockAlign = numChannels * (bitsPerSample / 8)
        let chunkSize = 36 + dataSize

        var d = Data(capacity: Int(44 + dataSize))
        func appendLE<T: FixedWidthInteger>(_ v: T) {
            var le = v.littleEndian
            withUnsafeBytes(of: &le) { d.append(contentsOf: $0) }
        }

        d.append(contentsOf: "RIFF".utf8)
        appendLE(chunkSize)
        d.append(contentsOf: "WAVE".utf8)
        d.append(contentsOf: "fmt ".utf8)
        appendLE(UInt32(16))
        appendLE(UInt16(1)) // PCM
        appendLE(numChannels)
        appendLE(sampleRate)
        appendLE(byteRate)
        appendLE(blockAlign)
        appendLE(bitsPerSample)
        d.append(contentsOf: "data".utf8)
        appendLE(dataSize)
        d.append(Data(count: Int(dataSize)))
        return d
    }
}
