import Foundation

/// Clean, self-contained G2 OS rendered onto the 576x288 monochrome EvenHub canvas.
/// Built from a crisp 2x2 Home Launcher with global Push-to-Talk microphone HUD
/// and Always-On protection (never accidentally drops back to the stock G2 OS).
public final class G2OSStateMachine: ObservableObject {
    public enum Screen: String, CaseIterable {
        case home = "홈"
        case agent = "AI 에이전트"
        case reader = "메모 리더"
        case briefing = "오늘 브리핑"
        case settings = "시스템 설정"
    }

    public struct ReaderDocument: Identifiable, Equatable {
        public let id: Int
        public let title: String
        public var lines: [String]
    }

    @Published public private(set) var currentScreen: Screen = .home
    @Published public private(set) var renderedFrameText: String = ""
    @Published public private(set) var lastActionSummary: String = "대기 중"
    @Published public private(set) var recentActions: [String] = []
    @Published public private(set) var toastMessage: String?

    // Home 2x2 launcher cursor (row: 0..1, col: 0..1)
    @Published public private(set) var homeRow: Int = 0
    @Published public private(set) var homeCol: Int = 0

    // AI Agent / Push-to-Talk history summary
    @Published public private(set) var lastVoiceSummary: String = "아직 음성 입력 없음"

    // Memo / Scroll Reader documents
    @Published public var documents: [ReaderDocument] = [
        ReaderDocument(
            id: 0,
            title: "시작 가이드",
            lines: [
                "1. G2 OS에 오신 것을 환영합니다.",
                "2. 화면 전체가 모션 패드로 동작합니다.",
                "3. 상·하·좌·우 스와이프로 이동하고,",
                "4. 한 번 탭하면 선택, 두 번 탭하면 뒤로,",
                "5. 길게 누르면 G2 마이크가 열립니다.",
                "6. 손을 떼면 마이크가 즉시 닫힙니다.",
                "7. 설정에서 나만의 메모를 추가하면",
                "8. 좌/우 스와이프로 전환해 읽을 수 있습니다."
            ]
        ),
        ReaderDocument(
            id: 1,
            title: "내 메모",
            lines: [
                "설정 > 메모 편집에서 내용을 수정하면",
                "이 화면에 바로 반영됩니다.",
                "",
                "위/아래 스와이프로 스크롤하고,",
                "한 번 탭하면 자동 스크롤이 켜집니다."
            ]
        )
    ]
    @Published public private(set) var readerDocIndex: Int = 0
    @Published public private(set) var readerScrollOffset: Int = 0
    @Published public private(set) var readerAutoScroll: Bool = false

    // Settings cursor (0..2)
    @Published public private(set) var settingsIndex: Int = 0

    // Telemetry mirror injected from BLE/Flic managers
    public var g2Battery: Int?
    public var g2Charging: Bool = false
    public var g2Firmware: String = "-"
    public var flicConnected: Bool = false
    public var flicVoltage: Float = 0
    public var alwaysOnEnabled: Bool = true
    public var isMicOn: Bool = false
    public var micPackets: Int = 0
    public var micDurationMs: Int = 0
    public var micSignal: Int16 = 0
    public var micDOA: Int16 = 0
    public var brightness: Int = 25
    public var silentMode: Bool = false
    public var isScreenAsleep: Bool = false

    // Outbound hardware callbacks
    public var onRenderChanged: ((String) -> Void)?
    public var onToggleMic: ((Bool) -> Void)?
    public var onSaveMicRecording: (() -> Void)?
    public var onSetBrightness: ((Int) -> Void)?
    public var onSetSilentMode: ((Bool) -> Void)?
    public var onQuerySettings: (() -> Void)?
    public var onSetScreenAsleep: ((Bool) -> Void)?

    private var autoScrollTimer: Timer?
    private var clockTimer: Timer?
    private var toastClearWorkItem: DispatchWorkItem?
    private var lastClockMinute: String = ""

