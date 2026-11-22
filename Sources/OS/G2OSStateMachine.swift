import Foundation

/// Self-contained mini OS rendered onto the G2 576x288 EvenHub canvas.
/// Every screen supports full directional control (Up/Down/Left/Right), scrolling,
/// selection/back/home, and global G2 microphone toggle from any screen.
public final class G2OSStateMachine: ObservableObject {
    public enum Screen: String, CaseIterable {
        case home = "홈 런처"
        case dashboard = "대시보드"
        case reader = "스크롤 리더"
        case mic = "G2 마이크"
        case dpadTest = "4방향 테스트"
        case settings = "기기 설정"
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

    // Home 2x3 grid cursor (col: 0..1, row: 0..2)
    @Published public private(set) var homeRow: Int = 0
    @Published public private(set) var homeCol: Int = 0

    // Dashboard page (0..2)
    @Published public private(set) var dashboardPage: Int = 0

    // Scroll reader state
    @Published public var documents: [ReaderDocument] = [
        ReaderDocument(
            id: 0,
            title: "발표 대본 (테스트)",
            lines: [
                "1. 안녕하세요. Even G2 커스텀 OS 테스트입니다.",
                "2. 지금 이 화면은 아이폰이 화면 꺼짐 상태에서도",
                "3. Flic Duo 리모콘으로 실시간 제어됩니다.",
                "4. 큰 버튼 클릭은 선택, 더블클릭은 뒤로가기,",
                "5. 큰 버튼 길게 누르기는 G2 마이크 On/Off입니다.",
                "6. 작은 버튼 클릭은 아래로, 더블클릭은 위로,",
                "7. 스와이프는 상하좌우 4방향 이동입니다.",
                "8. 큰 버튼을 누른 채 손목을 비틀면(Twist)",
                "9. 이렇게 문서를 부드럽게 스크롤할 수 있습니다.",
                "10. 좌/우 방향키로 다른 문서로 전환해 보세요.",
                "11. 확인 버튼을 누르면 자동 스크롤이 토글됩니다.",
                "12. --- 문서 끝 (맨 아래 도달) ---"
            ]
        ),
        ReaderDocument(
            id: 1,
            title: "Flic Duo 조작법",
            lines: [
                "[큰 버튼 (Button 0)]",
                " - 클릭: 확인 / 선택",
                " - 더블클릭: 뒤로가기",
                " - 홀드: G2 내장 마이크 On/Off",
                " - 누르고 비틀기: 연속 스크롤 ↑↓",
                " - 누르고 스와이프: 상/하/좌/우 이동",
                "",
                "[작은 버튼 (Button 1)]",
                " - 클릭: 아래 / 다음 항목",
                " - 더블클릭: 위 / 이전 항목",
                " - 홀드: 홈 런처 (홈에선 절전)",
                " - 누르고 비틀기: G2 밝기 조절"
            ]
        )
    ]
    @Published public private(set) var readerDocIndex: Int = 0
    @Published public private(set) var readerScrollOffset: Int = 0
    @Published public private(set) var readerAutoScroll: Bool = false

    // 4-way D-pad & scroll test cursor
    @Published public private(set) var padX: Int = 5 // 0..10
    @Published public private(set) var padY: Int = 2 // 0..4
    @Published public private(set) var padScrollValue: Int = 0

    // Settings menu index (0..3)
    @Published public private(set) var settingsIndex: Int = 0

    // Telemetry mirror injected from BLE/Flic managers
    public var g2Battery: Int?
    public var flicVoltage: Float = 0
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
    private var lastClockMinute: String = ""

    private let homeGrid: [[(label: String, target: Screen?)]] = [
        [("1.대시보드", .dashboard), ("2.스크롤리더", .reader)],
        [("3.G2마이크", .mic), ("4.4방향패드", .dpadTest)],
        [("5.기기설정", .settings), ("6.화면절전", nil)]
    ]

