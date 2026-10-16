import AppKit
import AuthenticationServices
import CalendarDomain
import Foundation
import GoogleCalendarAPI
import Observation
import os

/// Google accounts connected over OAuth, used only for what EventKit can't do:
/// creating Meet links and changing invitees. Everything else still goes through
/// the system calendar.
@Observable
final class GoogleAccountsStore {
    private(set) var accounts: [GoogleAuthService.Account] = []
    /// Calendars each account owns on Google, by account email.
    private(set) var remoteCalendars: [String: [RemoteCalendar]] = [:]
    private(set) var isConnecting = false
    private(set) var lastError: String?

    let config: GoogleOAuthConfig?
    private let auth: GoogleAuthService?
    private let client: GoogleCalendarClient?
    private let webAuth = WebAuthenticationSession()
    private let log = Logger(subsystem: AppInfo.subsystem, category: "google")

    /// The client ID comes from Info.plist (set in Config/Local.xcconfig). Without
    /// it the app runs normally, just without the Google features.
    init(clientID: String? = Bundle.main.object(forInfoDictionaryKey: "GoogleClientID") as? String) {
        config = clientID.flatMap(GoogleOAuthConfig.init(clientID:))
        if let config {
            let http = URLSessionHTTPClient()
            let auth = GoogleAuthService(config: config, http: http, store: KeychainTokenStore(service: AppInfo.bundleID + ".google-oauth"))
            self.auth = auth
            var client = GoogleCalendarClient(auth: auth, http: http)
            let log = Logger(subsystem: AppInfo.subsystem, category: "google")
            client.uidMismatchLogger = { mac, google in
                log.info("Event UID from macOS (\(mac, privacy: .public)) not found on Google; matched by time instead (\(google, privacy: .public))")
            }
            self.client = client
        } else {
            auth = nil
            client = nil
        }
    }

    /// Demo mode: these calendars count as connected, nothing reaches Google.
    private var demoCalendars: [String: RemoteCalendarRef]?

    init(demoCalendars: [String: RemoteCalendarRef]) {
        config = nil
        auth = nil
        client = nil
        self.demoCalendars = demoCalendars
    }

    var isConfigured: Bool { config != nil }

    func start() {
        Task { await reload() }
    }

    /// Loads accounts from the Keychain and each account's calendar list from Google.
    func reload() async {
        guard let auth, let client else { return }
        do {
            accounts = try await auth.accounts()
        } catch {
            lastError = ErrorText.message(for: error)
            return
        }
        for account in accounts where !account.needsReauthentication {
            do {
                remoteCalendars[account.email] = try await client.ownedCalendars(account: account.email)
            } catch {
                log.error("Couldn't load calendars for \(account.email, privacy: .private): \(String(describing: error), privacy: .public)")
                lastError = ErrorText.message(for: error)
                // A revoked token flips the account to "needs reconnect".
                accounts = (try? await auth.accounts()) ?? accounts
            }
        }
    }

    // MARK: Connecting

    /// Opens Google's sign-in in the system web sheet. Returns the connected email.
    @discardableResult
    func connect(loginHint: String? = nil) async -> String? {
        guard let auth, let config else { return nil }
        isConnecting = true
        defer { isConnecting = false }
        lastError = nil
        let request = AuthorizationRequest(config: config, loginHint: loginHint)
        do {
            let callback = try await webAuth.start(url: request.url, callbackScheme: config.callbackScheme)
            let email = try await auth.completeSignIn(request, callback: callback)
            log.info("Connected a Google account")
            await reload()
            return email
        } catch GoogleAPIError.userCancelled {
            return nil
        } catch {
            log.error("Google sign-in failed: \(String(describing: error), privacy: .public)")
            lastError = ErrorText.message(for: error)
            return nil
        }
    }

    func disconnect(email: String) async {
        guard let auth else { return }
        do {
            try await auth.disconnect(email: email)
        } catch {
            lastError = ErrorText.message(for: error)
        }
        remoteCalendars[email] = nil
        await reload()
    }

