import Foundation
import flic2lib

/// Native background driver for Flic Duo (and Flic 2) using the official `flic2lib-ios` framework.
/// Runs with `background: true` so button clicks, swipes, holds, and push-twist gestures wake the
/// iOS app immediately even when the iPhone screen is completely locked and turned off.
public final class FlicDuoDriver: NSObject, ObservableObject {
    @Published public private(set) var managerStateText: String = "초기화 중..."
    @Published public private(set) var isScanning: Bool = false
    @Published public private(set) var pairedButtonName: String?
    @Published public private(set) var isDuoHardware: Bool = false
    @Published public private(set) var isConnected: Bool = false
    @Published public private(set) var isReady: Bool = false
    @Published public private(set) var batteryVoltage: Float = 0
    @Published public private(set) var lastRawEventText: String = "없음"

    public var onAction: ((RemoteCommandEvent) -> Void)?
    public var onLog: ((String) -> Void)?

    private var activeButton: FLICButton?
    private var twistAccumulator: Int32 = 0
    private let twistStepThreshold: Int32 = 4096 // ~22.5 degrees (65536 = full 360 deg turn)

    public override init() {
        super.init()
    }

    /// Must be called as early as possible during app launch (including background launches)
    /// so iOS CoreBluetooth state restoration delivers pending button clicks without delay.
    public func configure() {
        _ = FLICManager.configure(with: self, buttonDelegate: self, background: true)
        emitLog("[Flic] FLICManager 백그라운드 모드로 초기화 완료")
    }

    public func startScan() {
        guard let manager = FLICManager.shared() else {
            emitLog("[Flic] Manager가 초기화되지 않았습니다.")
            return
        }
        guard !isScanning else { return }
        DispatchQueue.main.async { self.isScanning = true }
        emitLog("[Flic] Flic Duo / Flic 2 스캔 시작 (리모콘 버튼을 6초 이상 길게 눌러 페어링 모드로 진입하세요)")

        manager.scanForButtons(stateChangeHandler: { [weak self] event in
            guard let self else { return }
            switch event {
            case .discovered:
                self.emitLog("[Flic] 기기 발견! 연결 시도 중...")
            case .connected:
                self.emitLog("[Flic] BLE 연결됨 → 인증 확인 중...")
            case .verified:
                self.emitLog("[Flic] 정품 인증 및 페어링 완료!")
            case .verificationFailed:
                self.emitLog("[Flic] 인증 실패 — 다시 시도해 주세요.")
            @unknown default:
                break
            }
        }, completion: { [weak self] button, error in
            guard let self else { return }
            DispatchQueue.main.async { self.isScanning = false }
            if let error {
                self.emitLog("[Flic] 스캔 종료/오류: \(error.localizedDescription)")
                return
            }
            if let button {
                self.bind(button: button)
            }
        })
    }

    public func stopScan() {
        FLICManager.shared()?.stopScan()
        DispatchQueue.main.async { self.isScanning = false }
        emitLog("[Flic] 스캔 중지")
    }

    public func forgetPairedButton() {
        guard let manager = FLICManager.shared(), let button = activeButton else { return }
        manager.forgetButton(button) { [weak self] _, error in
            guard let self else { return }
            if let error {
                self.emitLog("[Flic] 연결 해제 실패: \(error.localizedDescription)")
                return
            }
            self.activeButton = nil
            DispatchQueue.main.async {
                self.pairedButtonName = nil
                self.isDuoHardware = false
                self.isConnected = false
                self.isReady = false
                self.batteryVoltage = 0
            }
            self.emitLog("[Flic] 페어링된 리모콘 삭제 완료")
        }
    }

    /// Plays tactile/audible confirmation beeps on the Flic Duo built-in buzzer (firmware >= 20).
    public func playBuzzerFeedback(micEnabled: Bool) {
        #if !targetEnvironment(simulator)
        guard let button = activeButton, button.isReady, button.isFlicDuo() else { return }
        let notes: [FLICButtonBuzzerNote]
        if micEnabled {
            notes = [FLICButtonBuzzerNote(hz: 2400, duration: 55)]
        } else {
            notes = [
                FLICButtonBuzzerNote(hz: 1800, duration: 40),
                FLICButtonBuzzerNote(hz: 0, duration: 35),
                FLICButtonBuzzerNote(hz: 1300, duration: 50)
            ]
        }
        button.playBuzzerSound(notes)
        #endif
    }

