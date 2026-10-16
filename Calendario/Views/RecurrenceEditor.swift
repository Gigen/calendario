import CalendarDomain
import SwiftUI

/// The Repeat menu, an optional custom rule editor, and when the repeat ends.
struct RecurrenceEditor: View {
    @Binding var draft: EventDraft
    let math: CalendarMath

    /// The user picked "Custom…" for a rule that a simple preset also describes.
    @State private var showsCustomEditor = false

    private var preset: RecurrencePreset {
        RecurrencePreset.detect(draft.recurrence, start: draft.start, calendar: math.calendar)
    }

    private var menuSelection: RecurrencePreset {
        showsCustomEditor && draft.recurrence != nil ? .custom : preset
    }

    private var currentEnd: RecurrenceRule.End { draft.recurrence?.end ?? .never }

    var body: some View {
        Picker("Repeat", selection: Binding(get: { menuSelection }, set: { choose($0) })) {
            Text("Never").tag(RecurrencePreset.none)
            Divider()
            Text("Every Day").tag(RecurrencePreset.daily)
            Text("Every Weekday").tag(RecurrencePreset.weekdays)
            Text("Every Week").tag(RecurrencePreset.weekly)
            Text("Every 2 Weeks").tag(RecurrencePreset.biweekly)
            Text("Every Month").tag(RecurrencePreset.monthly)
            Text("Every Year").tag(RecurrencePreset.yearly)
            Divider()
            Text("Custom…").tag(RecurrencePreset.custom)
        }

        if let rule = draft.recurrence {
            if menuSelection == .custom {
                CustomRuleEditor(rule: Binding(get: { rule }, set: { draft.recurrence = $0 }), start: draft.start, math: math)
            }
            endEditor(rule)
        }
    }

    private func choose(_ preset: RecurrencePreset) {
        showsCustomEditor = preset == .custom
        switch preset {
        case .none:
            draft.recurrence = nil
        case .custom:
            // Keep the current rule and edit it; start a new one as weekly.
            if draft.recurrence == nil {
                draft.recurrence = RecurrenceRule(frequency: .weekly)
            }
        default:
            draft.recurrence = preset.rule(end: currentEnd)
        }
    }

    private enum EndKind: Hashable { case never, count, date }

    @ViewBuilder private func endEditor(_ rule: RecurrenceRule) -> some View {
        let kind: EndKind = switch rule.end {
        case .never: .never
        case .afterOccurrences: .count
        case .until: .date
        }
        Picker("End Repeat", selection: Binding(get: { kind }, set: { setEnd(kind: $0) })) {
            Text("Never").tag(EndKind.never)
            Text("After").tag(EndKind.count)
            Text("On Date").tag(EndKind.date)
        }
        switch rule.end {
        case .never:
            EmptyView()
        case .afterOccurrences(let count):
            Stepper(value: Binding(get: { count }, set: { draft.recurrence?.end = .afterOccurrences($0) }), in: 1...999) {
                Text("\(count) times")
            }
        case .until(let date):
            DatePicker(
                "Last Day",
                selection: Binding(get: { date }, set: { draft.recurrence?.end = .until(day: $0, math: math) }),
                in: draft.start...,
                displayedComponents: .date
            )
        }
    }

    private func setEnd(kind: EndKind) {
        switch kind {
        case .never:
            draft.recurrence?.end = .never
        case .count:
            draft.recurrence?.end = .afterOccurrences(10)
        case .date:
            let monthLater = math.calendar.date(byAdding: .month, value: 1, to: draft.start) ?? draft.start
            draft.recurrence?.end = .until(day: monthLater, math: math)
        }
    }
}

/// Frequency, interval, and the weekly days or monthly pattern.
private struct CustomRuleEditor: View {
    @Binding var rule: RecurrenceRule
    let start: Date
    let math: CalendarMath

