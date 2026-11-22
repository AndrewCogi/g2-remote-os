import SwiftUI
import UIKit

struct ContentView: View {
    @EnvironmentObject var coordinator: AppCoordinator
    @EnvironmentObject var ble: G2BLEManager
    @EnvironmentObject var flic: FlicDuoDriver
    @EnvironmentObject var os: G2OSStateMachine

    @State private var selectedTab = 0
    @State private var pocketBlackMode = false

    var body: some View {
        ZStack {
            TabView(selection: $selectedTab) {
                NavigationStack {
                    ScrollView {
                        VStack(spacing: 14) {
                            statusStrip
                            G2MirrorView(text: os.renderedFrameText, isAsleep: ble.isScreenAsleep, isMicOn: ble.isMicEnabled)
                            VirtualRemoteView()
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                    }
                    .navigationTitle("G2 Remote OS")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button {
                                pocketBlackMode = true
                                UIApplication.shared.isIdleTimerDisabled = true
                            } label: {
                                Label("OLED 절전", systemImage: "moon.fill")
                            }
                        }
                    }
                }
                .tabItem {
                    Label("리모콘", systemImage: "gamecontroller.fill")
                }
                .tag(0)

                NavigationStack {
                    ConnectionView()
                }
                .tabItem {
                    Label("기기 연결", systemImage: "dot.radiowaves.left.and.right")
                }
                .tag(1)

                NavigationStack {
                    SettingsLogView()
                }
                .tabItem {
                    Label("설정/로그", systemImage: "slider.horizontal.3")
                }
                .tag(2)
            }
            .tint(.green)

            // Hidden keyboard listener for optional foreground / OLED-black 8BitDo Micro testing
            KeyboardCaptureView { event in
                os.handle(event)
            }
            .frame(width: 0, height: 0)
            .allowsHitTesting(false)

            if pocketBlackMode {
                pocketBlackOverlay
            }
        }
    }

    private var statusStrip: some View {
        HStack(spacing: 10) {
            StatusBadge(
                title: "G2",
                value: ble.phase == .connected ? "연결됨" : ble.phase.rawValue,
                active: ble.phase == .connected
            )
            StatusBadge(
                title: "Flic",
                value: flic.isReady ? (flic.isDuoHardware ? "Duo 준비" : "연결됨") : "대기",
                active: flic.isReady
            )
            StatusBadge(
                title: "MIC",
                value: ble.isMicEnabled ? "ON (\(ble.micPacketCount))" : "OFF",
                active: ble.isMicEnabled,
                activeColor: .red
            )
        }
    }

    /// Pure #000000 OLED screen-off illusion mode (useful if testing Bluetooth HID keyboards like 8BitDo Micro).
    private var pocketBlackOverlay: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 12) {
                Text("OLED 포켓 모드 (화면 픽셀 OFF)")
                    .font(.caption)
                    .foregroundColor(.gray.opacity(0.35))
                Text("더블탭하여 해제")
                    .font(.caption2)
                    .foregroundColor(.gray.opacity(0.25))
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            pocketBlackMode = false
            UIApplication.shared.isIdleTimerDisabled = false
        }
    }
}

private struct StatusBadge: View {
    let title: String
    let value: String
    let active: Bool
    var activeColor: Color = .green

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(active ? activeColor : Color.gray.opacity(0.5))
                .frame(width: 7, height: 7)
            Text("\(title): \(value)")
                .font(.caption2.monospaced())
                .lineLimit(1)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity)
        .background(Color.white.opacity(0.07))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}
