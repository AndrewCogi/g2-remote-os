import Foundation
#if canImport(UIKit)
import UIKit
#endif
import UserNotifications

public struct G2AlarmItem: Identifiable, Equatable, Codable {
    public let id: String
    public var hour: Int
    public var minute: Int
    public var label: String
    public var isEnabled: Bool
    /// Empty = one-shot; otherwise 1=Sun .. 7=Sat
    public var repeatWeekdays: [Int]

    public init(
        id: String = UUID().uuidString,
        hour: Int,
        minute: Int,
        label: String = "알람",
        isEnabled: Bool = true,
        repeatWeekdays: [Int] = []
    ) {
        self.id = id
        self.hour = max(0, min(23, hour))
        self.minute = max(0, min(59, minute))
        self.label = label.isEmpty ? "알람" : label
        self.isEnabled = isEnabled
        self.repeatWeekdays = repeatWeekdays
    }

    public var timeText: String {
        String(format: "%02d:%02d", hour, minute)
    }
}

public struct G2ActiveAlert: Equatable {
    public enum Kind: String {
        case alarm = "알람"
        case timer = "타이머 종료"
    }
    public let id: String
    public let kind: Kind
    public let title: String
    public let firedAt: Date
}

/// Full Alarm, Countdown Timer, and Stopwatch engine for G2 OS.
/// Triggers both full-screen G2 HUD alerts (with haptics / Flic buzzer) and iOS local notifications.
public final class AlarmTimerService: ObservableObject {
    @Published public var alarms: [G2AlarmItem] = []

    // Countdown timer
    @Published public private(set) var timerTotalSeconds: Int = 300
    @Published public private(set) var timerRemainingSeconds: Int = 300
    @Published public private(set) var isTimerRunning: Bool = false

    // Stopwatch
    @Published public private(set) var stopwatchSeconds: Int = 0
    @Published public private(set) var isStopwatchRunning: Bool = false
    @Published public private(set) var stopwatchLaps: [Int] = []

    // Active ringing alert displayed as full-screen G2 popup
    @Published public private(set) var activeAlert: G2ActiveAlert?

    public var onTick: (() -> Void)?
    public var onAlertStarted: ((G2ActiveAlert) -> Void)?
    public var onAlertDismissed: (() -> Void)?

    private let alarmsKey = "g2_alarms_v1"
    private var tickTimer: Timer?
    private var timerEndDate: Date?
    private var lastFiredAlarmStamp: [String: String] = [:]

    public init() {
        loadAlarms()
    }

    deinit {
        tickTimer?.invalidate()
    }

