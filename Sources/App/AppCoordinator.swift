import Combine
import Foundation
import UIKit

/// Central singleton coordinating G2 BLE, Always-On OS protection, Flic Duo,
/// fullscreen Motion Pad inputs, live data services (Weather, Calendar/QuickList, Pedometer, Alarm/Timer),
/// and the G2 OS state machine.
public final class AppCoordinator: ObservableObject {
    public static let shared = AppCoordinator()

    public let ble = G2BLEManager()
    public let flic = FlicDuoDriver()
    public let os = G2OSStateMachine()
    public let backgroundKeeper = BackgroundKeeper()

    // Live $0 free iOS data services
    public let weather = WeatherService()
    public let calendar = CalendarQuickListService()
    public let pedometer = PedometerService()
    public let clockTools = AlarmTimerService()

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

    public func bootstrap() {
        guard !bootstrapped else { return }
        bootstrapped = true
        appendLog("[SYS] G2 OS v0.3 시작")

        flic.configure()

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

        // Start free live services
        weather.start()
        calendar.start()
        pedometer.start()
        clockTools.start()
        syncAllServicesToOS(push: false)
    }

    public func triggerMotionAction(_ action: RemoteAction, detail: String = "") {
        playHaptic(for: action)
        os.handle(RemoteCommandEvent(action: action, source: .motionPad, detail: detail))
        updateImuStreamingNeed()
    }

    public func triggerVirtualAction(_ action: RemoteAction, detail: String = "") {
        playHaptic(for: action)
        os.handle(RemoteCommandEvent(action: action, source: .virtualPad, detail: detail))
        updateImuStreamingNeed()
    }

    public func clearLogs() {
        DispatchQueue.main.async { self.logs.removeAll() }
    }

    public func refreshAllData() {
        weather.requestLocationAndRefresh()
        calendar.refresh()
        ble.querySettings()
        syncAllServicesToOS(push: true)
    }

    private func updateImuStreamingNeed() {
        let needsImu = os.headUpWakeEnabled || os.currentScreen == .headUp
        ble.setImuStreaming(needsImu, reportFreqMs: 250)
    }

