import Foundation

public struct G2AlertItem: Identifiable, Equatable {
    public let id: String
    public let source: String
    public let sender: String
    public let timeLabel: String
    public let preview: String
    public let bodyLines: [String]

    public init(id: String, source: String, sender: String, timeLabel: String, preview: String, bodyLines: [String]) {
        self.id = id
        self.source = source
        self.sender = sender
        self.timeLabel = timeLabel
        self.preview = preview
        self.bodyLines = bodyLines
    }

    public static let defaults: [G2AlertItem] = [
        G2AlertItem(
            id: "a1",
            source: "kakao",
            sender: "김민수",
            timeLabel: "방금",
            preview: "오늘 3시 미팅 30분 뒤로 미뤄도 될까요? 자료는 노션에 올려뒀습니다.",
            bodyLines: [
                "오늘 3시 미팅 30분 뒤로 미뤄도 될까요?",
                "디자인 리뷰 자료는 노션에 미리 올려뒀습니다.",
                "혹시 G2 안경 실기 테스트도 같이 볼 수 있나요?"
            ]
        ),
        G2AlertItem(
            id: "a2",
            source: "agy",
            sender: "agy · spark01",
            timeLabel: "2분 전",
            preview: "DGX Spark GPU 준비 완료 · 오늘 관심 피드가 업데이트되었습니다.",
            bodyLines: [
                "1. DGX Spark 상태 (Tailscale 정상)",
                "   • spark01 (GB10 GPU): Whisper turbo 활성",
                "   • spark02 (폴백 대기): 활성",
                "2. 오늘 관심 피드가 준비되었습니다."
            ]
        )
    ]
}

/// Minimalist Even Realities G2 Spatial OS state machine rendered onto the 576x288 EvenHub canvas
/// with CoreGraphics 4-bit graphics + fast differential multi-container updates.
public final class G2OSStateMachine: ObservableObject {
    public enum Screen: String, CaseIterable {
        case dashboard = "바탕화면"
        case alerts = "알림 피드"
        case launcher = "메뉴"
        case feedApp = "피드"
        case readerDetail = "상세 보기"
        case agent = "AI 답변"
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

    public struct AITurn: Identifiable, Equatable {
        public let id: UUID
        public var question: String
        public var answer: String
        public var meta: String

        public init(id: UUID = UUID(), question: String, answer: String, meta: String = "") {
            self.id = id
            self.question = question
            self.answer = answer
            self.meta = meta
        }
    }

    public struct TranslateLangPair: Equatable {
        public let label: String
        public let src: String
        public let dst: String
    }

    public let translatePairs: [TranslateLangPair] = [
        TranslateLangPair(label: "자동 → 한국어", src: "auto", dst: "ko"),
        TranslateLangPair(label: "한국어 → 영어", src: "ko", dst: "en"),
        TranslateLangPair(label: "영어 → 한국어", src: "en", dst: "ko"),
        TranslateLangPair(label: "한국어 → 일본어", src: "ko", dst: "ja"),
        TranslateLangPair(label: "일본어 → 한국어", src: "ja", dst: "ko"),
        TranslateLangPair(label: "한국어 → 중국어", src: "ko", dst: "zh")
    ]

    @Published public private(set) var currentScreen: Screen = .dashboard
    @Published public private(set) var currentPage: G2PageSpec = .blankTransparent()
    @Published public private(set) var renderedFrameText: String = ""
    @Published public private(set) var lastActionSummary: String = "대기 중"
    @Published public private(set) var recentActions: [String] = []
    @Published public private(set) var toastMessage: String?

    // Studio Minimalist Spatial OS State (Home -> ↓ Alerts / → Menu 8-Slot Dock -> Feed App & Reader)
    @Published public var feedCategories: [G2FeedCategory] = FeedService.defaultCategories()
    @Published public var feedSearchQuery: String = ""
    @Published public private(set) var alerts: [G2AlertItem] = G2AlertItem.defaults
    @Published public private(set) var alertStackIdx: Int = 0
    @Published public private(set) var menuSlotIdx: Int = 0        // 0..7 (0 = 피드, 1..7 = empty)
    @Published public private(set) var menuFocus: Int = -1         // -1 = Bottom Dock, 0..N-1 = Quick Preview (↑ enter/exit)
    @Published public private(set) var feedCatIdx: Int = 0
    @Published public private(set) var feedCatFocus: Int = 0
    private var readerSourceIsAlert: Bool = false
    private var activeArticleId: String = ""
    private var detailScroll: Int = 0
    private var readerReturnScreen: Screen = .launcher
    private var aiReturnScreen: Screen = .dashboard
    private var voiceSearchCaptureActive: Bool = false

    public var onFeedVoiceSearch: ((String) -> Void)?

    // Dashboard right-side widget tab (legacy compatibility)
    @Published public private(set) var dashboardTab: Int = 0

    // App Launcher 3x2 card grid (page 0..1, row 0..1, col 0..2)
    @Published public private(set) var launcherPage: Int = 0
    @Published public private(set) var launcherRow: Int = 0
    @Published public private(set) var launcherCol: Int = 0

    // Even AI state (DGX Spark warm `agy`)
    @Published public private(set) var aiTurns: [AITurn] = []
    @Published public private(set) var aiTurnIndex: Int = 0
    @Published public private(set) var aiScrollOffset: Int = 0
    @Published public private(set) var aiLiveStatus: String = "길게 눌러 질문하세요"
    @Published public private(set) var aiLivePartialSTT: String = ""

    // Real-time Translate state
    @Published public private(set) var translatePairIndex: Int = 0
    @Published public private(set) var isTranslateActive: Bool = false
    @Published public private(set) var translateSourceText: String = "탭하여 실시간 통역을 시작하세요"
    @Published public private(set) var translateTargetText: String = ""

    // Conversate (Meeting Co-Pilot) state
    @Published public private(set) var isConversateActive: Bool = false
    @Published public private(set) var conversateTranscript: String = "탭하여 실시간 회의 듣기를 시작하세요"
    @Published public private(set) var conversateInsight: String = "용어 설명 · 핵심 포인트 · → 요약"
    @Published public private(set) var conversateScrollOffset: Int = 0

    // QuickList cursor
    @Published public private(set) var quickListIndex: Int = 0