    public func start() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
        tickTimer?.invalidate()
        tickTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.handleOneSecondTick()
        }
    }

    // MARK: - Alarms

    public func addAlarm(hour: Int, minute: Int, label: String, repeatWeekdays: [Int] = []) {
        let item = G2AlarmItem(hour: hour, minute: minute, label: label, isEnabled: true, repeatWeekdays: repeatWeekdays)
        alarms.append(item)
        alarms.sort { ($0.hour * 60 + $0.minute) < ($1.hour * 60 + $1.minute) }
        saveAlarms()
        scheduleLocalNotification(for: item)
        onTick?()
    }

    public func toggleAlarm(id: String) {
        guard let idx = alarms.firstIndex(where: { $0.id == id }) else { return }
        alarms[idx].isEnabled.toggle()
        saveAlarms()
        if alarms[idx].isEnabled {
            scheduleLocalNotification(for: alarms[idx])
        } else {
            UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ["alarm_\(id)"])
        }
        onTick?()
    }

    public func deleteAlarm(id: String) {
        alarms.removeAll { $0.id == id }
        saveAlarms()
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ["alarm_\(id)"])
        onTick?()
    }

    public var nextEnabledAlarm: G2AlarmItem? {
        let cal = Calendar.current
        let nowComps = cal.dateComponents([.hour, .minute], from: Date())
        let nowMin = (nowComps.hour ?? 0) * 60 + (nowComps.minute ?? 0)
        let enabled = alarms.filter(\.isEnabled)
        guard !enabled.isEmpty else { return nil }
        return enabled.min { a, b in
            let ma = (a.hour * 60 + a.minute - nowMin + 1440) % 1440
            let mb = (b.hour * 60 + b.minute - nowMin + 1440) % 1440
            return (ma == 0 ? 1440 : ma) < (mb == 0 ? 1440 : mb)
        }
    }

    // MARK: - Countdown Timer

    public func setTimerDuration(seconds: Int) {
        let clamped = max(10, min(36000, seconds))
        isTimerRunning = false
        timerEndDate = nil
        timerTotalSeconds = clamped
        timerRemainingSeconds = clamped
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ["g2_timer"])
        onTick?()
    }

    public func toggleTimer() {
        if isTimerRunning {
            isTimerRunning = false
            timerEndDate = nil
            UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ["g2_timer"])
        } else {
            if timerRemainingSeconds <= 0 {
                timerRemainingSeconds = timerTotalSeconds
            }
            isTimerRunning = true
            timerEndDate = Date().addingTimeInterval(TimeInterval(timerRemainingSeconds))
            scheduleTimerNotification(seconds: timerRemainingSeconds)
        }
        onTick?()
    }

    public func resetTimer() {
        isTimerRunning = false
        timerEndDate = nil
        timerRemainingSeconds = timerTotalSeconds
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ["g2_timer"])
        onTick?()
    }

    // MARK: - Stopwatch

    public func toggleStopwatch() {
        isStopwatchRunning.toggle()
        onTick?()
    }

    public func lapStopwatch() {
        guard isStopwatchRunning || stopwatchSeconds > 0 else { return }
        stopwatchLaps.insert(stopwatchSeconds, at: 0)
        if stopwatchLaps.count > 5 { stopwatchLaps.removeLast() }
        onTick?()
    }

    public func resetStopwatch() {
        isStopwatchRunning = false
        stopwatchSeconds = 0
        stopwatchLaps.removeAll()
        onTick?()
    }

    // MARK: - Alert Dismissal / Snooze

    public func dismissActiveAlert() {
        guard activeAlert != nil else { return }
        activeAlert = nil
        onAlertDismissed?()
        onTick?()
    }

    public func snoozeActiveAlert(minutes: Int = 5) {
        guard let current = activeAlert else { return }
        activeAlert = nil
        let target = Date().addingTimeInterval(TimeInterval(minutes * 60))
        let comps = Calendar.current.dateComponents([.hour, .minute], from: target)
        addAlarm(
            hour: comps.hour ?? 0,
            minute: comps.minute ?? 0,
            label: "\(current.title) (스누즈)"
        )
        onAlertDismissed?()
    }

    public static func formatDuration(_ totalSeconds: Int) -> String {
        let s = max(0, totalSeconds)
        let hrs = s / 3600
        let mins = (s % 3600) / 60
        let secs = s % 60
        if hrs > 0 {
            return String(format: "%d:%02d:%02d", hrs, mins, secs)
        }
        return String(format: "%02d:%02d", mins, secs)
    }

    // MARK: - Internal 1s Engine

    private func handleOneSecondTick() {
        var needsUI = false

        // 1. Check Countdown Timer
        if isTimerRunning, let end = timerEndDate {
            let rem = max(0, Int(ceil(end.timeIntervalSinceNow)))
            if rem != timerRemainingSeconds {
                timerRemainingSeconds = rem
                needsUI = true
            }
            if rem == 0 {
                isTimerRunning = false
                timerEndDate = nil
                fireAlert(G2ActiveAlert(id: "timer_\(Date().timeIntervalSince1970)", kind: .timer, title: "타이머 완료 (\(Self.formatDuration(timerTotalSeconds)))", firedAt: Date()))
                return
            }
        }

        // 2. Check Stopwatch
        if isStopwatchRunning {
            stopwatchSeconds += 1
            needsUI = true
        }

        // 3. Check Wall-Clock Alarms
        let now = Date()
        let cal = Calendar.current
        let comps = cal.dateComponents([.year, .month, .day, .hour, .minute, .second, .weekday], from: now)
        if let h = comps.hour, let m = comps.minute, let s = comps.second, let wd = comps.weekday, s <= 2 {
            let stamp = "\(comps.year ?? 0)-\(comps.month ?? 0)-\(comps.day ?? 0)-\(h)-\(m)"
            for i in alarms.indices where alarms[i].isEnabled {
                let alarm = alarms[i]
                guard alarm.hour == h, alarm.minute == m else { continue }
                guard alarm.repeatWeekdays.isEmpty || alarm.repeatWeekdays.contains(wd) else { continue }
                guard lastFiredAlarmStamp[alarm.id] != stamp else { continue }
                lastFiredAlarmStamp[alarm.id] = stamp

                if alarm.repeatWeekdays.isEmpty {
                    alarms[i].isEnabled = false
                    saveAlarms()
                }
                fireAlert(G2ActiveAlert(id: alarm.id, kind: .alarm, title: "\(alarm.timeText) \(alarm.label)", firedAt: now))
                return
            }
        }

        // 4. Periodic haptic pulse while alert is actively ringing
        if activeAlert != nil {
            #if canImport(UIKit)
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
            #endif
        }

        if needsUI {
            onTick?()
        }
    }

    private func fireAlert(_ alert: G2ActiveAlert) {
        activeAlert = alert
        #if canImport(UIKit)
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
        #endif
        onAlertStarted?(alert)
        onTick?()
    }

    private func scheduleLocalNotification(for alarm: G2AlarmItem) {
        let content = UNMutableNotificationContent()
        content.title = "G2 OS 알람"
        content.body = "\(alarm.timeText) · \(alarm.label)"
        content.sound = .default

        var comps = DateComponents()
        comps.hour = alarm.hour
        comps.minute = alarm.minute
        let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: !alarm.repeatWeekdays.isEmpty)
        let req = UNNotificationRequest(identifier: "alarm_\(alarm.id)", content: content, trigger: trigger)
        UNUserNotificationCenter.current().add(req)
    }

    private func scheduleTimerNotification(seconds: Int) {
        guard seconds > 0 else { return }
        let content = UNMutableNotificationContent()
        content.title = "G2 OS 타이머 완료"
        content.body = "\(Self.formatDuration(seconds)) 타이머가 종료되었습니다."
        content.sound = .default

        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: TimeInterval(seconds), repeats: false)
        let req = UNNotificationRequest(identifier: "g2_timer", content: content, trigger: trigger)
        UNUserNotificationCenter.current().add(req)
    }

    private func loadAlarms() {
        if let data = UserDefaults.standard.data(forKey: alarmsKey),
           let decoded = try? JSONDecoder().decode([G2AlarmItem].self, from: data) {
            alarms = decoded
        } else {
            alarms = [
                G2AlarmItem(hour: 8, minute: 0, label: "기상 알람", isEnabled: false, repeatWeekdays: [2, 3, 4, 5, 6])
            ]
        }
    }

    private func saveAlarms() {
        if let data = try? JSONEncoder().encode(alarms) {
            UserDefaults.standard.set(data, forKey: alarmsKey)
        }
    }
}
