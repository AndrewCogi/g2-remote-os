import Combine
import Foundation
import UIKit

/// Central singleton coordinating G2 BLE, Always-On OS protection, Flic Duo,
/// fullscreen Motion Pad inputs, and the G2 mini OS.
public final class AppCoordinator: ObservableObject {
    public static let shared = AppCoordinator()

    public let ble = G2BLEManager()
    public let flic = FlicDuoDriver()
    public let os = G2OSStateMachine()
    public let backgroundKeeper = BackgroundKeeper()

    @Published public private(set) var logs: [String] = []
    @Published public var keepAliveEnabled: Bool = true {
        didSet {
            UserDefaults.standard.set(keepAliveEnabled, forKey: Self.keepAliveKey)
            backgroundKeeper.setEnabled(keepAliveEnabled)
            ble.setAlwaysStayInCustomOS(keepAliveEnabled)
            os.alwaysOnEnabled = keepAliveEnabled
            os.refreshDisplay(pushToGlasses: false)
        }
    }
    @Published public var lastSavedRecordingPath: String?

    private static let keepAliveKey = "g2_always_on_os_v2"

    private var bootstrapped = false
    private var cancellables = Set<AnyCancellable>()
    private var observers: [NSObjectProtocol] = []
    private var lastMicRenderAt: Date = .distantPast
    private let logTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    private init() {
        wireCallbacks()
        installLifecycleObservers()
    }

    deinit {
        for token in observers {
            NotificationCenter.default.removeObserver(token)
        }
    }

    /// Safe to call multiple times; executes initialization exactly once on launch.
    public func bootstrap() {
        guard !bootstrapped else { return }
        bootstrapped = true
        appendLog("[SYS] G2 OS 시작")

        flic.configure()

        // Always-On protection defaults to ON so the glasses never fall back to stock OS.
        let saved: Bool
        if UserDefaults.standard.object(forKey: Self.keepAliveKey) == nil {
            saved = true
        } else {
            saved = UserDefaults.standard.bool(forKey: Self.keepAliveKey)
        }
        keepAliveEnabled = saved
        backgroundKeeper.setEnabled(saved)
        ble.setAlwaysStayInCustomOS(saved)
        os.alwaysOnEnabled = saved
    }

    public func triggerMotionAction(_ action: RemoteAction, detail: String = "") {
        playHaptic(for: action)
        os.handle(RemoteCommandEvent(action: action, source: .motionPad, detail: detail))
    }

    public func triggerVirtualAction(_ action: RemoteAction, detail: String = "") {
        playHaptic(for: action)
        os.handle(RemoteCommandEvent(action: action, source: .virtualPad, detail: detail))
    }

    public func clearLogs() {
        DispatchQueue.main.async { self.logs.removeAll() }
    }

    private func playHaptic(for action: RemoteAction) {
        switch action {
        case .micStart:
            UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
        case .micStop:
            UIImpactFeedbackGenerator(style: .soft).impactOccurred()
        case .select:
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        case .back:
            UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
        default:
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        }
    }

    private func installLifecycleObservers() {
        let nc = NotificationCenter.default
        observers.append(
            nc.addObserver(
                forName: UIApplication.willEnterForegroundNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                guard let self else { return }
                self.backgroundKeeper.ensureRunning()
                self.ble.ensureScreenActive(forceRecreate: false)
            }
        )
        observers.append(
            nc.addObserver(
                forName: UIApplication.didBecomeActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                guard let self else { return }
                self.backgroundKeeper.ensureRunning()
            }
        )
    }

    private func wireCallbacks() {
        ble.onLog = { [weak self] msg in self?.appendLog(msg) }
        flic.onLog = { [weak self] msg in self?.appendLog(msg) }
        backgroundKeeper.onLog = { [weak self] msg in self?.appendLog(msg) }

        // Forward Flic Duo hardware events -> OS
        flic.onAction = { [weak self] event in
            guard let self else { return }
            self.appendLog("[Flic] \(event.detail) → \(event.action.rawValue)")
            self.os.handle(event)
        }

        // Forward G2 temple touch events -> OS (ignore system exit notifications already handled by BLE guard)
        ble.onGlassesEvent = { [weak self] devEvent in
            guard let self else { return }
            let mapped: RemoteAction?
            switch devEvent.eventType {
            case .click: mapped = .select
            case .doubleClick: mapped = .back
            case .scrollTop: mapped = .up
            case .scrollBottom: mapped = .down
            case .longPress: mapped = .micStart
            case .longPressRelease: mapped = .micStop
            default: mapped = nil
            }
            if let mapped {
                self.os.handle(RemoteCommandEvent(action: mapped, source: .glassesTemple, detail: devEvent.eventType.label))
            }
        }

        // Mic packet telemetry -> throttled live G2 HUD refresh while Push-to-Talk mic is open
        ble.onMicPacket = { [weak self] packet in
            guard let self else { return }
            self.os.micPackets = self.ble.micPacketCount
            self.os.micDurationMs = self.ble.micDurationMs
            if let s = packet.signalRatio { self.os.micSignal = s }
            if let d = packet.directionDegrees { self.os.micDOA = d }

            let now = Date()
            if self.os.isMicOn && now.timeIntervalSince(self.lastMicRenderAt) >= 0.45 {
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
                guard let self else { return }
                self.os.g2Battery = val
                if self.os.currentScreen == .home || self.os.currentScreen == .briefing {
                    self.os.refreshDisplay(pushToGlasses: true)
                }
            }
            .store(in: &cancellables)

        ble.$isCharging
            .receive(on: DispatchQueue.main)
            .sink { [weak self] val in self?.os.g2Charging = val }
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

        flic.$isReady
            .receive(on: DispatchQueue.main)
            .sink { [weak self] ready in self?.os.flicConnected = ready }
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
