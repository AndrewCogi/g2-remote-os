import Combine
import Foundation
import UIKit

/// Central singleton coordinating G2 BLE, Always-On OS protection, Flic Duo,
/// fullscreen Motion Pad, live free iOS data services, and the DGX Spark 2x real-time `agy` bridge.
public final class AppCoordinator: ObservableObject {
    public static let shared = AppCoordinator()

    public let ble = G2BLEManager()
    public let flic = FlicDuoDriver()
    public let gamepad = GameControllerDriver()
    public let os = G2OSStateMachine()
    public let backgroundKeeper = BackgroundKeeper()
    public let spark = SparkBridgeClient()
    public let tailscale = TailscaleMonitor()

    // Live $0 free iOS data services
    public let weather = WeatherService()
    public let calendar = CalendarQuickListService()
    public let pedometer = PedometerService()
    public let clockTools = AlarmTimerService()
    public let feed = FeedService()

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
    private var lastAiDeltaRenderAt: Date = .distantPast
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
        appendLog("[SYS] G2 OS v0.4 (DGX Spark agy) 시작")

        flic.configure()
        gamepad.start()

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

        weather.start()
        calendar.start()
        pedometer.start()
        clockTools.start()
        tailscale.start()
        feed.refresh()
        syncTailscaleToOS(connected: tailscale.isTailscaleConnected, ip: tailscale.tailscaleIPv4, push: false)
        syncAllServicesToOS(push: false)

