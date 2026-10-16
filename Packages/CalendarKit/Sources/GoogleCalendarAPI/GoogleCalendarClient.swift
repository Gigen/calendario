import CalendarDomain
import Foundation

/// A coworker from the Workspace directory.
public struct DirectoryPerson: Sendable, Hashable, Identifiable {
    public var name: String?
    public var email: String
    public var id: String { email }

    public init(name: String?, email: String) {
        self.name = name
        self.email = email
    }
}

/// The result of creating or changing an event through Google.
public struct RemoteEventResult: Sendable, Equatable {
    public var id: String
    /// The iCalendar UID; the copy synced to the Mac carries the same one.
    public var iCalUID: String?
    public var meetURL: URL?
    public var htmlLink: URL?
}

/// The Google Calendar API v3 calls this app needs.
public struct GoogleCalendarClient: Sendable {
    public let auth: GoogleAuthService
    private let http: any HTTPClient
    private let sleep: @Sendable (Duration) async throws -> Void
    static let base = URL(string: "https://www.googleapis.com/calendar/v3")!

    public init(
        auth: GoogleAuthService,
        http: any HTTPClient,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.auth = auth
        self.http = http
        self.sleep = sleep
    }

    /// Calendars the account owns (the scope only allows writing to those).
    public func ownedCalendars(account email: String) async throws -> [RemoteCalendar] {
        struct Page: Decodable {
            struct Entry: Decodable {
                let id: String
                let summary: String?
                let summaryOverride: String?
                let primary: Bool?
            }
            let items: [Entry]?
            let nextPageToken: String?
        }
        var calendars: [RemoteCalendar] = []
        var pageToken: String?
        repeat {
            var query = [URLQueryItem(name: "minAccessRole", value: "owner")]
            if let pageToken { query.append(URLQueryItem(name: "pageToken", value: pageToken)) }
            let page: Page = try await send(email: email, method: "GET", path: "users/me/calendarList", query: query)
            for entry in page.items ?? [] {
                let title = entry.summaryOverride ?? entry.summary ?? entry.id
                calendars.append(RemoteCalendar(id: entry.id, title: title, isPrimary: entry.primary ?? false))
            }
            pageToken = page.nextPageToken
        } while pageToken != nil
        return calendars
    }

    /// Creates the event, with a Meet link if `draft.addConference`. Invitees get
    /// Google's invitation email.
    public func insertEvent(_ draft: EventDraft, in ref: RemoteCalendarRef, calendar: Calendar) async throws -> RemoteEventResult {
        let body = GoogleEventMapping.insertBody(for: draft, calendar: calendar, conferenceRequestID: UUID().uuidString)
        let event: GoogleEvent = try await send(
            email: ref.accountEmail, method: "POST", path: eventsPath(ref.calendarID),
            query: writeQuery(notify: !draft.attendees.isEmpty), body: body
        )
        return try await finished(event, in: ref)
    }

    /// Changes an existing (non-repeating) event, found by its iCalendar UID.
    public func updateEvent(original: Event, draft: EventDraft, in ref: RemoteCalendarRef, calendar: Calendar) async throws -> RemoteEventResult {
        guard let uid = original.externalID else { throw GoogleAPIError.eventNotFound }
        struct List: Decodable { let items: [GoogleEvent]? }
        let found: List = try await send(
            email: ref.accountEmail, method: "GET", path: eventsPath(ref.calendarID),
            query: [URLQueryItem(name: "iCalUID", value: uid)]
        )
        guard let existing = found.items?.first else { throw GoogleAPIError.eventNotFound }

        let body = GoogleEventMapping.patchBody(
            original: EventDraft(event: original),
            updated: draft,
            existingAttendees: existing.attendees ?? [],
            calendar: calendar,
            conferenceRequestID: UUID().uuidString
        )
        let attendeesChanged = body.attendees != nil
        let event: GoogleEvent = try await send(
            email: ref.accountEmail, method: "PATCH", path: eventsPath(ref.calendarID) + "/" + percentEncoded(existing.id),
            query: writeQuery(notify: attendeesChanged), body: body
        )
        return try await finished(event, in: ref)
    }

