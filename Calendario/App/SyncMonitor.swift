import CalendarDomain
import Foundation
import GoogleCalendarAPI
import Observation
import os

/// Detects when macOS stops syncing a connected Google account.
///
/// EventKit doesn't expose sync errors, so this compares instead: events Google
/// changed in the last few days, older than a grace period, should be in the
/// system calendar by now. If they aren't, the account's sign-in in Internet
/// Accounts has most likely broken. Reads only; nothing is written anywhere.
@Observable
final class SyncMonitor {
    /// Per Google account email. Missing means not checked yet.
    private(set) var health: [String: SyncHealth] = [:]
    private(set) var lastCheck: Date?
    /// Banners the user closed, until the account's state changes.
    private var dismissed: Set<String> = []

    private let store: CalendarStore
    private let google: GoogleAccountsStore
    private var started = false
    private var checking = false
    private let log = Logger(subsystem: AppInfo.subsystem, category: "sync-check")

    /// How far back to look for changes on Google.
    private static let lookback: TimeInterval = 3 * 86_400

    init(store: CalendarStore, google: GoogleAccountsStore) {
        self.store = store
        self.google = google
    }

    /// Accounts the system calendar is behind on, for the banner.
    var accountsBehind: [(email: String, missing: Int)] {
        health.compactMap { email, state in
            guard case .behind(let missing, _) = state, !dismissed.contains(email) else { return nil }
            return (email, missing)
        }
        .sorted { $0.email < $1.email }
    }

    func dismiss(_ email: String) {
        dismissed.insert(email)
    }

    /// Checks every 15 minutes, or every 2 while an account is behind, so the
    /// warning clears soon after the user fixes the sign-in.
    func start() {
        guard !started, google.isConfigured else { return }
        started = true
        Task {
            // Let the accounts and calendar lists load first.
            try? await Task.sleep(for: .seconds(20))
            while true {
                await check()
                let anyBehind = health.values.contains { if case .behind = $0 { true } else { false } }
                try? await Task.sleep(for: .seconds(anyBehind ? 120 : 900))
            }
        }
    }

    func check() async {
        guard !checking, store.access == .fullAccess else { return }
        checking = true
        defer { checking = false }

        let now = Date()
        let refsByCalendar = google.remoteCalendars(for: store)
        let byAccount = Dictionary(grouping: refsByCalendar, by: { $0.value.accountEmail })

        for account in google.accounts where !account.needsReauthentication {
            guard let pairs = byAccount[account.email], !pairs.isEmpty else {
                health[account.email] = .unknown
                continue
            }
            do {
                var changes: [RemoteChange] = []
                for remoteID in Set(pairs.map(\.value.calendarID)) {
                    changes += try await google.recentChanges(
                        account: account.email,
                        calendarID: remoteID,
                        updatedSince: now.addingTimeInterval(-Self.lookback),
                        timeMin: now.addingTimeInterval(-30 * 86_400),
                        timeMax: now.addingTimeInterval(180 * 86_400)
                    )
                }
                guard let interval = SyncHealth.comparisonInterval(for: changes) else {
                    update(account.email, .unknown)
                    continue
                }
                // Compare against all of the account's calendars, hidden ones included.
                let synced = try await store.provider.events(in: interval, calendarIDs: Set(pairs.map(\.key)))
                let result = SyncHealth.evaluate(changes: changes, syncedUIDs: Set(synced.compactMap(\.externalID)), now: now)
                update(account.email, result)
                if case .behind(let missing, _) = result {
                    log.info("System calendar is missing \(missing) Google changes for an account")
                }
            } catch {
                // A failed check says nothing about the sync; keep the last result.
                log.error("Sync check failed: \(String(describing: error), privacy: .public)")
            }
        }
        lastCheck = now
    }

    private func update(_ email: String, _ state: SyncHealth) {
        if health[email] != state { dismissed.remove(email) }
        health[email] = state
    }
}
