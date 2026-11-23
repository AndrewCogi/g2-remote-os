import SwiftUI
import UIKit

/// Minimalist dark hub for G2 OS.
/// Features a true 1:1 multi-container + 4-bit pixel G2 mirror, one-tap Fullscreen Motion Pad launch,
/// quick tools/alarm access, and dedicated sheets for Connection, Tools, and Full Hardware Settings.
struct ContentView: View {
    @EnvironmentObject var coordinator: AppCoordinator
    @EnvironmentObject var ble: G2BLEManager
    @EnvironmentObject var flic: FlicDuoDriver
    @EnvironmentObject var gamepad: GameControllerDriver
    @EnvironmentObject var os: G2OSStateMachine
    @EnvironmentObject var keeper: BackgroundKeeper
    @EnvironmentObject var calendar: CalendarQuickListService
    @EnvironmentObject var clockTools: AlarmTimerService
    @EnvironmentObject var spark: SparkBridgeClient
    @EnvironmentObject var tailscale: TailscaleMonitor

    @State private var showMotionPad = false
    @State private var showPocketMode = false
    @State private var showConnectionSheet = false
    @State private var showToolsSheet = false
    @State private var showSettingsSheet = false

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.03, green: 0.04, blue: 0.035),
                    Color.black
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            VStack(spacing: 16) {
                headerBar

                if let alert = clockTools.activeAlert {
                    activeAlertBanner(alert)
                }

                G2MirrorView(
                    page: os.currentPage,
                    isConnected: ble.phase == .connected,
                    isMicOn: ble.isMicEnabled,
                    alwaysOnActive: coordinator.keepAliveEnabled && keeper.isActive
                )

                pocketModeLaunchButton

                motionPadLaunchCard

                quickActionBar

                Spacer(minLength: 4)

                footerStatusLine
            }
            .padding(.horizontal, 18)
            .padding(.top, 10)
            .padding(.bottom, 14)

            KeyboardCaptureView { event in
                os.handle(event)
            }
            .frame(width: 0, height: 0)
            .allowsHitTesting(false)
        }
        .fullScreenCover(isPresented: $showMotionPad) {
            MotionPadFullscreenView()
                .environmentObject(coordinator)
                .environmentObject(ble)
                .environmentObject(flic)
                .environmentObject(gamepad)
                .environmentObject(os)
                .environmentObject(keeper)
                .environmentObject(spark)
                .environmentObject(tailscale)
        }
        .fullScreenCover(isPresented: $showPocketMode) {
            PocketModeView()
                .environmentObject(coordinator)
                .environmentObject(ble)
                .environmentObject(gamepad)
                .environmentObject(os)
        }
        .sheet(isPresented: $showConnectionSheet) {
            NavigationStack {
                ConnectionView()
            }
            .environmentObject(coordinator)
            .environmentObject(ble)
            .environmentObject(flic)
            .environmentObject(gamepad)
            .preferredColorScheme(.dark)
        }
        .sheet(isPresented: $showToolsSheet) {
            NavigationStack {
                ToolsSheetView()
            }
            .environmentObject(coordinator)
            .environmentObject(os)
            .environmentObject(calendar)
            .environmentObject(clockTools)
            .preferredColorScheme(.dark)
        }
        .sheet(isPresented: $showSettingsSheet) {
            NavigationStack {
                SettingsLogView()
            }
            .environmentObject(coordinator)
            .environmentObject(ble)
            .environmentObject(os)
            .environmentObject(keeper)
            .environmentObject(calendar)
            .environmentObject(spark)
            .environmentObject(tailscale)
            .preferredColorScheme(.dark)
        }
    }

    // MARK: - Top Header

    private var headerBar: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("G2 OS")
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                    .foregroundColor(.white)

                Button {
                    showConnectionSheet = true
                } label: {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(statusDotColor)
                            .frame(width: 7, height: 7)
                        Text(connectionSummaryText)
                            .font(.caption.weight(.medium))
                            .foregroundColor(.white.opacity(0.65))
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(.white.opacity(0.35))
                    }
                }
            }

            Spacer()

            headerIconButton(
                systemName: "alarm.fill",
                tint: clockTools.activeAlert != nil ? .red : .white.opacity(0.85)
            ) {
                showToolsSheet = true
            }

            headerIconButton(
                systemName: "dot.radiowaves.left.and.right",
                tint: ble.phase == .connected ? .green : .white.opacity(0.85)
            ) {
                showConnectionSheet = true
            }

            headerIconButton(
                systemName: "gearshape",
                tint: .white.opacity(0.85)
            ) {
                showSettingsSheet = true
            }
        }
    }

    private func activeAlertBanner(_ alert: G2ActiveAlert) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "bell.badge.fill")
                .foregroundColor(.red)
            VStack(alignment: .leading, spacing: 1) {
                Text(alert.kind.rawValue)
                    .font(.caption2.bold())
                    .foregroundColor(.red)
                Text(alert.title)
                    .font(.caption.weight(.semibold))
                    .foregroundColor(.white)
            }
            Spacer()
            Button("끄기") {
                clockTools.dismissActiveAlert()
            }
            .font(.caption.bold())
            .buttonStyle(.borderedProminent)
            .tint(.red)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.red.opacity(0.16))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.red.opacity(0.45), lineWidth: 1)
        )
    }

    private func headerIconButton(systemName: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(tint)
                .frame(width: 38, height: 38)
                .background(Color.white.opacity(0.07))
                .clipShape(Circle())
                .overlay(
                    Circle().stroke(Color.white.opacity(0.08), lineWidth: 1)
                )
        }
    }

    private var statusDotColor: Color {
        switch ble.phase {
        case .connected: return .green
        case .connecting, .handshaking, .scanning: return .orange
        case .disconnected: return .gray
        }
    }

    private var connectionSummaryText: String {
        if ble.phase == .connected {
            if let bat = ble.batteryLevel {
                return "G2 연결됨 · 배터리 \(bat)%"
            }
            return "G2 연결됨"
        }
        return ble.phase == .disconnected ? "G2 연결하기" : ble.phase.rawValue
    }

    // MARK: - Primary Hero Cards: Pocket Mode (8BitDo Zero 2) + Fullscreen Motion Pad

    private var pocketModeLaunchButton: some View {
        Button {
            showPocketMode = true
        } label: {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill((gamepad.isConnected ? Color.green : Color.blue).opacity(0.18))
                        .frame(width: 42, height: 42)
                    Image(systemName: "gamecontroller.fill")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(gamepad.isConnected ? .green : .cyan)
                }

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text("주머니 포켓 모드")
                            .font(.headline)
                            .foregroundColor(.white)
                        Text(gamepad.isConnected ? "Micro 연결됨" : "8BitDo Micro")
                            .font(.caption2.weight(.semibold))
                            .foregroundColor(gamepad.isConnected ? .black : .cyan)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(gamepad.isConnected ? Color.green : Color.cyan.opacity(0.18))
                            .clipShape(Capsule())
                    }
                    Text("주머니에 넣으면 근접 센서로 화면·터치 자동 OFF")
                        .font(.caption)
                        .foregroundColor(.white.opacity(0.55))
                        .lineLimit(1)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(.white.opacity(0.4))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 13)
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(Color.white.opacity(0.055))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke((gamepad.isConnected ? Color.green : Color.cyan).opacity(0.32), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private var motionPadLaunchCard: some View {
        Button {
            showMotionPad = true
        } label: {
            VStack(spacing: 16) {
                HStack {
                    HStack(spacing: 10) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(Color.green.opacity(0.18))
                                .frame(width: 42, height: 42)
                            Image(systemName: "hand.draw.fill")
                                .font(.system(size: 19, weight: .semibold))
                                .foregroundColor(.green)
                        }

                        VStack(alignment: .leading, spacing: 2) {
                            Text("모션 패드 열기")
                                .font(.headline)
                                .foregroundColor(.white)
                            Text("아이폰 화면 전체를 트랙패드로 사용")
                                .font(.caption)
                                .foregroundColor(.white.opacity(0.55))
                        }
                    }

                    Spacer()

                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(.green.opacity(0.85))
                        .padding(10)
                        .background(Color.green.opacity(0.12))
                        .clipShape(Circle())
                }

                LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                    gestureTile(icon: "arrow.up.and.down.and.arrow.left.and.right", title: "스와이프", subtitle: "상하좌우 이동")
                    gestureTile(icon: "hand.tap", title: "한 번 탭", subtitle: "클릭 · 선택")
                    gestureTile(icon: "arrow.uturn.backward", title: "더블탭", subtitle: "뒤로가기")
                    gestureTile(icon: "mic.fill", title: "길게 누르기", subtitle: "마이크 (떼면 끄기)")
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color.green.opacity(0.11),
                                Color.white.opacity(0.04)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(Color.green.opacity(0.28), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private func gestureTile(icon: String, title: String, subtitle: String) -> some View {
        HStack(spacing: 9) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.green)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundColor(.white.opacity(0.9))
                Text(subtitle)
                    .font(.system(size: 10.5))
                    .foregroundColor(.white.opacity(0.5))
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(Color.black.opacity(0.32))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    // MARK: - Compact Quick Utilities

    private var quickActionBar: some View {
        HStack(spacing: 10) {
            quickPill(icon: "house.fill", title: "대시보드") {
                coordinator.triggerMotionAction(.home, detail: "대시보드")
            }

            HStack(spacing: 0) {
                Button {
                    coordinator.triggerMotionAction(.brightnessDown, detail: "밝기-")
                } label: {
                    Image(systemName: "sun.min")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.white.opacity(0.85))
                        .frame(width: 38, height: 42)
                }

                Text("\(ble.brightnessLevel)")
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundColor(.green)
                    .frame(minWidth: 24)

                Button {
                    coordinator.triggerMotionAction(.brightnessUp, detail: "밝기+")
                } label: {
                    Image(systemName: "sun.max.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.white.opacity(0.85))
                        .frame(width: 38, height: 42)
                }
            }
            .background(Color.white.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color.white.opacity(0.07), lineWidth: 1)
            )

            quickPill(icon: "arrow.clockwise", title: "화면 복구") {
                ble.ensureScreenActive(forceRecreate: true)
            }
        }
    }

    private func quickPill(icon: String, title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .semibold))
                Text(title)
                    .font(.caption.weight(.semibold))
            }
            .foregroundColor(.white.opacity(0.88))
            .frame(maxWidth: .infinity)
            .frame(height: 42)
            .background(Color.white.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color.white.opacity(0.07), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Subtle Footer

    private var footerStatusLine: some View {
        HStack(spacing: 8) {
            Image(systemName: coordinator.keepAliveEnabled ? "lock.shield.fill" : "lock.open")
                .font(.caption2)
                .foregroundColor(coordinator.keepAliveEnabled ? .green : .orange)
            Text(os.headUpWakeEnabled ? "항시 OS · 들기 ON" : (coordinator.keepAliveEnabled ? "항시 OS 유지" : "항시 유지 꺼짐"))
                .font(.caption2)
                .foregroundColor(.white.opacity(0.5))

            Spacer()

            Button {
                showSettingsSheet = true
            } label: {
                HStack(spacing: 5) {
                    Circle()
                        .fill(tailscale.isTailscaleConnected ? (spark.isConnected ? Color.green : Color.orange) : Color.gray)
                        .frame(width: 6, height: 6)
                    Text(tailscaleFooterText)
                        .font(.caption2.monospaced())
                        .foregroundColor(tailscale.isTailscaleConnected ? .white.opacity(0.75) : .white.opacity(0.4))
                }
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 4)
    }

    private var tailscaleFooterText: String {
        if !tailscale.isTailscaleConnected { return "TS OFF" }
        if spark.isConnected { return "\(spark.activeNodeLabel) · \(spark.latencyMs)ms" }
        return "TS ON · 대기"
    }
}
