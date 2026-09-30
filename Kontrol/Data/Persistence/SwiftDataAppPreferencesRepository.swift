import Foundation
import SwiftData

@MainActor
final class SwiftDataAppPreferencesRepository: AppPreferencesRepository {
    private let container: ModelContainer
    // Match the project repository's pre-commit failure seam. It cannot return
    // a successful receipt without the real context save reaching storage.
    private let beforeSave: () throws -> Void

    init(container: ModelContainer, beforeSave: @escaping () throws -> Void = {}) {
        self.container = container
        self.beforeSave = beforeSave
    }

    private func context() -> ModelContext {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        return context
    }

    private func row(in context: ModelContext) throws -> AppPreferencesRecord? {
        // Fetch all rows, not just the canonical key: foreign singleton rows are
        // corruption, and selecting one of several rows would conceal damage.
        let rows = try context.fetch(FetchDescriptor<AppPreferencesRecord>())
        guard rows.count <= 1 else { throw AppPreferencesError.duplicateRecords }
        guard rows.allSatisfy({ $0.key == AppPreferencesRecord.singletonKey }) else {
            throw AppPreferencesError.invalidStoredData
        }
        return rows.first
    }

    private func snapshot(_ row: AppPreferencesRecord?) throws -> AppPreferencesSnapshot {
        guard let row else { return .defaults }
        let preferences = try AppPreferences(payloadVersion: row.payloadVersion,
            focusDefaultMinutes: row.focusDefaultMinutes, textSizeCode: row.textSize,
            reduceMotionCode: row.reduceMotion)
        return AppPreferencesSnapshot(preferences: preferences, revision: row.revision)
    }

    func load() throws -> AppPreferencesSnapshot {
        do {
            return try snapshot(row(in: context()))
        } catch let error as AppPreferencesError {
            throw error
        } catch {
            throw AppPreferencesError.persistenceFailure
        }
    }

    func save(_ draft: AppPreferencesDraft, expectedRevision: UUID?) throws -> AppPreferencesSnapshot {
        // No suspension between authoritative read, revision check, and commit.
        // Each editor's baseline is checked even when storage is still absent.
        let context = context()
        do {
            let row = try row(in: context)
            let current = try snapshot(row)
            guard current.revision == expectedRevision else {
                throw AppPreferencesError.staleRevision
            }
            let preferences = try draft.validated()
            let revision = UUID()
            if let row {
                row.payloadVersion = preferences.payloadVersion
                row.focusDefaultMinutes = preferences.focusDefaultMinutes
                row.textSize = preferences.textSize.rawValue
                row.reduceMotion = preferences.reduceMotion.rawValue
                row.revision = revision
            } else {
                context.insert(AppPreferencesRecord(payloadVersion: preferences.payloadVersion,
                    focusDefaultMinutes: preferences.focusDefaultMinutes,
                    textSize: preferences.textSize.rawValue, reduceMotion: preferences.reduceMotion.rawValue,
                    revision: revision))
            }
            try beforeSave()
            try context.save()
            return AppPreferencesSnapshot(preferences: preferences, revision: revision)
        } catch {
            // Never leave a failed transaction pending for autosave or another
            // operation. Other contexts (including unsaved UI work) are untouched.
            context.rollback()
            throw (error as? AppPreferencesError) ?? .persistenceFailure
        }
    }
}