    var body: some View {
        Picker("Frequency", selection: $rule.frequency) {
            Text("Daily").tag(RecurrenceRule.Frequency.daily)
            Text("Weekly").tag(RecurrenceRule.Frequency.weekly)
            Text("Monthly").tag(RecurrenceRule.Frequency.monthly)
            Text("Yearly").tag(RecurrenceRule.Frequency.yearly)
        }
        .onChange(of: rule.frequency) {
            // Day-of-week/month patterns from another frequency don't carry over.
            rule.daysOfWeek = []
            rule.daysOfMonth = []
            rule.monthsOfYear = []
            rule.setPositions = []
        }

        Stepper(value: $rule.interval, in: 1...99) {
            Text(intervalText)
        }

        switch rule.frequency {
        case .weekly: weekdayToggles
        case .monthly: monthlyPattern
        default: EmptyView()
        }
    }

    private var intervalText: String {
        let n = rule.interval
        return switch rule.frequency {
        case .daily: n == 1 ? String(localized: "Every day") : String(localized: "Every \(n) days")
        case .weekly: n == 1 ? String(localized: "Every week") : String(localized: "Every \(n) weeks")
        case .monthly: n == 1 ? String(localized: "Every month") : String(localized: "Every \(n) months")
        case .yearly: n == 1 ? String(localized: "Every year") : String(localized: "Every \(n) years")
        }
    }

    /// One toggle per weekday, in the locale's week order.
    private var weekdayToggles: some View {
        let first = math.calendar.firstWeekday
        let weekdays = (0..<7).map { (first - 1 + $0) % 7 + 1 }
        let symbols = math.calendar.shortStandaloneWeekdaySymbols
        let startWeekday = math.calendar.component(.weekday, from: start)
        let selected = rule.daysOfWeek.isEmpty ? [startWeekday] : rule.daysOfWeek.map(\.weekday)

        return LabeledContent("On") {
            HStack(spacing: 4) {
                ForEach(weekdays, id: \.self) { weekday in
                    Toggle(symbols[weekday - 1], isOn: Binding(
                        get: { selected.contains(weekday) },
                        set: { on in
                            var days = Set(selected)
                            if on { days.insert(weekday) } else if days.count > 1 { days.remove(weekday) }
                            rule.daysOfWeek = weekdays.filter(days.contains).map { .init(weekday: $0) }
                        }
                    ))
                    .toggleStyle(.button)
                }
            }
        }
    }

    private enum MonthlyKind: Hashable { case dayOfMonth, weekdayOrdinal }

    /// "On day 13" or "On the second Tuesday", both derived from the start date.
    @ViewBuilder private var monthlyPattern: some View {
        let day = math.calendar.component(.day, from: start)
        let weekday = math.calendar.component(.weekday, from: start)
        let range = math.calendar.range(of: .day, in: .month, for: start)?.count ?? 31
        // The last week counts as "last", so the rule still works in shorter months.
        let ordinal = day + 7 > range ? -1 : (day - 1) / 7 + 1
        let kind: MonthlyKind = rule.daysOfWeek.isEmpty ? .dayOfMonth : .weekdayOrdinal

        Picker("On", selection: Binding(get: { kind }, set: { newKind in
            if newKind == .dayOfMonth {
                rule.daysOfWeek = []
                rule.daysOfMonth = [day]
            } else {
                rule.daysOfMonth = []
                rule.daysOfWeek = [.init(weekday: weekday, weekNumber: ordinal)]
            }
        })) {
            Text("Day \(day)").tag(MonthlyKind.dayOfMonth)
            Text("The \(Self.ordinalText(ordinal)) \(math.calendar.weekdaySymbols[weekday - 1])").tag(MonthlyKind.weekdayOrdinal)
        }
    }

    private static func ordinalText(_ n: Int) -> String {
        switch n {
        case 1: String(localized: "first")
        case 2: String(localized: "second")
        case 3: String(localized: "third")
        case 4: String(localized: "fourth")
        default: String(localized: "last")
        }
    }
}
