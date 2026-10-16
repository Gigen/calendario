import CalendarDomain
import Foundation
import Testing

struct EventDraftTests {
    let cal = makeCalendar()
    var math: CalendarMath { CalendarMath(calendar: cal) }

    // MARK: New events

    @Test func newEventTodayStartsAtNextHalfHour() {
        let now = cal.date(2026, 10, 13, 14, 7)
        let draft = EventDraft.newEvent(on: now, now: now, calendarID: "c", math: math)
        #expect(draft.start == cal.date(2026, 10, 13, 14, 30))
        #expect(draft.end == cal.date(2026, 10, 13, 15, 30))
        #expect(draft.timeZone == cal.timeZone)
    }

    @Test func newEventOnOtherDayStartsAtNine() {
        let draft = EventDraft.newEvent(on: cal.date(2026, 10, 20), now: cal.date(2026, 10, 13, 14), calendarID: "c", math: math)
        #expect(draft.start == cal.date(2026, 10, 20, 9))
    }

    @Test func newEventLateInTheEveningStaysToday() {
        let now = cal.date(2026, 10, 13, 23, 45)
        let draft = EventDraft.newEvent(on: now, now: now, calendarID: "c", math: math)
        #expect(draft.start == cal.date(2026, 10, 13, 23, 30))
    }

    @Test func roundingKeepsExactBoundaries() {
        #expect(math.roundedUp(cal.date(2026, 10, 13, 14, 30), toMinutes: 30) == cal.date(2026, 10, 13, 14, 30))
        #expect(math.roundedUp(cal.date(2026, 10, 13, 14, 30, 1), toMinutes: 30) == cal.date(2026, 10, 13, 15))
        #expect(math.roundedUp(cal.date(2026, 10, 13, 23, 50), toMinutes: 30) == cal.date(2026, 10, 14))
    }

    @Test func snappingToQuarterHours() {
        #expect(math.snappedMinute(9 * 60 + 14, toMinutes: 15) == 9 * 60)
        #expect(math.snappedMinute(9 * 60 + 15, toMinutes: 15) == 9 * 60 + 15)
        #expect(math.snappedMinute(24 * 60 + 5, toMinutes: 15) == 24 * 60 - 15)
    }

    // MARK: Editing

    @Test func movingStartKeepsDuration() {
        var draft = EventDraft(start: cal.date(2026, 10, 13, 9), end: cal.date(2026, 10, 13, 10, 30), calendarID: "c")
        draft.setStart(cal.date(2026, 10, 14, 13), math: math)
        #expect(draft.end == cal.date(2026, 10, 14, 14, 30))
    }

    @Test func endBeforeStartPullsStartBack() {
        var draft = EventDraft(start: cal.date(2026, 10, 13, 9), end: cal.date(2026, 10, 13, 10), calendarID: "c")
        draft.setEnd(cal.date(2026, 10, 13, 8), math: math)
        #expect(draft.start == cal.date(2026, 10, 13, 8))
        #expect(draft.issues().isEmpty)
    }

    @Test func togglingAllDayCoversTouchedDays() {
        var draft = EventDraft(start: cal.date(2026, 10, 13, 22), end: cal.date(2026, 10, 14, 1), calendarID: "c")
        draft.setAllDay(true, math: math)
        #expect(draft.start == cal.date(2026, 10, 13))
        #expect(draft.end == cal.date(2026, 10, 15))
        #expect(draft.allDayLastDay(math: math) == cal.date(2026, 10, 14))
    }

    @Test func togglingAllDayForEventEndingAtMidnight() {
        var draft = EventDraft(start: cal.date(2026, 10, 13, 22), end: cal.date(2026, 10, 14), calendarID: "c")
        draft.setAllDay(true, math: math)
        #expect(draft.end == cal.date(2026, 10, 14)) // one day only
    }

    @Test func togglingAllDayOffGivesOneHourAtNine() {
        var draft = EventDraft(start: cal.date(2026, 10, 13), end: cal.date(2026, 10, 15), isAllDay: true, timeZone: nil, calendarID: "c")
        draft.setAllDay(false, math: math)
        #expect(draft.start == cal.date(2026, 10, 13, 9))
        #expect(draft.end == cal.date(2026, 10, 13, 10))
        #expect(draft.timeZone == cal.timeZone)
    }

    @Test func movingAllDayStartKeepsNumberOfDays() {
        var draft = EventDraft(start: cal.date(2026, 10, 13), end: cal.date(2026, 10, 16), isAllDay: true, calendarID: "c")
        draft.setStart(cal.date(2026, 10, 24, 15), math: math) // across the DST change
        #expect(draft.start == cal.date(2026, 10, 24))
        #expect(draft.end == cal.date(2026, 10, 27))
    }

    @Test func allDayLastDayEditing() {
        var draft = EventDraft(start: cal.date(2026, 10, 13), end: cal.date(2026, 10, 14), isAllDay: true, calendarID: "c")
        draft.setAllDayLastDay(cal.date(2026, 10, 15, 18), math: math)
        #expect(draft.end == cal.date(2026, 10, 16))
        draft.setAllDayLastDay(cal.date(2026, 10, 10), math: math)
        #expect(draft.start == cal.date(2026, 10, 10))
        #expect(draft.end == cal.date(2026, 10, 11))
    }

