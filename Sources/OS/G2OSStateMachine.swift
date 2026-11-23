import Foundation

/// Full-featured Even Realities G2 OS state machine rendered onto the 576x288 EvenHub canvas
/// using multi-container bordered cards + 4-bit pixel graphics (big digital clock, weather icon, battery bar).
///
/// Screens:
/// - Dashboard (default Home): Big pixel clock, weather, steps, battery + swipeable Calendar / QuickList / Clock widgets
/// - App Launcher: Glowing bordered 3x2 app cards (Page 1 & Page 2 covering all stock G2 OS apps)
/// - QuickList: Interactive checkable task list synced with Apple Reminders
/// - Alarm / Timer / Stopwatch: Live countdown, alarm toggles, lap stopwatch + full-screen ringing HUD
/// - Teleprompter: Multi-document scrollable script reader with auto-scroll
/// - Head-Up Wake (들어깨우기): Live G2 IMU pitch monitor, neutral calibration, transparent standby without stock-OS fallback
/// - Full Hardware Settings: Brightness, Auto-Brightness, Display Height/Distance, Wear Detection, Silent, ANCS Notifications
/// - AI Agent / Translate / Conversate / Navigate hubs (Phase 2 & 3 ready)
public final class G2OSStateMachine: ObservableObject {
    public enum Screen: String, CaseIterable {
        case dashboard = "대시보드"
        case launcher = "앱 메뉴"
        case agent = "Even AI"
        case quickList = "QuickList"
        case clockTools = "알람·타이머"
        case teleprompter = "텔레프롬프터"
        case headUp = "들어깨우기"
        case settings = "기기 설정"
        case translate = "실시간 통역"
        case conversate = "대화 지원"
        case navigate = "길찾기"
    }

    public struct ReaderDocument: Identifiable, Equatable {
        public let id: Int
        public let title: String
        public var lines: [String]
    }

    @Published public private(set) var currentScreen: Screen = .dashboard
    @Published public private(set) var currentPage: G2PageSpec = .blankTransparent()
    @Published public private(set) var renderedFrameText: String = ""
    @Published public private(set) var lastActionSummary: String = "대기 중"
    @Published public private(set) var recentActions: [String] = []
    @Published public private(set) var toastMessage: String?

    // Dashboard right-side widget tab (0 = Calendar, 1 = QuickList, 2 = Timer & System)
    @Published public private(set) var dashboardTab: Int = 0

    // App Launcher 3x2 card grid (page 0..1, row 0..1, col 0..2)
    @Published public private(set) var launcherPage: Int = 0
    @Published public private(set) var launcherRow: Int = 0
    @Published public private(set) var launcherCol: Int = 0

    // QuickList cursor
    @Published public private(set) var quickListIndex: Int = 0

    // Clock tools (0 = Alarms, 1 = Timer, 2 = Stopwatch)
    @Published public private(set) var clockTab: Int = 0
    @Published public private(set) var alarmIndex: Int = 0
    @Published public private(set) var timerPresetIndex: Int = 2 // 5m default
    public let timerPresetsSeconds: [Int] = [60, 180, 300, 600, 900, 1800]

    // Teleprompter state
    @Published public var documents: [ReaderDocument] = [
        ReaderDocument(
            id: 0,
            title: "G2 OS 사용 가이드",
            lines: [
                "1. 대시보드에서 좌/우 스와이프로",
                "   일정 · QuickList · 타이머를 확인하세요.",
                "2. 탭 또는 아래 스와이프로 앱 메뉴를 엽니다.",
                "3. 모션 패드 길게 누르기는 전역 마이크입니다.",
                "4. 들어깨우기 앱에서 기준 각도를 보정하면",
                "   고개를 들 때만 0.1초 만에 화면이 켜집니다.",
                "5. 설정에서 밝기·높이·거리·착용감지를",
                "   순정과 동일하게 조절할 수 있습니다."
            ]
        ),
        ReaderDocument(
            id: 1,
            title: "내 대본 / 메모",
            lines: [
                "아이폰 앱 설정 > 대본 편집에서",
                "발표 원고나 메모를 입력하면",
                "여기에 즉시 반영됩니다.",
                "",
                "위/아래 스와이프로 스크롤하고,",
                "탭하면 자동 스크롤이 시작됩니다."
            ]
        )
    ]
    @Published public private(set) var readerDocIndex: Int = 0
    @Published public private(set) var readerScrollOffset: Int = 0
    @Published public private(set) var readerAutoScroll: Bool = false

    // Head-Up Wake (들어깨우기) state via G2 IMU
    @Published public var headUpWakeEnabled: Bool = false
    @Published public var headUpTriggerAngle: Int = 20 // degrees delta from neutral
    @Published public var headUpIdleSeconds: Int = 15
    @Published public private(set) var headUpMenuIndex: Int = 0
    @Published public private(set) var isHeadUpDimmed: Bool = false
    @Published public private(set) var currentImu: G2ImuSample = G2ImuSample(x: 0, y: 0, z: 0)
    @Published public private(set) var neutralPitchDegrees: Double = 0
    @Published public private(set) var lastDeltaPitch: Double = 0

    // Full Settings menu cursor (0..7)
    @Published public private(set) var settingsIndex: Int = 0

    // Pixel graphics clock toggle (4-bit BMP image container on Dashboard)
    @Published public var pixelGraphicsEnabled: Bool = true

    // Live data injected from Services & BLE
    public var weather: WeatherSnapshot?
    public var calendarEvents: [G2CalendarEvent] = []
    public var quickTasks: [G2QuickTask] = []
    public var todaySteps: Int = 0
    public var todayDistanceKm: String = "0.0km"
    public var alarms: [G2AlarmItem] = []
    public var nextAlarm: G2AlarmItem?
    public var timerRemainingSeconds: Int = 300
    public var isTimerRunning: Bool = false
    public var stopwatchSeconds: Int = 0
    public var isStopwatchRunning: Bool = false
    public var stopwatchLaps: [Int] = []
    public var activeAlert: G2ActiveAlert?

