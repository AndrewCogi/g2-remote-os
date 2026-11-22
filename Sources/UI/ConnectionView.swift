import SwiftUI

struct ConnectionView: View {
    @EnvironmentObject var ble: G2BLEManager
    @EnvironmentObject var flic: FlicDuoDriver

    var body: some View {
        List {
            Section {
                HStack {
                    Text("상태")
                    Spacer()
                    Text(ble.phase.rawValue)
                        .foregroundColor(ble.phase == .connected ? .green : .secondary)
                }
                HStack {
                    Text("렌즈 링크")
                    Spacer()
                    Text("L: \(ble.leftConnected ? "연결" : "대기")  /  R: \(ble.rightConnected ? "연결" : "대기")")
                        .font(.caption.monospaced())
                }
                if let battery = ble.batteryLevel {
                    HStack {
                        Text("G2 배터리 / 펌웨어")
                        Spacer()
                        Text("\(battery)% (\(ble.firmwareLeft)/\(ble.firmwareRight))")
                            .font(.caption.monospaced())
                    }
                }

                HStack(spacing: 10) {
                    if ble.phase == .scanning {
                        Button("스캔 중지", role: .destructive) { ble.stopScan() }
                    } else if ble.phase == .connected || ble.phase == .connecting || ble.phase == .handshaking {
                        Button("연결 해제", role: .destructive) { ble.disconnect() }
                    } else {
                        Button("G2 안경 스캔") { ble.startScan() }
                            .buttonStyle(.borderedProminent)
                        Button("저장된 페어 재연결") { ble.reconnectSavedPair() }
                            .buttonStyle(.bordered)
                    }
                }
            } header: {
                Text("1. Even Realities G2 안경")
            } footer: {
                Text("중요: G2 안경은 한 번에 하나의 앱만 연결할 수 있습니다. 스캔 전에 공식 Even 앱을 완전히 종료(위로 밀어 닫기)해 주세요.")
            }

            if !ble.discoveredPairs.isEmpty {
                Section("검색된 G2 페어") {
                    ForEach(ble.discoveredPairs) { pair in
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("G2 Pair #\(pair.id)")
                                    .font(.headline)
                                Text("L: \(pair.leftName ?? "대기중") | R: \(pair.rightName ?? "대기중")")
                                    .font(.caption2.monospaced())
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            Button(pair.isComplete ? "연결" : "양쪽 대기") {
                                ble.connect(pair: pair)
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(!pair.isComplete)
                        }
                    }
                }
            }

            Section {
                HStack {
                    Text("SDK 상태")
                    Spacer()
                    Text(flic.managerStateText)
                        .foregroundColor(.secondary)
                }
                if let name = flic.pairedButtonName {
                    HStack {
                        Text("등록된 리모콘")
                        Spacer()
                        Text("\(name) (\(flic.isDuoHardware ? "Duo" : "Flic 2"))")
                            .foregroundColor(flic.isReady ? .green : .orange)
                    }
                    HStack {
                        Text("배터리 전압")
                        Spacer()
                        Text(flic.batteryVoltage > 0 ? String(format: "%.2f V", flic.batteryVoltage) : "측정 중")
                            .font(.caption.monospaced())
                    }
                    HStack {
                        Text("최근 Flic 신호")
                        Spacer()
                        Text(flic.lastRawEventText)
                            .font(.caption2.monospaced())
                            .foregroundColor(.green)
                    }
                }

                HStack(spacing: 10) {
                    if flic.isScanning {
                        Button("스캔 중지", role: .destructive) { flic.stopScan() }
                    } else {
                        Button("Flic Duo 페어링 스캔") { flic.startScan() }
                            .buttonStyle(.borderedProminent)
                    }
                    if flic.isReady && flic.isDuoHardware {
                        Button("버저 테스트") { flic.testBuzzer() }
                            .buttonStyle(.bordered)
                    }
                    if flic.pairedButtonName != nil {
                        Button("삭제", role: .destructive) { flic.forgetPairedButton() }
                    }
                }
            } header: {
                Text("2. Flic Duo / Flic 2 리모콘 (화면 꺼짐 백그라운드 지원)")
            } footer: {
                Text("페어링 시 Flic Duo의 버튼을 6초 이상 길게 눌러 페어링 모드로 진입한 뒤 위 스캔 버튼을 누르세요. Flic Hub 없이 아이폰에 직접 연결됩니다.")
            }
        }
        .navigationTitle("기기 연결")
    }
}