    /// Events in `calendarID` that Google changed since `updatedSince`, expanded into
    /// occurrences between `timeMin` and `timeMax`. Used to check that the Mac keeps up.
    /// Deleted events and Google-only types (working location, focus time, ...),
    /// which never reach the Mac over CalDAV, are left out.
    public func recentChanges(
        account email: String,
        calendarID: String,
        updatedSince: Date,
        timeMin: Date,
        timeMax: Date,
        maxPages: Int = 3
    ) async throws -> [RemoteChange] {
        struct Page: Decodable {
            struct Item: Decodable {
                struct When: Decodable { let date: String?; let dateTime: String? }
                let iCalUID: String?
                let updated: String?
                let status: String?
                let eventType: String?
                let start: When?
                let end: When?
            }
            let items: [Item]?
            let nextPageToken: String?
        }
        var changes: [RemoteChange] = []
        var pageToken: String?
        var pages = 0
        repeat {
            var query = [
                URLQueryItem(name: "updatedMin", value: GoogleEventMapping.timestamp(updatedSince)),
                URLQueryItem(name: "timeMin", value: GoogleEventMapping.timestamp(timeMin)),
                URLQueryItem(name: "timeMax", value: GoogleEventMapping.timestamp(timeMax)),
                URLQueryItem(name: "singleEvents", value: "true"),
                URLQueryItem(name: "maxResults", value: "250"),
                URLQueryItem(name: "fields", value: "items(iCalUID,updated,status,eventType,start,end),nextPageToken"),
            ]
            if let pageToken { query.append(URLQueryItem(name: "pageToken", value: pageToken)) }
            let page: Page = try await send(email: email, method: "GET", path: eventsPath(calendarID), query: query)
            for item in page.items ?? [] {
                guard item.status != "cancelled",
                      (item.eventType ?? "default") == "default",
                      let uid = item.iCalUID,
                      let updated = item.updated.flatMap(GoogleEventMapping.parseTimestamp),
                      let start = GoogleEventMapping.parseWhen(date: item.start?.date, dateTime: item.start?.dateTime),
                      let end = GoogleEventMapping.parseWhen(date: item.end?.date, dateTime: item.end?.dateTime)
                else { continue }
                changes.append(RemoteChange(iCalUID: uid, updated: updated, start: start, end: end))
            }
            pageToken = page.nextPageToken
            pages += 1
        } while pageToken != nil && pages < maxPages
        return changes
    }

    /// Sends the user's response (accept, maybe, decline) to an invitation. For a
    /// repeating event only this occurrence is answered, unless `wholeSeries`.
    /// Google notifies the organizer.
    public func respond(to event: Event, with status: Attendee.Status, in ref: RemoteCalendarRef, wholeSeries: Bool = false) async throws {
        struct List: Decodable { let items: [GoogleEvent]? }
        // By UID Google returns the series plus any occurrences changed individually.
        var items: [GoogleEvent] = []
        if let uid = event.externalID {
            let found: List = try await send(
                email: ref.accountEmail, method: "GET", path: eventsPath(ref.calendarID),
                query: [URLQueryItem(name: "iCalUID", value: uid)]
            )
            items = found.items ?? []
        }
        if items.isEmpty {
            // The UID macOS reports doesn't always match Google's (seen with
            // occurrences changed individually). Find the event by time and title
            // instead, then look its series up by Google's own UID.
            guard let occurrence = try await findOccurrence(of: event, in: ref) else { throw GoogleAPIError.eventNotFound }
            uidMismatchLogger?(event.externalID ?? "none", occurrence.iCalUID ?? "none")
            if let realUID = occurrence.iCalUID {
                let found: List = try await send(
                    email: ref.accountEmail, method: "GET", path: eventsPath(ref.calendarID),
                    query: [URLQueryItem(name: "iCalUID", value: realUID)]
                )
                items = found.items ?? []
            }
            if !wholeSeries || items.isEmpty {
                // Answer the occurrence that was found directly (all we can do if
                // its series can't be found either).
                try await patchResponse(of: occurrence, to: status, in: ref)
                return
            }
        }
        guard let series = items.first(where: { $0.recurrence != nil }) ?? items.first(where: { $0.recurringEventId == nil }) ?? items.first else {
            throw GoogleAPIError.eventNotFound
        }

        var targets: [GoogleEvent]
        if !event.isRecurring {
            targets = [series]
        } else if wholeSeries {
            // Changed occurrences keep their own guest list, so answer those too.
            targets = [series] + items.filter { $0.id != series.id }
        } else {
            let occurrence = event.occurrenceDate ?? event.start
            let originalStart = event.isAllDay
                ? GoogleEventMapping.dateString(occurrence, calendar: .autoupdatingCurrent)
                : GoogleEventMapping.timestamp(occurrence)
            let instances: List = try await send(
                email: ref.accountEmail, method: "GET", path: eventsPath(ref.calendarID) + "/" + percentEncoded(series.id) + "/instances",
                query: [URLQueryItem(name: "originalStart", value: originalStart)]
            )
            guard let instance = instances.items?.first else { throw GoogleAPIError.eventNotFound }
            targets = [instance]
        }

        var answered = 0
        for target in targets where try await patchResponse(of: target, to: status, in: ref) {
            answered += 1
        }
        guard answered > 0 else {
            throw GoogleAPIError.http(status: 400, message: "You're not on this event's guest list.")
        }
    }

