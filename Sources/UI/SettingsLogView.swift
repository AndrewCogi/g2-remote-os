import SwiftUI

struct SettingsLogView: View {
    @EnvironmentObject var coordinator: AppCoordinator
    @EnvironmentObject var ble: G2BLEManager
    @EnvironmentObject var os: G2OSStateMachine
    @EnvironmentObject var keeper: BackgroundKeeper

    @State private var customTitle: String = "내 메모"
    @State private var customBody: String = """
    여기에 원하는 발표 대본이나 메모를 입력하세요.
    저장하면 G2 안경의 '스크롤 리더' 3번째 문서로 즉시 올라갑니다.
    Flic Duo로 화면 꺼진 상태에서 위/아래 스크롤할 수 있습니다.
    """

    var body: some View {
        List {
            Section {
                Toggle("화면 꺼짐 백그라운드 상시 유지 (무음 믹스)", isOn: $coordinator.keepAliveEnabled)
                HStack {
                    Text("유지 엔진 상태")
                    Spacer()
                    Text(keeper.isActive ? "동작 중 (4초 하트비트 보호)" : "꺼짐 (버튼 클릭 시 자동 복구)")
                        .font(.caption)
                        .foregroundColor(keeper.isActive ? .green : .secondary)
                }
            } header: {
                Text("백그라운드 동작 옵션")
            } footer: {
                Text("켜두면 아이폰 화면을 꺼도 4초 G2 하트비트가 멈추지 않아 화면이 즉시 유지됩니다(다른 앱 음악과 믹스됨). 꺼두어도 Flic Duo 버튼을 누르면 0.5초 내로 화면이 자동 복구됩니다.")
            }

            Section("스크롤 리더용 내 문서 추가") {
                TextField("문서 제목", text: $customTitle)
                TextEditor(text: $customBody)
                    .frame(height: 110)
                    .font(.caption)
                Button("G2 스크롤 리더에 반영") {
                    os.updateCustomDocument(title: customTitle, body: customBody)
                    coordinator.appendLog("[OS] 사용자 문서 반영 완료: \(customTitle)")
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
                if coordinator.logs.isEmpty {
                    Text("로그가 없습니다.").foregroundColor(.secondary)
                } else {
                    ForEach(Array(coordinator.logs.prefix(60).enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.primary)
                    }
                }
            } header: {
                HStack {
                    Text("실시간 BLE / Flic / OS 로그")
                    Spacer()
                    Button("지우기") { coordinator.clearLogs() }
                        .font(.caption)
                }
            }
        }
        .navigationTitle("설정 & 로그")
    }
}