    // Clock tools (0 = Alarms, 1 = Timer, 2 = Stopwatch)
    @Published public private(set) var clockTab: Int = 0
    @Published public private(set) var alarmIndex: Int = 0
    @Published public private(set) var timerPresetIndex: Int = 2
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
                "3. 어디서든 모션 패드를 길게 누르면",
                "   DGX Spark Even AI(agy)에게 즉시 질문합니다.",
                "4. 실시간 통역 / 대화 지원에서는 탭 한 번으로",
                "   핸즈프리 연속 자막·회의 코파일럿이 동작합니다.",
                "5. 들어깨우기에서 기준 각도를 보정하면",
                "   고개 들 때만 0.1초 만에 대시보드가 뜹니다."
            ]
        ),
        ReaderDocument(
            id: 1,
            title: "내 대본 / 메모",
            lines: [
                "아이폰 앱 도구 > 텔레프롬프터에서",
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
    @Published public var headUpTriggerAngle: Int = 20
    @Published public var headUpIdleSeconds: Int = 15
    @Published public private(set) var headUpMenuIndex: Int = 0
    @Published public private(set) var isHeadUpDimmed: Bool = false
    @Published public private(set) var currentImu: G2ImuSample = G2ImuSample(x: 0, y: 0, z: 0)
    @Published public private(set) var neutralPitchDegrees: Double = 0
    @Published public private(set) var lastDeltaPitch: Double = 0

    // Full Settings menu cursor (0..7)
    @Published public private(set) var settingsIndex: Int = 0

    // Pixel graphics clock toggle
    @Published public var pixelGraphicsEnabled: Bool = true

    // Live data injected from Services, BLE, Tailscale & Spark Bridge
    public var tailscaleConnected: Bool = false
    public var tailscaleIP: String?
    public var sparkNodeStatus: String = "Spark 대기"
    public var sparkConnected: Bool = false
    public var sparkActiveShortTag: String = "" // e.g. "64" or "65"
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
    public var onStartVoiceSession: ((SparkVoiceMode, String, String) -> Void)?
    public var onStopVoiceSession: ((SparkVoiceMode) -> Void)?
    public var onRequestConversateSummary: (() -> Void)?
    public var onResetVoiceSession: ((SparkVoiceMode) -> Void)?
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
    private var activePushToTalkMode: SparkVoiceMode = .evenAI

    private struct AppTile {
        let title: String
        let subtitle: String
        let screen: Screen
    }

    private let launcherPages: [[[AppTile]]] = [
        [
            [
                AppTile(title: "Even AI", subtitle: "Spark agy", screen: .agent),
                AppTile(title: "실시간 통역", subtitle: "이중 자막", screen: .translate),
                AppTile(title: "대화 지원", subtitle: "회의 코파일럿", screen: .conversate)
            ],
            [
                AppTile(title: "QuickList", subtitle: "할 일 목록", screen: .quickList),
                AppTile(title: "알람·타이머", subtitle: "시계 도구", screen: .clockTools),
                AppTile(title: "텔레프롬프터", subtitle: "대본 리더", screen: .teleprompter)
            ]
        ],
        [
            [
                AppTile(title: "들어깨우기", subtitle: "IMU 제스처", screen: .headUp),
                AppTile(title: "기기 설정", subtitle: "밝기·위치", screen: .settings),
                AppTile(title: "길찾기", subtitle: "도보 안내", screen: .navigate)
            ],
            [
                AppTile(title: "대시보드", subtitle: "홈 위젯", screen: .dashboard),
                AppTile(title: "Even AI", subtitle: "음성 비서", screen: .agent),
                AppTile(title: "실시간 통역", subtitle: "통역 자막", screen: .translate)
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
                  !self.isTranslateActive,
                  !self.isConversateActive,
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

    // MARK: - DGX Spark AI / STT Live Event Handlers

    public func handleSparkEvent(_ event: SparkBridgeEvent) {
        lastInteractionAt = Date()
        switch event {
        case .connected(let host, let rtt, _):
            sparkConnected = true
            sparkNodeStatus = "\(host) · \(rtt)ms"
            if host.lowercased().contains("02") || host.hasSuffix("65") {
                sparkActiveShortTag = "65"
            } else {
                sparkActiveShortTag = "64"
            }
            rebuildDisplay(pushToGlasses: true)
        case .disconnected:
            sparkConnected = false
            sparkActiveShortTag = ""
            sparkNodeStatus = tailscaleConnected ? "Spark 대기" : "TS 꺼짐"
            rebuildDisplay(pushToGlasses: true)
        case .sttPartial(let mode, let text, _):
            switch mode {
            case .evenAI, .transcribe:
                aiLivePartialSTT = text
                if isMicOn { rebuildDisplay(pushToGlasses: true) }
            case .translate:
                translateSourceText = text
                if currentScreen == .translate { rebuildDisplay(pushToGlasses: true) }
            case .conversate:
                conversateTranscript = text
                if currentScreen == .conversate { rebuildDisplay(pushToGlasses: true) }
            }
        case .sttFinal(let mode, let text, _, let ms):
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            switch mode {
            case .evenAI, .transcribe:
                aiLivePartialSTT = ""
                if voiceSearchCaptureActive {
                    voiceSearchCaptureActive = false
                    if !trimmed.isEmpty {
                        feedSearchQuery = trimmed
                        onFeedVoiceSearch?(trimmed)
                        feedCatIdx = max(0, feedCategories.count - 1)
                        feedCatFocus = 0
                        currentScreen = .feedApp
                    }
                    rebuildDisplay(pushToGlasses: true)
                    return
                }
                if trimmed.isEmpty {
                    aiLiveStatus = "음성이 감지되지 않았습니다"
                } else {
                    let meta = String(format: "STT %.0fms", ms)
                    aiTurns.append(AITurn(question: trimmed, answer: "", meta: meta))
                    if aiTurns.count > 12 { aiTurns.removeFirst() }
                    aiTurnIndex = aiTurns.count - 1
                    aiScrollOffset = 0
                    aiLiveStatus = "생각 중..."
                    if currentScreen != .agent { aiReturnScreen = currentScreen }
                    currentScreen = .agent
                }
                rebuildDisplay(pushToGlasses: true)
            case .translate:
                if !trimmed.isEmpty {
                    translateSourceText = trimmed
                    translateTargetText = "번역 중..."
                    if currentScreen == .translate { rebuildDisplay(pushToGlasses: true) }
                }
            case .conversate:
                if !trimmed.isEmpty {
                    conversateTranscript = trimmed
                    if currentScreen == .conversate { rebuildDisplay(pushToGlasses: true) }
                }
            }
        case .aiStatus(let mode, let status):
            switch mode {
            case .evenAI, .transcribe:
                aiLiveStatus = status
                if currentScreen == .agent { rebuildDisplay(pushToGlasses: true) }
            case .translate:
                translateTargetText = status
                if currentScreen == .translate { rebuildDisplay(pushToGlasses: true) }
            case .conversate:
                conversateInsight = status
                if currentScreen == .conversate { rebuildDisplay(pushToGlasses: true) }
            }
        case .aiDelta(let mode, let fullText):
            switch mode {
            case .evenAI, .transcribe:
                if aiTurns.isEmpty {
                    aiTurns.append(AITurn(question: "음성 질문", answer: fullText))
                    aiTurnIndex = 0
                } else {
                    aiTurns[aiTurns.count - 1].answer = fullText
                    aiTurnIndex = aiTurns.count - 1
                }
                aiLiveStatus = "스트리밍 중..."
                if currentScreen == .agent { rebuildDisplay(pushToGlasses: true) }
            case .translate:
                translateTargetText = fullText
                if currentScreen == .translate { rebuildDisplay(pushToGlasses: true) }
            case .conversate:
                conversateInsight = fullText
                conversateScrollOffset = 0
                if currentScreen == .conversate { rebuildDisplay(pushToGlasses: true) }
            }
        case .aiDone(let mode, let text, _, let dur):
            let durTag = dur.map { String(format: " · %.1f초", $0) } ?? ""
            switch mode {
            case .evenAI, .transcribe:
                if aiTurns.isEmpty {
                    aiTurns.append(AITurn(question: "질문", answer: text, meta: "완료\(durTag)"))
                    aiTurnIndex = 0
                } else {
                    aiTurns[aiTurns.count - 1].answer = text
                    aiTurns[aiTurns.count - 1].meta += durTag
                    aiTurnIndex = aiTurns.count - 1
                }
                aiLiveStatus = "완료\(durTag)"
                if currentScreen == .agent { rebuildDisplay(pushToGlasses: true) }
            case .translate:
                translateTargetText = text
                if currentScreen == .translate { rebuildDisplay(pushToGlasses: true) }
            case .conversate:
                conversateInsight = text
                conversateScrollOffset = 0
                if currentScreen == .conversate { rebuildDisplay(pushToGlasses: true) }
            }
        case .error(let message):
            showToast(message, duration: 4.0)
            aiLiveStatus = message
            if currentScreen == .agent || currentScreen == .translate || currentScreen == .conversate {
                rebuildDisplay(pushToGlasses: true)
            }
        }
    }

    public func notifyVoiceCommandExecuted(_ description: String) {
        showToast("✓ \(description)", duration: 3.5)
        rebuildDisplay(pushToGlasses: true)
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

        if isHeadUpDimmed && event.action != .micStop {
            isHeadUpDimmed = false
            if event.action == .micStart {
                setPushToTalkActive(true)
            } else {
                rebuildDisplay()
            }
            return
        }

        if isScreenAsleep && event.action != .screenToggle {
            isScreenAsleep = false
            onSetScreenAsleep?(false)
            rebuildDisplay()
            return
        }

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

        switch event.action {
        case .micStart:
            setPushToTalkActive(true)
            return
        case .micStop:
            setPushToTalkActive(false)
            return
        case .micToggle:
            setPushToTalkActive(!isMicOn)
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
            // Instant 0.1s stealth screen blackout/wake (works even with Always-On OS active!)
            if alwaysOnEnabled {
                if isHeadUpDimmed {
                    wakeFromHeadUpStandby()
                } else {
                    enterHeadUpStandby()
                }
            } else {
                isScreenAsleep.toggle()
                onSetScreenAsleep?(isScreenAsleep)
                if !isScreenAsleep { rebuildDisplay() }
            }
            return
        case .home:
            stopContinuousVoiceModes()
            stopAutoScroll()
            currentScreen = .dashboard
            rebuildDisplay()
            return
        default:
            break
        }

        if isMicOn && !isTranslateActive && !isConversateActive { return }

        let isRepeat = event.detail.contains("연속")

        switch currentScreen {
        case .dashboard: handleDashboard(event.action)
        case .alerts: handleAlerts(event.action, isRepeat: isRepeat)
        case .launcher: handleLauncher(event.action, isRepeat: isRepeat)
        case .feedApp: handleFeedApp(event.action)
        case .readerDetail: handleReaderDetail(event.action)
        case .agent: handleAgent(event.action)
        case .translate: handleTranslate(event.action)
        case .conversate: handleConversate(event.action)
        case .quickList: handleQuickList(event.action)
        case .clockTools: handleClockTools(event.action)
        case .teleprompter: handleTeleprompter(event.action)
        case .headUp: handleHeadUp(event.action)
        case .settings: handleSettings(event.action)
        case .navigate: handleNavigateStub(event.action)
        }
        rebuildDisplay()
    }

    public func refreshDisplay(pushToGlasses: Bool = true) {
        if activeAlert != nil && isHeadUpDimmed {
            isHeadUpDimmed = false
        }
        rebuildDisplay(pushToGlasses: pushToGlasses)
    }

    // MARK: - Push-to-Talk & Continuous Voice Sessions

    private func setPushToTalkActive(_ enabled: Bool) {
        if enabled {
            stopContinuousVoiceModes()
            guard !isMicOn else { return }
            isMicOn = true
            isHeadUpDimmed = false
            micPackets = 0
            micDurationMs = 0
            micSignal = 0
            aiLivePartialSTT = ""
            voiceSearchCaptureActive = (currentScreen == .feedApp)
            if !voiceSearchCaptureActive && currentScreen != .agent {
                aiReturnScreen = currentScreen
            }
            activePushToTalkMode = voiceSearchCaptureActive ? .transcribe : ((currentScreen == .translate) ? .translate : .evenAI)

            let pair = translatePairs[translatePairIndex]
            let src = activePushToTalkMode == .translate ? pair.src : "auto"
            let dst = activePushToTalkMode == .translate ? pair.dst : "ko"

            onToggleMic?(true)
            onStartVoiceSession?(activePushToTalkMode, src, dst)
            rebuildDisplay()
        } else {
            guard isMicOn && !isTranslateActive && !isConversateActive else { return }
            let capturedPackets = micPackets
            let capturedSec = Double(micDurationMs) / 1000.0
            isMicOn = false
            onToggleMic?(false)
            onStopVoiceSession?(activePushToTalkMode)

            if capturedPackets > 0 {
                onSaveMicRecording?()
                lastVoiceSummary = String(format: "최근 음성 %.1f초 (%d pkt)", capturedSec, capturedPackets)
                if activePushToTalkMode == .evenAI && !voiceSearchCaptureActive {
                    currentScreen = .agent
                    aiLiveStatus = "인식 중..."
                }
            } else {
                voiceSearchCaptureActive = false
            }
            rebuildDisplay()
        }
    }

    private func stopContinuousVoiceModes() {
        if isTranslateActive {
            isTranslateActive = false
            isMicOn = false
            onToggleMic?(false)
            onStopVoiceSession?(.translate)
        }
        if isConversateActive {
            isConversateActive = false
            isMicOn = false
            onToggleMic?(false)
            onStopVoiceSession?(.conversate)
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

    // MARK: - Studio Minimalist Per-Screen Handlers

    private func recommendedArticles() -> [G2FeedArticle] {
        feedCategories.first?.articles ?? []
    }

    private func currentCategoryArticles() -> [G2FeedArticle] {
        guard !feedCategories.isEmpty else { return [] }
        let idx = max(0, min(feedCategories.count - 1, feedCatIdx))
        return feedCategories[idx].articles
    }

    private func findArticle(id: String) -> G2FeedArticle? {
        for cat in feedCategories {
            if let hit = cat.articles.first(where: { $0.id == id }) { return hit }
        }
        return recommendedArticles().first
    }

    // 1. Home (`↓` Alerts/Feed | `→` Menu | `L2` Direct Open)
    private func handleDashboard(_ action: RemoteAction) {
        let hasAlerts = !alerts.isEmpty
        switch action {
        case .down, .scrollDown:
            if hasAlerts {
                alertStackIdx = 0
                currentScreen = .alerts
            } else {
                feedCatIdx = 0
                feedCatFocus = 0
                currentScreen = .feedApp
            }
        case .right:
            menuSlotIdx = 0
            menuFocus = -1
            currentScreen = .launcher
        case .select:
            detailScroll = 0
            readerReturnScreen = .dashboard
            if hasAlerts {
                readerSourceIsAlert = true
                alertStackIdx = 0
                currentScreen = .readerDetail
            } else if let first = recommendedArticles().first {
                readerSourceIsAlert = false
                activeArticleId = first.id
                currentScreen = .readerDetail
            }
        case .up, .scrollUp:
            onRefreshDataServices?()
            onQuerySettings?()
        case .back:
            break
        default:
            break
        }
    }

    // 2. Alerts Stack (`↑↓` move, top `↑` -> Home | `←` dismiss 1 | `L2` open/clear | `R2` Home)
    private func handleAlerts(_ action: RemoteAction, isRepeat: Bool) {
        let count = alerts.count
        switch action {
        case .down, .scrollDown:
            if count > 0 && alertStackIdx < count {
                alertStackIdx += 1
            }
        case .up, .scrollUp:
            if alertStackIdx > 0 {
                alertStackIdx -= 1
            } else if !isRepeat {
                currentScreen = .dashboard
            }
        case .left:
            if !isRepeat && count > 0 && alertStackIdx < count {
                alerts.remove(at: alertStackIdx)
                if alertStackIdx > alerts.count { alertStackIdx = alerts.count }
                if alerts.isEmpty { alertStackIdx = 0 }
            }
        case .select:
            guard count > 0 else { return }
            if alertStackIdx == count {
                alerts.removeAll()
                alertStackIdx = 0
                currentScreen = .dashboard
            } else {
                readerSourceIsAlert = true
                detailScroll = 0
                readerReturnScreen = .alerts
                currentScreen = .readerDetail
            }
        case .back:
            currentScreen = .dashboard
        default:
            break
        }
    }

    // 3. Menu Preview (8 Slots: Dock `menuFocus=-1` -> `↑` enters Quick Preview, `L2` opens Full Feed!)
    private func handleLauncher(_ action: RemoteAction, isRepeat: Bool) {
        let slotCount = 8
        let rec = recommendedArticles()
        let isFeedSlot = (menuSlotIdx == 0)

        switch action {
        case .right:
            if menuSlotIdx < slotCount - 1 {
                menuSlotIdx += 1
                menuFocus = -1
            }
        case .left:
            if menuSlotIdx > 0 {
                menuSlotIdx -= 1
                menuFocus = -1
            } else if !isRepeat {
                currentScreen = .dashboard
            }
        case .up, .scrollUp:
            guard isFeedSlot && !rec.isEmpty else { return }
            if menuFocus < 0 {
                if !isRepeat { menuFocus = 0 }
            } else if menuFocus > 0 {
                menuFocus -= 1
            } else if !isRepeat {
                menuFocus = -1
            }
        case .down, .scrollDown:
            guard isFeedSlot && !rec.isEmpty else { return }
            if menuFocus >= 0 && menuFocus < rec.count - 1 {
                menuFocus += 1
            }
        case .select:
            guard isFeedSlot else { return }
            if menuFocus < 0 {
                feedCatIdx = 0
                feedCatFocus = 0
                currentScreen = .feedApp
            } else {
                let idx = max(0, min(rec.count - 1, menuFocus))
                readerSourceIsAlert = false
                activeArticleId = rec[idx].id
                detailScroll = 0
                readerReturnScreen = .launcher
                currentScreen = .readerDetail
            }
        case .back:
            if menuFocus >= 0 {
                menuFocus = -1
            } else {
                currentScreen = .dashboard
            }
        default:
            break
        }
    }

    // 4. Full-Screen Feed (`←→` categories | `↑↓` articles | `L2` read | `L2 꾹` voice search | `R2` menu)
    private func handleFeedApp(_ action: RemoteAction) {
        let items = currentCategoryArticles()
        switch action {
        case .right:
            if feedCatIdx < feedCategories.count - 1 {
                feedCatIdx += 1
                feedCatFocus = 0
            }
        case .left:
            if feedCatIdx > 0 {
                feedCatIdx -= 1
                feedCatFocus = 0
            }
        case .down, .scrollDown:
            if feedCatFocus < items.count - 1 { feedCatFocus += 1 }
        case .up, .scrollUp:
            if feedCatFocus > 0 { feedCatFocus -= 1 }
        case .select:
            guard !items.isEmpty else { return }
            let idx = max(0, min(items.count - 1, feedCatFocus))
            readerSourceIsAlert = false
            activeArticleId = items[idx].id
            detailScroll = 0
            readerReturnScreen = .feedApp
            currentScreen = .readerDetail
        case .back:
            menuFocus = -1
            currentScreen = .launcher
        default:
            break
        }
    }

    // 5. Article / Alert Full Reader (`↑↓` scroll | `R2` back)
    private func handleReaderDetail(_ action: RemoteAction) {
        let lines = currentReaderLines()
        let maxScroll = max(0, lines.count - 6)
        switch action {
        case .down, .scrollDown:
            if detailScroll < maxScroll { detailScroll += 1 }
        case .up, .scrollUp:
            if detailScroll > 0 { detailScroll -= 1 }
        case .back:
            currentScreen = readerReturnScreen
        default:
            break
        }
    }

    private func currentReaderLines() -> [String] {
        if readerSourceIsAlert {
            guard !alerts.isEmpty else { return [] }
            let idx = max(0, min(alerts.count - 1, alertStackIdx))
            return alerts[idx].bodyLines
        }
        guard let art = findArticle(id: activeArticleId) else { return [] }
        return [art.title, ""] + art.bodyLines
    }

    // 6. AI Reply (`↑↓` scroll | `R2` return to previous screen)
    private func handleAgent(_ action: RemoteAction) {
        let lines = currentAIAnswerLines()
        let maxOffset = max(0, lines.count - 5)
        switch action {
        case .up, .scrollUp:
            aiScrollOffset = max(0, aiScrollOffset - 1)
        case .down, .scrollDown:
            aiScrollOffset = min(maxOffset, aiScrollOffset + 1)
        case .back:
            currentScreen = aiReturnScreen
        default:
            break
        }
    }

    private func handleTranslate(_ action: RemoteAction) {
        switch action {
        case .left:
            translatePairIndex = (translatePairIndex + translatePairs.count - 1) % translatePairs.count
            if isTranslateActive { restartTranslateStream() }
        case .right:
            translatePairIndex = (translatePairIndex + 1) % translatePairs.count
            if isTranslateActive { restartTranslateStream() }
        case .select:
            if isTranslateActive {
                stopContinuousVoiceModes()
                showToast("실시간 통역 일시정지")
            } else {
                stopContinuousVoiceModes()
                isTranslateActive = true
                isMicOn = true
                let pair = translatePairs[translatePairIndex]
                translateSourceText = "듣는 중... (\(pair.label))"
                translateTargetText = ""
                onToggleMic?(true)
                onStartVoiceSession?(.translate, pair.src, pair.dst)
            }
        case .back:
            stopContinuousVoiceModes()
            currentScreen = .launcher
        default:
            break
        }
    }

    private func restartTranslateStream() {
        let pair = translatePairs[translatePairIndex]
        onStopVoiceSession?(.translate)
        translateSourceText = "듣는 중... (\(pair.label))"
        onStartVoiceSession?(.translate, pair.src, pair.dst)
    }

    private func handleConversate(_ action: RemoteAction) {
        let lines = Self.wrapForG2(conversateInsight, maxVisualUnits: 46)
        let maxOffset = max(0, lines.count - 3)
        switch action {
        case .up, .scrollUp:
            conversateScrollOffset = max(0, conversateScrollOffset - 1)
        case .down, .scrollDown:
            conversateScrollOffset = min(maxOffset, conversateScrollOffset + 1)
        case .right:
            conversateInsight = "회의 요약 생성 중..."
            conversateScrollOffset = 0
            onRequestConversateSummary?()
        case .left:
            conversateTranscript = "새 회의 세션 시작"
            conversateInsight = "용어 설명 · 핵심 포인트 · → 요약"
            conversateScrollOffset = 0
            onResetVoiceSession?(.conversate)
            showToast("회의 세션 초기화")
        case .select:
            if isConversateActive {
                stopContinuousVoiceModes()
                showToast("대화 지원 듣기 중지")
            } else {
                stopContinuousVoiceModes()
                isConversateActive = true
                isMicOn = true
                conversateTranscript = "● 실시간 회의 듣는 중..."
                onToggleMic?(true)
                onStartVoiceSession?(.conversate, "auto", "ko")
            }
        case .back:
            stopContinuousVoiceModes()
            currentScreen = .launcher
        default:
            break
        }
    }

    private func handleQuickList(_ action: RemoteAction) {
        let count = quickTasks.count
        switch action {
        case .up, .scrollUp: if count > 0 { quickListIndex = (quickListIndex + count - 1) % count }
        case .down, .scrollDown: if count > 0 { quickListIndex = (quickListIndex + 1) % count }
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
        default: break
        }
    }

    private func handleClockTools(_ action: RemoteAction) {
        switch action {
        case .left: clockTab = (clockTab + 2) % 3
        case .right: clockTab = (clockTab + 1) % 3
        case .up, .scrollUp:
            switch clockTab {
            case 0: if !alarms.isEmpty { alarmIndex = (alarmIndex + alarms.count - 1) % alarms.count }
            case 1:
                timerPresetIndex = (timerPresetIndex + timerPresetsSeconds.count - 1) % timerPresetsSeconds.count
                onSetTimerPreset?(timerPresetsSeconds[timerPresetIndex])
            default: onLapStopwatch?()
            }
        case .down, .scrollDown:
            switch clockTab {
            case 0: if !alarms.isEmpty { alarmIndex = (alarmIndex + 1) % alarms.count }
            case 1:
                timerPresetIndex = (timerPresetIndex + 1) % timerPresetsSeconds.count
                onSetTimerPreset?(timerPresetsSeconds[timerPresetIndex])
            default: onResetStopwatch?()
            }
        case .select:
            switch clockTab {
            case 0:
                if !alarms.isEmpty {
                    let idx = max(0, min(alarms.count - 1, alarmIndex))
                    onToggleAlarm?(alarms[idx].id)
                }
            case 1: onToggleTimer?()
            default: onToggleStopwatch?()
            }
        case .back: currentScreen = .launcher
        default: break
        }
    }

    private func handleTeleprompter(_ action: RemoteAction) {
        let lines = currentDocument.lines
        let maxOffset = max(0, lines.count - 5)
        switch action {
        case .up, .scrollUp: readerScrollOffset = max(0, readerScrollOffset - 1)
        case .down, .scrollDown: readerScrollOffset = min(maxOffset, readerScrollOffset + 1)
        case .left:
            stopAutoScroll()
            readerDocIndex = (readerDocIndex + documents.count - 1) % documents.count
            readerScrollOffset = 0
        case .right:
            stopAutoScroll()
            readerDocIndex = (readerDocIndex + 1) % documents.count
            readerScrollOffset = 0
        case .select: toggleAutoScroll()
        case .back:
            stopAutoScroll()
            currentScreen = .launcher
        default: break
        }
    }

    private func handleHeadUp(_ action: RemoteAction) {
        switch action {
        case .up, .scrollUp: headUpMenuIndex = (headUpMenuIndex + 4) % 5
        case .down, .scrollDown: headUpMenuIndex = (headUpMenuIndex + 1) % 5
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
            case 0: setHeadUpWakeMode(!headUpWakeEnabled)
            case 1:
                headUpTriggerAngle = (headUpTriggerAngle >= 45) ? 15 : headUpTriggerAngle + 5
                onSetHeadUpConfig?(headUpWakeEnabled, headUpTriggerAngle)
            case 2: headUpIdleSeconds = (headUpIdleSeconds >= 45) ? 10 : headUpIdleSeconds + 5
            case 3: calibrateHeadUpNeutral()
            case 4: enterHeadUpStandby()
            default: break
            }
        case .back: currentScreen = .launcher
        default: break
        }
    }

    private func handleSettings(_ action: RemoteAction) {
        let totalItems = 8
        switch action {
        case .up, .scrollUp: settingsIndex = (settingsIndex + totalItems - 1) % totalItems
        case .down, .scrollDown: settingsIndex = (settingsIndex + 1) % totalItems
        case .left: adjustSetting(delta: -1)
        case .right: adjustSetting(delta: +1)
        case .select: activateSetting()
        case .back: currentScreen = .launcher
        default: break
        }
    }

    private func adjustSetting(delta: Int) {
        switch settingsIndex {
        case 0: brightness = max(1, min(50, brightness + delta * 5)); onSetBrightness?(brightness)
        case 1: autoBrightness.toggle(); onSetAutoBrightness?(autoBrightness)
        case 2: displayHeight = max(0, min(20, displayHeight + delta * 2)); onSetDisplayHeight?(displayHeight)
        case 3: displayDistance = max(0, min(20, displayDistance + delta * 2)); onSetDisplayDistance?(displayDistance)
        case 4: wearDetection.toggle(); onSetWearDetection?(wearDetection)
        case 5: silentMode.toggle(); onSetSilentMode?(silentMode)
        case 6: ancsEnabled.toggle(); onSetAncsEnabled?(ancsEnabled)
        default: break
        }
    }

    private func activateSetting() {
        switch settingsIndex {
        case 0: brightness = (brightness >= 50) ? 10 : min(50, brightness + 10); onSetBrightness?(brightness)
        case 1: autoBrightness.toggle(); onSetAutoBrightness?(autoBrightness)
        case 2: displayHeight = (displayHeight >= 20) ? 0 : min(20, displayHeight + 4); onSetDisplayHeight?(displayHeight)
        case 3: displayDistance = (displayDistance >= 20) ? 0 : min(20, displayDistance + 4); onSetDisplayDistance?(displayDistance)
        case 4: wearDetection.toggle(); onSetWearDetection?(wearDetection)
        case 5: silentMode.toggle(); onSetSilentMode?(silentMode)
        case 6: ancsEnabled.toggle(); onSetAncsEnabled?(ancsEnabled)
        case 7: onQuerySettings?(); showToast("기기 상태 조회 요청")
        default: break
        }
    }

    private func handleNavigateStub(_ action: RemoteAction) {
        if action == .back { currentScreen = .launcher }
    }

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

    private func currentAIAnswerLines() -> [String] {
        guard !aiTurns.isEmpty else { return [] }
        let idx = max(0, min(aiTurns.count - 1, aiTurnIndex))
        let body = aiTurns[idx].answer.isEmpty ? "● \(aiLiveStatus)" : aiTurns[idx].answer
        return Self.wrapForG2(body, maxVisualUnits: 46)
    }

    public static func wrapForG2(_ text: String, maxVisualUnits: Int = 46) -> [String] {
        var result: [String] = []
        for rawLine in text.components(separatedBy: .newlines) {
            if rawLine.isEmpty {
                result.append("")
                continue
            }
            var current = ""
            var units = 0
            for ch in rawLine {
                let w = ch.isASCII ? 1 : 2
                if units + w > maxVisualUnits && !current.isEmpty {
                    result.append(current)
                    current = String(ch)
                    units = w
                } else {
                    current.append(ch)
                    units += w
                }
            }
            if !current.isEmpty { result.append(current) }
        }
        return result.isEmpty ? [""] : result
    }

    // MARK: - 576x288 Multi-Container + 4-bit Pixel Graphics Renderer

    private func rebuildDisplay(pushToGlasses: Bool = true) {
        let page: G2PageSpec
        if isHeadUpDimmed && activeAlert == nil && !isMicOn {
            page = .blankTransparent()
        } else if let alert = activeAlert {
            page = buildAlertPage(alert)
        } else {
            switch currentScreen {
            case .dashboard: page = buildDashboardPage()
            case .alerts: page = buildAlertsPage()
            case .launcher: page = buildLauncherPage()
            case .feedApp: page = buildFeedAppPage()
            case .readerDetail: page = buildReaderDetailPage()
            case .agent: page = buildEvenAIPage()
            case .translate: page = buildTranslatePage()
            case .conversate: page = buildConversatePage()
            case .quickList: page = buildQuickListPage()
            case .clockTools: page = buildClockToolsPage()
            case .teleprompter: page = buildTeleprompterPage()
            case .headUp: page = buildHeadUpPage()
            case .settings: page = buildSettingsPage()
            case .navigate:
                page = buildStandardScreenPage(
                    layoutKey: "screen_navigate",
                    title: "길찾기",
                    bodyLines: ["", "  도보 턴바이턴 준비 중"],
                    footer: ""
                )
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

    private func glassesTailscaleBadge() -> String {
        if !tailscaleConnected {
            return "TS✕"
        }
        if sparkConnected {
            return sparkActiveShortTag.isEmpty ? "TS●" : "TS●\(sparkActiveShortTag)"
        }
        return "TS○"
    }

    private func statusHeaderText(title: String) -> String {
        let bat = g2Battery.map { "\(g2Charging ? "+" : "")\($0)%" } ?? "--%"
        let headTag = headUpWakeEnabled ? " [들기]" : ""
        return "\(formattedClock())  \(title)\(headTag)  \(glassesTailscaleBadge()) \(bat)"
    }

    private func formattedCompactDate() -> String {
        let df = DateFormatter()
        df.dateFormat = "MM.dd E"
        df.locale = Locale(identifier: "ko_KR")
        return df.string(from: Date())
    }

    private func formattedTempOnly() -> String {
        if let w = weather {
            return "\(w.temperatureC)°"
        }
        return "--°"
    }

    private func clipVisual(_ text: String, maxUnits: Int) -> String {
        var out = ""
        var units = 0
        for ch in text {
            let w = ch.isASCII ? 1 : 2
            if units + w > maxUnits {
                return out + "…"
            }
            out.append(ch)
            units += w
        }
        return out
    }

    private func makeStudioRenderContext() -> G2StudioGraphics.RenderContext {
        let timeStr = formattedClock()
        lastClockMinute = timeStr
        return G2StudioGraphics.RenderContext(
            timeStr: timeStr,
            dateStr: formattedCompactDate(),
            tempStr: formattedTempOnly(),
            weatherCode: weather?.iconCode ?? "sun",
            batteryPercent: g2Battery ?? 85,
            charging: g2Charging,
            tailscaleConnected: tailscaleConnected,
            sparkConnected: sparkConnected,
            aiListening: isMicOn && !isTranslateActive && !isConversateActive,
            voiceSearchMode: voiceSearchCaptureActive,
            livePartialSTT: aiLivePartialSTT
        )
    }

    // 1. Studio Minimalist Home (100% Pixel-Identical 4-Tile CoreGraphics!)
    private func buildDashboardPage() -> G2PageSpec {
        G2StudioGraphics.renderHomePage(
            rc: makeStudioRenderContext(),
            alerts: alerts,
            recArticles: recommendedArticles()
        )
    }

    // 2. Studio Minimalist Alerts Stack (100% Pixel-Identical 4-Tile CoreGraphics!)
    private func buildAlertsPage() -> G2PageSpec {
        G2StudioGraphics.renderAlertsPage(
            rc: makeStudioRenderContext(),
            alerts: alerts,
            stackIdx: alertStackIdx
        )
    }

    // 3. Studio Minimalist Menu Preview + 8-Slot Dock (100% Pixel-Identical 4-Tile CoreGraphics!)
    private func buildLauncherPage() -> G2PageSpec {
        G2StudioGraphics.renderMenuPage(
            rc: makeStudioRenderContext(),
            slotIdx: menuSlotIdx,
            menuFocus: menuFocus,
            recArticles: recommendedArticles()
        )
    }

    // 4. Studio Full-Screen Feed App (100% Pixel-Identical 4-Tile CoreGraphics!)
    private func buildFeedAppPage() -> G2PageSpec {
        G2StudioGraphics.renderFeedAppPage(
            rc: makeStudioRenderContext(),
            categories: feedCategories,
            catIdx: feedCatIdx,
            catFocus: feedCatFocus,
            searchQuery: feedSearchQuery
        )
    }

    // 5. Studio Article / Alert Full Reader (100% Pixel-Identical 4-Tile CoreGraphics!)
    private func buildReaderDetailPage() -> G2PageSpec {
        let iconKind: String
        let headerLeft: String
        let headerRight: String
        let isNews: Bool

        if readerSourceIsAlert, !alerts.isEmpty {
            let idx = max(0, min(alerts.count - 1, alertStackIdx))
            let a = alerts[idx]
            iconKind = a.source
            headerLeft = a.sender
            headerRight = a.timeLabel
            isNews = false
        } else if let art = findArticle(id: activeArticleId) {
            iconKind = "feed"
            headerLeft = "\(art.category) · \(art.outlet)"
            headerRight = art.timeLabel
            isNews = true
        } else {
            iconKind = "feed"
            headerLeft = "상세 보기"
            headerRight = ""
            isNews = false
        }

        return G2StudioGraphics.renderReaderPage(
            rc: makeStudioRenderContext(),
            iconKind: iconKind,
            headerLeft: headerLeft,
            headerRight: headerRight,
            lines: currentReaderLines(),
            scrollOffset: detailScroll,
            isNewsTitleOnLine0: isNews
        )
    }

    // 6. Studio Minimalist AI Reply (100% Pixel-Identical 4-Tile CoreGraphics!)
    private func buildEvenAIPage() -> G2PageSpec {
        let question: String
        let lines: [String]
        if aiTurns.isEmpty {
            question = "AI"
            lines = [aiLiveStatus]
        } else {
            let idx = max(0, min(aiTurns.count - 1, aiTurnIndex))
            let turn = aiTurns[idx]
            question = turn.question
            lines = currentAIAnswerLines()
        }
        return G2StudioGraphics.renderAIReplyPage(
            rc: makeStudioRenderContext(),
            question: question,
            answerLines: lines,
            scrollOffset: aiScrollOffset
        )
    }

    // 4. Real-Time Bilingual Translate (2-card split: Source top + Translation bottom)
    private func buildTranslatePage() -> G2PageSpec {
        let pair = translatePairs[translatePairIndex]
        let liveBadge = isTranslateActive ? "● 듣는 중" : "⏸ 대기"
        let header = G2TextContainer(
            id: 1, name: "hdr", x: 12, y: 4, width: 552, height: 36,
            text: "\(statusHeaderText(title: "통역 ◀ \(pair.label) ▶ [\(liveBadge)]"))",
            captureEvents: true, padding: 4
        )
        let srcLines = Self.wrapForG2(translateSourceText, maxVisualUnits: 46).suffix(2)
        let srcCard = G2TextContainer(
            id: 2, name: "tsrc", x: 12, y: 44, width: 552, height: 84,
            text: (["[원문]"] + srcLines).joined(separator: "\n"),
            captureEvents: false, borderWidth: 1, borderColor: 6, borderRadius: 8, padding: 7
        )
        let dstLines = Self.wrapForG2(translateTargetText.isEmpty ? "번역 결과가 여기에 실시간 표시됩니다." : translateTargetText, maxVisualUnits: 46).suffix(3)
        let dstCard = G2TextContainer(
            id: 3, name: "tdst", x: 12, y: 134, width: 552, height: 104,
            text: (["[번역]"] + dstLines).joined(separator: "\n"),
            captureEvents: false, borderWidth: 2, borderColor: 14, borderRadius: 8, padding: 7
        )
        let foot = G2TextContainer(
            id: 4, name: "tfoot", x: 12, y: 244, width: 552, height: 38,
            text: toastMessage ?? "탭: 연속 통역 시작/정지 · ←→ 언어 변경 · 더블탭: 뒤로",
            captureEvents: false, padding: 4
        )
        return G2PageSpec(layoutKey: "screen_translate", textContainers: [header, srcCard, dstCard, foot])
    }

    // 5. Conversate (Live Meeting Co-Pilot: Transcript top + AI Insight/Summary bottom)
    private func buildConversatePage() -> G2PageSpec {
        let liveBadge = isConversateActive ? "● 회의 듣는 중" : "⏸ 대기"
        let header = G2TextContainer(
            id: 1, name: "hdr", x: 12, y: 4, width: 552, height: 36,
            text: "\(statusHeaderText(title: "대화 지원 [\(liveBadge)]"))",
            captureEvents: true, padding: 4
        )
        let trLines = Self.wrapForG2(conversateTranscript, maxVisualUnits: 46).suffix(2)
        let trCard = G2TextContainer(
            id: 2, name: "ctran", x: 12, y: 44, width: 552, height: 80,
            text: (["[받아쓰기]"] + trLines).joined(separator: "\n"),
            captureEvents: false, borderWidth: 1, borderColor: 6, borderRadius: 8, padding: 7
        )
        let aiWrapped = Self.wrapForG2(conversateInsight, maxVisualUnits: 46)
        let safeOff = max(0, min(conversateScrollOffset, max(0, aiWrapped.count - 3)))
        let aiSlice = Array(aiWrapped.dropFirst(safeOff).prefix(3))
        let aiCard = G2TextContainer(
            id: 3, name: "ccop", x: 12, y: 130, width: 552, height: 108,
            text: (["[AI 코파일럿]"] + aiSlice).joined(separator: "\n"),
            captureEvents: false, borderWidth: 2, borderColor: 14, borderRadius: 8, padding: 7
        )
        let foot = G2TextContainer(
            id: 4, name: "cfoot", x: 12, y: 244, width: 552, height: 38,
            text: toastMessage ?? "탭: 듣기 시작/정지 · → 회의 요약 · ↑↓ 스크롤 · ← 초기화",
            captureEvents: false, padding: 4
        )
        return G2PageSpec(layoutKey: "screen_conversate", textContainers: [header, trCard, aiCard, foot])
    }

    // 6. QuickList / Clock / Teleprompter / HeadUp / Settings
    private func buildQuickListPage() -> G2PageSpec {
        var lines: [String] = []
        if quickTasks.isEmpty {
            lines = ["", "등록된 할 일이 없습니다.", "음성으로 \"할 일 추가해줘\"라고 말해보세요."]
        } else {
            let safeIdx = max(0, min(quickTasks.count - 1, quickListIndex))
            let start = max(0, min(safeIdx - 2, max(0, quickTasks.count - 5)))
            for i in start..<min(quickTasks.count, start + 5) {
                let t = quickTasks[i]
                lines.append("\(i == safeIdx ? "▶ " : "  ")\(t.isCompleted ? "[✓]" : "[ ]") \(t.title)")
            }
        }
        return buildStandardScreenPage(
            layoutKey: "screen_quicklist",
            title: "QuickList (\(quickTasks.filter { !$0.isCompleted }.count))",
            bodyLines: lines,
            footer: toastMessage ?? "↑↓이동 · 탭 완료체크 · →동기화 · 더블탭 뒤로"
        )
    }

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
                body.append("설정된 알람이 없습니다.")
            } else {
                let safeIdx = max(0, min(alarms.count - 1, alarmIndex))
                let start = max(0, min(safeIdx - 1, max(0, alarms.count - 4)))
                for i in start..<min(alarms.count, start + 4) {
                    let a = alarms[i]
                    body.append("\(i == safeIdx ? "▶ " : "  ")\(a.timeText)  \(a.label)   [\(a.isEnabled ? "ON" : "OFF")]")
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
        return buildStandardScreenPage(layoutKey: "screen_clock", title: "알람 · 타이머", bodyLines: body, footer: footer)
    }

    private func buildTeleprompterPage() -> G2PageSpec {
        let doc = currentDocument
        let slice = Array(doc.lines.dropFirst(readerScrollOffset).prefix(5))
        let mode = readerAutoScroll ? "자동▶" : "수동"
        return buildStandardScreenPage(
            layoutKey: "screen_prompter",
            title: "\(doc.title) (\(readerDocIndex + 1)/\(documents.count)) [\(mode)]",
            bodyLines: slice,
            footer: "줄 \(readerScrollOffset + 1)/\(max(1, doc.lines.count)) · ↑↓스크롤 · ←→문서 · 탭 자동"
        )
    }

    private func buildHeadUpPage() -> G2PageSpec {
        let liveLine = String(format: "실시간 각도: %+.1f° (기준 %.1f° · 변화 %+.1f°)", currentImu.pitchDegrees, neutralPitchDegrees, lastDeltaPitch)
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
        return buildStandardScreenPage(layoutKey: "screen_headup", title: "들어깨우기 (IMU)", bodyLines: body, footer: toastMessage ?? "↑↓이동 · ←→조절 · 탭 실행 · 더블탭 뒤로")
    }

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
        return buildStandardScreenPage(layoutKey: "screen_settings", title: "기기 설정 (\(settingsIndex + 1)/\(items.count))", bodyLines: body, footer: toastMessage ?? "↑↓이동 · ←→값조절 · 탭 실행 · 더블탭 뒤로")
    }

    // Minimalist Push-to-Talk fallback (for non-Studio screens)
    private func buildMicOverlayPage() -> G2PageSpec {
        G2StudioGraphics.renderHomePage(
            rc: makeStudioRenderContext(),
            alerts: alerts,
            recArticles: recommendedArticles()
        )
    }

    private func buildAlertPage(_ alert: G2ActiveAlert) -> G2PageSpec {
        let card = G2TextContainer(
            id: 1, name: "alert", x: 20, y: 24, width: 536, height: 240,
            text: [
                "  ★  \(alert.kind.rawValue)  ★",
                "  ────────────────────────────────",
                "",
                "  \(alert.title)",
                "",
                "  ▶ 한 번 탭: 알림 끄기",
                "  ▶ 더블탭:   5분 뒤 스누즈"
            ].joined(separator: "\n"),
            captureEvents: true, borderWidth: 4, borderColor: 15, borderRadius: 10, padding: 14
        )
        return G2PageSpec(layoutKey: "overlay_alert", textContainers: [card])
    }

    private func buildStandardScreenPage(layoutKey: String, title: String, bodyLines: [String], footer: String) -> G2PageSpec {
        let header = G2TextContainer(id: 1, name: "hdr", x: 12, y: 4, width: 552, height: 36, text: statusHeaderText(title: title), captureEvents: true, padding: 4)
        let body = G2TextContainer(id: 2, name: "body", x: 12, y: 44, width: 552, height: 192, text: bodyLines.joined(separator: "\n"), captureEvents: false, borderWidth: 1, borderColor: 9, borderRadius: 8, padding: 8)
        let foot = G2TextContainer(id: 3, name: "foot", x: 12, y: 242, width: 552, height: 40, text: footer, captureEvents: false, padding: 4)
        return G2PageSpec(layoutKey: layoutKey, textContainers: [header, body, foot])
    }
}
