import Combine
import Foundation
import UIKit

/// Central singleton coordinating G2 BLE, Flic Duo background events, virtual pad, and the G2 mini OS.
/// Kept as a singleton so `AppDelegate.didFinishLaunchingWithOptions` can restore both CoreBluetooth
/// and `FLICManager` immediately during background wakes while the iPhone screen is locked.
public final class AppCoordinator: ObservableObject {
    public static let shared = AppCoordinator()

    public let ble = G2BLEManager()
    public let flic = FlicDuoDriver()
    public let os = G2OSStateMachine()
    public let backgroundKeeper = BackgroundKeeper()

    @Published public private(set) var logs: [String] = []
    @Published public var keepAliveEnabled: Bool = false {
        didSet {
            UserDefaults.standard.set(keepAliveEnabled, forKey: "g2_bg_keepalive")
            backgroundKeeper.setEnabled(keepAliveEnabled)
        }
    }
    @Published public var lastSavedRecordingPath: String?

    private var bootstrapped = false
    private var cancellables = Set<AnyCancellable>()
    private var lastMicRenderAt: Date = .distantPast
    private let logTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    private init() {
        wireCallbacks()
    }

    /// Safe to call multiple times; executes initialization exactly once on launch.
    public func bootstrap() {
        guard !bootstrapped else { return }
        bootstrapped = true
        appendLog("[SYS] G2 Remote OS 시작")

        flic.configure()

        let savedKeepAlive = UserDefaults.standard.bool(forKey: "g2_bg_keepalive")
        if savedKeepAlive {
            keepAliveEnabled = true
        }
    }

    public func triggerVirtualAction(_ action: RemoteAction, detail: String = "") {
        let generator = UIImpactFeedbackGenerator(style: .light)
        generator.impactOccurred()
        os.handle(RemoteCommandEvent(action: action, source: .virtualPad, detail: detail))
    }

    public func clearLogs() {
        DispatchQueue.main.async { self.logs.removeAll() }
    }

    private func wireCallbacks() {
        ble.onLog = { [weak self] msg in self?.appendLog(msg) }
        flic.onLog = { [weak self] msg in self?.appendLog(msg) }

        // Forward Flic Duo hardware events -> OS
        flic.onAction = { [weak self] event in
            guard let self else { return }
            self.appendLog("[Flic 입력] \(event.detail) → \(event.action.rawValue)")
            self.os.handle(event)
        }

        // Forward G2 temple touch events -> OS (so temple controls still work alongside the remote)
        ble.onGlassesEvent = { [weak self] devEvent in
            guard let self else { return }
            let mapped: RemoteAction?
            switch devEvent.eventType {
            case .click: mapped = .select
            case .doubleClick: mapped = .back
            case .scrollTop: mapped = .scrollUp
            case .scrollBottom: mapped = .scrollDown
            case .longPress: mapped = .micToggle
            default: mapped = nil
            }
            if let mapped {
                self.os.handle(RemoteCommandEvent(action: mapped, source: .glassesTemple, detail: devEvent.eventType.label))
            }
        }

        // Mic packet telemetry -> throttled G2 display refresh (every 500ms while on Mic screen)
        ble.onMicPacket = { [weak self] packet in
            guard let self else { return }
            self.os.micPackets = self.ble.micPacketCount
            self.os.micDurationMs = self.ble.micDurationMs
            if let s = packet.signalRatio { self.os.micSignal = s }
            if let d = packet.directionDegrees { self.os.micDOA = d }

            let now = Date()
            if self.os.currentScreen == .mic && now.timeIntervalSince(self.lastMicRenderAt) >= 0.5 {
                self.lastMicRenderAt = now
                self.os.refreshDisplay(pushToGlasses: true)
            }
        }

        // Outbound OS actions -> G2 hardware & Flic Duo buzzer
        os.onRenderChanged = { [weak self] text in
            self?.ble.renderScreenText(text)
        }
        os.onToggleMic = { [weak self] enabled in
            guard let self else { return }
            self.ble.setMicrophoneEnabled(enabled)
            self.flic.playBuzzerFeedback(micEnabled: enabled)
        }
        os.onSaveMicRecording = { [weak self] in
            guard let self else { return }
            if let url = self.ble.saveLastMicRecording() {
                DispatchQueue.main.async { self.lastSavedRecordingPath = url.lastPathComponent }
            }
        }
        os.onSetBrightness = { [weak self] level in
            self?.ble.setBrightness(level)
        }
        os.onSetSilentMode = { [weak self] enabled in
            self?.ble.setSilentMode(enabled)
        }
        os.onQuerySettings = { [weak self] in
            self?.ble.querySettings()
        }
        os.onSetScreenAsleep = { [weak self] asleep in
            self?.ble.setScreenAsleep(asleep)
        }

        // Sync BLE telemetry to OS state
        ble.$batteryLevel
            .receive(on: DispatchQueue.main)
            .sink { [weak self] val in
                self?.os.g2Battery = val
                if self?.os.currentScreen == .dashboard { self?.os.refreshDisplay(pushToGlasses: true) }
            }
            .store(in: &cancellables)

        ble.$brightnessLevel
            .receive(on: DispatchQueue.main)
            .sink { [weak self] val in self?.os.brightness = val }
            .store(in: &cancellables)

        ble.$silentMode
            .receive(on: DispatchQueue.main)
            .sink { [weak self] val in self?.os.silentMode = val }
            .store(in: &cancellables)

        ble.$phase
            .receive(on: DispatchQueue.main)
            .sink { [weak self] phase in
                if phase == .connected {
                    self?.os.refreshDisplay(pushToGlasses: true)
                }
            }
            .store(in: &cancellables)

        flic.$batteryVoltage
            .receive(on: DispatchQueue.main)
            .sink { [weak self] v in self?.os.flicVoltage = v }
            .store(in: &cancellables)
    }

    public func appendLog(_ message: String) {
        let stamped = "[\(logTimeFormatter.string(from: Date()))] \(message)"
        DispatchQueue.main.async {
            self.logs.insert(stamped, at: 0)
            if self.logs.count > 200 {
                self.logs.removeLast(self.logs.count - 200)
            }
        }
    }
}