    /// Called with (macOS UID, Google UID) when the two didn't match, for diagnostics.
    public var uidMismatchLogger: (@Sendable (String, String) -> Void)?

    /// Sets the user's response on one Google event. Returns false if they're not a guest.
    @discardableResult
    private func patchResponse(of target: GoogleEvent, to status: Attendee.Status, in ref: RemoteCalendarRef) async throws -> Bool {
        guard let attendees = GoogleEventMapping.attendees(target.attendees ?? [], respondingAs: ref.accountEmail, with: status) else { return false }
        var body = GoogleEventBody()
        body.attendees = attendees
        let _: GoogleEvent = try await send(
            email: ref.accountEmail, method: "PATCH", path: eventsPath(ref.calendarID) + "/" + percentEncoded(target.id),
            query: [URLQueryItem(name: "sendUpdates", value: "all")], body: body
        )
        return true
    }

    /// The Google occurrence starting at the event's start (within a minute), preferring
    /// the same title.
    private func findOccurrence(of event: Event, in ref: RemoteCalendarRef) async throws -> GoogleEvent? {
        struct List: Decodable { let items: [GoogleEvent]? }
        let list: List = try await send(
            email: ref.accountEmail, method: "GET", path: eventsPath(ref.calendarID),
            query: [
                URLQueryItem(name: "timeMin", value: GoogleEventMapping.timestamp(event.start.addingTimeInterval(-60))),
                URLQueryItem(name: "timeMax", value: GoogleEventMapping.timestamp(max(event.end, event.start).addingTimeInterval(60))),
                URLQueryItem(name: "singleEvents", value: "true"),
                URLQueryItem(name: "maxResults", value: "50"),
            ]
        )
        let sameStart = (list.items ?? []).filter { item in
            guard let start = GoogleEventMapping.parseWhen(date: item.start?.date, dateTime: item.start?.dateTime) else { return false }
            return event.isAllDay ? item.start?.date != nil : abs(start.timeIntervalSince(event.start)) < 60
        }
        return sameStart.first { $0.summary == event.title } ?? (sameStart.count == 1 ? sameStart.first : nil)
    }

