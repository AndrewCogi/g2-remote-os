import AVFoundation
import Foundation
import UIKit

/// Keeps the iOS app alive in the background while the iPhone screen is locked so the
/// G2 EvenHub heartbeat never stops and the glasses never drop back to stock OS.
/// Uses an inaudible all-zero PCM silent WAV loop mixed with other audio (`mixWithOthers`),
/// plus automatic recovery across phone calls, alarms, Siri interruptions, and route changes.
public final class BackgroundKeeper: ObservableObject {
    @Published public private(set) var isActive: Bool = false

    public var onLog: ((String) -> Void)?

    private var player: AVAudioPlayer?
    private var desiredEnabled: Bool = false
    private var observers: [NSObjectProtocol] = []

    public init(onLog: ((String) -> Void)? = nil) {
        self.onLog = onLog
        installObservers()
    }

    deinit {
        for token in observers {
            NotificationCenter.default.removeObserver(token)
        }
        player?.stop()
    }

    public func setEnabled(_ enabled: Bool) {
        desiredEnabled = enabled
        if enabled {
            start()
        } else {
            stop()
        }
    }

    public func start() {
        desiredEnabled = true
        if let player, player.isPlaying, isActive {
            return
        }
        activatePlayer(reason: "백그라운드 상시 유지(무음 믹스) 활성화")
    }

    public func stop() {
        desiredEnabled = false
        player?.stop()
        player = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        DispatchQueue.main.async { self.isActive = false }
        onLog?("[BG] 백그라운드 상시 유지 비활성화")
    }

    /// Re-verifies the silent audio loop is still running (e.g. after app foreground or interruption).
    public func ensureRunning() {
        guard desiredEnabled else { return }
        if player?.isPlaying != true {
            activatePlayer(reason: "백그라운드 상시 유지 자동 재개")
        }
    }

    // MARK: - Internal Audio Loop & Interruption Recovery

    private func activatePlayer(reason: String) {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)

            let wavData = Self.makeSilentWav(durationSeconds: 2, sampleRate: 8000)
            let p = try AVAudioPlayer(data: wavData)
            p.numberOfLoops = -1
            // PCM samples are mathematically 0x0000 (100% silent), while non-zero player volume
            // prevents iOS from optimizing away muted playback sessions in the background.
            p.volume = 0.01
            p.prepareToPlay()
            let started = p.play()

            self.player = p
            DispatchQueue.main.async { self.isActive = started }
            onLog?("[BG] \(reason)\(started ? "" : " (재생 대기)")")
        } catch {
            DispatchQueue.main.async { self.isActive = false }
            onLog?("[BG] 상시 유지 시작 실패: \(error.localizedDescription)")
        }
    }

    private func installObservers() {
        let nc = NotificationCenter.default

        observers.append(
            nc.addObserver(
                forName: AVAudioSession.interruptionNotification,
                object: nil,
                queue: .main
            ) { [weak self] note in
                guard let self, self.desiredEnabled else { return }
                guard let info = note.userInfo,
                      let rawType = info[AVAudioSessionInterruptionTypeKey] as? UInt,
                      let type = AVAudioSession.InterruptionType(rawValue: rawType)
                else { return }

                switch type {
                case .began:
                    self.isActive = false
                    self.onLog?("[BG] 오디오 인터럽션 감지 (통화/알람 등) — 종료 후 자동 재개 대기")
                case .ended:
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                        self?.ensureRunning()
                    }
                @unknown default:
                    break
                }
            }
        )

        observers.append(
            nc.addObserver(
                forName: AVAudioSession.routeChangeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                guard let self, self.desiredEnabled else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                    self?.ensureRunning()
                }
            }
        )

        observers.append(
            nc.addObserver(
                forName: AVAudioSession.mediaServicesWereResetNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                guard let self, self.desiredEnabled else { return }
                self.player = nil
                self.activatePlayer(reason: "미디어 서비스 리셋 후 상시 유지 재초기화")
            }
        )

        observers.append(
            nc.addObserver(
                forName: UIApplication.didBecomeActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.ensureRunning()
            }
        )
    }

    /// Generates a minimal 16-bit mono PCM all-zero silent WAV buffer in memory (zero disk I/O).
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
