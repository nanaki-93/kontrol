import Combine
import Foundation

/// One unsaved editor instance per sheet presentation. The only persisted identity
/// is the UUID of an edit; no mutable SwiftData object or completion value is held.
@MainActor
final class TaskEditorDraft: ObservableObject {
    enum Field: Hashable { case title, plan }

    @Published var title: String { didSet { saveError = nil } }
    @Published var notes: String { didSet { saveError = nil } }
    @Published var dueAt: Date? { didSet { saveError = nil } }
    @Published var plannedFor: PlannedDay? { didSet { saveError = nil } }
    @Published private(set) var saveError: TaskMutationError?

    let editingID: UUID?
    private let store: TaskStore
    private var finished = false
    private var submitting = false

    init(creatingIn store: TaskStore) {
        self.store = store
        editingID = nil
        title = ""
        notes = ""
        dueAt = nil
        plannedFor = nil
    }

    /// Reject an inconsistent stored plan instead of silently clearing it on edit.
    /// Edits always target this UUID, even if another owner deletes it meanwhile.
    init(editing snapshot: TaskSnapshot, in store: TaskStore) throws {
        let plan = try PlannedDay.validated(components: snapshot.plannedDay,
                                            timeZoneID: snapshot.plannedTimeZoneID)
        self.store = store
        editingID = snapshot.id
        title = snapshot.title
        notes = snapshot.notes ?? ""
        dueAt = snapshot.dueAt
        plannedFor = plan
    }

    /// Capture date components and the zone at selection time, not at submission.
    func selectPlannedDate(_ date: Date, calendar: Calendar, timeZone: TimeZone) {
        plannedFor = PlannedDay.today(at: date, calendar: calendar, timeZone: timeZone)
    }

    var invalidFields: Set<Field> {
        var fields = Set<Field>()
        if title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { fields.insert(.title) }
        if let plannedFor {
            do { _ = try plannedFor.validated() }
            catch { fields.insert(.plan) }
        }
        return fields
    }

    var canSubmit: Bool { !finished && !submitting && invalidFields.isEmpty }

    /// Cancel only discards the sheet's values; it never touches the store.
    func cancel() { finished = true }

    func submit(onSuccess: (TaskSnapshot) -> Void) {
        guard canSubmit else { return }
        submitting = true
        defer { submitting = false }
        let input = TaskInput(title: title, notes: notes, dueAt: dueAt, plannedFor: plannedFor)
        do {
            let committed: TaskSnapshot
            if let editingID {
                committed = try store.update(id: editingID, input: input)
            } else {
                committed = try store.create(input: input)
            }
            finished = true // Set before callbacks; a reentrant submit cannot create again.
            saveError = nil
            onSuccess(committed)
        } catch {
            // TaskStore classifies missing IDs and refreshes; never show raw IO errors.
            saveError = store.mutationError ?? .writeFailed
        }
    }
}
