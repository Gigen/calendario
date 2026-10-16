import CalendarDomain
import Foundation
import Testing

struct CalendarMatcherTests {
    let sources = [
        CalendarSource(id: "s-gmail", title: "me@gmail.com", kind: .google, accountEmail: "me@gmail.com"),
        CalendarSource(id: "s-work", title: "Me@Company.com", kind: .calDAV, accountEmail: "me@company.com"),
        CalendarSource(id: "s-icloud", title: "iCloud", kind: .iCloud),
    ]

    func calendar(_ id: String, _ title: String, _ source: String) -> CalendarInfo {
        CalendarInfo(id: id, title: title, color: .gray, sourceID: source)
    }

    @Test func matchesPrimaryByEmailAndOthersByTitle() {
        let calendars = [
            calendar("ek-primary", "me@gmail.com", "s-gmail"),
            calendar("ek-family", "Family", "s-gmail"),
            calendar("ek-icloud-family", "Family", "s-icloud"),
        ]
        let account = ConnectedAccount(email: "me@gmail.com", calendars: [
            RemoteCalendar(id: "me@gmail.com", title: "Me Person", isPrimary: true),
            RemoteCalendar(id: "fam123@group.calendar.google.com", title: "Family", isPrimary: false),
        ])
        let result = CalendarMatcher.match(sources: sources, calendars: calendars, accounts: [account])
        #expect(result["ek-primary"] == RemoteCalendarRef(accountEmail: "me@gmail.com", calendarID: "me@gmail.com"))
        #expect(result["ek-family"]?.calendarID == "fam123@group.calendar.google.com")
        #expect(result["ek-icloud-family"] == nil) // other accounts are never matched
    }

    @Test func workspaceAccountMatchedCaseInsensitively() {
        let calendars = [calendar("ek-work", "Team", "s-work")]
        let account = ConnectedAccount(email: "me@company.com", calendars: [RemoteCalendar(id: "team@group", title: "team ", isPrimary: false)])
        #expect(CalendarMatcher.match(sources: sources, calendars: calendars, accounts: [account])["ek-work"]?.calendarID == "team@group")
    }

    @Test func sourceTitledGoogleIsFoundByPrimaryCalendarName() {
        let google = CalendarSource(id: "s-google", title: "Google", kind: .google)
        let calendars = [calendar("ek-primary", "Me@Gmail.com", "s-google"), calendar("ek-work", "Work", "s-google")]
        let account = ConnectedAccount(email: "me@gmail.com", calendars: [
            RemoteCalendar(id: "me@gmail.com", title: "Me", isPrimary: true),
            RemoteCalendar(id: "work@group", title: "Work", isPrimary: false),
        ])
        let result = CalendarMatcher.match(sources: [google], calendars: calendars, accounts: [account])
        #expect(result["ek-primary"]?.calendarID == "me@gmail.com")
        #expect(result["ek-work"]?.calendarID == "work@group")
    }

    @Test func ambiguousTitlesAreNotGuessed() {
        let calendars = [calendar("a", "Projects", "s-gmail"), calendar("b", "Projects", "s-gmail")]
        let account = ConnectedAccount(email: "me@gmail.com", calendars: [RemoteCalendar(id: "p1", title: "Projects", isPrimary: false)])
        #expect(CalendarMatcher.match(sources: sources, calendars: calendars, accounts: [account]).isEmpty)
    }

    @Test func unconnectedAccountsDoNotMatch() {
        let calendars = [calendar("ek-primary", "me@gmail.com", "s-gmail")]
        #expect(CalendarMatcher.match(sources: sources, calendars: calendars, accounts: []).isEmpty)
    }

    @Test func mightBeGoogle() {
        #expect(CalendarMatcher.mightBeGoogle(sources[0]))
        #expect(CalendarMatcher.mightBeGoogle(sources[1]))
        #expect(!CalendarMatcher.mightBeGoogle(sources[2]))
    }
}

struct SaveRouteTests {
    let cal = makeCalendar()
    let remote = RemoteCalendarRef(accountEmail: "me@gmail.com", calendarID: "me@gmail.com")

    var event: Event {
        Event(id: "e", seriesID: "e", externalID: "uid", calendarID: "c", title: "Sync",
              start: cal.date(2026, 10, 14, 9), end: cal.date(2026, 10, 14, 10),
              attendees: [Attendee(name: nil, email: "ana@example.com")])
    }

