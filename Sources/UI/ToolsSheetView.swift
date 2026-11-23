import SwiftUI

/// Companion sheet for managing Alarms, Timers, QuickList tasks, and Teleprompter scripts.
struct ToolsSheetView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var coordinator: AppCoordinator
    @EnvironmentObject var os: G2OSStateMachine
    @EnvironmentObject var calendar: CalendarQuickListService
    @EnvironmentObject var clockTools: AlarmTimerService

    @State private var selectedSection = 0
    @State private var newAlarmDate = Date().addingTimeInterval(3600)
    @State private var newAlarmLabel = "알람"
    @State private var newTaskTitle = ""
    @State private var scriptTitle = "내 대본 / 메모"
    @State private var scriptBody = """
    여기에 발표 대본이나 메모를 입력하세요.
    저장하면 G2 안경의 '텔레프롬프터' 2번째 문서로 즉시 반영됩니다.
    """

    var body: some View {
        VStack(spacing: 0) {
            Picker("도구", selection: $selectedSection) {
                Text("알람·타이머").tag(0)
                Text("QuickList").tag(1)
                Text("텔레프롬프터").tag(2)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            if selectedSection == 0 {
                alarmsAndTimerList
            } else if selectedSection == 1 {
                quickListSection
            } else {
                teleprompterSection
            }
        }
        .tint(.green)
        .navigationTitle("G2 도구")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("완료") { dismiss() }
            }
        }
    }

    // MARK: - Alarms & Timer

    private var alarmsAndTimerList: some View {
        List {
            if let alert = clockTools.activeAlert {
                Section("울리는 알림") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("\(alert.kind.rawValue) · \(alert.title)")
                            .font(.headline)
                            .foregroundColor(.red)
                        HStack {
                            Button("끄기") { clockTools.dismissActiveAlert() }
                                .buttonStyle(.borderedProminent)
                            Button("5분 스누즈") { clockTools.snoozeActiveAlert(minutes: 5) }
                                .buttonStyle(.bordered)
                        }
                    }
                }
            }

            Section("새 알람 추가") {
                DatePicker("시간", selection: $newAlarmDate, displayedComponents: .hourAndMinute)
                TextField("라벨", text: $newAlarmLabel)
                Button("알람 저장") {
                    let comps = Calendar.current.dateComponents([.hour, .minute], from: newAlarmDate)
                    clockTools.addAlarm(hour: comps.hour ?? 8, minute: comps.minute ?? 0, label: newAlarmLabel)
                    newAlarmLabel = "알람"
                }
                .buttonStyle(.borderedProminent)
            }

            Section("등록된 알람 (\(clockTools.alarms.count))") {
                if clockTools.alarms.isEmpty {
                    Text("알람이 없습니다.").foregroundColor(.secondary)
                } else {
                    ForEach(clockTools.alarms) { alarm in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(alarm.timeText)
                                    .font(.title3.monospacedDigit().bold())
                                Text(alarm.label)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            Toggle("", isOn: Binding(
                                get: { alarm.isEnabled },
                                set: { _ in clockTools.toggleAlarm(id: alarm.id) }
                            ))
                            .labelsHidden()
                        }
                        .swipeActions {
                            Button("삭제", role: .destructive) {
                                clockTools.deleteAlarm(id: alarm.id)
                            }
                        }
                    }
                }
            }

            Section("빠른 타이머") {
                HStack {
                    Text(AlarmTimerService.formatDuration(clockTools.timerRemainingSeconds))
                        .font(.title2.monospacedDigit().bold())
                        .foregroundColor(.green)
                    Spacer()
                    Button(clockTools.isTimerRunning ? "일시정지" : "시작") {
                        clockTools.toggleTimer()
                    }
                    .buttonStyle(.borderedProminent)
                    Button("리셋") {
                        clockTools.resetTimer()
                    }
                    .buttonStyle(.bordered)
                }

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach([1, 3, 5, 10, 15, 30], id: \.self) { min in
                            Button("\(min)분") {
                                clockTools.setTimerDuration(seconds: min * 60)
                            }
                            .buttonStyle(.bordered)
                            .font(.caption)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }

    // MARK: - QuickList & Calendar

    private var quickListSection: some View {
        List {
            Section {
                HStack {
                    TextField("새 할 일 입력...", text: $newTaskTitle)
                    Button("추가") {
                        calendar.addTask(title: newTaskTitle)
                        newTaskTitle = ""
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(newTaskTitle.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            } header: {
                Text("할 일 추가 (G2 QuickList 즉시 반영)")
            }

            Section("할 일 목록 (\(calendar.tasks.count))") {
                ForEach(calendar.tasks) { task in
                    HStack {
                        Button {
                            calendar.toggleTask(id: task.id)
                        } label: {
                            Image(systemName: task.isCompleted ? "checkmark.circle.fill" : "circle")
                                .foregroundColor(task.isCompleted ? .green : .secondary)
                        }
                        .buttonStyle(.plain)

                        Text(task.title)
                            .strikethrough(task.isCompleted)
                            .foregroundColor(task.isCompleted ? .secondary : .primary)

                        Spacer()
                        if task.isFromAppleReminders {
                            Text("미리알림")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }
                    .swipeActions {
                        Button("삭제", role: .destructive) {
                            calendar.deleteTask(id: task.id)
                        }
                    }
                }
            }

            Section("Apple 캘린더 · 미리알림 연동") {
                HStack {
                    Text("캘린더 / 미리알림")
                    Spacer()
                    Text("\(calendar.calendarAuthorized ? "캘린더 ON" : "미연동") · \(calendar.remindersAuthorized ? "미리알림 ON" : "미연동")")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Button("권한 허용 및 지금 동기화") {
                    calendar.requestAccessAndSync()
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    // MARK: - Teleprompter Script Editor

    private var teleprompterSection: some View {
        List {
            Section("텔레프롬프터 대본 편집") {
                TextField("문서 제목", text: $scriptTitle)
                TextEditor(text: $scriptBody)
                    .frame(height: 180)
                    .font(.body)
                Button("G2 텔레프롬프터에 반영") {
                    os.updateCustomDocument(title: scriptTitle, body: scriptBody)
                    coordinator.appendLog("[OS] 텔레프롬프터 대본 반영: \(scriptTitle)")
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }
}
