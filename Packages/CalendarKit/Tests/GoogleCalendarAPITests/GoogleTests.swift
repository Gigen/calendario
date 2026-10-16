import CalendarDomain
import Foundation
@testable import GoogleCalendarAPI
import Testing

/// Replays canned responses and records requests.
final class FakeHTTP: HTTPClient, @unchecked Sendable {
    private let lock = NSLock()
    private var responses: [HTTPResponse]
    private(set) var requests: [HTTPRequest] = []

    init(_ responses: [HTTPResponse]) { self.responses = responses }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        lock.withLock {
            requests.append(request)
            return responses.isEmpty ? HTTPResponse(status: 500, body: Data()) : responses.removeFirst()
        }
    }
}

func json(_ text: String, status: Int = 200) -> HTTPResponse {
    HTTPResponse(status: status, body: Data(text.utf8))
}

/// An unsigned JWT carrying `email` (only the payload is read).
func idToken(email: String) -> String {
    let payload = Data(#"{"email":"\#(email)","sub":"1"}"#.utf8).base64URLEncoded()
    return "eyJhbGciOiJub25lIn0.\(payload).sig"
}

let clientID = "1234567890-abc.apps.googleusercontent.com"
let config = GoogleOAuthConfig(clientID: clientID)!

func formFields(_ request: HTTPRequest) -> [String: String] {
    let body = String(decoding: request.body ?? Data(), as: UTF8.self)
    var fields: [String: String] = [:]
    for pair in body.split(separator: "&") {
        let parts = pair.split(separator: "=", maxSplits: 1).map { String($0).removingPercentEncoding ?? String($0) }
        fields[parts[0]] = parts.count > 1 ? parts[1] : ""
    }
    return fields
}

struct OAuthTests {
    @Test func reversedClientIDAndRedirect() {
        #expect(config.reversedClientID == "com.googleusercontent.apps.1234567890-abc")
        #expect(config.redirectURI == "com.googleusercontent.apps.1234567890-abc:/oauth2redirect")
        #expect(GoogleOAuthConfig(clientID: "") == nil)
        #expect(GoogleOAuthConfig(clientID: "not-a-client-id") == nil)
    }

    @Test func pkceMatchesRFC7636Example() {
        let pkce = PKCE(verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
        #expect(pkce.challenge == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    @Test func generatedVerifierIsValid() {
        let verifier = PKCE.generate().verifier
        #expect((43...128).contains(verifier.count))
        #expect(verifier.allSatisfy { $0.isLetter || $0.isNumber || "-._~".contains($0) })
    }

    @Test func authorizationURL() {
        let request = AuthorizationRequest(config: config, pkce: PKCE(verifier: "v".padding(toLength: 43, withPad: "v", startingAt: 0)), state: "xyz", loginHint: "me@gmail.com")
        let items = URLComponents(url: request.url, resolvingAgainstBaseURL: false)!.queryItems!
        let query = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
        #expect(request.url.host == "accounts.google.com")
        #expect(query["client_id"] == clientID)
        #expect(query["redirect_uri"] == config.redirectURI)
        #expect(query["response_type"] == "code")
        #expect(query["code_challenge_method"] == "S256")
        #expect(query["state"] == "xyz")
        #expect(query["login_hint"] == "me@gmail.com")
        #expect(query["scope"]?.contains("calendar.events.owned") == true)
        #expect(query["client_secret"] == nil)
    }

    @Test func callbackValidation() throws {
        let request = AuthorizationRequest(config: config, state: "xyz")
        let ok = URL(string: "\(config.redirectURI)?state=xyz&code=4/abc")!
        #expect(try request.code(from: ok) == "4/abc")
        #expect(throws: GoogleAPIError.stateMismatch) {
            try request.code(from: URL(string: "\(config.redirectURI)?state=evil&code=4/abc")!)
        }
        #expect(throws: GoogleAPIError.userCancelled) {
            try request.code(from: URL(string: "\(config.redirectURI)?error=access_denied&state=xyz")!)
        }
    }

    @Test func tokenRequestHasVerifierAndNoSecret() {
        let request = AuthorizationRequest(config: config, pkce: PKCE(verifier: "verifier-value-that-is-long-enough-for-pkce-1234"))
        let fields = formFields(request.tokenRequest(code: "4/abc"))
        #expect(fields["code"] == "4/abc")
        #expect(fields["code_verifier"] == "verifier-value-that-is-long-enough-for-pkce-1234")
        #expect(fields["grant_type"] == "authorization_code")
        #expect(fields["client_secret"] == nil)
    }
}