    @Test func plainEditsStayOnTheSystemCalendar() {
        var draft = EventDraft(event: event)
        draft.title = "Renamed"
        #expect(SaveRoute.decide(original: event, draft: draft, remote: remote) == .system)
        #expect(SaveRoute.decide(original: event, draft: draft, remote: nil) == .system)
        let new = EventDraft(start: event.start, end: event.end, calendarID: "c")
        #expect(SaveRoute.decide(original: nil, draft: new, remote: nil) == .system)
    }

    @Test func meetOrInviteesGoThroughGoogle() {
        var new = EventDraft(start: event.start, end: event.end, calendarID: "c")
        new.addConference = true
        #expect(SaveRoute.decide(original: nil, draft: new, remote: remote) == .remoteInsert(remote))
        #expect(SaveRoute.decide(original: nil, draft: new, remote: nil) == .unsupported(.accountNotConnected))

        var edit = EventDraft(event: event)
        edit.addAttendee(email: "bob@example.com")
        #expect(SaveRoute.decide(original: event, draft: edit, remote: remote) == .remoteUpdate(remote))
    }

    @Test func inviteeCaseChangesDontCount() {
        var edit = EventDraft(event: event)
        edit.attendees = [Attendee(name: "Ana", email: "ANA@example.com")]
        #expect(SaveRoute.decide(original: event, draft: edit, remote: remote) == .system)
    }

    @Test func unsupportedCases() {
        var repeating = event
        repeating.recurrence = RecurrenceRule(frequency: .weekly)
        var edit = EventDraft(event: repeating)
        edit.addConference = true
        #expect(SaveRoute.decide(original: repeating, draft: edit, remote: remote) == .unsupported(.repeatingEvent))

        var moved = EventDraft(event: event)
        moved.calendarID = "other"
        moved.removeAttendee(email: "ana@example.com")
        #expect(SaveRoute.decide(original: event, draft: moved, remote: remote) == .unsupported(.calendarChange))
    }
}

struct PendingEventsTests {
    let cal = makeCalendar()
    var week: DateInterval { DateInterval(start: cal.date(2026, 10, 12), end: cal.date(2026, 10, 19)) }

    func event(_ id: String, uid: String?, day: Int = 14) -> Event {
        Event(id: id, externalID: uid, calendarID: "c", title: id, start: cal.date(2026, 10, day, 9), end: cal.date(2026, 10, day, 10))
    }

    @Test func pendingShownUntilSyncedCopyArrives() {
        var pending = PendingEvents()
        let now = cal.date(2026, 10, 14, 8)
        pending.add(event("pending-1", uid: "uid-1"), now: now)

        let before = pending.merge(synced: [event("other", uid: "uid-x")], in: week, now: now)
        #expect(before.map(\.id) == ["other", "pending-1"])

        let after = pending.merge(synced: [event("other", uid: "uid-x"), event("synced-1", uid: "uid-1")], in: week, now: now)
        #expect(after.map(\.id) == ["other", "synced-1"]) // no duplicate
        #expect(pending.events.isEmpty)
    }

    @Test func pendingOutsideIntervalIsKeptButNotShown() {
        var pending = PendingEvents()
        pending.add(event("p", uid: "u", day: 25))
        #expect(pending.merge(synced: [], in: week).isEmpty)
        #expect(pending.events.count == 1)
    }

    @Test func pendingExpires() {
        var pending = PendingEvents(timeout: 60)
        let now = cal.date(2026, 10, 14, 8)
        pending.add(event("p", uid: "u"), now: now)
        #expect(pending.merge(synced: [], in: week, now: now.addingTimeInterval(120)).isEmpty)
    }
}

struct ConferenceLinkTests {
    @Test func findsMeetLinkInGoogleNotes() {
        let notes = "Agenda\n\n-::~:~::~:~:~:~::-\nJoin with Google Meet: https://meet.google.com/abc-defg-hij\nOr dial: +1 555"
        #expect(ConferenceLink.find(in: [nil, "Room 4", notes]) == URL(string: "https://meet.google.com/abc-defg-hij"))
    }

    @Test func findsZoomAndTrimsPunctuation() {
        #expect(ConferenceLink.find(in: ["Call (https://us02web.zoom.us/j/123?pwd=x)."]) == URL(string: "https://us02web.zoom.us/j/123?pwd=x"))
    }