    private func syncAllServicesToOS(push: Bool) {
        os.weather = weather.snapshot
        os.calendarEvents = calendar.upcomingEvents
        os.quickTasks = calendar.tasks
        os.todaySteps = pedometer.todaySteps
        os.todayDistanceKm = pedometer.formattedDistanceKm
        os.alarms = clockTools.alarms
        os.nextAlarm = clockTools.nextEnabledAlarm
        os.timerRemainingSeconds = clockTools.timerRemainingSeconds
        os.isTimerRunning = clockTools.isTimerRunning
        os.stopwatchSeconds = clockTools.stopwatchSeconds
        os.isStopwatchRunning = clockTools.isStopwatchRunning
        os.stopwatchLaps = clockTools.stopwatchLaps
        os.activeAlert = clockTools.activeAlert
        os.refreshDisplay(pushToGlasses: push)
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
                self.calendar.refresh()
            }
        )
        observers.append(
            nc.addObserver(
                forName: UIApplication.didBecomeActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.backgroundKeeper.ensureRunning()
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
            self.updateImuStreamingNeed()
        }

        // Forward G2 IMU stream -> Head-Up Wake detector
        ble.onImuSample = { [weak self] sample in
            self?.os.handleImuSample(sample)
        }

        // Forward G2 temple touch events -> OS
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
                self.updateImuStreamingNeed()
            }
        }

        // Mic packet telemetry -> throttled live G2 HUD refresh
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

        // Service updates -> OS live refresh
        weather.onUpdate = { [weak self] _ in
            guard let self else { return }
            self.syncAllServicesToOS(push: self.os.currentScreen == .dashboard)
        }
        calendar.onChanged = { [weak self] in
            guard let self else { return }
            let push = (self.os.currentScreen == .dashboard || self.os.currentScreen == .quickList)
            self.syncAllServicesToOS(push: push)
        }
        pedometer.onUpdate = { [weak self] in
            guard let self else { return }
            self.syncAllServicesToOS(push: self.os.currentScreen == .dashboard)
        }
        clockTools.onTick = { [weak self] in
            guard let self else { return }
            let push = (self.os.currentScreen == .clockTools || self.os.currentScreen == .dashboard || self.clockTools.activeAlert != nil)
            self.syncAllServicesToOS(push: push)
        }
        clockTools.onAlertStarted = { [weak self] alert in
            guard let self else { return }
            self.appendLog("[알림] \(alert.kind.rawValue): \(alert.title)")
            self.flic.testBuzzer()
            self.syncAllServicesToOS(push: true)
        }
        clockTools.onAlertDismissed = { [weak self] in
            self?.syncAllServicesToOS(push: true)
        }

        // Outbound OS actions -> Hardware & Services
        os.onPageChanged = { [weak self] page in
            self?.ble.renderPage(page)
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
        os.onSetBrightness = { [weak self] level in self?.ble.setBrightness(level) }
        os.onSetAutoBrightness = { [weak self] on in self?.ble.setAutoBrightness(on) }
        os.onSetDisplayHeight = { [weak self] h in self?.ble.setDisplayHeight(h) }
        os.onSetDisplayDistance = { [weak self] d in self?.ble.setDisplayDistance(d) }
        os.onSetHeadUpConfig = { [weak self] on, angle in self?.ble.setHeadUp(enabled: on, angle: angle) }
        os.onSetWearDetection = { [weak self] on in self?.ble.setWearDetection(on) }
        os.onSetSilentMode = { [weak self] on in self?.ble.setSilentMode(on) }
        os.onSetAncsEnabled = { [weak self] on in self?.ble.setAncsNotifications(enabled: on) }
        os.onQuerySettings = { [weak self] in self?.ble.querySettings() }
        os.onSetScreenAsleep = { [weak self] asleep in self?.ble.setScreenAsleep(asleep) }
        os.onRefreshDataServices = { [weak self] in self?.refreshAllData() }
        os.onToggleQuickTask = { [weak self] id in self?.calendar.toggleTask(id: id) }
        os.onToggleAlarm = { [weak self] id in self?.clockTools.toggleAlarm(id: id) }
        os.onSetTimerPreset = { [weak self] secs in self?.clockTools.setTimerDuration(seconds: secs) }
        os.onToggleTimer = { [weak self] in self?.clockTools.toggleTimer() }
        os.onResetTimer = { [weak self] in self?.clockTools.resetTimer() }
        os.onToggleStopwatch = { [weak self] in self?.clockTools.toggleStopwatch() }
        os.onLapStopwatch = { [weak self] in self?.clockTools.lapStopwatch() }
        os.onResetStopwatch = { [weak self] in self?.clockTools.resetStopwatch() }
        os.onDismissAlert = { [weak self] in self?.clockTools.dismissActiveAlert() }
        os.onSnoozeAlert = { [weak self] in self?.clockTools.snoozeActiveAlert(minutes: 5) }

        // Sync BLE hardware readback -> OS state
        ble.$batteryLevel
            .receive(on: DispatchQueue.main)
            .sink { [weak self] val in
                guard let self else { return }
                self.os.g2Battery = val
                if self.os.currentScreen == .dashboard { self.os.refreshDisplay(pushToGlasses: true) }
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

        ble.$brightnessAuto
            .receive(on: DispatchQueue.main)
            .sink { [weak self] val in self?.os.autoBrightness = val }
            .store(in: &cancellables)

        ble.$displayHeight
            .receive(on: DispatchQueue.main)
            .sink { [weak self] val in self?.os.displayHeight = val }
            .store(in: &cancellables)

        ble.$displayDistance
            .receive(on: DispatchQueue.main)
            .sink { [weak self] val in self?.os.displayDistance = val }
            .store(in: &cancellables)

        ble.$wearDetection
            .receive(on: DispatchQueue.main)
            .sink { [weak self] val in self?.os.wearDetection = val }
            .store(in: &cancellables)

        ble.$silentMode
            .receive(on: DispatchQueue.main)
            .sink { [weak self] val in self?.os.silentMode = val }
            .store(in: &cancellables)

        ble.$firmwareLeft
            .receive(on: DispatchQueue.main)
            .sink { [weak self] val in self?.os.g2FirmwareLeft = val }
            .store(in: &cancellables)

        ble.$firmwareRight
            .receive(on: DispatchQueue.main)
            .sink { [weak self] val in self?.os.g2FirmwareRight = val }
            .store(in: &cancellables)

        ble.$phase
            .receive(on: DispatchQueue.main)
            .sink { [weak self] phase in
                if phase == .connected {
                    self?.syncAllServicesToOS(push: true)
                    self?.updateImuStreamingNeed()
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
