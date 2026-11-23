import SwiftUI
import UIKit

/// Fullscreen OLED-black trackpad covering the entire iPhone screen.
/// Gesture mapping:
/// - Swipe Up / Down / Left / Right -> Directional navigation
/// - Single Tap                     -> Click / Select
/// - Double Tap                     -> Back
/// - Press & Hold -> Mic Open       / Release -> Mic Close (Push-to-Talk)
struct MotionPadFullscreenView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var coordinator: AppCoordinator
    @EnvironmentObject var ble: G2BLEManager
    @EnvironmentObject var os: G2OSStateMachine

    @State private var showMiniMirror: Bool = false
    @State private var activeTouchPoint: CGPoint?
    @State private var isHoldingMic: Bool = false
    @State private var feedbackIcon: String?
    @State private var feedbackText: String?
    @State private var feedbackColor: Color = .green
    @State private var feedbackID: UUID = UUID()
    @State private var feedbackClearTask: DispatchWorkItem?

    var body: some View {
        ZStack {
            // Pure OLED black canvas
            Color.black.ignoresSafeArea()

            // Subtle ambient dot matrix so the trackpad surface feels tactile without glare
            TrackpadDotGrid()
                .opacity(isHoldingMic ? 0.16 : 0.08)
                .ignoresSafeArea()
                .allowsHitTesting(false)

            // Active finger glow ring (follows touch subtly)
            if let pt = activeTouchPoint {
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [
                                (isHoldingMic ? Color.red : Color.green).opacity(isHoldingMic ? 0.32 : 0.18),
                                Color.clear
                            ],
                            center: .center,
                            startRadius: 4,
                            endRadius: isHoldingMic ? 110 : 65
                        )
                    )
                    .frame(width: isHoldingMic ? 220 : 130, height: isHoldingMic ? 220 : 130)
                    .position(pt)
                    .allowsHitTesting(false)
                    .animation(.easeOut(duration: 0.15), value: isHoldingMic)
            }

            // Full-bleed UIKit touch recognizer covering 100% of the screen
            MotionPadTouchView(
                onSwipe: { direction in
                    switch direction {
                    case .up:
                        coordinator.triggerMotionAction(.up, detail: "스와이프 ↑")
                        flashFeedback(icon: "chevron.up", text: "위", color: .green)
                    case .down:
                        coordinator.triggerMotionAction(.down, detail: "스와이프 ↓")
                        flashFeedback(icon: "chevron.down", text: "아래", color: .green)
                    case .left:
                        coordinator.triggerMotionAction(.left, detail: "스와이프 ←")
                        flashFeedback(icon: "chevron.left", text: "왼쪽", color: .green)
                    case .right:
                        coordinator.triggerMotionAction(.right, detail: "스와이프 →")
                        flashFeedback(icon: "chevron.right", text: "오른쪽", color: .green)
                    }
                },
                onSingleTap: {
                    coordinator.triggerMotionAction(.select, detail: "탭")
                    flashFeedback(icon: "checkmark.circle.fill", text: "클릭", color: .green)
                },
                onDoubleTap: {
                    coordinator.triggerMotionAction(.back, detail: "더블탭")
                    flashFeedback(icon: "arrow.uturn.backward", text: "뒤로가기", color: .mint)
                },
                onMicStart: {
                    isHoldingMic = true
                    coordinator.triggerMotionAction(.micStart, detail: "길게 누르기")
                },
                onMicStop: {
                    isHoldingMic = false
                    coordinator.triggerMotionAction(.micStop, detail: "손 뗌")
                    flashFeedback(icon: "mic.slash.fill", text: "마이크 종료", color: .secondary)
                },
                onTouchPointChanged: { point in
                    activeTouchPoint = point
                }
            )
            .ignoresSafeArea()

            // Center visual feedback (live Push-to-Talk pulse OR brief directional/tap flash)
            centerFeedbackOverlay
                .allowsHitTesting(false)

            // Minimal top & bottom HUD overlays (touch passes through everywhere except top-right controls)
            VStack(spacing: 12) {
                topBar

                if showMiniMirror {
                    G2MiniMirrorStrip(
                        page: os.currentPage,
                        isMicOn: ble.isMicEnabled
                    )
                    .padding(.horizontal, 18)
                    .allowsHitTesting(false)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }

                Spacer()

                bottomHintBar
                    .allowsHitTesting(false)
            }
            .padding(.top, 8)
            .padding(.bottom, 14)
        }
        .statusBarHidden(false)
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = true
            ble.ensureScreenActive(forceRecreate: false)
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
            if isHoldingMic {
                isHoldingMic = false
                coordinator.triggerMotionAction(.micStop, detail: "화면 닫힘")
            }
        }
    }

    // MARK: - Minimal Overlays

    private var topBar: some View {
        HStack(spacing: 10) {
            // Subtle pass-through status pill
            HStack(spacing: 7) {
                Circle()
                    .fill(ble.phase == .connected ? Color.green : Color.orange)
                    .frame(width: 7, height: 7)
                Text(os.currentScreen.rawValue)
                    .font(.caption.weight(.semibold))
                    .foregroundColor(.white.opacity(0.75))
                if let bat = ble.batteryLevel {
                    Text("· \(bat)%")
                        .font(.caption.monospacedDigit())
                        .foregroundColor(.white.opacity(0.45))
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(Color.white.opacity(0.06))
            .clipShape(Capsule())
            .allowsHitTesting(false)

            Spacer()

            // Optional G2 mirror glance toggle
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    showMiniMirror.toggle()
                }
            } label: {
                Image(systemName: showMiniMirror ? "eyeglasses" : "eye.slash")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(showMiniMirror ? .green : .white.opacity(0.55))
                    .frame(width: 36, height: 36)
                    .background(Color.white.opacity(0.08))
                    .clipShape(Circle())
            }
            .accessibilityLabel("G2 미러 표시 전환")

            // Exit fullscreen motion pad
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(.white.opacity(0.75))
                    .frame(width: 36, height: 36)
                    .background(Color.white.opacity(0.09))
                    .clipShape(Circle())
            }
            .accessibilityLabel("모션 패드 닫기")
        }
        .padding(.horizontal, 18)
    }

    @ViewBuilder
    private var centerFeedbackOverlay: some View {
        if isHoldingMic || ble.isMicEnabled {
            VStack(spacing: 16) {
                ZStack {
                    Circle()
                        .stroke(Color.red.opacity(0.35), lineWidth: 2)
                        .frame(width: 118, height: 118)
                    Circle()
                        .fill(Color.red.opacity(0.16))
                        .frame(width: 92, height: 92)
                    Image(systemName: "mic.fill")
                        .font(.system(size: 36, weight: .semibold))
                        .foregroundColor(.red)
                }

                VStack(spacing: 6) {
                    Text("G2 마이크 듣는 중")
                        .font(.headline)
                        .foregroundColor(.white)
                    Text(String(format: "%.1f초 · %d pkt · 손 떼면 종료", Double(ble.micDurationMs) / 1000.0, ble.micPacketCount))
                        .font(.caption.monospacedDigit())
                        .foregroundColor(.white.opacity(0.65))
                }
            }
            .transition(.scale(scale: 0.92).combined(with: .opacity))
        } else if let icon = feedbackIcon, let text = feedbackText {
            VStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 40, weight: .light))
                    .foregroundColor(feedbackColor.opacity(0.9))
                Text(text)
                    .font(.subheadline.weight(.medium))
                    .foregroundColor(.white.opacity(0.75))
            }
            .id(feedbackID)
            .transition(.opacity.combined(with: .scale(scale: 0.9)))
        } else {
            VStack(spacing: 8) {
                Image(systemName: "hand.point.up.left")
                    .font(.system(size: 26, weight: .ultraLight))
                    .foregroundColor(.white.opacity(0.16))
                Text("화면 전체 모션 패드")
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.18))
            }
        }
    }

    private var bottomHintBar: some View {
        HStack(spacing: 14) {
            hintChip("스와이프", "이동")
            hintChip("탭", "클릭")
            hintChip("더블탭", "뒤로")
            hintChip("홀드", "마이크")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color.white.opacity(0.04))
        .clipShape(Capsule())
    }

    private func hintChip(_ gesture: String, _ label: String) -> some View {
        HStack(spacing: 4) {
            Text(gesture)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.green.opacity(0.75))
            Text(label)
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.4))
        }
    }

    private func flashFeedback(icon: String, text: String, color: Color) {
        feedbackClearTask?.cancel()
        withAnimation(.easeOut(duration: 0.12)) {
            feedbackIcon = icon
            feedbackText = text
            feedbackColor = color
            feedbackID = UUID()
        }
        let work = DispatchWorkItem {
            withAnimation(.easeOut(duration: 0.25)) {
                feedbackIcon = nil
                feedbackText = nil
            }
        }
        feedbackClearTask = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.55, execute: work)
    }
}