    // Hardware telemetry
    public var g2Battery: Int?
    public var g2Charging: Bool = false
    public var g2FirmwareLeft: String = "-"
    public var g2FirmwareRight: String = "-"
    public var flicConnected: Bool = false
    public var flicVoltage: Float = 0
    public var alwaysOnEnabled: Bool = true
    public var isMicOn: Bool = false
    public var micPackets: Int = 0
    public var micDurationMs: Int = 0
    public var micSignal: Int16 = 0
    public var micDOA: Int16 = 0
    public var lastVoiceSummary: String = "아직 음성 입력 없음"

    public var brightness: Int = 25
    public var autoBrightness: Bool = false
    public var displayHeight: Int = 10
    public var displayDistance: Int = 10
    public var wearDetection: Bool = true
    public var silentMode: Bool = false
    public var ancsEnabled: Bool = true
    public var isScreenAsleep: Bool = false

    // Outbound hardware & service callbacks
    public var onPageChanged: ((G2PageSpec) -> Void)?
    public var onToggleMic: ((Bool) -> Void)?
    public var onSaveMicRecording: (() -> Void)?
    public var onSetBrightness: ((Int) -> Void)?
    public var onSetAutoBrightness: ((Bool) -> Void)?
    public var onSetDisplayHeight: ((Int) -> Void)?
    public var onSetDisplayDistance: ((Int) -> Void)?
    public var onSetHeadUpConfig: ((Bool, Int) -> Void)?
    public var onSetWearDetection: ((Bool) -> Void)?
    public var onSetSilentMode: ((Bool) -> Void)?
    public var onSetAncsEnabled: ((Bool) -> Void)?
    public var onQuerySettings: (() -> Void)?
    public var onSetScreenAsleep: ((Bool) -> Void)?
    public var onRefreshDataServices: (() -> Void)?
    public var onToggleQuickTask: ((String) -> Void)?
    public var onToggleAlarm: ((String) -> Void)?
    public var onSetTimerPreset: ((Int) -> Void)?
    public var onToggleTimer: (() -> Void)?
    public var onResetTimer: (() -> Void)?
    public var onToggleStopwatch: (() -> Void)?
    public var onLapStopwatch: (() -> Void)?
    public var onResetStopwatch: (() -> Void)?
    public var onDismissAlert: (() -> Void)?
    public var onSnoozeAlert: (() -> Void)?

    private var autoScrollTimer: Timer?
    private var clockTimer: Timer?
    private var headUpIdleTimer: Timer?
    private var toastClearWorkItem: DispatchWorkItem?
    private var lastClockMinute: String = ""
    private var lastInteractionAt: Date = Date()
    private var lastImuUiRefreshAt: Date = .distantPast
    private var hasCalibratedNeutral: Bool = false

    private struct AppTile {
        let title: String
        let subtitle: String
        let screen: Screen
    }

    private let launcherPages: [[[AppTile]]] = [
        // Page 0: Core 6 apps
        [
            [
                AppTile(title: "Even AI", subtitle: "음성 비서", screen: .agent),
                AppTile(title: "QuickList", subtitle: "할 일 목록", screen: .quickList),
                AppTile(title: "알람·타이머", subtitle: "시계 도구", screen: .clockTools)
            ],
            [
                AppTile(title: "텔레프롬프터", subtitle: "대본 리더", screen: .teleprompter),
                AppTile(title: "들어깨우기", subtitle: "IMU 제스처", screen: .headUp),
                AppTile(title: "기기 설정", subtitle: "밝기·위치", screen: .settings)
            ]
        ],
        // Page 1: Extended G2 OS apps (Phase 2 & 3)
        [
            [
                AppTile(title: "실시간 통역", subtitle: "이중 자막", screen: .translate),
                AppTile(title: "대화 지원", subtitle: "회의 코파일럿", screen: .conversate),
                AppTile(title: "길찾기", subtitle: "도보 안내", screen: .navigate)
            ],
            [
                AppTile(title: "대시보드", subtitle: "홈 위젯", screen: .dashboard),
                AppTile(title: "들어깨우기", subtitle: "고개 들기", screen: .headUp),
                AppTile(title: "기기 설정", subtitle: "하드웨어", screen: .settings)
            ]
        ]
    ]

    public init() {
        rebuildDisplay(pushToGlasses: false)
        startClockTick()
        startHeadUpIdleWatch()
    }

    deinit {
        autoScrollTimer?.invalidate()
        clockTimer?.invalidate()
        headUpIdleTimer?.invalidate()
        toastClearWorkItem?.cancel()
    }

    private func startClockTick() {
        clockTimer?.invalidate()
        clockTimer = Timer.scheduledTimer(withTimeInterval: 15.0, repeats: true) { [weak self] _ in
            guard let self, !self.isScreenAsleep, !self.isHeadUpDimmed else { return }
            let nowMin = self.formattedClock()
            if nowMin != self.lastClockMinute {
                self.lastClockMinute = nowMin
                self.rebuildDisplay(pushToGlasses: true)
            }
        }
    }