        if tailscale.isTailscaleConnected {
            spark.connectWithFailover()
        }
    }

    private func syncTailscaleToOS(connected: Bool, ip: String?, push: Bool) {
        os.tailscaleConnected = connected
        os.tailscaleIP = ip
        if !connected {
            os.sparkConnected = false
            os.sparkActiveShortTag = ""
            os.sparkNodeStatus = "TS 꺼짐"
        } else if !spark.isConnected {
            os.sparkNodeStatus = "Spark 연결 중"
        }
        os.feedCategories = feed.categories
        os.refreshDisplay(pushToGlasses: push)
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
        feed.refresh()
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
        os.feedCategories = feed.categories
        os.refreshDisplay(pushToGlasses: push)
    }

    private func executeVoiceOSCommands(_ commands: [SparkOSCommand]) {
        for cmd in commands {
            switch cmd {
            case .timer(let seconds):
                clockTools.setTimerDuration(seconds: seconds)
                clockTools.toggleTimer()
                os.notifyVoiceCommandExecuted("타이머 \(AlarmTimerService.formatDuration(seconds)) 시작")
                appendLog("[음성 명령] 타이머 \(seconds)초 시작")
            case .alarm(let hour, let minute, let label):
                clockTools.addAlarm(hour: hour, minute: minute, label: label)
                os.notifyVoiceCommandExecuted(String(format: "알람 %02d:%02d 설정", hour, minute))
                appendLog(String(format: "[음성 명령] 알람 %02d:%02d (%@)", hour, minute, label))
            case .task(let title):
                calendar.addTask(title: title)
                os.notifyVoiceCommandExecuted("할 일 추가: \(title)")
                appendLog("[음성 명령] 할 일 추가: \(title)")
            case .brightness(let level):
                os.brightness = level
                ble.setBrightness(level)
                os.notifyVoiceCommandExecuted("밝기 \(level)/50")
                appendLog("[음성 명령] 밝기 \(level)")
            case .silent(let enabled):
                os.silentMode = enabled
                ble.setSilentMode(enabled)
                os.notifyVoiceCommandExecuted("무음 모드 \(enabled ? "ON" : "OFF")")
                appendLog("[음성 명령] 무음 \(enabled ? "ON" : "OFF")")
            }
        }
    }

    private func playHaptic(for action: RemoteAction) {
        switch action {
        case .micStart: UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
        case .micStop: UIImpactFeedbackGenerator(style: .soft).impactOccurred()
        case .select: UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        case .back: UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
        default: UIImpactFeedbackGenerator(style: .light).impactOccurred()
        }
    }

    private func installLifecycleObservers() {
        let nc = NotificationCenter.default
        observers.append(
            nc.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
                guard let self else { return }
                self.backgroundKeeper.ensureRunning()
                self.ble.ensureScreenActive(forceRecreate: false)
                self.calendar.refresh()
                self.tailscale.refresh()
                if self.tailscale.isTailscaleConnected && !self.spark.isConnected {
                    self.spark.connectWithFailover()
                }
            }
        )
        observers.append(
            nc.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                self?.backgroundKeeper.ensureRunning()
            }
        )
    }

    private func wireCallbacks() {
        ble.onLog = { [weak self] msg in self?.appendLog(msg) }
        flic.onLog = { [weak self] msg in self?.appendLog(msg) }
        gamepad.onLog = { [weak self] msg in self?.appendLog(msg) }
        backgroundKeeper.onLog = { [weak self] msg in self?.appendLog(msg) }
        spark.onLog = { [weak self] msg in self?.appendLog(msg) }

        tailscale.onStatusChanged = { [weak self] connected, ip in
            guard let self else { return }
            self.appendLog("[Tailscale] \(connected ? "연결됨 (\(ip ?? ""))" : "연결 해제됨")")
            self.syncTailscaleToOS(connected: connected, ip: ip, push: true)
            if connected {
                self.spark.connectWithFailover()
            } else {
                self.spark.disconnect()
            }
        }

        // Forward DGX Spark real-time STT & `agy` streaming events -> G2 OS (with BLE delta throttling)
        spark.onEvent = { [weak self] evt in
            guard let self else { return }
            switch evt {
            case .aiDelta:
                let now = Date()
                if now.timeIntervalSince(self.lastAiDeltaRenderAt) >= 0.30 {
                    self.lastAiDeltaRenderAt = now
                    self.os.handleSparkEvent(evt)
                }
            case .aiDone(_, _, let commands, _):
                self.os.handleSparkEvent(evt)
                if !commands.isEmpty {
                    self.executeVoiceOSCommands(commands)
                }
            default:
                self.os.handleSparkEvent(evt)
            }
        }

        flic.onAction = { [weak self] event in
            guard let self else { return }
            self.appendLog("[Flic] \(event.detail) → \(event.action.rawValue)")
            self.os.handle(event)
            self.updateImuStreamingNeed()
        }

        gamepad.onAction = { [weak self] event in
            guard let self else { return }
            self.playHaptic(for: event.action)
            self.appendLog("[8BitDo] \(event.detail) → \(event.action.rawValue)")
            self.os.handle(event)
            self.updateImuStreamingNeed()
        }

        ble.onImuSample = { [weak self] sample in
            self?.os.handleImuSample(sample)
        }

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

        // Stream raw 0x6402 LC3 audio frames LIVE to DGX Spark WebSocket + throttle G2 Mic HUD
        ble.onMicPacket = { [weak self] packet in
            guard let self else { return }
            self.spark.sendAudioChunk(packet.rawAudioBytes)

            self.os.micPackets = self.ble.micPacketCount
            self.os.micDurationMs = self.ble.micDurationMs
            if let s = packet.signalRatio { self.os.micSignal = s }
            if let d = packet.directionDegrees { self.os.micDOA = d }

            let now = Date()
            if self.os.isMicOn && !self.os.isTranslateActive && !self.os.isConversateActive && now.timeIntervalSince(self.lastMicRenderAt) >= 0.45 {
                self.lastMicRenderAt = now
                self.os.refreshDisplay(pushToGlasses: true)
            }
        }

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
        feed.onUpdated = { [weak self] cats in
            guard let self else { return }
            self.os.feedCategories = cats
            let push = (self.os.currentScreen == .dashboard || self.os.currentScreen == .launcher || self.os.currentScreen == .feedApp)
            self.os.refreshDisplay(pushToGlasses: push)
        }

        // Outbound OS callbacks
        os.onPageChanged = { [weak self] page in self?.ble.renderPage(page) }
        os.onFeedVoiceSearch = { [weak self] query in
            guard let self else { return }
            self.appendLog("[피드 검색] \(query)")
            self.feed.applyVoiceSearch(query)
        }
        os.onToggleMic = { [weak self] enabled in
            guard let self else { return }
            self.ble.setMicrophoneEnabled(enabled)
            self.flic.playBuzzerFeedback(micEnabled: enabled)
        }
        os.onStartVoiceSession = { [weak self] mode, src, dst in
            self?.spark.startAudioStream(mode: mode, srcLang: src, dstLang: dst)
        }
        os.onStopVoiceSession = { [weak self] _ in
            self?.spark.stopAudioStream()
        }
        os.onRequestConversateSummary = { [weak self] in
            self?.spark.sendTextPrompt(mode: .conversate, text: "__SUMMARIZE__")
        }
        os.onResetVoiceSession = { [weak self] mode in
            self?.spark.resetSession(mode: mode)
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

        ble.$batteryLevel
            .receive(on: DispatchQueue.main)
            .sink { [weak self] val in
                guard let self else { return }
                self.os.g2Battery = val
                if self.os.currentScreen == .dashboard { self.os.refreshDisplay(pushToGlasses: true) }
            }
            .store(in: &cancellables)
        ble.$isCharging.receive(on: DispatchQueue.main).sink { [weak self] v in self?.os.g2Charging = v }.store(in: &cancellables)
        ble.$brightnessLevel.receive(on: DispatchQueue.main).sink { [weak self] v in self?.os.brightness = v }.store(in: &cancellables)
        ble.$brightnessAuto.receive(on: DispatchQueue.main).sink { [weak self] v in self?.os.autoBrightness = v }.store(in: &cancellables)
        ble.$displayHeight.receive(on: DispatchQueue.main).sink { [weak self] v in self?.os.displayHeight = v }.store(in: &cancellables)
        ble.$displayDistance.receive(on: DispatchQueue.main).sink { [weak self] v in self?.os.displayDistance = v }.store(in: &cancellables)
        ble.$wearDetection.receive(on: DispatchQueue.main).sink { [weak self] v in self?.os.wearDetection = v }.store(in: &cancellables)
        ble.$silentMode.receive(on: DispatchQueue.main).sink { [weak self] v in self?.os.silentMode = v }.store(in: &cancellables)
        ble.$firmwareLeft.receive(on: DispatchQueue.main).sink { [weak self] v in self?.os.g2FirmwareLeft = v }.store(in: &cancellables)
        ble.$firmwareRight.receive(on: DispatchQueue.main).sink { [weak self] v in self?.os.g2FirmwareRight = v }.store(in: &cancellables)
        ble.$phase
            .receive(on: DispatchQueue.main)
            .sink { [weak self] phase in
                if phase == .connected {
                    self?.syncAllServicesToOS(push: true)
                    self?.updateImuStreamingNeed()
                }
            }
            .store(in: &cancellables)
        flic.$isReady.receive(on: DispatchQueue.main).sink { [weak self] v in self?.os.flicConnected = v }.store(in: &cancellables)
        flic.$batteryVoltage.receive(on: DispatchQueue.main).sink { [weak self] v in self?.os.flicVoltage = v }.store(in: &cancellables)
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
