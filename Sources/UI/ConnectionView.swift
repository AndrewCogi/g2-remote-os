import SwiftUI

struct ConnectionView: View {
    @Environment(\.dismiss) private var dismiss
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
                        Text("배터리 / 펌웨어")
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
                        if ble.phase == .connected {
                            Button("화면 복구") { ble.ensureScreenActive(forceRecreate: true) }
                                .buttonStyle(.bordered)
                        }
                    } else {
                        Button("G2 안경 스캔") { ble.startScan() }
                            .buttonStyle(.borderedProminent)
                        if ble.hasSavedPair {
                            Button("빠른 재연결") { ble.reconnectSavedPair() }
                                .buttonStyle(.bordered)
                        }
                    }
                }
            } header: {
                Text("Even Realities G2 안경")
            } footer: {
                Text("스캔 전에 공식 Even 앱을 완전히 종료해 주세요. 한 번 연결하면 다음부터는 자동으로 재연결됩니다.")
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
                    Text("상태")
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
                }

                HStack(spacing: 10) {
                    if flic.isScanning {
                        Button("스캔 중지", role: .destructive) { flic.stopScan() }
                    } else {
                        Button("Flic Duo 페어링") { flic.startScan() }
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
                Text("Flic Duo 리모콘 (도착 후 연결)")
            } footer: {
                Text("Flic Duo 버튼을 6초 이상 길게 눌러 페어링 모드에 진입한 뒤 스캔을 누르세요.")
            }
        }
        .tint(.green)
        .navigationTitle("기기 연결")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("완료") { dismiss() }
            }
        }
    }
}
