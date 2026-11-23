import EventKit
import Foundation

public struct G2CalendarEvent: Identifiable, Equatable {
    public let id: String
    public let title: String
    public let startDate: Date
    public let endDate: Date
    public let isAllDay: Bool

    public var timeLabel: String {
        if isAllDay { return "종일" }
        let fmt = DateFormatter()
        fmt.dateFormat = "HH:mm"
        return fmt.string(from: startDate)
    }
}

public struct G2QuickTask: Identifiable, Equatable, Codable {
    public let id: String
    public var title: String
    public var isCompleted: Bool
    public var isFromAppleReminders: Bool

    public init(id: String = UUID().uuidString, title: String, isCompleted: Bool = false, isFromAppleReminders: Bool = false) {
        self.id = id
        self.title = title
        self.isCompleted = isCompleted
        self.isFromAppleReminders = isFromAppleReminders
    }
}

/// Bridges Apple Calendar & Reminders (EventKit) into G2 OS Dashboard and QuickList,
/// with automatic local task storage so QuickList works immediately even without Reminders permission.
public final class CalendarQuickListService: ObservableObject {
    @Published public private(set) var upcomingEvents: [G2CalendarEvent] = []
    @Published public private(set) var tasks: [G2QuickTask] = []
    @Published public private(set) var calendarAuthorized: Bool = false
    @Published public private(set) var remindersAuthorized: Bool = false

    public var onChanged: (() -> Void)?

    private let store = EKEventStore()
    private let localTasksKey = "g2_local_quicklist_v1"
    private var localTasks: [G2QuickTask] = []
    private var refreshTimer: Timer?

    public init() {
        loadLocalTasks()
        tasks = localTasks
    }

    deinit {
        refreshTimer?.invalidate()
    }