    func account(email: String?) -> GoogleAuthService.Account? {
        guard let email = email?.lowercased() else { return nil }
        return accounts.first { $0.email == email }
    }

    // MARK: Matching

    var connectedAccounts: [ConnectedAccount] {
        accounts
            .filter { !$0.needsReauthentication }
            .map { ConnectedAccount(email: $0.email, calendars: remoteCalendars[$0.email] ?? []) }
    }

    /// System calendar ID -> Google calendar, for calendars of connected accounts.
    func remoteCalendars(for store: CalendarStore) -> [String: RemoteCalendarRef] {
        if let demoCalendars { return demoCalendars }
        return CalendarMatcher.match(sources: store.sources, calendars: store.calendars, accounts: connectedAccounts)
    }

    // MARK: Writing

    func insert(_ draft: EventDraft, in ref: RemoteCalendarRef) async throws -> RemoteEventResult {
        guard let client else { throw GoogleAPIError.notConfigured }
        return try await client.insertEvent(draft, in: ref, calendar: .autoupdatingCurrent)
    }

    func recentChanges(account: String, calendarID: String, updatedSince: Date, timeMin: Date, timeMax: Date) async throws -> [RemoteChange] {
        guard let client else { throw GoogleAPIError.notConfigured }
        return try await client.recentChanges(account: account, calendarID: calendarID, updatedSince: updatedSince, timeMin: timeMin, timeMax: timeMax)
    }

    /// Coworkers matching `query` in the account's Workspace directory.
    func searchDirectory(account: String, query: String) async throws -> [DirectoryPerson] {
        guard let client else { throw GoogleAPIError.notConfigured }
        return try await client.searchDirectory(account: account, query: query)
    }

    func respond(to event: Event, with status: Attendee.Status, in ref: RemoteCalendarRef, wholeSeries: Bool = false) async throws {
        guard let client else { throw GoogleAPIError.notConfigured }
        try await client.respond(to: event, with: status, in: ref, wholeSeries: wholeSeries)
    }

    func update(_ original: Event, with draft: EventDraft, in ref: RemoteCalendarRef) async throws -> RemoteEventResult {
        guard let client else { throw GoogleAPIError.notConfigured }
        return try await client.updateEvent(original: original, draft: draft, in: ref, calendar: .autoupdatingCurrent)
    }
}

/// Runs `ASWebAuthenticationSession`, which shows Google's page in a system sheet
/// and hands back the redirect to the app's reversed-client-ID scheme.
@MainActor
private final class WebAuthenticationSession: NSObject, ASWebAuthenticationPresentationContextProviding {
    private var session: ASWebAuthenticationSession?

    func start(url: URL, callbackScheme: String) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            // `@Sendable` keeps this closure off the main actor: the system calls it on
            // a background queue, and a main-actor closure would trap there. It only
            // resumes the continuation, which is safe from any thread.
            let session = ASWebAuthenticationSession(url: url, callback: .customScheme(callbackScheme)) { @Sendable callback, error in
                if let callback {
                    continuation.resume(returning: callback)
                } else if let error = error as? ASWebAuthenticationSessionError, error.code == .canceledLogin {
                    continuation.resume(throwing: GoogleAPIError.userCancelled)
                } else {
                    continuation.resume(throwing: error ?? GoogleAPIError.invalidResponse)
                }
            }
            session.presentationContextProvider = self
            // Shares the browser's Google sign-in, so the account chooser can offer it.
            session.prefersEphemeralWebBrowserSession = false
            self.session = session
            if !session.start() {
                continuation.resume(throwing: GoogleAPIError.authorizationFailed("The sign-in window couldn't be opened."))
            }
        }
    }

    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        // Normally called on the main thread; don't rely on it.
        if Thread.isMainThread {
            return MainActor.assumeIsolated { Self.anchorWindow() }
        }
        return DispatchQueue.main.sync { MainActor.assumeIsolated { Self.anchorWindow() } }
    }

    private static func anchorWindow() -> ASPresentationAnchor {
        NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first ?? ASPresentationAnchor()
    }
}