// MARK: - Subtle Ambient Trackpad Dot Grid

private struct TrackpadDotGrid: View {
    var body: some View {
        Canvas { context, size in
            let spacing: CGFloat = 28
            let dotSize: CGFloat = 2
            var y: CGFloat = spacing
            while y < size.height {
                var x: CGFloat = spacing
                while x < size.width {
                    let rect = CGRect(x: x, y: y, width: dotSize, height: dotSize)
                    context.fill(Path(ellipseIn: rect), with: .color(.green))
                    x += spacing
                }
                y += spacing
            }
        }
    }
}

// MARK: - Deterministic UIKit Fullscreen Touch Recognizer

enum MotionSwipeDirection {
    case up, down, left, right
}

struct MotionPadTouchView: UIViewRepresentable {
    let onSwipe: (MotionSwipeDirection) -> Void
    let onSingleTap: () -> Void
    let onDoubleTap: () -> Void
    let onMicStart: () -> Void
    let onMicStop: () -> Void
    let onTouchPointChanged: (CGPoint?) -> Void

    func makeUIView(context: Context) -> MotionPadUIView {
        let view = MotionPadUIView()
        bind(view)
        return view
    }

    func updateUIView(_ uiView: MotionPadUIView, context: Context) {
        bind(uiView)
    }