    private let homeGrid: [[(label: String, target: Screen)]] = [
        [("AI 에이전트", .agent), ("메모 리더", .reader)],
        [("오늘 브리핑", .briefing), ("시스템 설정", .settings)]
    ]

    public init() {
        rebuildDisplay(pushToGlasses: false)
        startClockTick()
    }

    deinit {
        autoScrollTimer?.invalidate()
        clockTimer?.invalidate()
        toastClearWorkItem?.cancel()
    }

    private func startClockTick() {
        clockTimer?.invalidate()
        clockTimer = Timer.scheduledTimer(withTimeInterval: 20.0, repeats: true) { [weak self] _ in
            guard let self, !self.isScreenAsleep else { return }
            let nowMin = self.formattedClock()
            if nowMin != self.lastClockMinute {
                self.lastClockMinute = nowMin
                self.rebuildDisplay(pushToGlasses: true)
            }
        }
    }

    public func updateCustomDocument(title: String, body: String) {
        let lines = body
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .newlines) }
        let safeLines = lines.isEmpty ? ["(내용 없음)"] : lines
        let doc = ReaderDocument(id: 1, title: title.isEmpty ? "내 메모" : title, lines: safeLines)
        if documents.count >= 2 {
            documents[1] = doc
        } else {
            documents.append(doc)
        }
        if currentScreen == .reader {
            readerScrollOffset = 0
            rebuildDisplay()
        }
    }

    public func handle(_ event: RemoteCommandEvent) {
        let entry = "[\(event.source.rawValue)] \(event.action.rawValue)" + (event.detail.isEmpty ? "" : " (\(event.detail))")
        lastActionSummary = entry
        recentActions.insert(entry, at: 0)
        if recentActions.count > 10 { recentActions.removeLast() }

        // If asleep, any input wakes our OS immediately.
        if isScreenAsleep && event.action != .screenToggle {
            isScreenAsleep = false
            onSetScreenAsleep?(false)
            rebuildDisplay()
            return
        }

        // Global Push-to-Talk & system actions (available on every screen)
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
                showToast("항시 OS 유지 활성화됨")
                rebuildDisplay()
            } else {
                isScreenAsleep.toggle()
                onSetScreenAsleep?(isScreenAsleep)
                if !isScreenAsleep { rebuildDisplay() }
            }
            return
        case .home:
            stopAutoScroll()
            currentScreen = .home
            rebuildDisplay()
            return
        default:
            break
        }

        // While Push-to-Talk mic is actively open, ignore accidental navigation inputs.
        if isMicOn {
            return
        }

        // Per-screen navigation
        switch currentScreen {
        case .home:
            handleHome(event.action)
        case .agent:
            handleAgent(event.action)
        case .reader:
            handleReader(event.action)
        case .briefing:
            handleBriefing(event.action)
        case .settings:
            handleSettings(event.action)
        }
        rebuildDisplay()
    }

    /// Re-renders the current G2 canvas frame (e.g. when battery or mic telemetry updates).
    public func refreshDisplay(pushToGlasses: Bool = true) {
        rebuildDisplay(pushToGlasses: pushToGlasses)
    }

    // MARK: - Push-to-Talk Mic Handling

    private func setMicActive(_ enabled: Bool) {
        guard enabled != isMicOn else { return }
        if enabled {
            isMicOn = true
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
                let summary = String(format: "최근 음성 %.1f초 (%d pkt)", capturedSec, capturedPackets)
                lastVoiceSummary = summary
                showToast(String(format: "음성 수집 완료 (%.1f초)", capturedSec))
            } else {
                showToast("마이크 닫힘")
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
            if !self.isMicOn && !self.isScreenAsleep {
                self.rebuildDisplay(pushToGlasses: true)
            }
        }
        toastClearWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }

    // MARK: - Per-Screen Handlers

    private func handleHome(_ action: RemoteAction) {
        switch action {
        case .up, .scrollUp, .down, .scrollDown:
            homeRow = (homeRow + 1) % 2
        case .left, .right:
            homeCol = (homeCol + 1) % 2
        case .select:
            let target = homeGrid[homeRow][homeCol].target
            currentScreen = target
            if target == .briefing || target == .settings {
                onQuerySettings?()
            }
        case .back:
            // Stay cleanly on Home — never sleep or exit to the stock G2 OS.
            break
        default:
            break
        }
    }

    private func handleAgent(_ action: RemoteAction) {
        switch action {
        case .select:
            showToast("길게 눌러 G2 마이크로 말하세요")
        case .back:
            currentScreen = .home
        default:
            break
        }
    }

    private func handleReader(_ action: RemoteAction) {
        let lines = currentDocument.lines
        let visibleLines = 4
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
            currentScreen = .home
        default:
            break
        }
    }

    private func handleBriefing(_ action: RemoteAction) {
        switch action {
        case .select:
            onQuerySettings?()
            showToast("기기 상태 새로고침")
        case .back:
            currentScreen = .home
        default:
            break
        }
    }

    private func handleSettings(_ action: RemoteAction) {
        switch action {
        case .up, .scrollUp:
            settingsIndex = (settingsIndex + 2) % 3
        case .down, .scrollDown:
            settingsIndex = (settingsIndex + 1) % 3
        case .left:
            if settingsIndex == 0 {
                brightness = max(1, brightness - 5)
                onSetBrightness?(brightness)
            } else if settingsIndex == 1 {
                silentMode.toggle()
                onSetSilentMode?(silentMode)
            }
        case .right:
            if settingsIndex == 0 {
                brightness = min(50, brightness + 5)
                onSetBrightness?(brightness)
            } else if settingsIndex == 1 {
                silentMode.toggle()
                onSetSilentMode?(silentMode)
            }
        case .select:
            switch settingsIndex {
            case 0:
                brightness = (brightness >= 50) ? 10 : min(50, brightness + 10)
                onSetBrightness?(brightness)
            case 1:
                silentMode.toggle()
                onSetSilentMode?(silentMode)
            case 2:
                onQuerySettings?()
                showToast("상태 조회 요청")
            default:
                break
            }
        case .back:
            currentScreen = .home
        default:
            break
        }
    }

    // MARK: - Auto-Scroll Helper

    private func toggleAutoScroll() {
        if readerAutoScroll {
            stopAutoScroll()
        } else {
            readerAutoScroll = true
            autoScrollTimer?.invalidate()
            autoScrollTimer = Timer.scheduledTimer(withTimeInterval: 1.8, repeats: true) { [weak self] _ in
                guard let self, self.currentScreen == .reader else {
                    self?.stopAutoScroll()
                    return
                }
                let maxOffset = max(0, self.currentDocument.lines.count - 4)
                if self.readerScrollOffset < maxOffset {
                    self.readerScrollOffset += 1
                } else {
                    self.readerScrollOffset = 0
                }
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

    // MARK: - G2 576x288 Monochrome Canvas Renderer

    private func rebuildDisplay(pushToGlasses: Bool = true) {
        let header = renderHeader()
        let body: String
        if isMicOn {
            body = renderMicOverlay()
        } else {
            switch currentScreen {
            case .home: body = renderHome()
            case .agent: body = renderAgent()
            case .reader: body = renderReader()
            case .briefing: body = renderBriefing()
            case .settings: body = renderSettings()
            }
        }
        let full = "\(header)\n\(body)"
        renderedFrameText = full
        if pushToGlasses && !isScreenAsleep {
            onRenderChanged?(full)
        }
    }

    private func formattedClock() -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "HH:mm"
        return fmt.string(from: Date())
    }

    private func formattedShortDate() -> String {
        let df = DateFormatter()
        df.dateFormat = "M/d (E)"
        df.locale = Locale(identifier: "ko_KR")
        return df.string(from: Date())
    }

    private func renderHeader() -> String {
        let timeStr = formattedClock()
        lastClockMinute = timeStr
        let batStr = g2Battery.map { "\(g2Charging ? "+" : "")\($0)%" } ?? "--%"
        let center: String
        if isMicOn {
            center = "● MIC 듣는 중"
        } else if currentScreen == .home {
            center = formattedShortDate()
        } else {
            center = currentScreen.rawValue
        }
        return "\(timeStr)   \(center)   \(batStr)\n──────────────────────────"
    }

    private func renderHome() -> String {
        func cell(_ r: Int, _ c: Int) -> String {
            let label = homeGrid[r][c].label
            return (homeRow == r && homeCol == c) ? "▶ [\(label)]" : "   \(label) "
        }

        let statusLine = toastMessage.map { "  · \($0)" } ?? "  G2 OS"
        return [
            statusLine,
            "",
            "\(cell(0, 0))   \(cell(0, 1))",
            "\(cell(1, 0))   \(cell(1, 1))",
            "",
            "스와이프 이동 · 탭 선택 · 홀드 마이크"
        ].joined(separator: "\n")
    }

    private func renderMicOverlay() -> String {
        let sec = Double(micDurationMs) / 1000.0
        let levelNorm = max(0, min(10, Int(abs(Int(micSignal))) / 280))
        let bar = String(repeating: "█", count: levelNorm) + String(repeating: "░", count: 10 - levelNorm)
        let secText = String(format: "%.1f", sec)
        return [
            "",
            "  ● 말씀하세요 (손 떼면 종료)",
            "",
            "  신호 [\(bar)]  \(secText)초",
            "  수신 \(micPackets) pkt · 방향 \(micDOA)°"
        ].joined(separator: "\n")
    }

    private func renderAgent() -> String {
        let status = toastMessage ?? "대기 중 · 길게 눌러 음성 입력"
        return [
            "  Antigravity Dots 음성 허브",
            "",
            "  상태: \(status)",
            "  \(lastVoiceSummary)",
            "",
            "길게 누르기: 말하기 · 더블탭: 홈"
        ].joined(separator: "\n")
    }

    private func renderReader() -> String {
        let doc = currentDocument
        let visible = 4
        let slice = Array(doc.lines.dropFirst(readerScrollOffset).prefix(visible))
        let playTag = readerAutoScroll ? "자동" : "수동"
        let top = "◀ \(doc.title) (\(readerDocIndex + 1)/\(documents.count)) ▶ [\(playTag)]"
        let footer = "줄 \(readerScrollOffset + 1)/\(max(1, doc.lines.count)) · ↑↓스크롤 · 더블탭 홈"
        return ([top] + slice + [footer]).joined(separator: "\n")
    }

    private func renderBriefing() -> String {
        let df = DateFormatter()
        df.dateFormat = "yyyy년 M월 d일 (E)"
        df.locale = Locale(identifier: "ko_KR")
        let bat = g2Battery.map { "\($0)%\(g2Charging ? " 충전중" : "")" } ?? "조회 중"
        let flic = flicConnected ? String(format: "연결 (%.2fV)", flicVoltage) : "대기"
        let lock = alwaysOnEnabled ? "항시 유지 ON" : "일반 모드"
        return [
            "  \(df.string(from: Date()))",
            "  G2 배터리: \(bat) · 밝기 \(brightness)/50",
            "  OS 보호: \(lock) · 무음 \(silentMode ? "ON" : "OFF")",
            "  리모콘: \(flic)",
            "",
            "탭: 새로고침 · 더블탭: 홈"
        ].joined(separator: "\n")
    }

    private func renderSettings() -> String {
        let items = [
            "화면 밝기   < \(brightness) / 50 >",
            "무음 모드   [\(silentMode ? "ON" : "OFF")]",
            "배터리 · 펌웨어 새로고침"
        ]
        var lines = items.enumerated().map { idx, text in
            idx == settingsIndex ? "▶ \(text)" : "   \(text)"
        }
        lines.append("")
        if let toast = toastMessage {
            lines.append("  · \(toast)")
        } else {
            lines.append("↑↓이동 · ←→조절 · 탭 실행 · 더블탭 홈")
        }
        return lines.joined(separator: "\n")
    }
}