    @Test func changingTimeZoneKeepsWallClock() {
        var draft = EventDraft(start: cal.date(2026, 10, 13, 9), end: cal.date(2026, 10, 13, 10), calendarID: "c")
        let newYork = TimeZone(identifier: "America/New_York")!
        draft.setTimeZone(newYork, math: math)
        var nyCalendar = cal
        nyCalendar.timeZone = newYork
        #expect(draft.start == nyCalendar.date(2026, 10, 13, 9))
        #expect(draft.duration == 3600)
        #expect(draft.timeZone == newYork)
    }

    // MARK: Validation

    @Test func validation() {
        var draft = EventDraft(start: cal.date(2026, 10, 13, 9), end: cal.date(2026, 10, 13, 10), calendarID: "c")
        #expect(draft.issues().isEmpty)
        draft.recurrence = RecurrenceRule(frequency: .daily, end: .until(cal.date(2026, 10, 12)))
        #expect(draft.issues() == [.repeatEndsBeforeStart])
        draft.recurrence = RecurrenceRule(frequency: .daily, end: .afterOccurrences(0))
        #expect(draft.issues() == [.invalidOccurrenceCount])
        draft.recurrence = nil
        draft.url = "not a url"
        #expect(draft.issues() == [.invalidURL])
        draft.url = "https://example.com"
        #expect(draft.parsedURL == URL(string: "https://example.com"))
    }

    @Test func repeatUntilIncludesWholeDay() {
        guard case .until(let date) = RecurrenceRule.End.until(day: cal.date(2026, 10, 20, 8), math: math) else {
            Issue.record("expected .until")
            return
        }
        #expect(date == cal.date(2026, 10, 20, 23, 59, 59))
    }

    @Test func eventKitAllDayEndRoundTrips() {
        let exclusive = cal.date(2026, 10, 14)
        let ekEnd = Normalization.eventKitAllDayEnd(exclusiveEnd: exclusive)
        #expect(Normalization.allDayExclusiveEnd(start: cal.date(2026, 10, 13), end: ekEnd, calendar: cal) == exclusive)
    }

    // MARK: Edit scope

    @Test func scopeChoices() {
        let single = makeEvent("a", cal.date(2026, 10, 13, 9), cal.date(2026, 10, 13, 10))
        #expect(EditScope.saveChoices(original: nil, draft: EventDraft(event: single)) == [.thisEvent])
        #expect(EditScope.saveChoices(original: single, draft: EventDraft(event: single)) == [.thisEvent])
        #expect(EditScope.deleteChoices(for: single) == [.thisEvent])

        var repeating = single
        repeating.recurrence = RecurrenceRule(frequency: .weekly)
        var draft = EventDraft(event: repeating)
        draft.title = "Renamed"
        #expect(EditScope.saveChoices(original: repeating, draft: draft) == [.thisEvent, .futureEvents])
        #expect(EditScope.deleteChoices(for: repeating) == [.thisEvent, .futureEvents])

        draft.calendarID = "other"
        #expect(EditScope.saveChoices(original: repeating, draft: draft) == [.futureEvents])

        draft = EventDraft(event: repeating)
        draft.recurrence = RecurrenceRule(frequency: .daily)
        #expect(EditScope.saveChoices(original: repeating, draft: draft) == [.futureEvents])
    }
}

struct RecurrencePresetTests {
    let cal = makeCalendar()
    // Tuesday 2026-10-13.
    var start: Date { cal.date(2026, 10, 13, 9) }

    @Test(arguments: [RecurrencePreset.none, .daily, .weekdays, .weekly, .biweekly, .monthly, .yearly])
    func presetsRoundTrip(preset: RecurrencePreset) {
        #expect(RecurrencePreset.detect(preset.rule(), start: start, calendar: cal) == preset)
    }

    @Test func explicitStartWeekdayStillCountsAsWeekly() {
        let rule = RecurrenceRule(frequency: .weekly, daysOfWeek: [.init(weekday: 3)]) // Tuesday
        #expect(RecurrencePreset.detect(rule, start: start, calendar: cal) == .weekly)
    }

    @Test func otherRulesAreCustom() {
        let everyMonAndWed = RecurrenceRule(frequency: .weekly, daysOfWeek: [.init(weekday: 2), .init(weekday: 4)])
        #expect(RecurrencePreset.detect(everyMonAndWed, start: start, calendar: cal) == .custom)
        let every3Days = RecurrenceRule(frequency: .daily, interval: 3)
        #expect(RecurrencePreset.detect(every3Days, start: start, calendar: cal) == .custom)
        let secondTuesday = RecurrenceRule(frequency: .monthly, daysOfWeek: [.init(weekday: 3, weekNumber: 2)])
        #expect(RecurrencePreset.detect(secondTuesday, start: start, calendar: cal) == .custom)
    }

    @Test func presetKeepsEnd() {
        let rule = RecurrencePreset.weekly.rule(end: .afterOccurrences(5))
        #expect(rule?.end == .afterOccurrences(5))
    }
}