    public init() {
        rebuildDisplay(pushToGlasses: false)
        startClockTick()
    }

    deinit {
        autoScrollTimer?.invalidate()
        clockTimer?.invalidate()
    }

    private func startClockTick() {
        clockTimer?.invalidate()
        clockTimer = Timer.scheduledTimer(withTimeInterval: 30.0, repeats: true) { [weak self] _ in
            guard let self, !self.isScreenAsleep else { return }
            let fmt = DateFormatter()
            fmt.dateFormat = "HH:mm"
            let nowMin = fmt.string(from: Date())
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
        if documents.count >= 3 {
            documents[2] = ReaderDocument(id: 2, title: title.isEmpty ? "사용자 메모" : title, lines: safeLines)
        } else {
            documents.append(ReaderDocument(id: 2, title: title.isEmpty ? "사용자 메모" : title, lines: safeLines))
        }
        if currentScreen == .reader {
            rebuildDisplay()
        }
    }

    public func handle(_ event: RemoteCommandEvent) {
        let entry = "[\(event.source.rawValue)] \(event.action.rawValue)" + (event.detail.isEmpty ? "" : " (\(event.detail))")
        lastActionSummary = entry
        recentActions.insert(entry, at: 0)
        if recentActions.count > 8 { recentActions.removeLast() }

        // If screen is asleep, any button wakes the G2 display immediately.
        if isScreenAsleep && event.action != .screenToggle {
            isScreenAsleep = false
            onSetScreenAsleep?(false)
            rebuildDisplay()
            return
        }

        // Global shortcuts that work on every screen
        switch event.action {
        case .micToggle:
            let next = !isMicOn
            isMicOn = next
            onToggleMic?(next)
            rebuildDisplay()
            return
        case .brightnessUp:
            brightness = min(50, brightness + 5)
            onSetBrightness?(brightness)
            rebuildDisplay()
            return
        case .brightnessDown:
            brightness = max(1, brightness - 5)
            onSetBrightness?(brightness)
            rebuildDisplay()
            return
        case .screenToggle:
            isScreenAsleep.toggle()
            onSetScreenAsleep?(isScreenAsleep)
            if !isScreenAsleep { rebuildDisplay() }
            return
        case .home:
            stopAutoScroll()
            if currentScreen == .home {
                isScreenAsleep = true
                onSetScreenAsleep?(true)
            } else {
                currentScreen = .home
                rebuildDisplay()
            }
            return
        default:
            break
        }

        // Screen-specific navigation
        switch currentScreen {
        case .home:
            handleHome(event.action)
        case .dashboard:
            handleDashboard(event.action)
        case .reader:
            handleReader(event.action)
        case .mic:
            handleMic(event.action)
        case .dpadTest:
            handleDpadTest(event.action)
        case .settings:
            handleSettings(event.action)
        }
        rebuildDisplay()
    }

    /// Re-renders the current G2 text frame (e.g. when battery or mic telemetry updates).
    public func refreshDisplay(pushToGlasses: Bool = true) {
        rebuildDisplay(pushToGlasses: pushToGlasses)
    }

    // MARK: - Per-Screen Handlers

    private func handleHome(_ action: RemoteAction) {
        switch action {
        case .up, .scrollUp:
            homeRow = (homeRow + 2) % 3
        case .down, .scrollDown:
            homeRow = (homeRow + 1) % 3
        case .left:
            homeCol = (homeCol + 1) % 2
        case .right:
            homeCol = (homeCol + 1) % 2
        case .select:
            let item = homeGrid[homeRow][homeCol]
            if let target = item.target {
                currentScreen = target
                if target == .settings { onQuerySettings?() }
            } else {
                isScreenAsleep = true
                onSetScreenAsleep?(true)
            }
        case .back:
            isScreenAsleep = true
            onSetScreenAsleep?(true)
        default:
            break
        }
    }

    private func handleDashboard(_ action: RemoteAction) {
        switch action {
        case .left, .up, .scrollUp:
            dashboardPage = (dashboardPage + 2) % 3
        case .right, .down, .scrollDown:
            dashboardPage = (dashboardPage + 1) % 3
        case .select:
            onQuerySettings?()
        case .back:
            currentScreen = .home
        default:
            break
        }
    }

    private func handleReader(_ action: RemoteAction) {
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
            currentScreen = .home
        default:
            break
        }
    }

