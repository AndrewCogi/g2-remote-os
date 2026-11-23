import Foundation
import GameController

/// Minimalist native iOS GameController + GCKeyboard driver for left-handed **8BitDo Micro**
/// held 90° clockwise (D-Pad on top, short inner triggers `L2`/`R2` under left index/middle fingers).
///
/// Active controls ONLY (all other buttons — L1/R1, ABXY, -/+, Home — are completely ignored):
/// - **D-Pad (90° CW auto-rotated):** `↑ ↓ ← →` (+ smooth auto-repeat on hold)
/// - **Short `L2` (`leftTrigger`, Left Index):** 0ms click = Open (`.select`), Hold/Release = AI (`.micStart`/`.micStop`)
/// - **Short `R2` (`rightTrigger`, Left Middle):** 0ms click = Back / Close (`.back`)
public final class GameControllerDriver: ObservableObject {
    @Published public private(set) var isConnected: Bool = false
    @Published public private(set) var controllerName: String = "연결 대기 중"
    @Published public private(set) var connectionModeLabel: String = "대기"
    @Published public private(set) var lastButtonLabel: String = "-"
    @Published public private(set) var isGCKeyboardConnected: Bool = false

    public var onAction: ((RemoteCommandEvent) -> Void)?
    public var onLog: ((String) -> Void)?

    private enum PhysicalDirection { case up, down, left, right }

    private var l2IsDown = false
    private var l2DidFireAI = false
    private var l2HoldWork: DispatchWorkItem?

    private var observers: [NSObjectProtocol] = []
    private var activeDirectionAction: RemoteAction?
    private var activeDirectionLabel: String = ""
    private var repeatDelayWork: DispatchWorkItem?
    private var repeatTimer: Timer?
    private var stickLastPhysicalDir: PhysicalDirection?

    public init() {}

    deinit {
        resetAllInputStates()
        for token in observers {
            NotificationCenter.default.removeObserver(token)
        }
    }

    public func start() {
        guard observers.isEmpty else { return }

        let nc = NotificationCenter.default
        observers.append(
            nc.addObserver(forName: .GCControllerDidConnect, object: nil, queue: .main) { [weak self] note in
                guard let self, let controller = note.object as? GCController else { return }
                self.attachGamepad(controller)
            }
        )
        observers.append(
            nc.addObserver(forName: .GCControllerDidDisconnect, object: nil, queue: .main) { [weak self] note in
                guard let self else { return }
                let name = (note.object as? GCController)?.vendorName ?? "컨트롤러"
                self.handleDisconnectCleanup()
                self.onLog?("[8BitDo Micro] 연결 해제: \(name)")
                self.refreshConnectionSummary()
            }
        )
        observers.append(
            nc.addObserver(forName: .GCKeyboardDidConnect, object: nil, queue: .main) { [weak self] _ in
                self?.attachKeyboard()
            }
        )
        observers.append(
            nc.addObserver(forName: .GCKeyboardDidDisconnect, object: nil, queue: .main) { [weak self] _ in
                guard let self else { return }
                self.handleDisconnectCleanup()
                self.isGCKeyboardConnected = false
                self.onLog?("[8BitDo Micro] 키보드 모드 해제")
                self.refreshConnectionSummary()
            }
        )

        for controller in GCController.controllers() {
            attachGamepad(controller)
        }
        if GCKeyboard.coalesced != nil {
            attachKeyboard()
        }
        refreshConnectionSummary()
    }

    private func resetAllInputStates() {
        stopRepeat()
        l2HoldWork?.cancel()
        l2HoldWork = nil
        l2IsDown = false
        l2DidFireAI = false
    }

    private func handleDisconnectCleanup() {
        let wasHoldingAI = l2DidFireAI
        resetAllInputStates()
        if wasHoldingAI {
            emit(.micStop, detail: "연결 끊김")
        }
    }

    // MARK: - Left-Handed 90° CW D-Pad Rotation (D-Pad on Top)

    private func mapDirection(_ phys: PhysicalDirection) -> (RemoteAction, String) {
        // 90° CW: physical Left -> Up, Right -> Down, Down -> Left, Up -> Right
        switch phys {
        case .left:  return (.up, "↑")
        case .right: return (.down, "↓")
        case .down:  return (.left, "←")
        case .up:    return (.right, "→")
        }
    }

    // MARK: - Short L2 (0ms Open / Hold AI) & Short R2 (0ms Back)