    private func bind(_ view: MotionPadUIView) {
        view.onSwipe = onSwipe
        view.onSingleTap = onSingleTap
        view.onDoubleTap = onDoubleTap
        view.onMicStart = onMicStart
        view.onMicStop = onMicStop
        view.onTouchPointChanged = onTouchPointChanged
    }
}

/// Low-level UIView touch state machine that cleanly disambiguates:
/// 1. 4-Way Swipe (threshold 36pt)
/// 2. Single Tap vs Double Tap (240ms window, 56pt radius)
/// 3. Press & Hold (360ms stationary) -> Mic Open, and Release/Cancel -> Mic Close
final class MotionPadUIView: UIView {
    var onSwipe: ((MotionSwipeDirection) -> Void)?
    var onSingleTap: (() -> Void)?
    var onDoubleTap: (() -> Void)?
    var onMicStart: (() -> Void)?
    var onMicStop: (() -> Void)?
    var onTouchPointChanged: ((CGPoint?) -> Void)?

    private let swipeThreshold: CGFloat = 36
    private let holdDuration: TimeInterval = 0.36
    private let holdMoveTolerance: CGFloat = 20
    private let doubleTapMaxInterval: TimeInterval = 0.24
    private let doubleTapMaxDistance: CGFloat = 56

    private var activeTouch: UITouch?
    private var startPoint: CGPoint = .zero
    private var startTimestamp: TimeInterval = 0
    private var didTriggerSwipe: Bool = false
    private var isHoldingMic: Bool = false
    private var isPotentialDoubleTap: Bool = false