    /// Coworkers in the account's Workspace directory whose name or email starts with
    /// `query`. Needs the optional directory scope; personal accounts have no directory.
    public func searchDirectory(account email: String, query: String, limit: Int = 8) async throws -> [DirectoryPerson] {
        struct Response: Decodable {
            struct Person: Decodable {
                struct Name: Decodable { let displayName: String? }
                struct Email: Decodable {
                    struct Metadata: Decodable { let primary: Bool? }
                    let value: String?
                    let metadata: Metadata?
                }
                let names: [Name]?
                let emailAddresses: [Email]?
            }
            let people: [Person]?
        }
        var components = URLComponents(string: "https://people.googleapis.com/v1/people:searchDirectoryPeople")!
        components.queryItems = [
            URLQueryItem(name: "query", value: query),
            URLQueryItem(name: "readMask", value: "names,emailAddresses"),
            URLQueryItem(name: "sources", value: "DIRECTORY_SOURCE_TYPE_DOMAIN_PROFILE"),
            URLQueryItem(name: "sources", value: "DIRECTORY_SOURCE_TYPE_DOMAIN_CONTACT"),
            URLQueryItem(name: "pageSize", value: String(limit)),
        ]
        guard let url = components.url else { throw GoogleAPIError.invalidResponse }
        let response: Response = try await send(email: email, method: "GET", url: url)
        return (response.people ?? []).compactMap { person in
            let emails = person.emailAddresses ?? []
            guard let address = (emails.first { $0.metadata?.primary == true } ?? emails.first)?.value else { return nil }
            return DirectoryPerson(name: person.names?.first?.displayName, email: address.lowercased())
        }
    }

    // MARK: Helpers

    /// Meet links are usually ready at once; if Google reports "pending", poll briefly.
    private func finished(_ event: GoogleEvent, in ref: RemoteCalendarRef) async throws -> RemoteEventResult {
        var current = event
        var attempts = 0
        while current.conferencePending, attempts < 5 {
            attempts += 1
            try await sleep(.seconds(1))
            current = try await send(
                email: ref.accountEmail, method: "GET", path: eventsPath(ref.calendarID) + "/" + percentEncoded(current.id),
                query: [URLQueryItem(name: "conferenceDataVersion", value: "1")]
            )
        }
        return RemoteEventResult(
            id: current.id,
            iCalUID: current.iCalUID,
            meetURL: current.meetURL,
            htmlLink: current.htmlLink.flatMap(URL.init(string:))
        )
    }

    private func writeQuery(notify: Bool) -> [URLQueryItem] {
        [
            URLQueryItem(name: "conferenceDataVersion", value: "1"),
            // "none" for events without invitees; with invitees, send invitations.
            URLQueryItem(name: "sendUpdates", value: notify ? "all" : "none"),
        ]
    }

    private func eventsPath(_ calendarID: String) -> String {
        "calendars/\(percentEncoded(calendarID))/events"
    }

    private func percentEncoded(_ segment: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~@")
        return segment.addingPercentEncoding(withAllowedCharacters: allowed) ?? segment
    }

    /// An authorized JSON request. A 401 gets one retry with a fresh token.
    private func send<Response: Decodable>(
        email: String, method: String, path: String, query: [URLQueryItem] = [], body: (any Encodable)? = nil
    ) async throws -> Response {
        var components = URLComponents(string: Self.base.absoluteString + "/" + path)!
        if !query.isEmpty { components.queryItems = query }
        guard let url = components.url else { throw GoogleAPIError.invalidResponse }
        return try await send(email: email, method: method, url: url, body: body)
    }

    private func send<Response: Decodable>(
        email: String, method: String, url: URL, body: (any Encodable)? = nil
    ) async throws -> Response {
        let data = try body.map { try JSONEncoder().encode($0) }

        var response = try await perform(method: method, url: url, body: data, token: auth.accessToken(for: email))
        if response.status == 401 {
            response = try await perform(method: method, url: url, body: data, token: auth.accessToken(for: email, forceRefresh: true))
        }
        guard response.isSuccess else { throw GoogleAPIError.from(response) }
        do {
            return try JSONDecoder().decode(Response.self, from: response.body)
        } catch {
            throw GoogleAPIError.invalidResponse
        }
    }

    private func perform(method: String, url: URL, body: Data?, token: String) async throws -> HTTPResponse {
        var headers = ["Authorization": "Bearer \(token)", "Accept": "application/json"]
        if body != nil { headers["Content-Type"] = "application/json" }
        return try await http.send(HTTPRequest(method: method, url: url, headers: headers, body: body))
    }
}