    @Test func ignoresOtherLinks() {
        #expect(ConferenceLink.find(in: ["https://example.com/meet.google.com", "no links"]) == nil)
    }
}

struct SyncHealthTests {
    let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

    func change(_ uid: String, minutesAgo: Double) -> RemoteChange {
        RemoteChange(iCalUID: uid, updated: now.addingTimeInterval(-minutesAgo * 60), start: now, end: now.addingTimeInterval(3600))
    }

    @Test func healthyWhenEverySettledChangeIsSynced() {
        let changes = [change("a", minutesAgo: 120), change("b", minutesAgo: 5)]
        // "b" is recent and may not have synced yet; that's fine.
        #expect(SyncHealth.evaluate(changes: changes, syncedUIDs: ["a"], now: now) == .healthy)
    }

    @Test func behindWhenOldChangesAreMissing() {
        let changes = [change("a", minutesAgo: 600), change("b", minutesAgo: 90), change("c", minutesAgo: 90)]
        let health = SyncHealth.evaluate(changes: changes, syncedUIDs: ["c"], now: now)
        #expect(health == .behind(missing: 2, oldestChange: now.addingTimeInterval(-600 * 60)))
    }

    @Test func repeatingInstancesCountOnce() {
        let changes = [change("series", minutesAgo: 90), change("series", minutesAgo: 90), change("series", minutesAgo: 90)]
        #expect(SyncHealth.evaluate(changes: changes, syncedUIDs: [], now: now) == .behind(missing: 1, oldestChange: now.addingTimeInterval(-90 * 60)))
    }

    @Test func unknownWithoutSettledChanges() {
        #expect(SyncHealth.evaluate(changes: [], syncedUIDs: [], now: now) == .unknown)
        #expect(SyncHealth.evaluate(changes: [change("a", minutesAgo: 10)], syncedUIDs: [], now: now) == .unknown)
    }

    @Test func comparisonIntervalPadsByADay() {
        let changes = [change("a", minutesAgo: 60)]
        let interval = SyncHealth.comparisonInterval(for: changes)
        #expect(interval?.start == now.addingTimeInterval(-86_400))
        #expect(interval?.end == now.addingTimeInterval(3600 + 86_400))
        #expect(SyncHealth.comparisonInterval(for: []) == nil)
    }
}

struct ParticipantsTests {
    let cal = makeCalendar()

    func event(attendees: [Attendee], organizer: Attendee?) -> Event {
        Event(id: "e", calendarID: "c", title: "t", start: cal.date(2026, 10, 14, 9), end: cal.date(2026, 10, 14, 10), attendees: attendees, organizer: organizer)
    }

    @Test func organizerFirstMatchedByEmail() {
        let ana = Attendee(name: "Ana", email: "ana@example.com", status: .accepted)
        let bob = Attendee(name: "Bob", email: "BOB@example.com", status: .pending)
        let list = event(attendees: [ana, bob], organizer: Attendee(name: "Bob", email: "bob@example.com")).participants
        #expect(list.map(\.attendee.name) == ["Bob", "Ana"])
        #expect(list.map(\.isOrganizer) == [true, false])
    }

    @Test func missingOrganizerIsAdded() {
        let ana = Attendee(name: "Ana", email: "ana@example.com")
        let list = event(attendees: [ana], organizer: Attendee(name: "Org", email: "org@example.com", status: .accepted)).participants
        #expect(list.map(\.attendee.name) == ["Org", "Ana"])
    }

    @Test func noAttendeesMeansNoList() {
        #expect(event(attendees: [], organizer: Attendee(name: "Org", email: "org@example.com")).participants.isEmpty)
    }
}

struct PendingResponsesTests {
    let cal = makeCalendar()
    let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

    func invite(_ id: String, status: Attendee.Status) -> Event {
        Event(id: id, calendarID: "c", title: "t", start: cal.date(2026, 10, 15, 9), end: cal.date(2026, 10, 15, 10),
              attendees: [Attendee(name: "Org", email: "org@x.com", status: .accepted),
                          Attendee(name: "Me", email: "me@x.com", status: status, isCurrentUser: true)])
    }

