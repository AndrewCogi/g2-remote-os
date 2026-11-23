import SwiftUI

struct SettingsLogView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var coordinator: AppCoordinator
    @EnvironmentObject var ble: G2BLEManager
    @EnvironmentObject var os: G2OSStateMachine
    @EnvironmentObject var keeper: BackgroundKeeper

    @State private var customTitle: String = "내 메모"
    @State private var customBody: String = """
    여기에 발표 대본이나 메모를 입력하세요.
    저장하면 G2 안경의 '메모 리더'에 즉시 반영됩니다.
    모션 패드에서 위/아래 스와이프로 스크롤하세요.
    """
    @State private var showLogs: Bool = false

    private var appVersionText: String {
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.2.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "v\(short) (Build \(build))"
    }

    var body: some View {
        List {
            Section {
                Toggle("항시 G2 OS 유지 (기존 OS 복귀 차단)", isOn: $coordinator.keepAliveEnabled)

                HStack {
                    Text("백그라운드 보호")
                    Spacer()
                    Text(keeper.isActive ? "동작 중 (3.5초 하트비트 보호)" : "꺼짐")
                        .font(.caption)
                        .foregroundColor(keeper.isActive ? .green : .secondary)
                }

                Button("지금 G2 화면 강제 복구") {
                    ble.ensureScreenActive(forceRecreate: true)
                }
            } header: {
                Text("OS 항시 유지")
            } footer: {
                Text("켜두면 아이폰 화면을 꺼도 무음 오디오 믹스와 3.5초 하트비트로 G2가 기본 OS로 돌아가지 않도록 유지하며, 이탈 신호가 감지되어도 자동으로 복귀합니다.")
            }

            Section("메모 리더 문서 편집") {
                TextField("문서 제목", text: $customTitle)
                TextEditor(text: $customBody)
                    .frame(height: 110)
                    .font(.caption)
                Button("G2 메모 리더에 반영") {
                    os.updateCustomDocument(title: customTitle, body: customBody)
                    coordinator.appendLog("[OS] 사용자 메모 반영: \(customTitle)")
                }
                .buttonStyle(.borderedProminent)
            }

            if let saved = coordinator.lastSavedRecordingPath {
                Section("최근 저장된 G2 마이크 녹음") {
                    Text(saved)
                        .font(.caption.monospaced())
                        .foregroundColor(.green)
                }
            }

            Section {
                HStack {
                    Text("앱 버전")
                    Spacer()
                    Text(appVersionText)
                        .font(.caption.monospaced())
                        .foregroundColor(.secondary)
                }

                DisclosureGroup("실시간 시스템 로그 (\(coordinator.logs.count))", isExpanded: $showLogs) {
                    if coordinator.logs.isEmpty {
                        Text("로그가 없습니다.")
                            .foregroundColor(.secondary)
                    } else {
                        Button("로그 지우기", role: .destructive) {
                            coordinator.clearLogs()
                        }
                        .font(.caption)

                        ForEach(Array(coordinator.logs.prefix(60).enumerated()), id: \.offset) { _, line in
                            Text(line)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(.secondary)
                        }
                    }
                }
            } header: {
                Text("진단")
            }
        }
        .tint(.green)
        .navigationTitle("설정")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("완료") { dismiss() }
            }
        }
    }
}
