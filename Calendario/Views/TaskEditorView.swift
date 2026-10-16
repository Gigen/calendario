import CalendarDomain
import SwiftUI

/// Create or edit a reminder: title, notes, list, due date/time, alert, priority.
struct TaskEditorView: View {
    @Environment(ReminderStore.self) private var reminders
    let original: TaskItem?
    @State var draft: TaskDraft
    var onClose: () -> Void
    var onDelete: (TaskItem) -> Void

    @State private var isSaving = false
    @State private var errorMessage: String?
    private let math = CalendarMath()

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    TextField("Title", text: $draft.title, prompt: Text("New Reminder"))
                        .font(.title3)
                    TextField("Notes", text: $draft.notes, prompt: Text("Add notes"), axis: .vertical)
                        .lineLimit(2...8)
                }
                Section {
                    dueEditor
                }
                Section {
                    Toggle("Alert", isOn: Binding(
                        get: { draft.alert != nil },
                        set: { draft.alert = $0 ? draft.suggestedAlert(now: Date(), math: math) : nil }
                    ))
                    if let alert = draft.alert {
                        DatePicker("Alert At", selection: Binding(get: { alert }, set: { draft.alert = $0 }))
                    }
                }
                Section {
                    ListPicker(selection: $draft.listID)
                    Picker("Priority", selection: $draft.priority) {
                        Text("None").tag(PriorityLevel.none)
                        Text("Low").tag(PriorityLevel.low)
                        Text("Medium").tag(PriorityLevel.medium)
                        Text("High").tag(PriorityLevel.high)
                    }
                } footer: {
                    if original?.isRecurring == true {
                        Text("This reminder repeats. Change the repeat rule in Reminders.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                if let original, reminders.canModify(original) {
                    Button("Delete Reminder…", role: .destructive) { onDelete(original) }
                }
                Spacer()
                Button("Cancel", role: .cancel, action: onClose)
                    .keyboardShortcut(.cancelAction)
                Button(original == nil ? "Add Reminder" : "Save", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(isSaving)
            }
            .padding(12)
        }
        .frame(width: 460, height: 520)
        .alert("Couldn't Save Reminder", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK") {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    @ViewBuilder private var dueEditor: some View {
        Toggle("Due Date", isOn: Binding(
            get: { draft.due != nil },
            set: { draft.setHasDue($0, day: Date(), math: math) }
        ))
        if let due = draft.due {
            DatePicker("Day", selection: Binding(get: { due.date }, set: { draft.setDueDay($0, math: math) }), displayedComponents: .date)
            Toggle("Time", isOn: Binding(
                get: { due.hasTime },
                set: { draft.setHasTime($0, now: Date(), math: math) }
            ))
            if due.hasTime {
                DatePicker("At", selection: Binding(get: { due.date }, set: { draft.setDueTime($0) }), displayedComponents: .hourAndMinute)
            }
        }
    }

    private func save() {
        var toSave = draft
        if toSave.title.trimmingCharacters(in: .whitespaces).isEmpty {
            toSave.title = String(localized: "New Reminder")
        }
        isSaving = true
        Task {
            defer { isSaving = false }
            do {
                try await reminders.save(toSave, original: original)
                onClose()
            } catch {
                errorMessage = ErrorText.message(for: error)
            }
        }
    }
}

/// Writable reminder lists grouped by account.
private struct ListPicker: View {
    @Environment(ReminderStore.self) private var reminders
    @Binding var selection: String

    var body: some View {
        Picker("List", selection: $selection) {
            ForEach(reminders.sources) { source in
                let lists = reminders.lists(in: source).filter(\.allowsContentModifications)
                if !lists.isEmpty {
                    Section(source.title) {
                        ForEach(lists) { list in
                            Label {
                                Text(list.title)
                            } icon: {
                                CalendarPalette.swatch(list.color) // menus ignore tint; use a real image
                            }
                            .tag(list.id)
                        }
                    }
                }
            }
        }
    }
}
