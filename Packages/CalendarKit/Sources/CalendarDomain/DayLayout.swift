import Foundation

/// Assigns events to days and lays out overlapping timed events side by side.
public struct DayLayout: Sendable {
    public var math: CalendarMath

    public init(math: CalendarMath = CalendarMath()) {
        self.math = math
    }

    /// Whether `event` should appear on the local day starting at `dayStart`.
    /// Multi-day events appear on every day they touch. End is exclusive, so an event
    /// ending exactly at midnight doesn't spill into the next day.
    public func event(_ event: Event, occursOn dayStart: Date) -> Bool {
        let day = math.dayInterval(containing: dayStart)
        if event.end <= event.start {
            return event.start >= day.start && event.start < day.end
        }
        return event.start < day.end && event.end > day.start
    }

    /// Events on the given day, all-day first, then by start time and longest first.
    public func events(_ events: [Event], on dayStart: Date) -> [Event] {
        events.filter { event($0, occursOn: dayStart) }.sorted(by: Self.displayOrder)
    }

    /// Display ordering for lists of events within one day.
    public static func displayOrder(_ a: Event, _ b: Event) -> Bool {
        if a.isAllDay != b.isAllDay { return a.isAllDay }
        if a.start != b.start { return a.start < b.start }
        if a.duration != b.duration { return a.duration > b.duration }
        return a.title.localizedStandardCompare(b.title) == .orderedAscending
    }

    /// A timed event or reminder positioned within a day column.
    public struct Placement: Hashable, Sendable {
        public var item: CalendarItem
        /// Wall-clock minutes since midnight, clipped to the day (0...1440).
        /// Reminders have no length: `endMinute == startMinute`.
        public var startMinute: Int
        public var endMinute: Int
        public var column: Int
        public var columnCount: Int
        /// The event started on an earlier day / continues into a later day.
        public var continuesBefore: Bool
        public var continuesAfter: Bool
    }

    /// Lays out the timed events and timed reminders of one day. Overlapping items
    /// share the width: each cluster of transitively overlapping items gets as many
    /// columns as it needs, and each item takes the first free column.
    ///
    /// - Parameter minimumMinutes: Short events and reminders (which have no length)
    ///   are treated as at least this long, so their boxes don't sit on top of each other.
    public func placements(for events: [Event], tasks: [TaskItem] = [], on dayStart: Date, minimumMinutes: Int = 20) -> [Placement] {
        let day = math.dayInterval(containing: dayStart)
        let minutesInDay = 24 * 60

        let eventItems: [Placement] = events
            .filter { !$0.isAllDay && event($0, occursOn: day.start) }
            .map { event in
                let start = max(event.start, day.start)
                let end = min(event.end, day.end)
                let startMinute = start == day.start ? 0 : math.wallClockMinutes(of: start)
                var endMinute = end >= day.end ? minutesInDay : math.wallClockMinutes(of: end)
                // Across a DST fall-back, the wall clock can go backwards.
                endMinute = max(endMinute, startMinute)
                return Placement(
                    item: .event(event),
                    startMinute: startMinute,
                    endMinute: endMinute,
                    column: 0,
                    columnCount: 1,
                    continuesBefore: event.start < day.start,
                    continuesAfter: event.end > day.end
                )
            }
        let taskItems: [Placement] = tasks.compactMap { task in
            guard case .time(let due) = task.due, day.containsHalfOpen(due) else { return nil }
            let minute = math.wallClockMinutes(of: due)
            return Placement(item: .task(task), startMinute: minute, endMinute: minute, column: 0, columnCount: 1, continuesBefore: false, continuesAfter: false)
        }

        var items = (eventItems + taskItems).sorted {
            if $0.startMinute != $1.startMinute { return $0.startMinute < $1.startMinute }
            if $0.endMinute != $1.endMinute { return $0.endMinute > $1.endMinute }
            return $0.item.id < $1.item.id
        }

        func visualEnd(_ p: Placement) -> Int {
            max(p.endMinute, min(p.startMinute + minimumMinutes, minutesInDay))
        }

        var clusterStart = 0
        var clusterEnd = Int.min
        var columnEnds: [Int] = []

        func closeCluster(upTo index: Int) {
            for i in clusterStart..<index { items[i].columnCount = columnEnds.count }
        }

        for index in items.indices {
            let start = items[index].startMinute
            if start >= clusterEnd, index > clusterStart {
                closeCluster(upTo: index)
                clusterStart = index
                columnEnds = []
            }
            let end = visualEnd(items[index])
            if let free = columnEnds.firstIndex(where: { $0 <= start }) {
                items[index].column = free
                columnEnds[free] = end
            } else {
                items[index].column = columnEnds.count
                columnEnds.append(end)
            }
            clusterEnd = index == clusterStart ? end : max(clusterEnd, end)
        }
        closeCluster(upTo: items.count)
        return items
    }
}

/// An entry on a calendar day: an event or a reminder.
public enum CalendarItem: Hashable, Sendable, Identifiable {
    case event(Event)
    case task(TaskItem)

    public var id: String {
        switch self {
        case .event(let event): "event:\(event.id)"
        case .task(let task): "task:\(task.id)"
        }
    }

    public var event: Event? {
        if case .event(let event) = self { return event }
        return nil
    }

    /// All-day events, then reminders due on the day without a time, then timed items
    /// by time (an event before a reminder at the same time).
    public static func merged(events: [Event], tasks: [TaskItem]) -> [CalendarItem] {
        func key(_ item: CalendarItem) -> (Int, Date, Int) {
            switch item {
            case .event(let event): event.isAllDay ? (0, event.start, 0) : (2, event.start, 0)
            case .task(let task):
                if let due = task.due, due.hasTime { (2, due.date, 1) } else { (1, task.due?.date ?? .distantPast, 1) }
            }
        }
        let items = events.map(CalendarItem.event) + tasks.map(CalendarItem.task)
        return items.enumerated()
            .sorted { lhs, rhs in
                let (a, b) = (key(lhs.element), key(rhs.element))
                if a.0 != b.0 { return a.0 < b.0 }
                if a.1 != b.1 { return a.1 < b.1 }
                if a.2 != b.2 { return a.2 < b.2 }
                return lhs.offset < rhs.offset
            }
            .map(\.element)
    }
}