struct AuthServiceTests {
    let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

    func service(_ http: FakeHTTP, store: InMemoryTokenStore = InMemoryTokenStore()) -> GoogleAuthService {
        let fixed = now
        return GoogleAuthService(config: config, http: http, store: store, now: { fixed })
    }

    @Test func signInStoresCredentialByEmail() async throws {
        let http = FakeHTTP([json(#"""
        {"access_token":"at1","expires_in":3600,"refresh_token":"rt1",
         "scope":"openid email \#(GoogleOAuthConfig.eventsScope) \#(GoogleOAuthConfig.calendarListScope)",
         "id_token":"\#(idToken(email: "Me@Gmail.com"))"}
        """#)])
        let store = InMemoryTokenStore()
        let auth = service(http, store: store)
        let request = AuthorizationRequest(config: config, state: "s")
        let email = try await auth.completeSignIn(request, callback: URL(string: "\(config.redirectURI)?state=s&code=c")!)
        #expect(email == "me@gmail.com")
        #expect(try store.loadAll().first?.refreshToken == "rt1")
        #expect(try await auth.accessToken(for: email) == "at1") // still valid: no network
        #expect(http.requests.count == 1)
    }

    @Test func signInWithoutCalendarScopeFails() async throws {
        let http = FakeHTTP([json(#"{"access_token":"at","expires_in":3600,"refresh_token":"rt","scope":"openid email","id_token":"\#(idToken(email: "a@b.com"))"}"#)])
        let auth = service(http)
        let request = AuthorizationRequest(config: config, state: "s")
        await #expect(throws: GoogleAPIError.missingScopes) {
            try await auth.completeSignIn(request, callback: URL(string: "\(config.redirectURI)?state=s&code=c")!)
        }
    }

    @Test func expiredTokenIsRefreshedSilently() async throws {
        let store = InMemoryTokenStore([StoredCredential(email: "a@b.com", refreshToken: "rt", accessToken: "old", accessTokenExpiry: now.addingTimeInterval(30))])
        let http = FakeHTTP([json(#"{"access_token":"new","expires_in":3600}"#)])
        let auth = service(http, store: store)
        #expect(try await auth.accessToken(for: "a@b.com") == "new")
        #expect(formFields(http.requests[0])["grant_type"] == "refresh_token")
        #expect(formFields(http.requests[0])["client_secret"] == nil)
        #expect(try store.loadAll().first?.accessToken == "new")
        #expect(try store.loadAll().first?.refreshToken == "rt") // kept when not rotated
    }

    @Test func revokedRefreshTokenMarksAccountForReconnect() async throws {
        let store = InMemoryTokenStore([StoredCredential(email: "a@b.com", refreshToken: "rt")])
        let http = FakeHTTP([json(#"{"error":"invalid_grant","error_description":"Token has been expired or revoked."}"#, status: 400)])
        let auth = service(http, store: store)
        await #expect(throws: GoogleAPIError.needsReauthentication(email: "a@b.com")) {
            try await auth.accessToken(for: "a@b.com")
        }
        #expect(try await auth.accounts().first?.needsReauthentication == true)
        #expect(try store.loadAll().first?.needsReauthentication == true)
    }

    @Test func unknownAccount() async {
        let auth = service(FakeHTTP([]))
        await #expect(throws: GoogleAPIError.accountNotConnected(email: "x@y.com")) {
            try await auth.accessToken(for: "x@y.com")
        }
    }
}

struct EventMappingTests {
    var cal: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        return calendar
    }

    func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 0, _ min: Int = 0) -> Date {
        cal.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
    }

    @Test func timedEventBody() throws {
        var draft = EventDraft(title: "Sync", start: date(2026, 10, 14, 9), end: date(2026, 10, 14, 10), timeZone: cal.timeZone, calendarID: "x")
        draft.addConference = true
        draft.addAttendee(email: "Ana@Example.com")
        draft.alarms = [.relative(-600), .relative(-600), .relative(300)]
        let body = GoogleEventMapping.insertBody(for: draft, calendar: cal, conferenceRequestID: "req-1")
        #expect(body.start == .init(dateTime: "2026-10-14T09:00:00+02:00", timeZone: "Europe/Berlin"))
        #expect(body.end?.dateTime == "2026-10-14T10:00:00+02:00")
        #expect(body.conferenceData?.createRequest.requestId == "req-1")
        #expect(body.conferenceData?.createRequest.conferenceSolutionKey.type == "hangoutsMeet")
        #expect(body.attendees == [.object(["email": .string("ana@example.com")])])
        // Duplicates merged; alerts after the start can't be expressed.
        #expect(body.reminders == .init(useDefault: false, overrides: [.init(minutes: 10)]))
    }

    @Test func allDayEventUsesDatesWithExclusiveEnd() {
        let draft = EventDraft(title: "Trip", start: date(2026, 10, 24), end: date(2026, 10, 27), isAllDay: true, timeZone: nil, calendarID: "x")
        let body = GoogleEventMapping.insertBody(for: draft, calendar: cal, conferenceRequestID: "r")
        #expect(body.start == .init(date: "2026-10-24"))
        #expect(body.end == .init(date: "2026-10-27"))
        #expect(body.conferenceData == nil)
    }

    @Test func floatingTimeUsesCurrentZone() {
        let draft = EventDraft(start: date(2026, 1, 5, 9), end: date(2026, 1, 5, 10), timeZone: nil, calendarID: "x")
        let (start, _) = GoogleEventMapping.times(for: draft, calendar: cal)
        #expect(start == .init(dateTime: "2026-01-05T09:00:00+01:00", timeZone: "Europe/Berlin"))
    }

    @Test(arguments: [
        (RecurrenceRule(frequency: .weekly), false, "RRULE:FREQ=WEEKLY"),
        (RecurrenceRule(frequency: .weekly, interval: 2, daysOfWeek: [.init(weekday: 2), .init(weekday: 4)]), false, "RRULE:FREQ=WEEKLY;INTERVAL=2;BYDAY=MO,WE"),
        (RecurrenceRule(frequency: .monthly, daysOfWeek: [.init(weekday: 3, weekNumber: -1)]), false, "RRULE:FREQ=MONTHLY;BYDAY=-1TU"),
        (RecurrenceRule(frequency: .daily, end: .afterOccurrences(5)), false, "RRULE:FREQ=DAILY;COUNT=5"),
    ])
    func rrules(rule: RecurrenceRule, allDay: Bool, expected: String) {
        #expect(GoogleEventMapping.rrule(rule, isAllDay: allDay, calendar: cal) == expected)
    }

    @Test func rruleUntilMatchesStartType() {
        let until = RecurrenceRule(frequency: .daily, end: .until(date(2026, 12, 31, 23, 59)))
        #expect(GoogleEventMapping.rrule(until, isAllDay: false, calendar: cal) == "RRULE:FREQ=DAILY;UNTIL=20261231T225900Z")
        #expect(GoogleEventMapping.rrule(until, isAllDay: true, calendar: cal) == "RRULE:FREQ=DAILY;UNTIL=20261231")
    }

    @Test func patchSendsOnlyChangesAndKeepsAttendeeResponses() {
        let event = Event(
            id: "e", seriesID: "e", externalID: "uid@google.com", calendarID: "x", title: "Sync", notes: "Join with Google Meet: https://meet.google.com/x",
            start: date(2026, 10, 14, 9), end: date(2026, 10, 14, 10), timeZone: cal.timeZone,
            attendees: [Attendee(name: "Ana", email: "ana@example.com", status: .accepted)]
        )
        var draft = EventDraft(event: event)
        draft.addAttendee(email: "bob@example.com")
        let existing: [JSONValue] = [
            .object(["email": .string("me@gmail.com"), "organizer": .bool(true), "responseStatus": .string("accepted")]),
            .object(["email": .string("ana@example.com"), "responseStatus": .string("accepted")]),
        ]
        let body = GoogleEventMapping.patchBody(original: EventDraft(event: event), updated: draft, existingAttendees: existing, calendar: cal, conferenceRequestID: "r")
        #expect(body.summary == nil)
        #expect(body.description == nil) // unchanged notes aren't written back
        #expect(body.start == nil)
        #expect(body.attendees == [
            existing[0],
            existing[1],
            .object(["email": .string("bob@example.com")]),
        ])
    }

    @Test func responseParsing() throws {
        let data = Data(#"""
        {"id":"abc","iCalUID":"abc@google.com","htmlLink":"https://www.google.com/calendar/event?eid=1",
         "hangoutLink":"https://meet.google.com/old-link",
         "conferenceData":{"entryPoints":[{"entryPointType":"phone","uri":"tel:+1"},{"entryPointType":"video","uri":"https://meet.google.com/aaa-bbbb-ccc"}],
                           "createRequest":{"status":{"statusCode":"success"}}}}
        """#.utf8)
        let event = try JSONDecoder().decode(GoogleEvent.self, from: data)
        #expect(event.meetURL == URL(string: "https://meet.google.com/aaa-bbbb-ccc"))
        #expect(!event.conferencePending)
    }
}

struct ClientTests {
    @Test func insertWaitsForPendingMeetAndRetriesOn401() async throws {
        let store = InMemoryTokenStore([StoredCredential(email: "me@gmail.com", refreshToken: "rt", accessToken: "at", accessTokenExpiry: .distantFuture)])
        let http = FakeHTTP([
            json(#"{"error":{"code":401,"message":"Invalid Credentials"}}"#, status: 401),
            json(#"{"access_token":"at2","expires_in":3600}"#),
            json(#"{"id":"ev1","iCalUID":"ev1@google.com","conferenceData":{"createRequest":{"status":{"statusCode":"pending"}}}}"#),
            json(#"{"id":"ev1","iCalUID":"ev1@google.com","conferenceData":{"entryPoints":[{"entryPointType":"video","uri":"https://meet.google.com/xyz"}],"createRequest":{"status":{"statusCode":"success"}}}}"#),
        ])
        let auth = GoogleAuthService(config: config, http: http, store: store)
        let client = GoogleCalendarClient(auth: auth, http: http, sleep: { _ in })
        var draft = EventDraft(title: "Meet", start: Date(), end: Date().addingTimeInterval(3600), calendarID: "x")
        draft.addConference = true
        let result = try await client.insertEvent(draft, in: RemoteCalendarRef(accountEmail: "me@gmail.com", calendarID: "me@gmail.com"), calendar: .current)

        #expect(result.meetURL == URL(string: "https://meet.google.com/xyz"))
        #expect(result.iCalUID == "ev1@google.com")
        let insert = http.requests[2]
        #expect(insert.method == "POST")
        #expect(insert.url.absoluteString.hasPrefix("https://www.googleapis.com/calendar/v3/calendars/me@gmail.com/events?"))
        #expect(insert.url.query?.contains("conferenceDataVersion=1") == true)
        #expect(insert.url.query?.contains("sendUpdates=none") == true)
        #expect(insert.headers["Authorization"] == "Bearer at2")
    }

    @Test func httpErrorMessageIsSurfaced() async throws {
        let store = InMemoryTokenStore([StoredCredential(email: "me@gmail.com", refreshToken: "rt", accessToken: "at", accessTokenExpiry: .distantFuture)])
        let http = FakeHTTP([json(#"{"error":{"code":403,"message":"Insufficient Permission"}}"#, status: 403)])
        let client = GoogleCalendarClient(auth: GoogleAuthService(config: config, http: http, store: store), http: http)
        await #expect(throws: GoogleAPIError.http(status: 403, message: "Insufficient Permission")) {
            _ = try await client.ownedCalendars(account: "me@gmail.com")
        }
    }
}

struct RecentChangesTests {
    @Test func parsesChangesAndSkipsDeletedAndGoogleOnlyTypes() async throws {
        let store = InMemoryTokenStore([StoredCredential(email: "me@work.com", refreshToken: "rt", accessToken: "at", accessTokenExpiry: .distantFuture)])
        let http = FakeHTTP([json(#"""
        {"items":[
          {"iCalUID":"a@google.com","updated":"2026-10-14T08:51:23.456Z","status":"confirmed","start":{"dateTime":"2026-10-15T09:00:00+02:00"},"end":{"dateTime":"2026-10-15T10:00:00+02:00"}},
          {"iCalUID":"b@google.com","updated":"2026-10-14T08:00:00Z","status":"cancelled","start":{"dateTime":"2026-10-15T09:00:00+02:00"},"end":{"dateTime":"2026-10-15T10:00:00+02:00"}},
          {"iCalUID":"c@google.com","updated":"2026-10-14T08:00:00Z","eventType":"workingLocation","start":{"date":"2026-10-15"},"end":{"date":"2026-10-16"}},
          {"iCalUID":"d@google.com","updated":"2026-10-14T07:00:00Z","eventType":"default","start":{"date":"2026-10-20"},"end":{"date":"2026-10-21"}}
        ]}
        """#)])
        let client = GoogleCalendarClient(auth: GoogleAuthService(config: config, http: http, store: store), http: http)
        let now = Date()
        let changes = try await client.recentChanges(account: "me@work.com", calendarID: "me@work.com", updatedSince: now, timeMin: now, timeMax: now)
        #expect(changes.map(\.iCalUID) == ["a@google.com", "d@google.com"])
        #expect(changes[0].updated == GoogleEventMapping.parseTimestamp("2026-10-14T08:51:23.456Z"))
        let query = http.requests[0].url.query ?? ""
        #expect(query.contains("singleEvents=true"))
        #expect(query.contains("updatedMin="))
    }
}

struct RespondTests {
    let attendees: [JSONValue] = [
        .object(["email": .string("org@example.com"), "organizer": .bool(true), "responseStatus": .string("accepted")]),
        .object(["email": .string("me@work.com"), "self": .bool(true), "responseStatus": .string("needsAction")]),
        .object(["email": .string("ana@example.com"), "responseStatus": .string("declined")]),
    ]

    @Test func changesOnlyOwnResponse() {
        let updated = GoogleEventMapping.attendees(attendees, respondingAs: "me@work.com", with: .accepted)
        #expect(updated?[1]["responseStatus"] == .string("accepted"))
        #expect(updated?[0] == attendees[0])
        #expect(updated?[2] == attendees[2])
    }

    @Test func fallsBackToEmailMatch() {
        let withoutSelf: [JSONValue] = [.object(["email": .string("Me@Work.com"), "responseStatus": .string("needsAction")])]
        #expect(GoogleEventMapping.attendees(withoutSelf, respondingAs: "me@work.com", with: .tentative)?[0]["responseStatus"] == .string("tentative"))
    }

    @Test func notInvitedOrUnsupportedStatus() {
        #expect(GoogleEventMapping.attendees([attendees[0]], respondingAs: "me@work.com", with: .declined) == nil)
        #expect(GoogleEventMapping.attendees(attendees, respondingAs: "me@work.com", with: .pending) == nil)
    }

    @Test func respondingToOccurrencePatchesInstance() async throws {
        let store = InMemoryTokenStore([StoredCredential(email: "me@work.com", refreshToken: "rt", accessToken: "at", accessTokenExpiry: .distantFuture)])
        let http = FakeHTTP([
            json(#"{"items":[{"id":"series1","iCalUID":"u@google.com"}]}"#),
            json(#"{"items":[{"id":"series1_20261014T070000Z","attendees":[{"email":"me@work.com","self":true,"responseStatus":"needsAction"}]}]}"#),
            json(#"{"id":"series1_20261014T070000Z"}"#),
        ])
        let client = GoogleCalendarClient(auth: GoogleAuthService(config: config, http: http, store: store), http: http)
        let start = Date(timeIntervalSince1970: 1_791_962_400)
        let event = Event(id: "e", seriesID: "s", externalID: "u@google.com", calendarID: "c", title: "Standup",
                          start: start, end: start.addingTimeInterval(900), occurrenceDate: start,
                          recurrence: RecurrenceRule(frequency: .daily))
        try await client.respond(to: event, with: .declined, in: RemoteCalendarRef(accountEmail: "me@work.com", calendarID: "me@work.com"))
        #expect(http.requests[1].url.path.hasSuffix("/events/series1/instances"))
        let patch = http.requests[2]
        #expect(patch.method == "PATCH")
        #expect(patch.url.path.hasSuffix("/events/series1_20261014T070000Z"))
        #expect(patch.url.query?.contains("sendUpdates=all") == true)
        #expect(String(decoding: patch.body ?? Data(), as: UTF8.self).contains(#""responseStatus":"declined""#))
    }
}

struct DirectoryTests {
    @Test func searchParsesPeopleAndPrefersPrimaryEmail() async throws {
        let store = InMemoryTokenStore([StoredCredential(email: "me@work.com", refreshToken: "rt", accessToken: "at", accessTokenExpiry: .distantFuture)])
        let http = FakeHTTP([json(#"""
        {"people":[
          {"names":[{"displayName":"Ana Novak"}],"emailAddresses":[{"value":"ana.alias@work.com"},{"value":"Ana@Work.com","metadata":{"primary":true}}]},
          {"emailAddresses":[{"value":"room-1@work.com"}]},
          {"names":[{"displayName":"No Email"}]}
        ]}
        """#)])
        let client = GoogleCalendarClient(auth: GoogleAuthService(config: config, http: http, store: store), http: http)
        let people = try await client.searchDirectory(account: "me@work.com", query: "an")
        #expect(people == [DirectoryPerson(name: "Ana Novak", email: "ana@work.com"), DirectoryPerson(name: nil, email: "room-1@work.com")])
        let url = http.requests[0].url.absoluteString
        #expect(url.hasPrefix("https://people.googleapis.com/v1/people:searchDirectoryPeople?"))
        #expect(url.contains("query=an"))
        #expect(url.contains("sources=DIRECTORY_SOURCE_TYPE_DOMAIN_PROFILE"))
    }

    @Test func grantedScopesAreRemembered() async throws {
        let http = FakeHTTP([json(#"""
        {"access_token":"at","expires_in":3600,"refresh_token":"rt",
         "scope":"openid \#(GoogleOAuthConfig.eventsScope) \#(GoogleOAuthConfig.calendarListScope) \#(GoogleOAuthConfig.directoryScope)",
         "id_token":"\#(idToken(email: "me@work.com"))"}
        """#)])
        let auth = GoogleAuthService(config: config, http: http, store: InMemoryTokenStore())
        let request = AuthorizationRequest(config: config, state: "s")
        _ = try await auth.completeSignIn(request, callback: URL(string: "\(config.redirectURI)?state=s&code=c")!)
        #expect(try await auth.accounts().first?.canSearchDirectory == true)
    }

    @Test func oldCredentialsCanBeDecoded() throws {
        let old = #"{"email":"a@b.com","refreshToken":"rt","needsReauthentication":false}"#
        let credential = try JSONDecoder().decode(StoredCredential.self, from: Data(old.utf8))
        #expect(credential.grantedScopes == nil)
    }
}

struct RespondSeriesTests {
    @Test func wholeSeriesAnswersSeriesAndChangedOccurrences() async throws {
        let store = InMemoryTokenStore([StoredCredential(email: "me@work.com", refreshToken: "rt", accessToken: "at", accessTokenExpiry: .distantFuture)])
        let me = #"{"email":"me@work.com","self":true,"responseStatus":"needsAction"}"#
        let http = FakeHTTP([
            json(#"{"items":[{"id":"ex1","recurringEventId":"s1","attendees":[\#(me)]},{"id":"s1","recurrence":["RRULE:FREQ=WEEKLY"],"attendees":[\#(me)]}]}"#),
            json(#"{"id":"s1"}"#),
            json(#"{"id":"ex1"}"#),
        ])
        let client = GoogleCalendarClient(auth: GoogleAuthService(config: config, http: http, store: store), http: http)
        let event = Event(id: "e", seriesID: "x", externalID: "u@google.com", calendarID: "c", title: "Weekly",
                          start: Date(), end: Date().addingTimeInterval(1800), recurrence: RecurrenceRule(frequency: .weekly))
        try await client.respond(to: event, with: .accepted, in: RemoteCalendarRef(accountEmail: "me@work.com", calendarID: "me@work.com"), wholeSeries: true)
        #expect(http.requests.count == 3)
        #expect(http.requests[1].url.path.hasSuffix("/events/s1")) // the series first
        #expect(http.requests[2].url.path.hasSuffix("/events/ex1"))
    }
}

struct RespondFallbackTests {
    @Test func findsEventByTimeWhenUIDDoesNotMatch() async throws {
        let store = InMemoryTokenStore([StoredCredential(email: "me@work.com", refreshToken: "rt", accessToken: "at", accessTokenExpiry: .distantFuture)])
        let me = #"{"email":"me@work.com","self":true,"responseStatus":"needsAction"}"#
        let http = FakeHTTP([
            json(#"{"items":[]}"#), // UID from macOS: nothing
            json(#"{"items":[{"id":"other","summary":"Other","start":{"dateTime":"2026-11-11T14:00:00+01:00"}},{"id":"s1_20261111T130000Z","iCalUID":"real@google.com","summary":"Weekly","start":{"dateTime":"2026-11-11T14:00:00+01:00"},"attendees":[\#(me)]}]}"#),
            json(#"{"items":[{"id":"s1","recurrence":["RRULE:FREQ=WEEKLY"],"attendees":[\#(me)]}]}"#), // by Google's UID
            json(#"{"id":"s1"}"#),
        ])
        var client = GoogleCalendarClient(auth: GoogleAuthService(config: config, http: http, store: store), http: http)
        let mismatches = MismatchLog()
        client.uidMismatchLogger = { mac, google in mismatches.add(mac + "|" + google) }
        let start = GoogleEventMapping.parseTimestamp("2026-11-11T14:00:00+01:00")!
        let event = Event(id: "e", seriesID: "x", externalID: "mac-uid", calendarID: "c", title: "Weekly",
                          start: start, end: start.addingTimeInterval(1800), isDetached: true)
        try await client.respond(to: event, with: .accepted, in: RemoteCalendarRef(accountEmail: "me@work.com", calendarID: "me@work.com"), wholeSeries: true)
        #expect(mismatches.values == ["mac-uid|real@google.com"])
        #expect(http.requests[2].url.query?.contains("iCalUID=real@google.com") == true)
        #expect(http.requests[3].method == "PATCH")
        #expect(http.requests[3].url.path.hasSuffix("/events/s1"))
    }
}

final class MismatchLog: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var values: [String] = []
    func add(_ value: String) { lock.withLock { values.append(value) } }
}