    public func testBuzzer() {
        #if !targetEnvironment(simulator)
        guard let button = activeButton, button.isReady, button.isFlicDuo() else {
            emitLog("[Flic] 버저 테스트는 연결된 Flic Duo에서만 동작합니다.")
            return
        }
        button.playBuzzerSound([
            FLICButtonBuzzerNote(hz: 2000, duration: 50),
            FLICButtonBuzzerNote(hz: 0, duration: 40),
            FLICButtonBuzzerNote(hz: 2600, duration: 60)
        ])
        emitLog("[Flic] Flic Duo 버저 테스트 재생")
        #else
        emitLog("[Flic] 시뮬레이터에서는 버저 테스트를 건너뜁니다.")
        #endif
    }

    // MARK: - Internal Binding & Gesture Mapping

    private func bind(button: FLICButton) {
        activeButton = button
        button.delegate = self
        button.triggerMode = .clickAndDoubleClickAndHold
        button.connect()

        let duo = button.isFlicDuo()
        DispatchQueue.main.async {
            self.pairedButtonName = button.nickname ?? button.name ?? button.serialNumber
            self.isDuoHardware = duo
            self.isConnected = (button.state == .connected)
            self.isReady = button.isReady
            self.batteryVoltage = button.batteryVoltage
        }
        emitLog("[Flic] 바인딩 완료: \(button.name ?? button.serialNumber) (\(duo ? "Flic Duo" : "Flic 2"))")
    }

    private func handleStructuredEvent(_ event: FLICButtonEvent) {
        // Ignore stale queued events older than 5 seconds after reconnect.
        if event.wasQueued && event.age > 5.0 { return }

        // Listen strictly to one event class so each physical press triggers exactly once.
        guard event.eventClass == .singleOrDoubleClickOrHold else { return }

        let btnLabel = (event.buttonNumber == 0) ? "큰버튼(0)" : "작은버튼(1)"

        // 1. Directional swipe gesture (Flic Duo motion sensor: Left/Right/Up/Down)
        switch event.gesture {
        case .up:
            dispatch(.up, detail: "\(btnLabel) 스와이프 ↑")
            return
        case .down:
            dispatch(.down, detail: "\(btnLabel) 스와이프 ↓")
            return
        case .left:
            dispatch(.left, detail: "\(btnLabel) 스와이프 ←")
            return
        case .right:
            dispatch(.right, detail: "\(btnLabel) 스와이프 →")
            return
        default:
            break
        }

        // 2. Standard Click / DoubleClick / Hold per physical button
        if event.buttonNumber == 0 {
            // Big Button (0): Select / Back / Mic Toggle
            switch event.type {
            case .singleClick, .click:
                dispatch(.select, detail: "\(btnLabel) 클릭")
            case .doubleClick:
                dispatch(.back, detail: "\(btnLabel) 더블클릭")
            case .hold:
                dispatch(.micToggle, detail: "\(btnLabel) 홀드(마이크)")
            default:
                break
            }
        } else {
            // Small Button (1): Scroll Down / Scroll Up / Home
            switch event.type {
            case .singleClick, .click:
                dispatch(.down, detail: "\(btnLabel) 클릭(아래)")
            case .doubleClick:
                dispatch(.up, detail: "\(btnLabel) 더블클릭(위)")
            case .hold:
                dispatch(.home, detail: "\(btnLabel) 홀드(홈)")
            default:
                break
            }
        }
    }

    private func dispatch(_ action: RemoteAction, detail: String) {
        DispatchQueue.main.async {
            self.lastRawEventText = "\(detail) → \(action.rawValue)"
            self.onAction?(RemoteCommandEvent(action: action, source: .flicDuo, detail: detail))
        }
    }

    private func emitLog(_ msg: String) {
        DispatchQueue.main.async { self.onLog?(msg) }
    }
}