    private func startHeadUpIdleWatch() {
        headUpIdleTimer?.invalidate()
        headUpIdleTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            guard self.headUpWakeEnabled,
                  !self.isHeadUpDimmed,
                  !self.isMicOn,
                  self.activeAlert == nil,
                  self.currentScreen != .headUp,
                  self.currentScreen != .teleprompter
            else { return }

            let idle = Date().timeIntervalSince(self.lastInteractionAt)
            if idle >= Double(self.headUpIdleSeconds) && abs(self.lastDeltaPitch) < Double(self.headUpTriggerAngle) * 0.65 {
                self.enterHeadUpStandby()
            }
        }
    }

    public func updateCustomDocument(title: String, body: String) {
        let lines = body
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .newlines) }
        let safeLines = lines.isEmpty ? ["(내용 없음)"] : lines
        let doc = ReaderDocument(id: 1, title: title.isEmpty ? "내 대본 / 메모" : title, lines: safeLines)
        if documents.count >= 2 {
            documents[1] = doc
        } else {
            documents.append(doc)
        }
        if currentScreen == .teleprompter {
            readerScrollOffset = 0
            rebuildDisplay()
        }
    }

    // MARK: - IMU Head-Up Wake Processing

    public func handleImuSample(_ sample: G2ImuSample) {
        currentImu = sample
        let pitch = sample.pitchDegrees
        if !hasCalibratedNeutral {
            neutralPitchDegrees = pitch
            hasCalibratedNeutral = true
        }
        let delta = pitch - neutralPitchDegrees
        lastDeltaPitch = delta

        if headUpWakeEnabled && isHeadUpDimmed {
            if abs(delta) >= Double(headUpTriggerAngle) {
                wakeFromHeadUpStandby(showDashboard: true)
                return
            }
        }

        // Refresh live angle readout smoothly while viewing the Head-Up calibration screen.
        let now = Date()
        if currentScreen == .headUp && !isHeadUpDimmed && now.timeIntervalSince(lastImuUiRefreshAt) >= 0.6 {
            lastImuUiRefreshAt = now
            rebuildDisplay(pushToGlasses: true)
        }
    }

    public func calibrateHeadUpNeutral() {
        neutralPitchDegrees = currentImu.pitchDegrees
        hasCalibratedNeutral = true
        lastDeltaPitch = 0
        showToast(String(format: "기준 자세 보정 완료 (%.0f°)", neutralPitchDegrees))
        rebuildDisplay()
    }

    public func setHeadUpWakeMode(_ enabled: Bool) {
        headUpWakeEnabled = enabled
        if !enabled && isHeadUpDimmed {
            isHeadUpDimmed = false
        }
        lastInteractionAt = Date()
        onSetHeadUpConfig?(enabled, headUpTriggerAngle)
        rebuildDisplay()
    }

    public func enterHeadUpStandby() {
        isHeadUpDimmed = true
        rebuildDisplay(pushToGlasses: true)
    }

    public func wakeFromHeadUpStandby(showDashboard: Bool = false) {
        lastInteractionAt = Date()
        guard isHeadUpDimmed else { return }
        isHeadUpDimmed = false
        if showDashboard {
            currentScreen = .dashboard
        }
        rebuildDisplay(pushToGlasses: true)
    }

    // MARK: - Unified Input Dispatcher

    public func handle(_ event: RemoteCommandEvent) {
        lastInteractionAt = Date()
        let entry = "[\(event.source.rawValue)] \(event.action.rawValue)" + (event.detail.isEmpty ? "" : " (\(event.detail))")
        lastActionSummary = entry
        recentActions.insert(entry, at: 0)
        if recentActions.count > 12 { recentActions.removeLast() }

        // 1. If dimmed in Head-Up transparent standby, any input wakes immediately!
        if isHeadUpDimmed && event.action != .micStop {
            isHeadUpDimmed = false
            if event.action == .micStart {
                setMicActive(true)
            } else {
                rebuildDisplay()
            }
            return
        }

        // 2. If asleep, any input wakes immediately.
        if isScreenAsleep && event.action != .screenToggle {
            isScreenAsleep = false
            onSetScreenAsleep?(false)
            rebuildDisplay()
            return
        }

        // 3. If an Alarm or Timer alert is ringing, Tap dismisses and Double-Tap snoozes 5m!
        if activeAlert != nil {
            switch event.action {
            case .select, .home:
                onDismissAlert?()
                return
            case .back:
                onSnoozeAlert?()
                return
            default:
                return
            }
        }

        // 4. Global Push-to-Talk & hardware shortcuts
        switch event.action {
        case .micStart:
            setMicActive(true)
            return
        case .micStop:
            setMicActive(false)
            return
        case .micToggle:
            setMicActive(!isMicOn)
            return
        case .brightnessUp:
            brightness = min(50, brightness + 5)
            onSetBrightness?(brightness)
            showToast("밝기 \(brightness)/50")
            rebuildDisplay()
            return
        case .brightnessDown:
            brightness = max(1, brightness - 5)
            onSetBrightness?(brightness)
            showToast("밝기 \(brightness)/50")
            rebuildDisplay()
            return
        case .screenToggle:
            if alwaysOnEnabled {
                if headUpWakeEnabled {
                    if isHeadUpDimmed { wakeFromHeadUpStandby() } else { enterHeadUpStandby() }
                } else {
                    showToast("항시 OS 유지 활성화됨")
                    rebuildDisplay()
                }
            } else {
                isScreenAsleep.toggle()
                onSetScreenAsleep?(isScreenAsleep)
                if !isScreenAsleep { rebuildDisplay() }
            }
            return
        case .home:
            stopAutoScroll()
            currentScreen = .dashboard
            rebuildDisplay()
            return
        default:
            break
        }

        if isMicOn { return }

        // 5. Screen-specific navigation
        switch currentScreen {
        case .dashboard: handleDashboard(event.action)
        case .launcher: handleLauncher(event.action)
        case .quickList: handleQuickList(event.action)
        case .clockTools: handleClockTools(event.action)
        case .teleprompter: handleTeleprompter(event.action)
        case .headUp: handleHeadUp(event.action)
        case .settings: handleSettings(event.action)
        case .agent, .translate, .conversate, .navigate: handleFeatureStub(event.action)
        }
        rebuildDisplay()
    }

    public func refreshDisplay(pushToGlasses: Bool = true) {
        if activeAlert != nil && isHeadUpDimmed {
            isHeadUpDimmed = false
        }
        rebuildDisplay(pushToGlasses: pushToGlasses)
    }

    // MARK: - Mic & Toast Helpers

    private func setMicActive(_ enabled: Bool) {
        guard enabled != isMicOn else { return }
        if enabled {
            isMicOn = true
            isHeadUpDimmed = false
            micPackets = 0
            micDurationMs = 0
            micSignal = 0
            onToggleMic?(true)
            rebuildDisplay()
        } else {
            let capturedPackets = micPackets
            let capturedSec = Double(micDurationMs) / 1000.0
            isMicOn = false
            onToggleMic?(false)
            if capturedPackets > 0 {
                onSaveMicRecording?()
                lastVoiceSummary = String(format: "최근 음성 %.1f초 (%d pkt)", capturedSec, capturedPackets)
                showToast(String(format: "음성 녹음 완료 (%.1f초)", capturedSec))
            } else {
                showToast("마이크 종료")
            }
            rebuildDisplay()
        }
    }

    private func showToast(_ message: String, duration: TimeInterval = 3.0) {
        toastMessage = message
        toastClearWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.toastMessage = nil
            if !self.isMicOn && !self.isScreenAsleep && !self.isHeadUpDimmed {
                self.rebuildDisplay(pushToGlasses: true)
            }
        }
        toastClearWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }

    // MARK: - Per-Screen Handlers

    private func handleDashboard(_ action: RemoteAction) {
        switch action {
        case .left:
            dashboardTab = (dashboardTab + 2) % 3
        case .right:
            dashboardTab = (dashboardTab + 1) % 3
        case .down, .scrollDown, .select:
            currentScreen = .launcher
        case .up, .scrollUp:
            onRefreshDataServices?()
            onQuerySettings?()
            showToast("대시보드 새로고침")
        case .back:
            // Stay on Dashboard — never drop back to stock OS.
            break
        default:
            break
        }
    }

    private func handleLauncher(_ action: RemoteAction) {
        switch action {
        case .up, .scrollUp:
            launcherRow = (launcherRow + 1) % 2
        case .down, .scrollDown:
            launcherRow = (launcherRow + 1) % 2
        case .left:
            if launcherCol > 0 {
                launcherCol -= 1
            } else {
                launcherPage = (launcherPage + launcherPages.count - 1) % launcherPages.count
                launcherCol = 2
            }
        case .right:
            if launcherCol < 2 {
                launcherCol += 1
            } else {
                launcherPage = (launcherPage + 1) % launcherPages.count
                launcherCol = 0
            }
        case .select:
            let target = launcherPages[launcherPage][launcherRow][launcherCol].screen
            currentScreen = target
            if target == .settings || target == .dashboard {
                onQuerySettings?()
            }
        case .back:
            currentScreen = .dashboard
        default:
            break
        }
    }

    private func handleQuickList(_ action: RemoteAction) {
        let count = quickTasks.count
        switch action {
        case .up, .scrollUp:
            if count > 0 { quickListIndex = (quickListIndex + count - 1) % count }
        case .down, .scrollDown:
            if count > 0 { quickListIndex = (quickListIndex + 1) % count }
        case .select:
            if count > 0 {
                let idx = max(0, min(count - 1, quickListIndex))
                onToggleQuickTask?(quickTasks[idx].id)
            }
        case .right:
            onRefreshDataServices?()
            showToast("할 일 동기화")
        case .back, .left:
            currentScreen = .launcher
        default:
            break
        }
    }

    private func handleClockTools(_ action: RemoteAction) {
        switch action {
        case .left:
            clockTab = (clockTab + 2) % 3
        case .right:
            clockTab = (clockTab + 1) % 3
        case .up, .scrollUp:
            switch clockTab {
            case 0:
                if !alarms.isEmpty { alarmIndex = (alarmIndex + alarms.count - 1) % alarms.count }
            case 1:
                timerPresetIndex = (timerPresetIndex + timerPresetsSeconds.count - 1) % timerPresetsSeconds.count
                onSetTimerPreset?(timerPresetsSeconds[timerPresetIndex])
            default:
                onLapStopwatch?()
            }
        case .down, .scrollDown:
            switch clockTab {
            case 0:
                if !alarms.isEmpty { alarmIndex = (alarmIndex + 1) % alarms.count }
            case 1:
                timerPresetIndex = (timerPresetIndex + 1) % timerPresetsSeconds.count
                onSetTimerPreset?(timerPresetsSeconds[timerPresetIndex])
            default:
                onResetStopwatch?()
            }
        case .select:
            switch clockTab {
            case 0:
                if !alarms.isEmpty {
                    let idx = max(0, min(alarms.count - 1, alarmIndex))
                    onToggleAlarm?(alarms[idx].id)
                }
            case 1:
                onToggleTimer?()
            default:
                onToggleStopwatch?()
            }
        case .back:
            currentScreen = .launcher
        default:
            break
        }
    }

    private func handleTeleprompter(_ action: RemoteAction) {
        let lines = currentDocument.lines
        let visibleLines = 5
        let maxOffset = max(0, lines.count - visibleLines)
        switch action {
        case .up, .scrollUp:
            readerScrollOffset = max(0, readerScrollOffset - 1)
        case .down, .scrollDown:
            readerScrollOffset = min(maxOffset, readerScrollOffset + 1)
        case .left:
            stopAutoScroll()
            readerDocIndex = (readerDocIndex + documents.count - 1) % documents.count
            readerScrollOffset = 0
        case .right:
            stopAutoScroll()
            readerDocIndex = (readerDocIndex + 1) % documents.count
            readerScrollOffset = 0
        case .select:
            toggleAutoScroll()
        case .back:
            stopAutoScroll()
            currentScreen = .launcher
        default:
            break
        }
    }

    private func handleHeadUp(_ action: RemoteAction) {
        switch action {
        case .up, .scrollUp:
            headUpMenuIndex = (headUpMenuIndex + 4) % 5
        case .down, .scrollDown:
            headUpMenuIndex = (headUpMenuIndex + 1) % 5
        case .left:
            if headUpMenuIndex == 1 {
                headUpTriggerAngle = max(10, headUpTriggerAngle - 5)
                onSetHeadUpConfig?(headUpWakeEnabled, headUpTriggerAngle)
            } else if headUpMenuIndex == 2 {
                headUpIdleSeconds = max(8, headUpIdleSeconds - 5)
            }
        case .right:
            if headUpMenuIndex == 1 {
                headUpTriggerAngle = min(50, headUpTriggerAngle + 5)
                onSetHeadUpConfig?(headUpWakeEnabled, headUpTriggerAngle)
            } else if headUpMenuIndex == 2 {
                headUpIdleSeconds = min(60, headUpIdleSeconds + 5)
            }
        case .select:
            switch headUpMenuIndex {
            case 0:
                setHeadUpWakeMode(!headUpWakeEnabled)
            case 1:
                headUpTriggerAngle = (headUpTriggerAngle >= 45) ? 15 : headUpTriggerAngle + 5
                onSetHeadUpConfig?(headUpWakeEnabled, headUpTriggerAngle)
            case 2:
                headUpIdleSeconds = (headUpIdleSeconds >= 45) ? 10 : headUpIdleSeconds + 5
            case 3:
                calibrateHeadUpNeutral()
            case 4:
                enterHeadUpStandby()
            default:
                break
            }
        case .back:
            currentScreen = .launcher
        default:
            break
        }
    }

    private func handleSettings(_ action: RemoteAction) {
        let totalItems = 8
        switch action {
        case .up, .scrollUp:
            settingsIndex = (settingsIndex + totalItems - 1) % totalItems
        case .down, .scrollDown:
            settingsIndex = (settingsIndex + 1) % totalItems
        case .left:
            adjustSetting(delta: -1)
        case .right:
            adjustSetting(delta: +1)
        case .select:
            activateSetting()
        case .back:
            currentScreen = .launcher
        default:
            break
        }
    }

    private func adjustSetting(delta: Int) {
        switch settingsIndex {
        case 0:
            brightness = max(1, min(50, brightness + delta * 5))
            onSetBrightness?(brightness)
        case 1:
            autoBrightness.toggle()
            onSetAutoBrightness?(autoBrightness)
        case 2:
            displayHeight = max(0, min(20, displayHeight + delta * 2))
            onSetDisplayHeight?(displayHeight)
        case 3:
            displayDistance = max(0, min(20, displayDistance + delta * 2))
            onSetDisplayDistance?(displayDistance)
        case 4:
            wearDetection.toggle()
            onSetWearDetection?(wearDetection)
        case 5:
            silentMode.toggle()
            onSetSilentMode?(silentMode)
        case 6:
            ancsEnabled.toggle()
            onSetAncsEnabled?(ancsEnabled)
        default:
            break
        }
    }

    private func activateSetting() {
        switch settingsIndex {
        case 0:
            brightness = (brightness >= 50) ? 10 : min(50, brightness + 10)
            onSetBrightness?(brightness)
        case 1:
            autoBrightness.toggle()
            onSetAutoBrightness?(autoBrightness)
        case 2:
            displayHeight = (displayHeight >= 20) ? 0 : min(20, displayHeight + 4)
            onSetDisplayHeight?(displayHeight)
        case 3:
            displayDistance = (displayDistance >= 20) ? 0 : min(20, displayDistance + 4)
            onSetDisplayDistance?(displayDistance)
        case 4:
            wearDetection.toggle()
            onSetWearDetection?(wearDetection)
        case 5:
            silentMode.toggle()
            onSetSilentMode?(silentMode)
        case 6:
            ancsEnabled.toggle()
            onSetAncsEnabled?(ancsEnabled)
        case 7:
            onQuerySettings?()
            showToast("기기 상태 조회 요청")
        default:
            break
        }
    }

    private func handleFeatureStub(_ action: RemoteAction) {
        switch action {
        case .select:
            showToast("길게 눌러 G2 마이크를 테스트하세요")
        case .back:
            currentScreen = .launcher
        default:
            break
        }
    }

    // MARK: - Auto-Scroll

    private func toggleAutoScroll() {
        if readerAutoScroll {
            stopAutoScroll()
        } else {
            readerAutoScroll = true
            autoScrollTimer?.invalidate()
            autoScrollTimer = Timer.scheduledTimer(withTimeInterval: 1.8, repeats: true) { [weak self] _ in
                guard let self, self.currentScreen == .teleprompter else {
                    self?.stopAutoScroll()
                    return
                }
                let maxOffset = max(0, self.currentDocument.lines.count - 5)
                self.readerScrollOffset = (self.readerScrollOffset < maxOffset) ? (self.readerScrollOffset + 1) : 0
                self.rebuildDisplay()
            }
        }
    }

    private func stopAutoScroll() {
        readerAutoScroll = false
        autoScrollTimer?.invalidate()
        autoScrollTimer = nil
    }

    private var currentDocument: ReaderDocument {
        documents[max(0, min(documents.count - 1, readerDocIndex))]
    }

    // MARK: - 576x288 Multi-Container + 4-bit Pixel Graphics Renderer

    private func rebuildDisplay(pushToGlasses: Bool = true) {
        let page: G2PageSpec
        if isHeadUpDimmed && activeAlert == nil && !isMicOn {
            page = .blankTransparent()
        } else if let alert = activeAlert {
            page = buildAlertPage(alert)
        } else if isMicOn {
            page = buildMicOverlayPage()
        } else {
            switch currentScreen {
            case .dashboard: page = buildDashboardPage()
            case .launcher: page = buildLauncherPage()
            case .quickList: page = buildQuickListPage()
            case .clockTools: page = buildClockToolsPage()
            case .teleprompter: page = buildTeleprompterPage()
            case .headUp: page = buildHeadUpPage()
            case .settings: page = buildSettingsPage()
            case .agent: page = buildFeaturePage(title: "Even AI (Antigravity)", subtitle: "agy CLI 무료 음성 에이전트 (3단계 연동 예정)", extra: lastVoiceSummary)
            case .translate: page = buildFeaturePage(title: "실시간 통역", subtitle: "온디바이스 음성인식 + 이중 언어 자막 (3단계)", extra: lastVoiceSummary)
            case .conversate: page = buildFeaturePage(title: "대화 지원 (Conversate)", subtitle: "회의 받아쓰기 · 용어 풀이 · 자동 요약 (3단계)", extra: lastVoiceSummary)
            case .navigate: page = buildFeaturePage(title: "길찾기 (Navigate)", subtitle: "MapKit 도보 턴바이턴 + 4-bit 미니맵 (2단계)", extra: "GPS 준비 완료")
            }
        }

        currentPage = page
        renderedFrameText = page.summaryText
        if pushToGlasses && !isScreenAsleep {
            onPageChanged?(page)
        }
    }

    private func formattedClock() -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "HH:mm"
        return fmt.string(from: Date())
    }

    private func formattedDateKo() -> String {
        let df = DateFormatter()
        df.dateFormat = "M월 d일 (E)"
        df.locale = Locale(identifier: "ko_KR")
        return df.string(from: Date())
    }

    private func statusHeaderText(title: String) -> String {
        let bat = g2Battery.map { "\(g2Charging ? "+" : "")\($0)%" } ?? "--%"
        let headTag = headUpWakeEnabled ? " [들기]" : ""
        return "\(formattedClock())   \(title)\(headTag)   \(bat)"
    }

    // 1. Stock-Style Dashboard (Big 4-bit Pixel Clock + Weather/Steps Card + Right Widget Card + Dock)
    private func buildDashboardPage() -> G2PageSpec {
        let timeStr = formattedClock()
        lastClockMinute = timeStr
        let batVal = g2Battery ?? 80
        let weatherLine = weather?.compactLine ?? "날씨 확인 중..."
        let alarmLine = nextAlarm.map { "알람 \($0.timeText)" } ?? "알람 없음"
        let timerTag = isTimerRunning ? " · 타이머 \(AlarmTimerService.formatDuration(timerRemainingSeconds))" : ""

        var images: [G2ImageContainer] = []
        let leftInfoY: Int
        let leftInfoH: Int
        let leftInfoText: String

        if pixelGraphicsEnabled {
            let canvas = G2PixelCanvas(width: 244, height: 64)
            canvas.drawBigClock(timeStr, originX: 4, originY: 8, digitW: 24, digitH: 46, thickness: 5, spacing: 7, level: 15)
            canvas.drawWeatherIcon(code: weather?.iconCode ?? "cloud", cx: 196, cy: 24)
            canvas.drawBatteryBar(x: 176, y: 48, w: 48, h: 12, percent: batVal)

            let hash = "\(timeStr)_\(weather?.iconCode ?? "c")_\(batVal / 5)"
            images.append(
                G2ImageContainer(
                    id: 10,
                    name: "clk",
                    x: 14,
                    y: 10,
                    width: 244,
                    height: 64,
                    packed4bpp: canvas.pack4bpp(),
                    contentHash: hash
                )
            )
            leftInfoY = 80
            leftInfoH = 128
            leftInfoText = [
                formattedDateKo(),
                weatherLine,
                "걸음 \(todaySteps)보 (\(todayDistanceKm))",
                "G2 \(g2Battery.map { "\($0)%" } ?? "--%") · \(alarmLine)"
            ].joined(separator: "\n")
        } else {
            leftInfoY = 12
            leftInfoH = 196
            leftInfoText = [
                "\(timeStr)  \(formattedDateKo())",
                "────────────────",
                weatherLine,
                "걸음 \(todaySteps)보 (\(todayDistanceKm))",
                "G2 \(g2Battery.map { "\($0)%" } ?? "--%") · \(alarmLine)"
            ].joined(separator: "\n")
        }

        // Right widget card content (3 swipeable widgets)
        let rightTitle: String
        let rightBody: [String]
        switch dashboardTab {
        case 0:
            rightTitle = "● 일정  ○ 할일  ○ 상태"
            if calendarEvents.isEmpty {
                rightBody = ["", "예정된 일정이 없습니다.", "설정에서 캘린더를 연동하세요."]
            } else {
                rightBody = calendarEvents.prefix(4).map { "\($0.timeLabel) \($0.title)" }
            }
        case 1:
            rightTitle = "○ 일정  ● 할일  ○ 상태"
            let pending = quickTasks.filter { !$0.isCompleted }
            if pending.isEmpty {
                rightBody = ["", "모든 할 일을 완료했습니다!"]
            } else {
                rightBody = pending.prefix(4).map { "□ \($0.title)" }
            }
        default:
            rightTitle = "○ 일정  ○ 할일  ● 상태"
            rightBody = [
                "타이머: \(AlarmTimerService.formatDuration(timerRemainingSeconds)) \(isTimerRunning ? "진행중" : "대기")",
                "들어깨우기: \(headUpWakeEnabled ? "ON (\(headUpTriggerAngle)°)" : "OFF")",
                "OS 보호: \(alwaysOnEnabled ? "항시 유지 ON" : "일반")",
                "리모콘: \(flicConnected ? "Flic 연결됨" : "모션 패드")"
            ]
        }

        let rightText = ([rightTitle, "────────────────────"] + rightBody).joined(separator: "\n")
        let dockText = toastMessage.map { "· \($0)   [탭: 앱 메뉴]" }
            ?? "◀ 좌/우 위젯 전환 ▶   |   탭 · ↓ : 앱 메뉴\(timerTag)"

        let containers: [G2TextContainer] = [
            G2TextContainer(
                id: 1,
                name: "rightcard",
                x: 268,
                y: 12,
                width: 296,
                height: 196,
                text: rightText,
                captureEvents: true,
                borderWidth: 1,
                borderColor: 8,
                borderRadius: 8,
                padding: 8
            ),
            G2TextContainer(
                id: 2,
                name: "leftinfo",
                x: 12,
                y: leftInfoY,
                width: 248,
                height: leftInfoH,
                text: leftInfoText,
                captureEvents: false,
                borderWidth: 1,
                borderColor: 5,
                borderRadius: 8,
                padding: 7
            ),
            G2TextContainer(
                id: 3,
                name: "dock",
                x: 12,
                y: 218,
                width: 552,
                height: 58,
                text: dockText,
                captureEvents: false,
                borderWidth: 1,
                borderColor: 12,
                borderRadius: 8,
                padding: 8
            )
        ]

        return G2PageSpec(
            layoutKey: pixelGraphicsEnabled ? "dashboard_gfx" : "dashboard_txt",
            textContainers: containers,
            imageContainers: images
        )
    }

    // 2. Stock-Style Glowing Bordered 3x2 App Launcher
    private func buildLauncherPage() -> G2PageSpec {
        let header = G2TextContainer(
            id: 1,
            name: "hdr",
            x: 12,
            y: 4,
            width: 552,
            height: 36,
            text: "\(statusHeaderText(title: "앱 메뉴 (\(launcherPage + 1)/\(launcherPages.count))"))   [더블탭: 대시보드]",
            captureEvents: true,
            borderWidth: 0,
            borderColor: 0,
            borderRadius: 0,
            padding: 4
        )

        var containers: [G2TextContainer] = [header]
        let grid = launcherPages[launcherPage]
        let colXs = [12, 200, 388]
        let rowYs = [46, 164]

        var cid = 2
        for r in 0..<2 {
            for c in 0..<3 {
                let tile = grid[r][c]
                let selected = (r == launcherRow && c == launcherCol)
                let mark = selected ? "▶ " : "  "
                let text = "\(mark)\(tile.title)\n\n  \(tile.subtitle)"
                containers.append(
                    G2TextContainer(
                        id: cid,
                        name: "app\(cid)",
                        x: colXs[c],
                        y: rowYs[r],
                        width: 176,
                        height: 108,
                        text: text,
                        captureEvents: false,
                        borderWidth: selected ? 3 : 1,
                        borderColor: selected ? 15 : 4,
                        borderRadius: 8,
                        padding: 8
                    )
                )
                cid += 1
            }
        }

        // Encode selected cell in layoutKey so border width/color updates cleanly via cmd 7 rebuild!
        return G2PageSpec(
            layoutKey: "launcher_p\(launcherPage)_r\(launcherRow)_c\(launcherCol)",
            textContainers: containers
        )
    }

    // 3. Interactive QuickList
    private func buildQuickListPage() -> G2PageSpec {
        var lines: [String] = []
        if quickTasks.isEmpty {
            lines = ["", "등록된 할 일이 없습니다.", "아이폰 앱에서 할 일을 추가하세요."]
        } else {
            let safeIdx = max(0, min(quickTasks.count - 1, quickListIndex))
            let start = max(0, min(safeIdx - 2, max(0, quickTasks.count - 5)))
            for i in start..<min(quickTasks.count, start + 5) {
                let t = quickTasks[i]
                let cur = (i == safeIdx) ? "▶ " : "  "
                let box = t.isCompleted ? "[✓]" : "[ ]"
                lines.append("\(cur)\(box) \(t.title)")
            }
        }
        return buildStandardScreenPage(
            layoutKey: "screen_quicklist",
            title: "QuickList (\(quickTasks.filter { !$0.isCompleted }.count))",
            bodyLines: lines,
            footer: toastMessage ?? "↑↓이동 · 탭 완료체크 · →동기화 · 더블탭 뒤로"
        )
    }

    // 4. Alarm / Timer / Stopwatch
    private func buildClockToolsPage() -> G2PageSpec {
        let tabs = [
            clockTab == 0 ? "[● 알람]" : "  알람 ",
            clockTab == 1 ? "[● 타이머]" : "  타이머 ",
            clockTab == 2 ? "[● 스톱워치]" : "  스톱워치 "
        ].joined(separator: "   ")

        var body: [String] = [tabs, ""]
        let footer: String

        switch clockTab {
        case 0:
            if alarms.isEmpty {
                body.append("설정된 알람이 없습니다. 아이폰 앱에서 추가하세요.")
            } else {
                let safeIdx = max(0, min(alarms.count - 1, alarmIndex))
                let start = max(0, min(safeIdx - 1, max(0, alarms.count - 4)))
                for i in start..<min(alarms.count, start + 4) {
                    let a = alarms[i]
                    let cur = (i == safeIdx) ? "▶ " : "  "
                    body.append("\(cur)\(a.timeText)  \(a.label)   [\(a.isEnabled ? "ON" : "OFF")]")
                }
            }
            footer = "←→탭전환 · ↑↓선택 · 탭 ON/OFF · 더블탭 뒤로"
        case 1:
            let dur = AlarmTimerService.formatDuration(timerRemainingSeconds)
            let presetLabel = "\(timerPresetsSeconds[timerPresetIndex] / 60)분"
            body.append("  남은 시간:  \(dur)   (\(isTimerRunning ? "진행 중" : "대기"))")
            body.append("  프리셋 선택: < \(presetLabel) >")
            footer = "↑↓시간변경 · 탭 시작/정지 · ←→탭전환 · 더블탭 뒤로"
        default:
            body.append("  경과 시간:  \(AlarmTimerService.formatDuration(stopwatchSeconds))   (\(isStopwatchRunning ? "측정 중" : "정지"))")
            if !stopwatchLaps.isEmpty {
                let lapsStr = stopwatchLaps.prefix(3).enumerated().map { "L\($0.offset + 1) \(AlarmTimerService.formatDuration($0.element))" }.joined(separator: " | ")
                body.append("  랩: \(lapsStr)")
            }
            footer = "탭 시작/정지 · ↑랩 기록 · ↓초기화 · 더블탭 뒤로"
        }

        return buildStandardScreenPage(
            layoutKey: "screen_clock",
            title: "알람 · 타이머",
            bodyLines: body,
            footer: footer
        )
    }

    // 5. Teleprompter
    private func buildTeleprompterPage() -> G2PageSpec {
        let doc = currentDocument
        let slice = Array(doc.lines.dropFirst(readerScrollOffset).prefix(5))
        let mode = readerAutoScroll ? "자동▶" : "수동"
        let title = "\(doc.title) (\(readerDocIndex + 1)/\(documents.count)) [\(mode)]"
        let footer = "줄 \(readerScrollOffset + 1)/\(max(1, doc.lines.count)) · ↑↓스크롤 · ←→문서 · 탭 자동"
        return buildStandardScreenPage(
            layoutKey: "screen_prompter",
            title: title,
            bodyLines: slice,
            footer: footer
        )
    }

    // 6. Head-Up Wake (들어깨우기) with Live G2 IMU Telemetry
    private func buildHeadUpPage() -> G2PageSpec {
        let liveLine = String(
            format: "실시간 각도: %+.1f° (기준 %.1f° · 변화 %+.1f°)",
            currentImu.pitchDegrees,
            neutralPitchDegrees,
            lastDeltaPitch
        )
        let items = [
            "들어깨우기 대기 모드:   [\(headUpWakeEnabled ? "ON" : "OFF")]",
            "깨우기 각도 민감도:     < \(headUpTriggerAngle)° >",
            "자동 투명 대기 시간:    < \(headUpIdleSeconds)초 >",
            "현재 고개 자세를 기준(0°)으로 보정",
            "지금 투명 대기(화면 숨김) 테스트"
        ]
        var body: [String] = [liveLine]
        for (i, text) in items.enumerated() {
            body.append((i == headUpMenuIndex ? "▶ " : "  ") + text)
        }
        return buildStandardScreenPage(
            layoutKey: "screen_headup",
            title: "들어깨우기 (IMU)",
            bodyLines: body,
            footer: toastMessage ?? "↑↓이동 · ←→조절 · 탭 실행 · 더블탭 뒤로"
        )
    }

    // 7. Full Hardware Settings (SID 0x09 + 0x20 + 0x04)
    private func buildSettingsPage() -> G2PageSpec {
        let items = [
            "화면 밝기          < \(brightness) / 50 >",
            "자동 밝기          [\(autoBrightness ? "ON" : "OFF")]",
            "화면 높이 (Y)      < \(displayHeight) / 20 >",
            "화면 거리 (X)      < \(displayDistance) / 20 >",
            "착용 감지          [\(wearDetection ? "ON" : "OFF")]",
            "무음 모드          [\(silentMode ? "ON" : "OFF")]",
            "ANCS 알림 허용     [\(ancsEnabled ? "ON" : "OFF")]",
            "배터리 · 펌웨어 새로고침 (\(g2FirmwareLeft))"
        ]
        let start = max(0, min(settingsIndex - 2, max(0, items.count - 5)))
        var body: [String] = []
        for i in start..<min(items.count, start + 5) {
            body.append((i == settingsIndex ? "▶ " : "  ") + items[i])
        }
        return buildStandardScreenPage(
            layoutKey: "screen_settings",
            title: "기기 설정 (\(settingsIndex + 1)/\(items.count))",
            bodyLines: body,
            footer: toastMessage ?? "↑↓이동 · ←→값조절 · 탭 실행 · 더블탭 뒤로"
        )
    }

    // 8. Phase 2/3 Feature Hub Page
    private func buildFeaturePage(title: String, subtitle: String, extra: String) -> G2PageSpec {
        buildStandardScreenPage(
            layoutKey: "screen_feature",
            title: title,
            bodyLines: ["", "  \(subtitle)", "", "  \(extra)"],
            footer: toastMessage ?? "홀드: G2 마이크 테스트 · 더블탭: 앱 메뉴"
        )
    }

    // 9. Global Push-to-Talk Mic Overlay
    private func buildMicOverlayPage() -> G2PageSpec {
        let sec = Double(micDurationMs) / 1000.0
        let levelNorm = max(0, min(12, Int(abs(Int(micSignal))) / 250))
        let bar = String(repeating: "█", count: levelNorm) + String(repeating: "░", count: 12 - levelNorm)
        let secStr = String(format: "%.1f", sec)

        let card = G2TextContainer(
            id: 1,
            name: "mic",
            x: 16,
            y: 22,
            width: 544,
            height: 244,
            text: [
                "  ● G2 내장 마이크 듣는 중 (LC3 16kHz)",
                "  ────────────────────────────────",
                "",
                "  말씀하세요... 손을 떼면 즉시 종료됩니다.",
                "",
                "  신호 [\(bar)]   \(secStr)초",
                "  수신 \(micPackets) pkt  ·  방향 \(micDOA)°"
            ].joined(separator: "\n"),
            captureEvents: true,
            borderWidth: 3,
            borderColor: 15,
            borderRadius: 10,
            padding: 12
        )
        return G2PageSpec(layoutKey: "overlay_mic", textContainers: [card])
    }

    // 10. Global Full-Screen Alarm / Timer Alert Popup
    private func buildAlertPage(_ alert: G2ActiveAlert) -> G2PageSpec {
        let card = G2TextContainer(
            id: 1,
            name: "alert",
            x: 20,
            y: 24,
            width: 536,
            height: 240,
            text: [
                "  ★  \(alert.kind.rawValue)  ★",
                "  ────────────────────────────────",
                "",
                "  \(alert.title)",
                "",
                "  ▶ 한 번 탭: 알림 끄기",
                "  ▶ 더블탭:   5분 뒤 스누즈"
            ].joined(separator: "\n"),
            captureEvents: true,
            borderWidth: 4,
            borderColor: 15,
            borderRadius: 10,
            padding: 14
        )
        return G2PageSpec(layoutKey: "overlay_alert", textContainers: [card])
    }

    // Shared 3-container screen frame (Header + Bordered Body Card + Subtle Footer)
    private func buildStandardScreenPage(
        layoutKey: String,
        title: String,
        bodyLines: [String],
        footer: String
    ) -> G2PageSpec {
        let header = G2TextContainer(
            id: 1,
            name: "hdr",
            x: 12,
            y: 4,
            width: 552,
            height: 36,
            text: statusHeaderText(title: title),
            captureEvents: true,
            borderWidth: 0,
            borderColor: 0,
            borderRadius: 0,
            padding: 4
        )
        let body = G2TextContainer(
            id: 2,
            name: "body",
            x: 12,
            y: 44,
            width: 552,
            height: 192,
            text: bodyLines.joined(separator: "\n"),
            captureEvents: false,
            borderWidth: 1,
            borderColor: 9,
            borderRadius: 8,
            padding: 8
        )
        let foot = G2TextContainer(
            id: 3,
            name: "foot",
            x: 12,
            y: 242,
            width: 552,
            height: 40,
            text: footer,
            captureEvents: false,
            borderWidth: 0,
            borderColor: 0,
            borderRadius: 0,
            padding: 4
        )
        return G2PageSpec(layoutKey: layoutKey, textContainers: [header, body, foot])
    }
}