    private func handleMic(_ action: RemoteAction) {
        switch action {
        case .select, .up, .down:
            let next = !isMicOn
            isMicOn = next
            onToggleMic?(next)
        case .right:
            onSaveMicRecording?()
        case .back, .left:
            currentScreen = .home
        default:
            break
        }
    }

    private func handleDpadTest(_ action: RemoteAction) {
        switch action {
        case .up:
            padY = max(0, padY - 1)
        case .down:
            padY = min(4, padY + 1)
        case .left:
            padX = max(0, padX - 1)
        case .right:
            padX = min(10, padX + 1)
        case .scrollUp:
            padScrollValue = min(100, padScrollValue + 5)
        case .scrollDown:
            padScrollValue = max(-100, padScrollValue - 5)
        case .select:
            padX = 5; padY = 2; padScrollValue = 0
        case .back:
            currentScreen = .home
        default:
            break
        }
    }

    private func handleSettings(_ action: RemoteAction) {
        switch action {
        case .up, .scrollUp:
            settingsIndex = (settingsIndex + 3) % 4
        case .down, .scrollDown:
            settingsIndex = (settingsIndex + 1) % 4
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
            case 3:
                isScreenAsleep = true
                onSetScreenAsleep?(true)
            default:
                break
            }
        case .back:
            currentScreen = .home
        default:
            break
        }
    }

    // MARK: - Auto-scroll helper

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
                let maxOffset = max(0, self.currentDocument.lines.count - 5)
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

    // MARK: - G2 576x288 Monochrome Canvas Renderer (~40 cols x 9 rows)

    private func rebuildDisplay(pushToGlasses: Bool = true) {
        let header = renderHeader()
        let body: String
        switch currentScreen {
        case .home: body = renderHome()
        case .dashboard: body = renderDashboard()
        case .reader: body = renderReader()
        case .mic: body = renderMic()
        case .dpadTest: body = renderDpadTest()
        case .settings: body = renderSettings()
        }
        let full = "\(header)\n\(body)"
        renderedFrameText = full
        if pushToGlasses && !isScreenAsleep {
            onRenderChanged?(full)
        }
    }

