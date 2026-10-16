import CalendarDomain
import Foundation

/// Fictional calendars, events and reminders for screenshots and trying the app out
/// (launch with `-demo YES`). Nothing here touches EventKit, the Keychain or Google.
/// All data is relative to the current week, so "today" always has something on it.
nonisolated final class DemoProvider: CalendarProvider, TaskProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var allEvents: [Event] = []
    private var allTasks: [TaskItem] = []
    private let math = CalendarMath()

    let sources = [
        CalendarSource(id: "src-icloud", title: "iCloud", kind: .iCloud),
        CalendarSource(id: "src-google", title: "you@example.com", kind: .google, accountEmail: "you@example.com"),
        CalendarSource(id: "src-subscribed", title: "Other", kind: .subscribed),
    ]

    let calendarList = [
        CalendarInfo(id: "cal-personal", title: "Personal", color: CalendarPalette.hex(0x5E8BF0), sourceID: "src-icloud"),
        CalendarInfo(id: "cal-family", title: "Family", color: CalendarPalette.hex(0xF2994A), sourceID: "src-icloud"),
        CalendarInfo(id: "cal-fitness", title: "Fitness", color: CalendarPalette.hex(0x3DBE74), sourceID: "src-icloud"),
        CalendarInfo(id: "cal-work", title: "Work", color: CalendarPalette.hex(0x9B6CF2), sourceID: "src-google"),
        CalendarInfo(id: "cal-team", title: "Team Events", color: CalendarPalette.hex(0x2BB3C0), sourceID: "src-google"),
        CalendarInfo(id: "cal-holidays", title: "Holidays", color: CalendarPalette.hex(0xEB5757), sourceID: "src-subscribed", allowsContentModifications: false, isSubscribed: true),
    ]

    let lists = [
        CalendarInfo(id: "list-personal", title: "Reminders", color: CalendarPalette.hex(0xF2994A), sourceID: "src-icloud", entityType: .tasks),
        CalendarInfo(id: "list-groceries", title: "Groceries", color: CalendarPalette.hex(0x3DBE74), sourceID: "src-icloud", entityType: .tasks),
        CalendarInfo(id: "list-work", title: "Work To-Dos", color: CalendarPalette.hex(0x9B6CF2), sourceID: "src-icloud", entityType: .tasks),
    ]

    /// Work calendars treated as "connected to Google", so Meet and invitees show.
    static let googleCalendars: [String: RemoteCalendarRef] = [
        "cal-work": RemoteCalendarRef(accountEmail: "you@example.com", calendarID: "you@example.com"),
        "cal-team": RemoteCalendarRef(accountEmail: "you@example.com", calendarID: "team@example.com"),
    ]

    init() {
        generate()
    }

    // MARK: Sample data

    private func generate() {
        let today = math.startOfDay(Date())
        let me = Attendee(name: "You", email: "you@example.com", status: .accepted, isCurrentUser: true)
        let sam = Attendee(name: "Sam Rivera", email: "sam@example.com", status: .accepted)
        let jordan = Attendee(name: "Jordan Lee", email: "jordan@example.com", status: .tentative)
        let priya = Attendee(name: "Priya Shah", email: "priya@example.com", status: .declined)
        let chris = Attendee(name: "Chris Novak", email: "chris@example.com", status: .pending)
        var counter = 0
        let mon = -mondayOffset(today)

        func at(_ dayOffset: Int, _ hour: Int, _ minute: Int = 0) -> Date {
            math.date(on: math.addingDays(dayOffset, to: today), minute: hour * 60 + minute)
        }
        func add(_ title: String, _ calendar: String, _ start: Date, _ end: Date, allDay: Bool = false,
                 location: String? = nil, attendees: [Attendee] = [], organizer: Attendee? = nil,
                 meet: Bool = false, series: String? = nil) {
            counter += 1
            let id = "demo-\(counter)"
            allEvents.append(Event(
                id: id, seriesID: series ?? id, externalID: (series ?? id) + "@example.com", calendarID: calendar,
                title: title, location: location, start: start, end: end, isAllDay: allDay,
                timeZone: allDay ? nil : .current, occurrenceDate: start,
                recurrence: series == nil ? nil : RecurrenceRule(frequency: .weekly),
                alarms: allDay ? [] : [.relative(-600)], attendees: attendees, organizer: organizer,
                conferenceURL: meet ? URL(string: "https://meet.google.com/abc-defg-hij") : nil
            ))
        }

        for week in -5...6 {
            let base = week * 7
            for weekday in 0..<5 {
                let day = base + weekday - mondayOffset(today)
                add("Team standup", "cal-work", at(day, 9, 30), at(day, 9, 45), attendees: [me, sam, jordan], organizer: sam, meet: true, series: "standup")
            }
            add("Yoga", "cal-fitness", at(base - mondayOffset(today) + 1, 18), at(base - mondayOffset(today) + 1, 19), location: "Studio 5")
            add("Swimming", "cal-fitness", at(base - mondayOffset(today) + 3, 7), at(base - mondayOffset(today) + 3, 8))
        }

        // This week, Monday-based so work happens on weekdays.
        add("Design review", "cal-work", at(mon, 11), at(mon, 12), location: "Room Orion", attendees: [me, sam, jordan, priya], organizer: me, meet: true)
        add("Lunch with Sam", "cal-personal", at(mon, 12, 30), at(mon, 13, 30), location: "Green Bistro")
        add("1:1 with Jordan", "cal-work", at(mon, 15), at(mon, 15, 30), attendees: [me, jordan], organizer: jordan, meet: true)
        add("Pick up kids", "cal-family", at(mon, 16, 30), at(mon, 17))
        add("Roadmap planning", "cal-work", at(mon + 1, 10), at(mon + 1, 12), attendees: [me, sam, priya, chris], organizer: priya, meet: true)
        add("Dentist", "cal-personal", at(mon + 1, 14), at(mon + 1, 15), location: "Smile Clinic")
        add("Team lunch", "cal-team", at(mon + 2, 12), at(mon + 2, 13, 30), location: "Rooftop terrace")
        add("Code review", "cal-work", at(mon + 2, 14, 30), at(mon + 2, 15, 30))
        add("Customer call", "cal-work", at(mon + 2, 15), at(mon + 2, 16), attendees: [me, chris], organizer: me, meet: true)
        add("Piano lesson", "cal-family", at(mon + 2, 17, 30), at(mon + 2, 18, 30))
        add("Offsite", "cal-team", at(mon + 3, 0), at(mon + 5, 0), allDay: true, location: "Lakeside Lodge")
        add("Book club", "cal-personal", at(mon + 3, 19), at(mon + 3, 21))
        add("Sprint demo", "cal-work", at(mon + 4, 14), at(mon + 4, 15), attendees: [me, sam, jordan], organizer: sam, meet: true)
        add("Dinner with friends", "cal-personal", at(mon + 4, 19, 30), at(mon + 4, 22), location: "Casa Luna")
        add("Farmers market", "cal-personal", at(mon + 5, 9), at(mon + 5, 11))
        add("Grandma's birthday", "cal-family", at(mon - 1, 0), at(mon, 0), allDay: true)
        add("Movie night", "cal-family", at(mon - 1, 20), at(mon - 1, 22))
        add("Quarterly review", "cal-work", at(mon + 8, 13), at(mon + 8, 15), attendees: [me, sam, priya], organizer: sam, meet: true)
        add("Public holiday", "cal-holidays", at(mon + 11, 0), at(mon + 12, 0), allDay: true)
        add("Concert", "cal-personal", at(mon + 12, 20), at(mon + 12, 23), location: "City Hall")
        add("Hackathon", "cal-team", at(mon + 17, 0), at(mon + 19, 0), allDay: true)
        // Unanswered invitations, for the inbox.
        let invited = Attendee(name: "You", email: "you@example.com", status: .pending, isCurrentUser: true)
        add("Product sync", "cal-work", at(mon + 1, 16), at(mon + 1, 16, 45), attendees: [me, chris, sam], organizer: chris, meet: true)
        add("Architecture deep dive", "cal-work", at(mon + 3, 10), at(mon + 3, 11, 30), attendees: [me, priya], organizer: priya, meet: true)
        // Next week, so they're still upcoming whatever day it is.
        add("Hiring panel", "cal-work", at(mon + 8, 11), at(mon + 8, 12), attendees: [invited, priya, sam], organizer: priya, meet: true)
        add("Brainstorm: Q1 ideas", "cal-team", at(mon + 10, 14), at(mon + 10, 15, 30), attendees: [invited, chris, jordan], organizer: chris, meet: true)
        add("Partner check-in", "cal-work", at(mon + 11, 9), at(mon + 11, 9, 30), attendees: [invited, sam], organizer: sam, meet: true)

        func task(_ title: String, _ list: String, _ due: TaskDue?, done: Bool = false, priority: Int = 0) {
            counter += 1
            allTasks.append(TaskItem(id: "task-\(counter)", listID: list, title: title, due: due, isCompleted: done, priority: priority))
        }
        task("Send meeting notes", "list-work", .time(at(mon, 13, 45)))
        task("Book train tickets", "list-personal", .time(at(mon + 1, 10, 15)), priority: 1)
        task("Pay rent", "list-personal", .day(at(mon, 0)))
        task("Water the plants", "list-personal", .day(at(mon + 2, 0)))
        task("Renew passport", "list-personal", .day(at(mon - 3, 0)), priority: 5)
        task("Prepare slides", "list-work", .time(at(mon + 4, 9)))
        task("Update roadmap doc", "list-work", .day(at(mon + 1, 0)), done: true)
        task("Oat milk", "list-groceries", nil)
        task("Coffee beans", "list-groceries", nil)
        task("Tomatoes", "list-groceries", nil, done: true)
        task("Call the plumber", "list-personal", .time(at(mon + 3, 17)))
    }

    /// Days from Monday to `day` in the current week.
    private func mondayOffset(_ day: Date) -> Int {
        (math.calendar.component(.weekday, from: day) + 5) % 7
    }

    // MARK: CalendarProvider

    func eventAccessStatus() async -> AccessStatus { .fullAccess }
    func requestEventAccess() async throws -> AccessStatus { .fullAccess }
    func sources() async throws -> [CalendarSource] { sources }
    func eventCalendars() async throws -> [CalendarInfo] { calendarList }
    func defaultCalendarIDForNewEvents() async -> String? { "cal-personal" }
    func requestSync() async {}

    func events(in interval: DateInterval, calendarIDs: Set<String>) async throws -> [Event] {
        lock.withLock {
            allEvents.filter { calendarIDs.contains($0.calendarID) && $0.start < interval.end && $0.end > interval.start }
        }
    }

    func saveEvent(_ draft: EventDraft, original: Event?, scope: EditScope) async throws -> String? {
        lock.withLock {
            let id = original?.id ?? "demo-new-\(UUID().uuidString)"
            allEvents.removeAll { $0.id == id }
            allEvents.append(Event(id: id, seriesID: id, externalID: id, calendarID: draft.calendarID, title: draft.title,
                                   location: draft.location.isEmpty ? nil : draft.location, notes: draft.notes.isEmpty ? nil : draft.notes,
                                   start: draft.start, end: draft.end, isAllDay: draft.isAllDay, timeZone: draft.timeZone,
                                   alarms: draft.alarms, attendees: draft.attendees))
            return id
        }
    }

    func deleteEvent(_ event: Event, scope: EditScope) async throws {
        lock.withLock { allEvents.removeAll { $0.id == event.id } }
    }

    func changes() -> AsyncStream<Void> { AsyncStream { _ in } }

    // MARK: TaskProvider

    func taskAccessStatus() async -> AccessStatus { .fullAccess }
    func requestTaskAccess() async throws -> AccessStatus { .fullAccess }
    func taskSources() async throws -> [CalendarSource] { [sources[0]] }
    func taskLists() async throws -> [CalendarInfo] { lists }
    func defaultTaskListID() async -> String? { "list-personal" }

    func tasks(dueIn interval: DateInterval, listIDs: Set<String>) async throws -> [TaskItem] {
        lock.withLock { allTasks.filter { listIDs.contains($0.listID) && ($0.due.map { interval.containsHalfOpen($0.date) } ?? false) } }
    }

    func tasks(inLists listIDs: Set<String>, completedSince: Date?) async throws -> [TaskItem] {
        lock.withLock { allTasks.filter { listIDs.contains($0.listID) && (!$0.isCompleted || completedSince != nil) } }
    }

    func saveTask(_ draft: TaskDraft, original: TaskItem?) async throws -> String {
        lock.withLock {
            let id = original?.id ?? "task-new-\(UUID().uuidString)"
            allTasks.removeAll { $0.id == id }
            allTasks.append(TaskItem(id: id, listID: draft.listID, title: draft.title, notes: draft.notes.isEmpty ? nil : draft.notes,
                                     due: draft.due, priority: draft.priority.iCalendarValue, alarms: draft.alarms))
            return id
        }
    }

    func setCompleted(_ completed: Bool, task: TaskItem) async throws {
        lock.withLock {
            if let index = allTasks.firstIndex(where: { $0.id == task.id }) { allTasks[index].isCompleted = completed }
        }
    }

    func deleteTask(_ task: TaskItem) async throws {
        lock.withLock { allTasks.removeAll { $0.id == task.id } }
    }
}
