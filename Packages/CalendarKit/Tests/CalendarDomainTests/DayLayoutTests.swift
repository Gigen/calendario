import CalendarDomain
import Foundation
import Testing

struct DayLayoutTests {
    let cal = makeCalendar()
    var layout: DayLayout { DayLayout(math: CalendarMath(calendar: cal)) }

    // MARK: Which day an event belongs to

    @Test func multiDayEventAppearsOnEveryDayItTouches() {
        let trip = makeEvent("trip", cal.date(2026, 10, 5, 18), cal.date(2026, 10, 7, 9))
        #expect(layout.event(trip, occursOn: cal.date(2026, 10, 5)))
        #expect(layout.event(trip, occursOn: cal.date(2026, 10, 6)))
        #expect(layout.event(trip, occursOn: cal.date(2026, 10, 7)))
        #expect(!layout.event(trip, occursOn: cal.date(2026, 10, 8)))
    }

    @Test func eventEndingAtMidnightDoesNotSpillOver() {
        let late = makeEvent("late", cal.date(2026, 10, 5, 22), cal.date(2026, 10, 6))
        #expect(layout.event(late, occursOn: cal.date(2026, 10, 5)))
        #expect(!layout.event(late, occursOn: cal.date(2026, 10, 6)))
    }

    @Test func allDayEventUsesExclusiveEnd() {
        let holiday = makeEvent("h", cal.date(2026, 10, 5), cal.date(2026, 10, 7), allDay: true)
        #expect(layout.event(holiday, occursOn: cal.date(2026, 10, 5)))
        #expect(layout.event(holiday, occursOn: cal.date(2026, 10, 6)))
        #expect(!layout.event(holiday, occursOn: cal.date(2026, 10, 7)))
    }

    @Test func zeroLengthEventAppearsOnItsDay() {
        let ping = makeEvent("ping", cal.date(2026, 10, 5, 9), cal.date(2026, 10, 5, 9))
        #expect(layout.event(ping, occursOn: cal.date(2026, 10, 5)))
        #expect(!layout.event(ping, occursOn: cal.date(2026, 10, 4)))
    }

    @Test func dayListPutsAllDayFirstThenByStart() {
        let day = cal.date(2026, 10, 5)
        let events = [
            makeEvent("b", cal.date(2026, 10, 5, 10), cal.date(2026, 10, 5, 11)),
            makeEvent("a", cal.date(2026, 10, 5, 9), cal.date(2026, 10, 5, 10)),
            makeEvent("all", cal.date(2026, 10, 5), cal.date(2026, 10, 6), allDay: true),
        ]
        #expect(layout.events(events, on: day).map(\.id) == ["all", "a", "b"])
    }

    // MARK: Side-by-side layout

    @Test func nonOverlappingEventsGetFullWidth() {
        let day = cal.date(2026, 10, 5)
        let placed = layout.placements(for: [
            makeEvent("a", cal.date(2026, 10, 5, 9), cal.date(2026, 10, 5, 10)),
            makeEvent("b", cal.date(2026, 10, 5, 10), cal.date(2026, 10, 5, 11)),
        ], on: day)
        #expect(placed.map(\.columnCount) == [1, 1])
        #expect(placed.map(\.column) == [0, 0])
        #expect(placed.map(\.startMinute) == [540, 600])
    }

    @Test func overlappingEventsShareColumns() {
        let day = cal.date(2026, 10, 5)
        // a 9-11, b 9:30-10, c 10:30-12: a and b overlap, a and c overlap, b and c don't.
        let placed = layout.placements(for: [
            makeEvent("a", cal.date(2026, 10, 5, 9), cal.date(2026, 10, 5, 11)),
            makeEvent("b", cal.date(2026, 10, 5, 9, 30), cal.date(2026, 10, 5, 10)),
            makeEvent("c", cal.date(2026, 10, 5, 10, 30), cal.date(2026, 10, 5, 12)),
            makeEvent("d", cal.date(2026, 10, 5, 14), cal.date(2026, 10, 5, 15)),
        ], on: day)
        let byID = Dictionary(uniqueKeysWithValues: placed.map { ($0.item.event!.id, $0) })
        #expect(byID["a"]?.column == 0)
        #expect(byID["b"]?.column == 1)
        #expect(byID["c"]?.column == 1) // reuses b's freed column
        #expect(byID["a"]?.columnCount == 2)
        #expect(byID["c"]?.columnCount == 2)
        #expect(byID["d"]?.columnCount == 1)
    }