    private func renderHeader() -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "HH:mm"
        let timeStr = fmt.string(from: Date())
        let batStr = g2Battery.map { "\($0)%" } ?? "--%"
        let micTag = isMicOn ? " [●MIC]" : ""
        return "\(timeStr) | \(currentScreen.rawValue) | \(batStr)\(micTag)\n----------------------------------------"
    }

    private func renderHome() -> String {
        var rows: [String] = []
        for r in 0..<3 {
            let left = homeGrid[r][0].label
            let right = homeGrid[r][1].label
            let lCell = (homeRow == r && homeCol == 0) ? "▶[\(left)]" : "  \(left) "
            let rCell = (homeRow == r && homeCol == 1) ? "▶[\(right)]" : "  \(right) "
            rows.append("\(lCell)    \(rCell)")
        }
        rows.append("")
        rows.append("방향:상하좌우 | 클릭:선택 | 홀드:마이크")
        return rows.joined(separator: "\n")
    }

    private func renderDashboard() -> String {
        let flicStr = flicVoltage > 0 ? String(format: "%.2fV", flicVoltage) : "미연결"
        switch dashboardPage {
        case 0:
            let df = DateFormatter()
            df.dateFormat = "yyyy-MM-dd (E)"
            df.locale = Locale(identifier: "ko_KR")
            return [
                "날짜: \(df.string(from: Date()))",
                "G2 배터리: \(g2Battery.map { "\($0)%" } ?? "조회중") | 밝기: \(brightness)/50",
                "Flic 배터리: \(flicStr) | 무음: \(silentMode ? "ON" : "OFF")",
                "마이크: \(isMicOn ? "녹음중 (\(micPackets) pkt)" : "대기")",
                "",
                "[1/3] ◀ 좌/우로 페이지 전환 ▶"
            ].joined(separator: "\n")
        case 1:
            return [
                "[Flic Duo 퀵 가이드]",
                "큰버튼: 클릭=선택 / 더블=뒤로 / 홀드=마이크",
                "작은버튼: 클릭=↓ / 더블=↑ / 홀드=홈",
                "스와이프: ↑↓←→ | Twist: 연속스크롤",
                "",
                "[2/3] ◀ 좌/우로 페이지 전환 ▶"
            ].joined(separator: "\n")
        default:
            let recent = recentActions.prefix(4).map { "- \($0)" }
            let list = recent.isEmpty ? ["(아직 입력 없음)"] : Array(recent)
            return ([ "[최근 리모콘 입력]" ] + list + [ "[3/3] ◀ 좌/우 ▶ | 뒤로=홈" ]).joined(separator: "\n")
        }
    }

    private func renderReader() -> String {
        let doc = currentDocument
        let visible = 5
        let slice = Array(doc.lines.dropFirst(readerScrollOffset).prefix(visible))
        let playTag = readerAutoScroll ? "▶자동" : "⏸수동"
        let header = "◀ \(doc.title) (\(readerDocIndex + 1)/\(documents.count)) ▶ [\(playTag)]"
        let footer = "줄 \(readerScrollOffset + 1)/\(max(1, doc.lines.count)) | ↑↓스크롤 | 클릭:자동 | ←→문서"
        return ([header] + slice + [footer]).joined(separator: "\n")
    }

    private func renderMic() -> String {
        let sec = Double(micDurationMs) / 1000.0
        let levelNorm = max(0, min(10, Int(abs(Int(micSignal))) / 300))
        let bar = String(repeating: "█", count: levelNorm) + String(repeating: "░", count: 10 - levelNorm)
        return [
            "상태: \(isMicOn ? "● G2 마이크 수신 중 (LC3 16kHz)" : "○ 대기 중")",
            String(format: "수신: %d pkt (%.1f초)", micPackets, sec),
            "신호: [\(bar)] (\(micSignal)) | 방향: \(micDOA)°",
            "",
            "클릭/홀드: 마이크 On/Off",
            "오른쪽(→): .lc3 녹음 저장 | 뒤로: 홈"
        ].joined(separator: "\n")
    }

    private func renderDpadTest() -> String {
        var gridLines: [String] = []
        for y in 0..<5 {
            var line = ""
            for x in 0..<11 {
                line += (x == padX && y == padY) ? "◆" : "·"
            }
            if y == 0 { line += "  좌표:(\(padX),\(padY))" }
            if y == 1 { line += "  스크롤:\(padScrollValue)" }
            if y == 2 { line += "  클릭:리셋" }
            if y == 3 { line += "  뒤로:홈" }
            gridLines.append(line)
        }
        gridLines.append("최근: \(lastActionSummary)")
        return gridLines.joined(separator: "\n")
    }

    private func renderSettings() -> String {
        let items = [
            "밝기 조절: < \(brightness) / 50 >",
            "무음 모드: \(silentMode ? "[ON]" : "[OFF]")",
            "배터리/펌웨어 새로고침",
            "G2 화면 절전 모드로 전환"
        ]
        var lines = items.enumerated().map { idx, text in
            idx == settingsIndex ? "▶ \(text)" : "  \(text)"
        }
        lines.append("")
        lines.append("↑↓이동 | ←→값변경 | 클릭:실행 | 뒤로:홈")
        return lines.joined(separator: "\n")
    }
}