    private var holdTimer: Timer?
    private var pendingSingleTap: DispatchWorkItem?
    private var lastTapEndTime: TimeInterval = 0
    private var lastTapEndPoint: CGPoint = .zero

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isMultipleTouchEnabled = false
        isExclusiveTouch = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        cleanupAllTimersAndMic()
    }

    override func willMove(toWindow newWindow: UIWindow?) {
        super.willMove(toWindow: newWindow)
        if newWindow == nil {
            cleanupAllTimersAndMic()
        }
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard activeTouch == nil, let touch = touches.first else { return }
        let pt = touch.location(in: self)
        let now = ProcessInfo.processInfo.systemUptime

        activeTouch = touch
        startPoint = pt
        startTimestamp = now
        didTriggerSwipe = false
        isHoldingMic = false
        onTouchPointChanged?(pt)

        // Check if this touch could complete a double-tap.
        let dt = now - lastTapEndTime
        let dist = hypot(pt.x - lastTapEndPoint.x, pt.y - lastTapEndPoint.y)
        if dt <= doubleTapMaxInterval && dist <= doubleTapMaxDistance {
            pendingSingleTap?.cancel()
            pendingSingleTap = nil
            isPotentialDoubleTap = true
        } else {
            isPotentialDoubleTap = false
        }

        // Schedule Press & Hold -> Mic Open.
        holdTimer?.invalidate()
        holdTimer = Timer.scheduledTimer(withTimeInterval: holdDuration, repeats: false) { [weak self] _ in
            guard let self, self.activeTouch != nil, !self.didTriggerSwipe else { return }
            self.pendingSingleTap?.cancel()
            self.pendingSingleTap = nil
            self.isPotentialDoubleTap = false
            self.lastTapEndTime = 0
            self.isHoldingMic = true
            self.onMicStart?()
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let activeTouch, touches.contains(activeTouch) else { return }
        let pt = activeTouch.location(in: self)
        onTouchPointChanged?(pt)

        // Once Push-to-Talk mic is open, ignore drift until the user lifts their finger.
        if isHoldingMic || didTriggerSwipe {
            return
        }

        let dx = pt.x - startPoint.x
        let dy = pt.y - startPoint.y
        let dist = hypot(dx, dy)

        if dist >= holdMoveTolerance {
            holdTimer?.invalidate()
            holdTimer = nil
        }

        if dist >= swipeThreshold {
            didTriggerSwipe = true
            isPotentialDoubleTap = false
            pendingSingleTap?.cancel()
            pendingSingleTap = nil
            lastTapEndTime = 0

            let direction: MotionSwipeDirection
            if abs(dx) >= abs(dy) {
                direction = dx > 0 ? .right : .left
            } else {
                direction = dy > 0 ? .down : .up
            }
            onSwipe?(direction)
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let activeTouch, touches.contains(activeTouch) else { return }
        let pt = activeTouch.location(in: self)
        let now = ProcessInfo.processInfo.systemUptime

        holdTimer?.invalidate()
        holdTimer = nil
        self.activeTouch = nil
        onTouchPointChanged?(nil)

        if isHoldingMic {
            isHoldingMic = false
            onMicStop?()
            return
        }

        if didTriggerSwipe {
            didTriggerSwipe = false
            return
        }

        // Neither swipe nor hold -> Single Tap or Double Tap.
        if isPotentialDoubleTap && (now - startTimestamp) < holdDuration {
            isPotentialDoubleTap = false
            lastTapEndTime = 0
            pendingSingleTap?.cancel()
            pendingSingleTap = nil
            onDoubleTap?()
            return
        }

        isPotentialDoubleTap = false
        lastTapEndTime = now
        lastTapEndPoint = pt

        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.lastTapEndTime = 0
            self.onSingleTap?()
        }
        pendingSingleTap?.cancel()
        pendingSingleTap = work
        DispatchQueue.main.asyncAfter(deadline: .now() + doubleTapMaxInterval, execute: work)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let activeTouch, touches.contains(activeTouch) else { return }
        holdTimer?.invalidate()
        holdTimer = nil
        self.activeTouch = nil
        didTriggerSwipe = false
        isPotentialDoubleTap = false
        onTouchPointChanged?(nil)

        if isHoldingMic {
            isHoldingMic = false
            onMicStop?()
        }
    }

    private func cleanupAllTimersAndMic() {
        holdTimer?.invalidate()
        holdTimer = nil
        pendingSingleTap?.cancel()
        pendingSingleTap = nil
        activeTouch = nil
        if isHoldingMic {
            isHoldingMic = false
            onMicStop?()
        }
    }
}