// MARK: - FLICManagerDelegate

extension FlicDuoDriver: FLICManagerDelegate {
    public func managerDidRestoreState(_ manager: FLICManager) {
        let buttons = manager.buttons()
        emitLog("[Flic] 백그라운드 상태 복원됨 (등록된 버튼 \(buttons.count)개)")
        if let first = buttons.first {
            bind(button: first)
        }
    }

    public func manager(_ manager: FLICManager, didUpdate state: FLICManagerState) {
        let text: String
        switch state {
        case .poweredOn: text = "준비됨 (BLE ON)"
        case .poweredOff: text = "블루투스 꺼짐"
        case .unauthorized: text = "블루투스 권한 거부"
        case .unsupported: text = "BLE 미지원"
        case .resetting: text = "재설정 중..."
        case .unknown: text = "알 수 없음"
        @unknown default: text = "기타"
        }
        DispatchQueue.main.async { self.managerStateText = text }
    }
}

// MARK: - FLICButtonDelegate

extension FlicDuoDriver: FLICButtonDelegate {
    public func buttonDidConnect(_ button: FLICButton) {
        DispatchQueue.main.async { self.isConnected = true }
        emitLog("[Flic] 연결됨 (암호화 인증 진행 중)")
    }

    public func buttonIsReady(_ button: FLICButton) {
        DispatchQueue.main.async {
            self.isConnected = true
            self.isReady = true
            self.isDuoHardware = button.isFlicDuo()
            self.batteryVoltage = button.batteryVoltage
        }
        if button.isFlicDuo() {
            // Enable Push & Twist on both Duo buttons (big = continuous scroll, small = brightness).
            button.enableDuoPushTwist(forBigButton: true, smallButton: true)
            emitLog("[Flic] Flic Duo 준비 완료! (2버튼 + 4방향 스와이프 + Push & Twist 활성)")
        } else {
            emitLog("[Flic] Flic 2 준비 완료!")
        }
    }

    public func button(_ button: FLICButton, didDisconnectWithError error: Error?) {
        DispatchQueue.main.async {
            self.isConnected = false
            self.isReady = false
        }
        emitLog("[Flic] 연결 끊김: \(error?.localizedDescription ?? "정상") (버튼 누르면 자동 재연결)")
    }

    public func button(_ button: FLICButton, didFailToConnectWithError error: Error?) {
        DispatchQueue.main.async {
            self.isConnected = false
            self.isReady = false
        }
        emitLog("[Flic] 연결 실패: \(error?.localizedDescription ?? "알 수 없음")")
    }

    public func button(_ button: FLICButton, didReceive event: FLICButtonEvent) {
        handleStructuredEvent(event)
    }

    public func button(
        _ button: FLICButton,
        didReceiveDuoPushTwistNotification buttonInfo: [FLICDuoPushTwistNotificationButtonInfo],
        angleDiff: Int32
    ) {
        guard buttonInfo.count >= 2 else { return }
        let big = buttonInfo[0]
        let small = buttonInfo[1]

        if big.isFirstEvent || small.isFirstEvent {
            twistAccumulator = 0
            return
        }

        twistAccumulator += angleDiff
        while abs(twistAccumulator) >= twistStepThreshold {
            let positive = twistAccumulator > 0
            twistAccumulator += positive ? -twistStepThreshold : twistStepThreshold

            if big.isPressed {
                dispatch(positive ? .scrollDown : .scrollUp, detail: "큰버튼 Twist \(positive ? "↻" : "↺")")
            } else if small.isPressed {
                dispatch(positive ? .brightnessUp : .brightnessDown, detail: "작은버튼 Twist \(positive ? "↻" : "↺")")
            }
        }
    }

    public func button(_ button: FLICButton, didUnpairWithError error: Error?) {
        DispatchQueue.main.async {
            self.isConnected = false
            self.isReady = false
        }
        emitLog("[Flic] 페어링 만료됨 — 다시 스캔해서 연결해 주세요.")
    }

    public func button(_ button: FLICButton, didUpdateBatteryVoltage voltage: Float) {
        DispatchQueue.main.async { self.batteryVoltage = voltage }
    }
}
