import CalendarDomain
import Foundation
import Observation
import os

/// App-wide reminders state: access, lists and which lists are hidden. Reminders
/// access is separate from calendar access, and the calendar works without it.
@Observable
final class ReminderStore {
    let provider: any TaskProvider

    /// `nil` until the system has answered.
    private(set) var access: AccessStatus?
    private(set) var isRequestingAccess = false
    private(set) var sources: [CalendarSource] = []
    private(set) var lists: [CalendarInfo] = []
    private(set) var lastError: String?
    /// Bumped whenever anything a view displays may have changed.
    private(set) var revision = 0

    var hiddenListIDs: Set<String> {
        didSet {
            UserDefaults.standard.set(Array(hiddenListIDs), forKey: Self.hiddenKey)
            revision += 1
        }
    }

    private static let hiddenKey = "hiddenReminderListIDs"
    private static let lastUsedListKey = "lastUsedReminderListID"
    private var listsByID: [String: CalendarInfo] = [:]
    private var systemColors: [String: RGBAColor] = [:]
    private var systemDefaultListID: String?
    private var started = false
    private let log = Logger(subsystem: AppInfo.subsystem, category: "access")

    init(provider: any TaskProvider) {
        self.provider = provider
        self.hiddenListIDs = Set(UserDefaults.standard.stringArray(forKey: Self.hiddenKey) ?? [])
    }

    // MARK: Lifecycle

    /// Same pattern as `CalendarStore.start()`: load, listen, never prompt by itself.
    func start() {
        guard !started else { return }
        started = true
        Task {
            await reload()
            for await _ in provider.changes() {
                await reload()
            }
        }
    }

    func requestAccess() async {
        guard !isRequestingAccess else { return }
        isRequestingAccess = true
        defer { isRequestingAccess = false }
        do {
            access = try await provider.requestTaskAccess()
        } catch {
            access = await provider.taskAccessStatus()
            lastError = error.localizedDescription
            log.error("Reminders access request failed: \(error.localizedDescription, privacy: .public)")
        }
        log.info("Reminders access is now \(String(describing: self.access), privacy: .public)")
        await reload()
    }

    func reload() async {
        access = await provider.taskAccessStatus()
        guard access == .fullAccess else {
            sources = []
            lists = []
            listsByID = [:]
            revision += 1
            return
        }
        do {
            sources = try await provider.taskSources()
                .sorted { ($0.kind.sortRank, $0.title.lowercased()) < ($1.kind.sortRank, $1.title.lowercased()) }
            let loaded = try await provider.taskLists()
                .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
            systemColors = Dictionary(loaded.map { ($0.id, $0.color) }, uniquingKeysWith: { first, _ in first })
            lists = ColorOverrides.apply(to: loaded, systemColors: systemColors)
            listsByID = Dictionary(lists.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            systemDefaultListID = await provider.defaultTaskListID()
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
        revision += 1
    }

    // MARK: Lists

    func list(id: String) -> CalendarInfo? { listsByID[id] }

    func lists(in source: CalendarSource) -> [CalendarInfo] {
        lists.filter { $0.sourceID == source.id }
    }

    func setColor(_ color: RGBAColor?, for list: CalendarInfo) {
        // Views read colors from the list itself, so no reload is needed.
        ColorOverrides.set(color, for: list.id)
        lists = ColorOverrides.apply(to: lists, systemColors: systemColors)
        listsByID = Dictionary(lists.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    func hasCustomColor(_ list: CalendarInfo) -> Bool {
        ColorOverrides.all()[list.id] != nil
    }

    var writableLists: [CalendarInfo] { lists.filter(\.allowsContentModifications) }

    var visibleListIDs: Set<String> {
        Set(lists.map(\.id)).subtracting(hiddenListIDs)
    }

    var visibleLists: [CalendarInfo] { lists.filter { !hiddenListIDs.contains($0.id) } }

    func isVisible(_ list: CalendarInfo) -> Bool { !hiddenListIDs.contains(list.id) }

    func setVisible(_ visible: Bool, for list: CalendarInfo) {
        if visible { hiddenListIDs.remove(list.id) } else { hiddenListIDs.insert(list.id) }
    }

    /// New reminders go into the last list used, else the system default.
    var listIDForNewTasks: String? {
        let writable = Set(writableLists.map(\.id))
        let lastUsed = UserDefaults.standard.string(forKey: Self.lastUsedListKey)
        return [lastUsed, systemDefaultListID].compactMap { $0 }.first(where: writable.contains)
            ?? writableLists.first?.id
    }

    func canModify(_ task: TaskItem) -> Bool {
        list(id: task.listID)?.allowsContentModifications ?? false
    }

    // MARK: Reading

    /// Reminders due in `interval` in visible lists, for the calendar views.
    func tasks(dueIn interval: DateInterval) async throws -> [TaskItem] {
        guard access == .fullAccess else { return [] }
        return try await provider.tasks(dueIn: interval, listIDs: visibleListIDs)
    }

    /// Everything open in visible lists, plus recently completed ones.
    func allTasks(completedSince: Date?) async throws -> [TaskItem] {
        guard access == .fullAccess else { return [] }
        return try await provider.tasks(inLists: visibleListIDs, completedSince: completedSince)
    }

    // MARK: Writing

    func save(_ draft: TaskDraft, original: TaskItem?) async throws {
        try await provider.saveTask(draft, original: original)
        if original == nil {
            UserDefaults.standard.set(draft.listID, forKey: Self.lastUsedListKey)
        }
        if hiddenListIDs.contains(draft.listID) {
            hiddenListIDs.remove(draft.listID)
        }
        revision += 1
    }

    func setCompleted(_ completed: Bool, task: TaskItem) async throws {
        try await provider.setCompleted(completed, task: task)
        revision += 1
    }

    func delete(_ task: TaskItem) async throws {
        try await provider.deleteTask(task)
        revision += 1
    }
}
