import SwiftUI
import UIKit

/// Pure OLED-black **Proximity Sensor Pocket Mode** for using **8BitDo Zero 2** (or any Bluetooth HID
/// gamepad/keyboard) with the iPhone slipped into a pocket or placed face-down on a desk.
///
/// How it saves battery & eliminates pocket mis-touches (using official iOS APIs):
/// 1. Keeps the app unlocked in the foreground (`isIdleTimerDisabled = true`) so `GCController` / `GCKeyboard` stay active.
/// 2. Enables `UIDevice.current.isProximityMonitoringEnabled = true` — the moment the phone enters a pocket
///    or sits face-down, iOS physically shuts off both the OLED display and touch digitizer (0mW screen + 0% mis-touch!).
/// 3. Dims screen brightness to 0.0 on `#000000` black while uncovered, automatically restoring original brightness on exit.
/// 4. Defers all system edge gestures and requires a deliberate 1.2s long-press to unlock & exit.
struct PocketModeView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var coordinator: AppCoordinator
    @EnvironmentObject var ble: G2BLEManager
    @EnvironmentObject var gamepad: GameControllerDriver
    @EnvironmentObject var os: G2OSStateMachine

    @State private var savedBrightness: CGFloat = 0.5
    @State private var hasSavedBrightness: Bool = false
    @State private var isProximityCovered: Bool = false
    @State private var unlockHolding: Bool = false
    @State private var unlockProgress: CGFloat = 0
    @State private var unlockTimer: Timer?

    var body: some View {
        ZStack {
            // 100% pure OLED black (#000000) so uncovered pixels draw minimal current
            Color.black.ignoresSafeArea()

            VStack(spacing: 22) {
                // Minimal dim status header
                HStack(spacing: 8) {
                    Circle()
                        .fill(gamepad.isConnected ? Color.green.opacity(0.65) : Color.orange.opacity(0.55))
                        .frame(width: 7, height: 7)
                    Text(gamepad.isConnected ? "\(gamepad.controllerName) · \(gamepad.connectionModeLabel)" : "8BitDo Micro 연결 대기 중")
                        .font(.caption.weight(.medium))
                        .foregroundColor(.white.opacity(0.45))
                    Spacer()
                    if let bat = ble.batteryLevel {
                        Text("G2 \(bat)%")
                            .font(.caption2.monospacedDigit())
                            .foregroundColor(.white.opacity(0.32))
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, 16)

                Spacer()

                // Center calm indicator
                VStack(spacing: 12) {
                    Image(systemName: isProximityCovered ? "moon.fill" : "iphone.gen3.radiowaves.left.and.right")
                        .font(.system(size: 32, weight: .ultraLight))
                        .foregroundColor(.green.opacity(0.42))

                    Text("주머니 포켓 모드 활성")
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(.white.opacity(0.5))

                    Text("주머니에 넣거나 엎어두면 근접 센서가\n화면·터치 전원을 자동으로 끕니다")
                        .font(.caption)
                        .multilineTextAlignment(.center)
                        .foregroundColor(.white.opacity(0.28))

                    // Live screen + last controller input
                    HStack(spacing: 10) {
                        Text(os.currentScreen.rawValue)
                            .foregroundColor(.green.opacity(0.55))
                        Text("·")
                            .foregroundColor(.white.opacity(0.2))
                        Text("최근 입력: \(gamepad.lastButtonLabel)")
                            .foregroundColor(.white.opacity(0.38))
                    }
                    .font(.caption2.monospaced())
                    .padding(.top, 4)
                }

                // Minimal 4-item left-handed 8BitDo Micro legend
                Text("8BitDo Micro · 왼손 세로 (90° ↻)")
                    .font(.caption2.monospaced().weight(.semibold))
                    .foregroundColor(.green.opacity(0.45))

                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                    keyHint("십자키", "상하좌우 이동")
                    keyHint("짧은 L2", "열기 (0ms)")
                    keyHint("짧은 L2 꾹", "AI 음성 · 검색")
                    keyHint("짧은 R2", "뒤로가기 / 닫기")
                }
                .padding(.horizontal, 26)
                .padding(.top, 6)

                Spacer()

                // Deliberate 1.2s long-press exit pill (immune to accidental pocket touches)
                ZStack {
                    Capsule()
                        .fill(Color.white.opacity(0.06))
                        .frame(width: 220, height: 48)
                    GeometryReader { geo in
                        Capsule()
                            .fill(Color.green.opacity(0.28))
                            .frame(width: geo.size.width * unlockProgress, height: 48)
                    }
                    .frame(width: 220, height: 48)
                    .clipShape(Capsule())

                    HStack(spacing: 8) {
                        Image(systemName: unlockHolding ? "lock.open" : "lock.fill")
                            .font(.caption.weight(.semibold))
                        Text(unlockHolding ? "계속 누르고 계세요..." : "길게 눌러 포켓 모드 해제")
                            .font(.caption.weight(.medium))
                    }
                    .foregroundColor(.white.opacity(unlockHolding ? 0.85 : 0.42))
                }
                .contentShape(Capsule())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { _ in
                            if !unlockHolding { beginUnlockHold() }
                        }
                        .onEnded { _ in
                            cancelUnlockHold()
                        }
                )
                .padding(.bottom, 26)
            }

            // Keep UIKeyCommand fallback active inside fullscreen Pocket Mode too
            KeyboardCaptureView { event in
                os.handle(event)
            }
            .frame(width: 0, height: 0)
            .allowsHitTesting(false)
        }
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .defersSystemGestures(on: .all)
        .onAppear { activatePocketMode() }
        .onDisappear { deactivatePocketMode() }
        .onReceive(NotificationCenter.default.publisher(for: UIDevice.proximityStateDidChangeNotification)) { _ in
            isProximityCovered = UIDevice.current.proximityState
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in
            restoreBrightnessIfNeeded()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            // Re-dim smoothly when returning while still in Pocket Mode
            UIScreen.main.brightness = 0.0
            UIDevice.current.isProximityMonitoringEnabled = true
        }
    }

    private func keyHint(_ key: String, _ desc: String) -> some View {
        HStack(spacing: 6) {
            Text(key)
                .font(.caption2.monospaced().weight(.semibold))
                .foregroundColor(.green.opacity(0.5))
                .frame(width: 62, alignment: .leading)
            Text(desc)
                .font(.caption2)
                .foregroundColor(.white.opacity(0.3))
                .lineLimit(1)
            Spacer(minLength: 0)
        }
    }

    private func activatePocketMode() {
        savedBrightness = UIScreen.main.brightness
        hasSavedBrightness = true
        UIApplication.shared.isIdleTimerDisabled = true
        UIDevice.current.isProximityMonitoringEnabled = true
        isProximityCovered = UIDevice.current.proximityState
        UIScreen.main.brightness = 0.0
        ble.ensureScreenActive(forceRecreate: false)
        coordinator.appendLog("[포켓 모드] 근접 센서 화면 절전 ON (8BitDo 입력 대기)")
    }

    private func deactivatePocketMode() {
        cancelUnlockHold()
        UIDevice.current.isProximityMonitoringEnabled = false
        UIApplication.shared.isIdleTimerDisabled = false
        restoreBrightnessIfNeeded()
        coordinator.appendLog("[포켓 모드] 해제 (화면 밝기 복원)")
    }

    private func restoreBrightnessIfNeeded() {
        guard hasSavedBrightness else { return }
        UIScreen.main.brightness = savedBrightness
    }

    private func beginUnlockHold() {
        unlockHolding = true
        unlockProgress = 0
        let startedAt = Date()
        let duration: TimeInterval = 1.15
        unlockTimer?.invalidate()
        unlockTimer = Timer.scheduledTimer(withTimeInterval: 0.03, repeats: true) { timer in
            let elapsed = Date().timeIntervalSince(startedAt)
            let p = min(1.0, CGFloat(elapsed / duration))
            unlockProgress = p
            if p >= 1.0 {
                timer.invalidate()
                unlockTimer = nil
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                dismiss()
            }
        }
    }

    private func cancelUnlockHold() {
        unlockTimer?.invalidate()
        unlockTimer = nil
        unlockHolding = false
        withAnimation(.easeOut(duration: 0.15)) {
            unlockProgress = 0
        }
    }
}
