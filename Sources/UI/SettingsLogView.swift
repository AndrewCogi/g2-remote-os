import SwiftUI

struct SettingsLogView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var coordinator: AppCoordinator
    @EnvironmentObject var ble: G2BLEManager
    @EnvironmentObject var os: G2OSStateMachine
    @EnvironmentObject var keeper: BackgroundKeeper
    @EnvironmentObject var calendar: CalendarQuickListService
    @EnvironmentObject var spark: SparkBridgeClient
    @EnvironmentObject var tailscale: TailscaleMonitor

    @State private var showLogs: Bool = false
    @State private var testPromptText: String = ""

    private var appVersionText: String {
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.3.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "v\(short) (Build \(build))"
    }

    var body: some View {
        List {
            Section {
                HStack {
                    Text("Tailscale VPN")
                    Spacer()
                    HStack(spacing: 6) {
                        Circle()
                            .fill(tailscale.isTailscaleConnected ? Color.green : Color.red)
                            .frame(width: 8, height: 8)
                        Text(tailscale.isTailscaleConnected ? "연결됨 (\(tailscale.tailscaleIPv4 ?? ""))" : "꺼짐")
                            .font(.caption.monospaced())
                            .foregroundColor(tailscale.isTailscaleConnected ? .green : .red)
                    }
                }

                HStack {
                    Text("DGX Spark 브릿지")
                    Spacer()
                    Text(spark.isConnected ? "\(spark.activeNodeLabel) · \(spark.latencyMs)ms" : spark.activeNodeLabel)
                        .font(.caption.monospaced())
                        .foregroundColor(spark.isConnected ? .green : .secondary)
                }

                HStack {
                    Text("1순위 (spark01)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    TextField("100.101.25.64:8765", text: $spark.primaryEndpoint)
                        .font(.caption.monospaced())
                        .multilineTextAlignment(.trailing)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                }

                HStack {
                    Text("2순위 (spark02)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    TextField("100.101.25.65:8765", text: $spark.fallbackEndpoint)
                        .font(.caption.monospaced())
                        .multilineTextAlignment(.trailing)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                }

                Picker("agy 추론 속도", selection: $spark.effort) {
                    Text("초고속 (low)").tag("low")
                    Text("균형 (medium)").tag("medium")
                    Text("심층 (high)").tag("high")
                }

                HStack(spacing: 10) {
                    Button(spark.isConnecting ? "연결 중..." : "Spark 연결/재시도") {
                        tailscale.refresh()
                        spark.disconnect()
                        spark.connectWithFailover()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(spark.isConnecting)

                    if let tsURL = URL(string: "tailscale://"), !tailscale.isTailscaleConnected {
                        Button("Tailscale 열기") {
                            UIApplication.shared.open(tsURL)
                        }
                        .buttonStyle(.bordered)
                    }
                }

                HStack {
                    TextField("Even AI 텍스트 테스트 질문...", text: $testPromptText)
                        .font(.caption)
                    Button("전송") {
                        spark.sendTextPrompt(mode: .evenAI, text: testPromptText)
                        testPromptText = ""
                    }
                    .buttonStyle(.bordered)
                    .disabled(testPromptText.trimmingCharacters(in: .whitespaces).isEmpty)
                }

                if let err = spark.lastError {
                    Text(err)
                        .font(.caption2)
                        .foregroundColor(.orange)
                }
            } header: {
                Text("Tailscale & DGX Spark AI (agy)")
            } footer: {
                Text("폰에서 Tailscale을 켜면 자동으로 감지되어 spark01(64) → 실패 시 spark02(65)로 자동 연결되며, G2 안경 상단에도 상태(TS●64 / TS●65 / TS✕)가 실시간 표시됩니다.")
            }

            Section {
                Toggle("항시 G2 OS 유지 (기존 OS 복귀 차단)", isOn: $coordinator.keepAliveEnabled)

                Toggle("4-bit 픽셀 그래픽 시계 (대시보드)", isOn: Binding(
                    get: { os.pixelGraphicsEnabled },
                    set: {
                        os.pixelGraphicsEnabled = $0
                        os.refreshDisplay(pushToGlasses: true)
                    }
                ))

                HStack {
                    Text("백그라운드 보호")
                    Spacer()
                    Text(keeper.isActive ? "동작 중 (3.5초 하트비트)" : "꺼짐")
                        .font(.caption)
                        .foregroundColor(keeper.isActive ? .green : .secondary)
                }

                Button("지금 G2 화면 강제 복구") {
                    ble.ensureScreenActive(forceRecreate: true)
                }
            } header: {
                Text("OS 항시 유지 & 그래픽")
            } footer: {
                Text("항시 유지가 켜져 있으면 화면을 꺼도 기본 OS로 돌아가지 않습니다.")
            }

            Section {
                Toggle("들어깨우기 (고개 들기 대기)", isOn: Binding(
                    get: { os.headUpWakeEnabled },
                    set: {
                        os.setHeadUpWakeMode($0)
                        ble.setImuStreaming($0, reportFreqMs: 250)
                    }
                ))

                Stepper("깨우기 각도: \(os.headUpTriggerAngle)°", value: Binding(
                    get: { os.headUpTriggerAngle },
                    set: {
                        os.headUpTriggerAngle = $0
                        ble.setHeadUp(enabled: os.headUpWakeEnabled, angle: $0)
                    }
                ), in: 10...50, step: 5)

                Stepper("자동 투명 대기: \(os.headUpIdleSeconds)초", value: $os.headUpIdleSeconds, in: 8...60, step: 5)

                HStack {
                    Text("실시간 IMU 각도")
                    Spacer()
                    Text(String(format: "%+.1f° (변화 %+.1f°)", os.currentImu.pitchDegrees, os.lastDeltaPitch))
                        .font(.caption.monospacedDigit())
                        .foregroundColor(.green)
                }

                HStack(spacing: 10) {
                    Button("현재 자세 0° 보정") {
                        os.calibrateHeadUpNeutral()
                    }
                    .buttonStyle(.borderedProminent)

                    Button(os.isHeadUpDimmed ? "화면 깨우기" : "투명 대기 테스트") {
                        if os.isHeadUpDimmed { os.wakeFromHeadUpStandby() } else { os.enterHeadUpStandby() }
                    }
                    .buttonStyle(.bordered)
                }
            } header: {
                Text("들어깨우기 (G2 IMU)")
            } footer: {
                Text("켜두면 일정 시간 후 렌즈가 완전 투명 상태로 대기하며, 고개를 들거나 패드를 터치하면 0.1초 만에 우리 OS가 다시 뜹니다(기본 OS 이탈 없음).")
            }

            Section {
                Toggle("자동 밝기", isOn: Binding(
                    get: { ble.brightnessAuto },
                    set: {
                        os.autoBrightness = $0
                        ble.setAutoBrightness($0)
                    }
                ))

                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("수동 밝기")
                        Spacer()
                        Text("\(ble.brightnessLevel) / 50")
                            .font(.caption.monospacedDigit())
                            .foregroundColor(.green)
                    }
                    Slider(
                        value: Binding(
                            get: { Double(ble.brightnessLevel) },
                            set: {
                                let v = Int($0)
                                os.brightness = v
                                ble.setBrightness(v)
                            }
                        ),
                        in: 1...50,
                        step: 1
                    )
                }

                Stepper("화면 높이 (Y): \(ble.displayHeight) / 20", value: Binding(
                    get: { ble.displayHeight },
                    set: {
                        os.displayHeight = $0
                        ble.setDisplayHeight($0)
                    }
                ), in: 0...20)

                Stepper("화면 거리 (X): \(ble.displayDistance) / 20", value: Binding(
                    get: { ble.displayDistance },
                    set: {
                        os.displayDistance = $0
                        ble.setDisplayDistance($0)
                    }
                ), in: 0...20)

                Toggle("착용 감지 (Wear Detection)", isOn: Binding(
                    get: { ble.wearDetection },
                    set: {
                        os.wearDetection = $0
                        ble.setWearDetection($0)
                    }
                ))

                Toggle("무음 모드 (Silent Mode)", isOn: Binding(
                    get: { ble.silentMode },
                    set: {
                        os.silentMode = $0
                        ble.setSilentMode($0)
                    }
                ))

                Toggle("ANCS 시스템 알림 허용 (실험)", isOn: Binding(
                    get: { ble.ancsEnabled },
                    set: {
                        os.ancsEnabled = $0
                        ble.setAncsNotifications(enabled: $0)
                    }
                ))
            } header: {
                Text("G2 하드웨어 설정 (순정 전체)")
            } footer: {
                Text("ANCS 알림은 아이폰 설정 > Bluetooth > G2 > '시스템 알림 공유'가 켜져 있어야 동작합니다.")
            }

            Section("데이터 연동 (무료 온디바이스)") {
                Button("Apple 캘린더 · 미리알림 연동 허용") {
                    calendar.requestAccessAndSync()
                }
                Button("날씨 · 일정 · 기기 상태 지금 새로고침") {
                    coordinator.refreshAllData()
                }
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
                Text("정보 & 진단")
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
