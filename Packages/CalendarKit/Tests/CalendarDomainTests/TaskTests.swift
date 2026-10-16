import CalendarDomain
import Foundation
import Testing

struct TaskDueTests {
    let cal = makeCalendar()

    @Test func dayOnlyComponentsRoundTrip() {
        let due = TaskDue.day(cal.date(2026, 10, 20))
        let parts = due.components(calendar: cal)
        #expect(parts.hour == nil)
        #expect(parts.timeZone == nil) // floating, like Reminders.app
        #expect(TaskDue(components: parts, calendar: cal) == due)
    }

    @Test func timedComponentsRoundTrip() {
        let due = TaskDue.time(cal.date(2026, 10, 20, 14, 30))
        let parts = due.components(calendar: cal)
        #expect(parts.hour == 14)
        #expect(TaskDue(components: parts, calendar: cal) == due)
    }

    @Test func timedComponentsInOtherZone() {
        var parts = DateComponents(year: 2026, month: 10, day: 20, hour: 9, minute: 0)
        parts.timeZone = TimeZone(identifier: "America/New_York")
        // 9:00 in New York is 15:00 in Berlin.
        #expect(TaskDue(components: parts, calendar: cal) == .time(cal.date(2026, 10, 20, 15)))
    }

    @Test func incompleteComponentsAreRejected() {
        #expect(TaskDue(components: DateComponents(month: 10, day: 20), calendar: cal) == nil)
    }
}

struct TaskItemTests {
    let cal = makeCalendar()
    var math: CalendarMath { CalendarMath(calendar: cal) }

    @Test func overdue() {
        let now = cal.date(2026, 10, 13, 12)
        let dueYesterday = TaskItem(id: "a", listID: "l", title: "a", due: .day(cal.date(2026, 10, 12)))
        let dueToday = TaskItem(id: "b", listID: "l", title: "b", due: .day(cal.date(2026, 10, 13)))
        let dueThisMorning = TaskItem(id: "c", listID: "l", title: "c", due: .time(cal.date(2026, 10, 13, 9)))
        var done = dueYesterday
        done.isCompleted = true
        #expect(dueYesterday.isOverdue(now: now, math: math))
        #expect(!dueToday.isOverdue(now: now, math: math)) // day-only: not overdue until tomorrow
        #expect(dueThisMorning.isOverdue(now: now, math: math))
        #expect(!done.isOverdue(now: now, math: math))
    }

    @Test(arguments: [(0, PriorityLevel.none), (1, .high), (4, .high), (5, .medium), (6, .low), (9, .low)])
    func priorityMapping(value: Int, level: PriorityLevel) {
        #expect(PriorityLevel(iCalendar: value) == level)
        #expect(PriorityLevel(iCalendar: level.iCalendarValue) == level)
    }

    @Test func dayBucketingAndOrder() {
        let day = cal.date(2026, 10, 13)
        let tasks = [
            TaskItem(id: "timed", listID: "l", title: "timed", due: .time(cal.date(2026, 10, 13, 8))),
            TaskItem(id: "done", listID: "l", title: "done", due: .day(day), isCompleted: true),
            TaskItem(id: "allday", listID: "l", title: "allday", due: .day(day)),
            TaskItem(id: "tomorrow", listID: "l", title: "tomorrow", due: .day(cal.date(2026, 10, 14))),
            TaskItem(id: "undated", listID: "l", title: "undated"),
        ]
        #expect(TaskLayout.tasks(tasks, dueOn: day, math: math).map(\.id) == ["allday", "timed", "done"])
        #expect(tasks.sorted(by: TaskLayout.displayOrder).map(\.id) == ["allday", "timed", "tomorrow", "undated", "done"])
    }
}

struct TaskDraftTests {
    let cal = makeCalendar()
    var math: CalendarMath { CalendarMath(calendar: cal) }

    @Test func alarmsSplitIntoEditableAlertAndPreservedRest() {
        let task = TaskItem(
            id: "a", listID: "l", title: "a",
            alarms: [.relative(-600), .absolute(cal.date(2026, 10, 13, 9)), .absolute(cal.date(2026, 10, 14, 9))]
        )
        let draft = TaskDraft(task: task)
        #expect(draft.alert == cal.date(2026, 10, 13, 9))
        #expect(draft.otherAlarms == [.relative(-600), .absolute(cal.date(2026, 10, 14, 9))])
        // Unchanged draft gives back the same alarm set, so the provider leaves them alone.
        #expect(Set(draft.alarms) == Set(task.alarms))
    }

    @Test func suggestedAlert() {
        let now = cal.date(2026, 10, 13, 14, 10)
        var draft = TaskDraft(listID: "l")
        #expect(draft.suggestedAlert(now: now, math: math) == cal.date(2026, 10, 13, 15))
        draft.due = .day(cal.date(2026, 10, 20))
        #expect(draft.suggestedAlert(now: now, math: math) == cal.date(2026, 10, 20, 9))
        draft.due = .time(cal.date(2026, 10, 20, 17))
        #expect(draft.suggestedAlert(now: now, math: math) == cal.date(2026, 10, 20, 17))
    }

    @Test func togglingDueAndTime() {
        let now = cal.date(2026, 10, 13, 14, 10)
        var draft = TaskDraft(listID: "l")
        draft.setHasDue(true, day: now, math: math)
        #expect(draft.due == .day(cal.date(2026, 10, 13)))
        // 9:00 is already past today, so the next full hour.
        draft.setHasTime(true, now: now, math: math)
        #expect(draft.due == .time(cal.date(2026, 10, 13, 15)))
        draft.setHasTime(false, now: now, math: math)
        #expect(draft.due == .day(cal.date(2026, 10, 13)))
        draft.setDueDay(cal.date(2026, 10, 20), math: math)
        draft.setHasTime(true, now: now, math: math)
        #expect(draft.due == .time(cal.date(2026, 10, 20, 9)))
        draft.setHasDue(false, day: now, math: math)
        #expect(draft.due == nil)
    }

    @Test func addingTimeToTomorrowUsesNineEvenLateToday() {
        let now = cal.date(2026, 10, 13, 22)
        var draft = TaskDraft(listID: "l", due: .day(cal.date(2026, 10, 14)))
        draft.setHasTime(true, now: now, math: math)
        #expect(draft.due == .time(cal.date(2026, 10, 14, 9)))
    }

    @Test func movingDueDayKeepsTime() {
        var draft = TaskDraft(listID: "l", due: .time(cal.date(2026, 10, 13, 17, 45)))
        draft.setDueDay(cal.date(2026, 10, 25), math: math) // DST day
        #expect(draft.due == .time(cal.date(2026, 10, 25, 17, 45)))
    }
}