    private func handleShortL2(pressed: Bool) {
        if pressed {
            guard !l2IsDown else { return }
            l2IsDown = true
            l2DidFireAI = false
            l2HoldWork?.cancel()

            let work = DispatchWorkItem { [weak self] in
                guard let self, self.l2IsDown else { return }
                self.l2DidFireAI = true
                self.emit(.micStart, detail: "L2 꾹 (AI)")
            }
            l2HoldWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.36, execute: work)
        } else {
            guard l2IsDown else { return }
            l2IsDown = false
            l2HoldWork?.cancel()
            l2HoldWork = nil

            if l2DidFireAI {
                l2DidFireAI = false
                emit(.micStop, detail: "L2 뗌 (전송)")
            } else {
                emit(.select, detail: "L2 (열기)")
            }
        }
    }

    private func handleShortR2(pressed: Bool) {
        guard pressed else { return }
        emit(.back, detail: "R2 (뒤로)")
    }

    // MARK: - Gamepad Attachment (8BitDo Micro `S` Switch Mode)

    private func attachGamepad(_ controller: GCController) {
        let name = controller.vendorName ?? controller.productCategory
        onLog?("[8BitDo Micro] 연결됨: \(name) (왼손 세로 · 십자 + L2/R2)")

        if let pad = controller.extendedGamepad {
            pad.dpad.valueChangedHandler = { [weak self] _, xValue, yValue in
                self?.handleDirectionalAxis(x: xValue, y: yValue, prefix: "십자")
            }
            pad.leftThumbstick.valueChangedHandler = { [weak self] _, xValue, yValue in
                guard let self else { return }
                let threshold: Float = 0.65
                let phys: PhysicalDirection?
                if abs(yValue) >= abs(xValue) {
                    if yValue > threshold { phys = .up }
                    else if yValue < -threshold { phys = .down }
                    else { phys = nil }
                } else {
                    if xValue < -threshold { phys = .left }
                    else if xValue > threshold { phys = .right }
                    else { phys = nil }
                }
                if phys != self.stickLastPhysicalDir {
                    self.stickLastPhysicalDir = phys
                    if let p = phys {
                        let (action, sym) = self.mapDirection(p)
                        self.beginDirectionHold(action, detail: "십자 \(sym)")
                    } else {
                        self.stopRepeat()
                    }
                }
            }

            // ONLY short inner shoulders L2 / R2 are bound; all other buttons are ignored.
            pad.leftTrigger.pressedChangedHandler = { [weak self] _, _, pressed in
                DispatchQueue.main.async { self?.handleShortL2(pressed: pressed) }
            }
            pad.rightTrigger.pressedChangedHandler = { [weak self] _, _, pressed in
                DispatchQueue.main.async { self?.handleShortR2(pressed: pressed) }
            }
        }

        refreshConnectionSummary()
    }

    // MARK: - Minimal Keyboard Fallback (`K` Mode: Arrows + Q=L2, W=R2)

    private func attachKeyboard() {
        guard let keyboard = GCKeyboard.coalesced?.keyboardInput else { return }
        isGCKeyboardConnected = true
        onLog?("[8BitDo Micro] 키보드 모드 연결됨")

        keyboard.keyChangedHandler = { [weak self] _, _, keyCode, pressed in
            DispatchQueue.main.async {
                self?.handleKeyCode(keyCode, pressed: pressed)
            }
        }
        refreshConnectionSummary()
    }

    private func handleKeyCode(_ code: GCKeyCode, pressed: Bool) {
        switch code {
        case .upArrow:    handleDirectKeyDir(.up, sym: "↑", pressed: pressed)
        case .downArrow:  handleDirectKeyDir(.down, sym: "↓", pressed: pressed)
        case .leftArrow:  handleDirectKeyDir(.left, sym: "←", pressed: pressed)
        case .rightArrow: handleDirectKeyDir(.right, sym: "→", pressed: pressed)
        case .keyQ, .returnOrEnter, .spacebar:
            handleShortL2(pressed: pressed)
        case .keyW, .escape, .deleteOrBackspace:
            handleShortR2(pressed: pressed)
        default:
            break
        }
    }

    private func handleDirectKeyDir(_ action: RemoteAction, sym: String, pressed: Bool) {
        if pressed {
            beginDirectionHold(action, detail: "십자 \(sym)")
        } else if activeDirectionAction == action {
            stopRepeat()
        }
    }

    // MARK: - Smooth D-Pad Hold Auto-Repeat

    private func handleDirectionalAxis(x: Float, y: Float, prefix: String) {
        let phys: PhysicalDirection?
        if y > 0.5 { phys = .up }
        else if y < -0.5 { phys = .down }
        else if x < -0.5 { phys = .left }
        else if x > 0.5 { phys = .right }
        else { phys = nil }

        if let p = phys {
            let (action, sym) = mapDirection(p)
            if activeDirectionAction != action {
                beginDirectionHold(action, detail: "\(prefix) \(sym)")
            }
        } else {
            stopRepeat()
        }
    }

    private func beginDirectionHold(_ action: RemoteAction, detail: String) {
        stopRepeat()
        activeDirectionAction = action
        activeDirectionLabel = detail
        emit(action, detail: detail)

        let delayWork = DispatchWorkItem { [weak self] in
            guard let self, self.activeDirectionAction == action else { return }
            self.repeatTimer?.invalidate()
            self.repeatTimer = Timer.scheduledTimer(withTimeInterval: 0.13, repeats: true) { [weak self] _ in
                guard let self, let dir = self.activeDirectionAction else { return }
                self.emit(dir, detail: "\(self.activeDirectionLabel) 연속")
            }
        }
        repeatDelayWork = delayWork
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.34, execute: delayWork)
    }

    private func stopRepeat() {
        repeatDelayWork?.cancel()
        repeatDelayWork = nil
        repeatTimer?.invalidate()
        repeatTimer = nil
        activeDirectionAction = nil
        activeDirectionLabel = ""
    }

    // MARK: - Dispatch & State

    private func emit(_ action: RemoteAction, detail: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.lastButtonLabel = detail
            self.onAction?(RemoteCommandEvent(action: action, source: .zero2, detail: detail))
        }
    }

    private func refreshConnectionSummary() {
        let pads = GCController.controllers()
        if let first = pads.first {
            isConnected = true
            controllerName = first.vendorName ?? first.productCategory
            connectionModeLabel = "게임패드 (S 모드)"
        } else if GCKeyboard.coalesced != nil {
            isConnected = true
            controllerName = "8BitDo Micro / BT 키보드"
            connectionModeLabel = "키보드 (K 모드)"
        } else {
            isConnected = false
            controllerName = "연결 대기 중"
            connectionModeLabel = "대기"
        }
    }
}