    public func start() {
        refreshPermissionsAndData(requestIfNeeded: false)
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            self?.refreshPermissionsAndData(requestIfNeeded: false)
        }
    }

    public func requestAccessAndSync() {
        requestCalendarAccess { [weak self] in
            self?.requestRemindersAccess {
                self?.refreshPermissionsAndData(requestIfNeeded: false)
            }
        }
    }

    public func refresh() {
        refreshPermissionsAndData(requestIfNeeded: false)
    }

    public func addTask(title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        if remindersAuthorized, let defaultCal = store.defaultCalendarForNewReminders() {
            let rem = EKReminder(eventStore: store)
            rem.title = trimmed
            rem.calendar = defaultCal
            if (try? store.save(rem, commit: true)) != nil {
                fetchReminders()
                return
            }
        }

        let item = G2QuickTask(title: trimmed, isCompleted: false, isFromAppleReminders: false)
        localTasks.insert(item, at: 0)
        saveLocalTasks()
        rebuildMergedTasks(appleReminders: [])
    }

    public func toggleTask(id: String) {
        if let idx = tasks.firstIndex(where: { $0.id == id }), tasks[idx].isFromAppleReminders {
            if let rem = store.calendarItem(withIdentifier: id) as? EKReminder {
                rem.isCompleted.toggle()
                try? store.save(rem, commit: true)
                fetchReminders()
                return
            }
        }

        if let idx = localTasks.firstIndex(where: { $0.id == id }) {
            localTasks[idx].isCompleted.toggle()
            saveLocalTasks()
        }
        if let idx = tasks.firstIndex(where: { $0.id == id }) {
            tasks[idx].isCompleted.toggle()
            onChanged?()
        }
    }

    public func deleteTask(id: String) {
        if let rem = store.calendarItem(withIdentifier: id) as? EKReminder {
            try? store.remove(rem, commit: true)
            fetchReminders()
            return
        }
        localTasks.removeAll { $0.id == id }
        saveLocalTasks()
        tasks.removeAll { $0.id == id }
        onChanged?()
    }

    // MARK: - EventKit Helpers

    private func refreshPermissionsAndData(requestIfNeeded: Bool) {
        let calStatus = EKEventStore.authorizationStatus(for: .event)
        let remStatus = EKEventStore.authorizationStatus(for: .reminder)

        let calOk: Bool
        let remOk: Bool
        if #available(iOS 17.0, *) {
            calOk = (calStatus == .fullAccess || calStatus == .authorized)
            remOk = (remStatus == .fullAccess || remStatus == .authorized)
        } else {
            calOk = (calStatus == .authorized)
            remOk = (remStatus == .authorized)
        }

        DispatchQueue.main.async {
            self.calendarAuthorized = calOk
            self.remindersAuthorized = remOk
        }

        if calOk {
            fetchUpcomingEvents()
        } else if requestIfNeeded {
            requestCalendarAccess { [weak self] in self?.fetchUpcomingEvents() }
        }

        if remOk {
            fetchReminders()
        } else {
            DispatchQueue.main.async {
                self.tasks = self.localTasks
                self.onChanged?()
            }
        }
    }

    private func requestCalendarAccess(completion: @escaping () -> Void) {
        if #available(iOS 17.0, *) {
            store.requestFullAccessToEvents { [weak self] granted, _ in
                DispatchQueue.main.async {
                    self?.calendarAuthorized = granted
                    if granted { self?.fetchUpcomingEvents() }
                    completion()
                }
            }
        } else {
            store.requestAccess(to: .event) { [weak self] granted, _ in
                DispatchQueue.main.async {
                    self?.calendarAuthorized = granted
                    if granted { self?.fetchUpcomingEvents() }
                    completion()
                }
            }
        }
    }

    private func requestRemindersAccess(completion: @escaping () -> Void) {
        if #available(iOS 17.0, *) {
            store.requestFullAccessToReminders { [weak self] granted, _ in
                DispatchQueue.main.async {
                    self?.remindersAuthorized = granted
                    if granted { self?.fetchReminders() }
                    completion()
                }
            }
        } else {
            store.requestAccess(to: .reminder) { [weak self] granted, _ in
                DispatchQueue.main.async {
                    self?.remindersAuthorized = granted
                    if granted { self?.fetchReminders() }
                    completion()
                }
            }
        }
    }

    private func fetchUpcomingEvents() {
        let now = Date()
        let end = Calendar.current.date(byAdding: .hour, value: 36, to: now) ?? now.addingTimeInterval(36 * 3600)
        let pred = store.predicateForEvents(withStart: now.addingTimeInterval(-1800), end: end, calendars: nil)
        let events = store.events(matching: pred)
            .filter { $0.endDate >= now }
            .sorted { $0.startDate < $1.startDate }
            .prefix(8)
            .map {
                G2CalendarEvent(
                    id: $0.eventIdentifier ?? UUID().uuidString,
                    title: $0.title ?? "(제목 없음)",
                    startDate: $0.startDate,
                    endDate: $0.endDate,
                    isAllDay: $0.isAllDay
                )
            }
        DispatchQueue.main.async {
            self.upcomingEvents = Array(events)
            self.onChanged?()
        }
    }

    private func fetchReminders() {
        let pred = store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: nil)
        store.fetchReminders(matching: pred) { [weak self] items in
            guard let self else { return }
            let mapped = (items ?? []).prefix(12).map {
                G2QuickTask(
                    id: $0.calendarItemIdentifier,
                    title: $0.title ?? "(할 일)",
                    isCompleted: $0.isCompleted,
                    isFromAppleReminders: true
                )
            }
            DispatchQueue.main.async {
                self.rebuildMergedTasks(appleReminders: Array(mapped))
            }
        }
    }

    private func rebuildMergedTasks(appleReminders: [G2QuickTask]) {
        if appleReminders.isEmpty && remindersAuthorized {
            tasks = localTasks
        } else if !appleReminders.isEmpty {
            tasks = appleReminders + localTasks
        } else {
            tasks = localTasks
        }
        onChanged?()
    }

    private func loadLocalTasks() {
        if let data = UserDefaults.standard.data(forKey: localTasksKey),
           let decoded = try? JSONDecoder().decode([G2QuickTask].self, from: data),
           !decoded.isEmpty {
            localTasks = decoded
        } else {
            localTasks = [
                G2QuickTask(title: "G2 들어깨우기 각도 맞추기"),
                G2QuickTask(title: "알람 · 타이머 동작 테스트"),
                G2QuickTask(title: "캘린더 / 미리알림 연동 켜기")
            ]
        }
    }

    private func saveLocalTasks() {
        if let data = try? JSONEncoder().encode(localTasks) {
            UserDefaults.standard.set(data, forKey: localTasksKey)
        }
    }
}
