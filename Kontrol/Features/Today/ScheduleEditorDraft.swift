import Combine
import Foundation

/// A sheet-local value draft. Opening, changing, or discarding it never writes to storage.
/// Endpoints are absolute instants; changing the device zone only changes their display.
@MainActor
final class ScheduleEditorDraft: ObservableObject {
    enum Field: Hashable { case title, start, end }

    @Published var title: String { didSet { fieldsChanged() } }
    @Published var startAt: Date { didSet { fieldsChanged() } }
    @Published var endAt: Date { didSet { fieldsChanged() } }
    @Published var note: String { didSet { fieldsChanged() } }
    @Published private(set) var saveError: ScheduleMutationError?
    @Published private(set) var overlapReview: ScheduleOverlapReview?

    let editingID: UUID?
    private let store: ScheduleStore
    private var reviewedInput: ScheduleInput?
    private var finished = false
    private var submitting = false

    /// Start at 9am on the selected local day (or its first available time) and
    /// use an actual one-hour interval, including on 23/25-hour calendar days.
    init(creatingOn selectedDate: Date, calendar: Calendar, in store: ScheduleStore) {
        self.store = store
        editingID = nil
        title = ""
        note = ""
        let dayStart = calendar.startOfDay(for: selectedDate)
        let proposed = calendar.date(bySettingHour: 9, minute: 0, second: 0, of: dayStart)
        let dayEnd = calendar.dateInterval(of: .day, for: selectedDate)?.end
        let start = proposed.flatMap { candidate in
            candidate >= dayStart && (dayEnd.map { candidate < $0 } ?? true) ? candidate : nil
        } ?? dayStart
        startAt = start
        endAt = start.addingTimeInterval(60 * 60)
    }

    init(editing snapshot: ScheduleSnapshot, in store: ScheduleStore) {
        self.store = store
        editingID = snapshot.id
        title = snapshot.title
        startAt = snapshot.startAt
        endAt = snapshot.endAt
        note = snapshot.note ?? ""
    }

    var invalidFields: Set<Field> {
        var fields = Set<Field>()
        if title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { fields.insert(.title) }
        if !startAt.timeIntervalSinceReferenceDate.isFinite { fields.insert(.start) }
        if !endAt.timeIntervalSinceReferenceDate.isFinite ||
            (startAt.timeIntervalSinceReferenceDate.isFinite && endAt <= startAt) {
            fields.insert(.end)
        }
        return fields
    }

    var canSubmit: Bool { !finished && !submitting && invalidFields.isEmpty }
    var canKeepBoth: Bool { canSubmit && overlapReview != nil && reviewedInput == input }

    /// Edit time/dismissal removes approval but retains every editable field.
    func editTime() { clearReview() }

    func cancel() {
        guard !submitting else { return }
        finished = true
        clearReview()
    }

    /// Initial Save always checks for conflicts. An old review cannot be used here.
    func submit(onSuccess: (ScheduleSnapshot) -> Void) {
        guard canSubmit else { return }
        clearReview()
        save(allowOverlap: false, review: nil, onSuccess: onSuccess)
    }

    /// Only the current, explicitly reviewed draft may request Keep both. The
    /// repository re-reads persisted peers and replaces a stale decision.
    func keepBoth(onSuccess: (ScheduleSnapshot) -> Void) {
        guard canKeepBoth, let review = overlapReview else { return }
        save(allowOverlap: true, review: review, onSuccess: onSuccess)
    }

    private var input: ScheduleInput {
        ScheduleInput(title: title, startAt: startAt, endAt: endAt, note: note)
    }

    private func fieldsChanged() {
        saveError = nil
        clearReview()
    }

    private func clearReview() {
        overlapReview = nil
        reviewedInput = nil
    }

    private func save(allowOverlap: Bool, review: ScheduleOverlapReview?,
                      onSuccess: (ScheduleSnapshot) -> Void) {
        submitting = true
        defer { submitting = false }
        let submitted = input
        do {
            let committed: ScheduleSnapshot
            if let editingID {
                committed = try store.update(id: editingID, input: submitted,
                                             allowOverlap: allowOverlap, review: review)
            } else {
                committed = try store.create(input: submitted, allowOverlap: allowOverlap,
                                             review: review)
            }
            finished = true // A reentrant callback cannot submit again.
            clearReview()
            saveError = nil
            onSuccess(committed)
        } catch ScheduleRepositoryError.overlap(let freshReview) {
            // A vanished conflict is not an approval to save: ask for a normal Save.
            clearReview()
            if !freshReview.conflicts.isEmpty && submitted == input {
                overlapReview = freshReview
                reviewedInput = submitted
            }
            saveError = nil
        } catch {
            saveError = store.mutationError ?? .persistence
        }
    }
}