    @Test func shownUntilSyncedThenForgotten() {
        var pending = PendingResponses()
        pending.set(.declined, for: invite("e1", status: .pending), now: now)

        let stale = pending.apply(to: [invite("e1", status: .pending), invite("e2", status: .pending)], now: now)
        #expect(stale[0].attendees[1].status == .declined)
        #expect(stale[0].attendees[0].status == .accepted) // others untouched
        #expect(stale[1].attendees[1].status == .pending) // other events untouched

        _ = pending.apply(to: [invite("e1", status: .declined)], now: now) // synced
        // Later changes made elsewhere show as they are.
        let later = pending.apply(to: [invite("e1", status: .accepted)], now: now)
        #expect(later[0].attendees[1].status == .accepted)
    }

    @Test func expiresSoSyncedValueWins() {
        var pending = PendingResponses(timeout: 60)
        pending.set(.declined, for: invite("e1", status: .pending), now: now)
        let result = pending.apply(to: [invite("e1", status: .pending)], now: now.addingTimeInterval(120))
        #expect(result[0].attendees[1].status == .pending)
    }

    @Test func keptWhileEventIsOutOfView() {
        var pending = PendingResponses()
        pending.set(.tentative, for: invite("e1", status: .pending), now: now)
        _ = pending.apply(to: [], now: now)
        #expect(pending.apply(to: [invite("e1", status: .pending)], now: now)[0].attendees[1].status == .tentative)
    }
}

struct InvitationsTests {
    let cal = makeCalendar()
    var now: Date { cal.date(2026, 10, 16, 12) }

    func invite(_ id: String, series: String? = nil, day: Int, status: Attendee.Status = .pending, organizerIsMe: Bool = false) -> Event {
        let me = Attendee(name: "Me", email: "me@x.com", status: status, isCurrentUser: true)
        return Event(id: id, seriesID: series ?? id, externalID: series.map { "\($0)@google.com" }, calendarID: "c", title: id,
                     start: cal.date(2026, 10, day, 9), end: cal.date(2026, 10, day, 10),
                     recurrence: series == nil ? nil : RecurrenceRule(frequency: .weekly),
                     attendees: [me, Attendee(name: "Org", email: "org@x.com", status: .accepted)],
                     organizer: organizerIsMe ? me : Attendee(name: "Org", email: "org@x.com"))
    }

    @Test func onlyUpcomingUnansweredInvitations() {
        let events = [
            invite("later", day: 20),
            invite("past", day: 10),
            invite("accepted", day: 18, status: .accepted),
            invite("mine", day: 18, organizerIsMe: true),
            invite("soon", day: 17),
        ]
        #expect(Invitations.pending(in: events, now: now).map(\.id) == ["soon", "later"])
    }

    @Test func repeatingInvitationAppearsOnce() {
        let events = [invite("w2", series: "s", day: 23), invite("w1", series: "s", day: 16 + 1), invite("w3", series: "s", day: 30)]
        #expect(Invitations.pending(in: events, now: now).map(\.id) == ["w1"])
    }

    @Test func changedOccurrencesWithOwnIdentifiersStillGroupByUID() {
        // Occurrences the organizer edited get their own EventKit identifier.
        var w1 = invite("w1", series: "s", day: 17)
        var w2 = invite("w2", series: "s", day: 24)
        w1.seriesID = "ek-1"
        w2.seriesID = "ek-2"
        w2.isDetached = true
        #expect(Invitations.pending(in: [w1, w2], now: now).map(\.id) == ["w1"])

        var pending = PendingResponses()
        pending.set(.declined, for: w1, wholeSeries: true)
        #expect(pending.apply(to: [w1, w2]).map { $0.invitationForCurrentUser?.status } == [.declined, .declined])
    }

    @Test func changedOccurrenceBorrowsSeriesRule() {
        var changed = invite("w1", series: "s", day: 17)
        changed.recurrence = nil
        changed.isDetached = true
        let regular = invite("w2", series: "s", day: 24)
        let result = Invitations.pending(in: [changed, regular], now: now)
        #expect(result.map(\.id) == ["w1"])
        #expect(result.first?.recurrence == RecurrenceRule(frequency: .weekly))
    }

    @Test func seriesResponseCoversAllOccurrences() {
        var pending = PendingResponses()
        pending.set(.accepted, for: invite("w1", series: "s", day: 17), wholeSeries: true)
        let result = pending.apply(to: [invite("w1", series: "s", day: 17), invite("w2", series: "s", day: 24), invite("other", day: 20)])
        #expect(result.map { $0.invitationForCurrentUser?.status } == [.accepted, .accepted, .pending])
    }
}