    @Test func multiDayTimedEventIsClippedToDay() {
        let event = makeEvent("overnight", cal.date(2026, 10, 5, 22), cal.date(2026, 10, 6, 2))
        let first = layout.placements(for: [event], on: cal.date(2026, 10, 5)).first
        let second = layout.placements(for: [event], on: cal.date(2026, 10, 6)).first
        #expect(first?.startMinute == 22 * 60)
        #expect(first?.endMinute == 24 * 60)
        #expect(first?.continuesAfter == true)
        #expect(second?.startMinute == 0)
        #expect(second?.endMinute == 120)
        #expect(second?.continuesBefore == true)
    }

    @Test func allDayEventsAreExcludedFromTimedLayout() {
        let day = cal.date(2026, 10, 5)
        let placed = layout.placements(for: [makeEvent("h", day, cal.date(2026, 10, 6), allDay: true)], on: day)
        #expect(placed.isEmpty)
    }

    @Test func positionsUseWallClockOnDSTDay() {
        // 2026-10-25 has a repeated 02:00-03:00 hour; 09:00 must still sit at the 9:00 row.
        let day = cal.date(2026, 10, 25)
        let placed = layout.placements(for: [
            makeEvent("a", cal.date(2026, 10, 25, 9), cal.date(2026, 10, 25, 10)),
        ], on: day)
        #expect(placed.first?.startMinute == 540)
        #expect(placed.first?.endMinute == 600)
    }

    @Test func shortEventsDoNotVisuallyStack() {
        let day = cal.date(2026, 10, 5)
        // Two 5-minute events 10 minutes apart: with a 20-minute minimum they overlap visually.
        let placed = layout.placements(for: [
            makeEvent("a", cal.date(2026, 10, 5, 9), cal.date(2026, 10, 5, 9, 5)),
            makeEvent("b", cal.date(2026, 10, 5, 9, 10), cal.date(2026, 10, 5, 9, 15)),
        ], on: day)
        #expect(placed.map(\.columnCount) == [2, 2])
    }

    // MARK: Timed reminders

    @Test func timedRemindersArePlacedAtTheirTimeBesideEvents() {
        let day = cal.date(2026, 10, 15)
        let meeting = makeEvent("m", cal.date(2026, 10, 15, 9), cal.date(2026, 10, 15, 10))
        let atNineThirty = TaskItem(id: "r1", listID: "l", title: "Call", due: .time(cal.date(2026, 10, 15, 9, 30)))
        let atNoon = TaskItem(id: "r2", listID: "l", title: "Lunch", due: .time(cal.date(2026, 10, 15, 12)))
        let dayOnly = TaskItem(id: "r3", listID: "l", title: "Someday today", due: .day(day))
        let tomorrow = TaskItem(id: "r4", listID: "l", title: "Later", due: .time(cal.date(2026, 10, 16, 9)))

        let placed = layout.placements(for: [meeting], tasks: [atNineThirty, atNoon, dayOnly, tomorrow], on: day)
        let byID = Dictionary(uniqueKeysWithValues: placed.map { ($0.item.id, $0) })
        #expect(placed.count == 3) // day-only and other-day reminders aren't in the grid
        #expect(byID["task:r1"]?.startMinute == 9 * 60 + 30)
        #expect(byID["task:r1"]?.endMinute == 9 * 60 + 30)
        #expect(byID["task:r1"]?.column == 1) // beside the meeting it overlaps
        #expect(byID["event:m"]?.columnCount == 2)
        #expect(byID["task:r2"]?.columnCount == 1)
    }

    @Test func remindersCloserThanMinimumShareColumns() {
        let day = cal.date(2026, 10, 15)
        let a = TaskItem(id: "a", listID: "l", title: "a", due: .time(cal.date(2026, 10, 15, 14)))
        let b = TaskItem(id: "b", listID: "l", title: "b", due: .time(cal.date(2026, 10, 15, 14, 10)))
        let placed = layout.placements(for: [], tasks: [a, b], on: day)
        #expect(placed.map(\.columnCount) == [2, 2])
    }

    @Test func mergedOrder() {
        let day = cal.date(2026, 10, 15)
        let allDay = makeEvent("all", day, cal.date(2026, 10, 16), allDay: true)
        let morning = makeEvent("morning", cal.date(2026, 10, 15, 9), cal.date(2026, 10, 15, 10))
        let dayTask = TaskItem(id: "d", listID: "l", title: "d", due: .day(day))
        let nineTask = TaskItem(id: "n", listID: "l", title: "n", due: .time(cal.date(2026, 10, 15, 9)))
        let merged = CalendarItem.merged(events: [morning, allDay], tasks: [nineTask, dayTask])
        #expect(merged.map(\.id) == ["event:all", "task:d", "event:morning", "task:n"])
    }
}
