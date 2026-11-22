import SwiftUI

/// Provides BOTH:
/// 1. Direct All-Action Control Pad (Up/Down/Left/Right, Scroll Up/Down, Select, Back, Home, Mic, Brightness, Sleep)
/// 2. Virtual Flic Duo Simulator (Big/Small button click, double-click, hold, and 4-way swipe)
struct VirtualRemoteView: View {
    @EnvironmentObject var coordinator: AppCoordinator
    @EnvironmentObject var ble: G2BLEManager
    @EnvironmentObject var os: G2OSStateMachine

    @State private var mode: Int = 0 // 0 = All-Control Pad, 1 = Virtual Flic Duo

    var body: some View {
        VStack(spacing: 12) {
            Picker("패드 모드", selection: $mode) {
                Text("전체 조작 패드").tag(0)
                Text("가상 Flic Duo").tag(1)
            }
            .pickerStyle(.segmented)

            if mode == 0 {
                fullControlPad
            } else {
                virtualFlicDuoPad
            }

            HStack {
                Text("최근 입력:")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                Text(os.lastActionSummary)
                    .font(.caption2.monospaced())
                    .foregroundColor(.green)
                    .lineLimit(1)
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.white.opacity(0.05))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }

    // MARK: - Full Control Pad (D-Pad + Scroll + Mic + System)

    private var fullControlPad: some View {
        VStack(spacing: 12) {
            HStack(spacing: 14) {
                // 4-Way D-Pad + Center Select
                VStack(spacing: 8) {
                    padButton(icon: "chevron.up", label: "위", action: .up)
                    HStack(spacing: 8) {
                        padButton(icon: "chevron.left", label: "좌", action: .left)
                        padButton(icon: "checkmark.circle.fill", label: "확인", action: .select, tint: .green)
                        padButton(icon: "chevron.right", label: "우", action: .right)
                    }
                    padButton(icon: "chevron.down", label: "아래", action: .down)
                }

                // Dedicated Scroll Wheel & Brightness Column
                VStack(spacing: 8) {
                    wideActionButton(icon: "arrow.up.to.line", title: "스크롤 ↑", action: .scrollUp)
                    wideActionButton(icon: "arrow.down.to.line", title: "스크롤 ↓", action: .scrollDown)
                    HStack(spacing: 6) {
                        compactButton(icon: "sun.min", title: "밝기-", action: .brightnessDown)
                        compactButton(icon: "sun.max.fill", title: "밝기+", action: .brightnessUp)
                    }
                }
            }

            // Bottom System Row: Back, Home, Mic Toggle, Sleep
            HStack(spacing: 8) {
                systemButton(icon: "arrow.uturn.backward", title: "뒤로", action: .back)
                systemButton(icon: "house.fill", title: "홈", action: .home)
                systemButton(
                    icon: ble.isMicEnabled ? "mic.fill" : "mic.slash",
                    title: ble.isMicEnabled ? "마이크 끄기" : "마이크 켜기",
                    action: .micToggle,
                    highlight: ble.isMicEnabled ? .red : .green
                )
                systemButton(icon: "power", title: "절전", action: .screenToggle)
            }
        }
        .padding(12)
        .background(Color.white.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    // MARK: - Virtual Flic Duo Simulator (matches real hardware mapping 1:1)

    private var virtualFlicDuoPad: some View {
        VStack(spacing: 10) {
            Text("실제 Flic Duo와 동일한 매핑 (드래그 = 4방향 스와이프)")
                .font(.caption2)
                .foregroundColor(.secondary)

            HStack(spacing: 12) {
                // Big Button (Button 0)
                VStack(spacing: 6) {
                    Text("큰 버튼 (Button 0)")
                        .font(.caption.bold())
                    Text("클릭:확인 · 더블:뒤로 · 홀드:마이크")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)

                    HStack(spacing: 6) {
                        simChip("클릭") { coordinator.triggerVirtualAction(.select, detail: "가상 큰버튼 클릭") }
                        simChip("더블") { coordinator.triggerVirtualAction(.back, detail: "가상 큰버튼 더블") }
                        simChip("홀드", color: .red) { coordinator.triggerVirtualAction(.micToggle, detail: "가상 큰버튼 홀드") }
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity)
                .background(Color.green.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 12))

                // Small Button (Button 1)
                VStack(spacing: 6) {
                    Text("작은 버튼 (Button 1)")
                        .font(.caption.bold())
                    Text("클릭:↓ · 더블:↑ · 홀드:홈/절전")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)

                    HStack(spacing: 6) {
                        simChip("클릭") { coordinator.triggerVirtualAction(.down, detail: "가상 작은버튼 클릭") }
                        simChip("더블") { coordinator.triggerVirtualAction(.up, detail: "가상 작은버튼 더블") }
                        simChip("홀드", color: .orange) { coordinator.triggerVirtualAction(.home, detail: "가상 작은버튼 홀드") }
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity)
                .background(Color.blue.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }

            // Swipe & Twist simulation area
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.white.opacity(0.06))
                .frame(height: 68)
                .overlay(
                    VStack(spacing: 4) {
                        Image(systemName: "hand.draw.fill")
                            .foregroundColor(.green)
                        Text("여기를 상·하·좌·우로 스와이프 (Flic Duo 모션 시뮬레이션)")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                )
                .gesture(
                    DragGesture(minimumDistance: 24)
                        .onEnded { value in
                            let dx = value.translation.width
                            let dy = value.translation.height
                            if abs(dx) > abs(dy) {
                                coordinator.triggerVirtualAction(dx > 0 ? .right : .left, detail: "가상 스와이프")
                            } else {
                                coordinator.triggerVirtualAction(dy > 0 ? .down : .up, detail: "가상 스와이프")
                            }
                        }
                )
        }
        .padding(12)
        .background(Color.white.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    // MARK: - Button Components

    private func padButton(icon: String, label: String, action: RemoteAction, tint: Color = .white) -> some View {
        Button {
            coordinator.triggerVirtualAction(action)
        } label: {
            VStack(spacing: 2) {
                Image(systemName: icon).font(.system(size: 16, weight: .bold))
                Text(label).font(.system(size: 10))
            }
            .foregroundColor(tint)
            .frame(width: 58, height: 50)
            .background(tint == .green ? Color.green.opacity(0.22) : Color.white.opacity(0.1))
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
    }

    private func wideActionButton(icon: String, title: String, action: RemoteAction) -> some View {
        Button {
            coordinator.triggerVirtualAction(action)
        } label: {
            Label(title, systemImage: icon)
                .font(.caption.bold())
                .frame(maxWidth: .infinity)
                .frame(height: 44)
                .background(Color.white.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .foregroundColor(.white)
    }

    private func compactButton(icon: String, title: String, action: RemoteAction) -> some View {
        Button {
            coordinator.triggerVirtualAction(action)
        } label: {
            VStack(spacing: 2) {
                Image(systemName: icon).font(.caption)
                Text(title).font(.system(size: 9))
            }
            .frame(maxWidth: .infinity)
            .frame(height: 44)
            .background(Color.white.opacity(0.1))
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .foregroundColor(.white)
    }

    private func systemButton(icon: String, title: String, action: RemoteAction, highlight: Color = .white) -> some View {
        Button {
            coordinator.triggerVirtualAction(action)
        } label: {
            VStack(spacing: 3) {
                Image(systemName: icon).font(.system(size: 15, weight: .semibold))
                Text(title).font(.system(size: 10, weight: .medium))
            }
            .foregroundColor(highlight)
            .frame(maxWidth: .infinity)
            .frame(height: 48)
            .background(highlight == .red ? Color.red.opacity(0.22) : Color.white.opacity(0.09))
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
    }

    private func simChip(_ title: String, color: Color = .white, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.caption2.bold())
                .foregroundColor(color)
                .padding(.horizontal, 8)
                .padding(.vertical, 7)
                .frame(maxWidth: .infinity)
                .background(Color.white.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }
}
