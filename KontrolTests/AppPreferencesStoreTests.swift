import Combine
import SwiftData
import SwiftUI
import XCTest
@testable import Kontrol

@MainActor
private final class PreferencesRepositorySpy: AppPreferencesRepository {
    enum Injected: Error { case failed }
    var value: AppPreferencesSnapshot = .defaults
    var readFailure: Error?
    var saveFailure: Error?
    var receiptPreferences: AppPreferences?
    private(set) var loads = 0
    private(set) var saves = 0

    func load() throws -> AppPreferencesSnapshot {
        loads += 1
        if let readFailure { throw readFailure }
        return value
    }

    func save(_ draft: AppPreferencesDraft, expectedRevision: UUID?) throws -> AppPreferencesSnapshot {
        saves += 1
        if let saveFailure { throw saveFailure }
        guard value.revision == expectedRevision else { throw AppPreferencesError.staleRevision }
        value = AppPreferencesSnapshot(preferences: try receiptPreferences ?? draft.validated(), revision: UUID())
        return value
    }
}

@MainActor
final class AppPreferencesStoreTests: XCTestCase {
    func testAccessibilityResolverPreservesSystemMappingsAndLargeTextIsAMinimumNotAMultiplier() throws {
        let system = AppPreferences.defaults
        let large = try AppPreferences(focusDefaultMinutes: 25, textSize: .large)
        let sizes: [DynamicTypeSize] = [.xSmall, .small, .medium, .large, .xLarge, .xxLarge, .xxxLarge,
                                      .accessibility1, .accessibility2, .accessibility3, .accessibility4, .accessibility5]
        for size in sizes {
            for preferences in [nil, system] {
                let effective = AppAccessibilityPreferences.resolve(preferences, systemTextSize: size,
                                                                     systemReduceMotion: false)
                XCTAssertEqual(effective.textSize, size)
                XCTAssertEqual(AppTypography.scale(for: effective.textSize), AppTypography.systemScale(for: size))
            }
            let effective = AppAccessibilityPreferences.resolve(large, systemTextSize: size, systemReduceMotion: false)
            XCTAssertEqual(effective.textSize, max(size, .xxLarge))
            for role in AppTypography.Role.allCases {
                XCTAssertEqual(AppTypography.pointSize(role, for: effective.textSize),
                               role.baseSize * max(1.3, AppTypography.systemScale(for: size)), accuracy: 0.001)
            }
            // Resolution is idempotent, including inherited sheet inputs.
            XCTAssertEqual(AppAccessibilityPreferences.resolve(large, systemTextSize: effective.textSize,
                                                               systemReduceMotion: effective.reduceMotion), effective)
        }
    }

    func testAccessibilityMotionORTruthTableAndPreviewSeamsAreNotPreferences() throws {
        for motion in AppReduceMotion.allCases {
            let preferences = try AppPreferences(focusDefaultMinutes: 25, reduceMotion: motion)
            for system in [false, true] {
                let effective = AppAccessibilityPreferences.resolve(preferences, systemTextSize: .large,
                                                                     systemReduceMotion: system)
                XCTAssertEqual(effective.reduceMotion, system || motion == .reduce)
                XCTAssertEqual(LoadingState.resolvedReduceMotion(system: effective.reduceMotion), effective.reduceMotion)
                // Explicit previews remain replacement seams, outside production resolution.
                XCTAssertFalse(LoadingState.resolvedReduceMotion(system: effective.reduceMotion, preview: false))
                XCTAssertTrue(LoadingState.resolvedReduceMotion(system: effective.reduceMotion, preview: true))
                XCTAssertEqual(AppTypography.scale(for: effective.textSize, override: 1), 1)
            }
        }
        XCTAssertTrue(AppAccessibilityPreferences.resolve(nil, systemTextSize: .large,
                                                          systemReduceMotion: true).reduceMotion)
    }

    func testAccessibilityUsesOnlyReadableCommittedReceiptsAndFallsBackToSystemOnReadFailure() throws {
        let repository = PreferencesRepositorySpy()
        let store = AppPreferencesStore(repository: repository)
        let editor = AppPreferencesEditorDraft(snapshot: store.editableSnapshot)
        func effective() -> AppAccessibilityPreferences {
            AppAccessibilityPreferences.resolve(store.editableSnapshot?.preferences,
                                                systemTextSize: .large, systemReduceMotion: false)
        }
        let baseline = effective()
        editor.draft.textSize = .large
        editor.draft.reduceMotion = .reduce
        XCTAssertEqual(effective(), baseline, "Local edits must not affect any scene")
        repository.saveFailure = PreferencesRepositorySpy.Injected.failed
        XCTAssertThrowsError(try editor.save(using: store))
        XCTAssertEqual(effective(), baseline)
        repository.saveFailure = nil
        try editor.save(using: store)
        XCTAssertEqual(effective(), AppAccessibilityPreferences(textSize: .xxLarge, reduceMotion: true, largeTextRequested: true))
        let saved = store.committed
        repository.readFailure = PreferencesRepositorySpy.Injected.failed
        store.retry()
        XCTAssertEqual(store.committed, saved, "Keep saved values without treating them as currently readable")
        XCTAssertEqual(effective(), baseline, "A read failure uses safe system behavior")
        repository.readFailure = nil
        store.retry()
        XCTAssertEqual(effective(), AppAccessibilityPreferences(textSize: .xxLarge, reduceMotion: true, largeTextRequested: true))
        XCTAssertEqual(repository.saves, 2, "Rendering and retries never persist accessibility inputs")
    }

    func testMissingPreferencesLoadDefaultsWithoutSavingAndRetryIsExplicit() {
        let repository = PreferencesRepositorySpy()
        let store = AppPreferencesStore(repository: repository)
        XCTAssertEqual(store.state, .loaded)
        XCTAssertEqual(store.committed, .defaults)
        XCTAssertEqual(store.editableSnapshot, .defaults)
        XCTAssertEqual(repository.loads, 1)
        XCTAssertEqual(repository.saves, 0)
        var states: [AppPreferencesReadState] = []
        let observation = store.$state.sink { states.append($0) }
        store.retry()
        XCTAssertEqual(states, [.loaded, .loading, .loaded])
        XCTAssertEqual(repository.loads, 2)
        XCTAssertEqual(repository.saves, 0)
        withExtendedLifetime(observation) {}
    }

    func testTwoEditorsShareCommittedPublicationButKeepIndependentInputsAndBaselines() throws {
        let repository = PreferencesRepositorySpy()
        let store = AppPreferencesStore(repository: repository)
        let first = AppPreferencesEditorDraft(snapshot: store.editableSnapshot)
        let second = AppPreferencesEditorDraft(snapshot: store.editableSnapshot)
        first.draft.focusDefaultMinutes = "50"
        first.draft.textSize = .large
        second.draft.focusDefaultMinutes = "37"
        second.draft.reduceMotion = .reduce
        let secondInput = second.draft
        var publications: [AppPreferencesSnapshot?] = []
        let observation = store.$committed.sink { publications.append($0) }
        try first.save(using: store)
        XCTAssertEqual(publications, [.defaults, repository.value])
        XCTAssertEqual(first.baseline, repository.value)
        XCTAssertFalse(first.hasChanges)
        XCTAssertEqual(second.draft, secondInput)
        XCTAssertEqual(second.baseline, .defaults)
        XCTAssertTrue(second.hasChanges)
        XCTAssertThrowsError(try second.save(using: store)) {
            XCTAssertEqual($0 as? AppPreferencesEditorError, .preferences(.staleRevision))
        }
        XCTAssertEqual(second.error, .preferences(.staleRevision))
        XCTAssertEqual(second.baseline, .defaults)
        XCTAssertEqual(second.draft, secondInput)
        XCTAssertEqual(publications.count, 2, "A stale proposal must not publish")
        // Reloading shared state alone never rebases an open editor.
        store.retry()
        XCTAssertEqual(second.baseline, .defaults)
        XCTAssertEqual(second.draft, secondInput)
        let savesBeforeReview = repository.saves
        try second.reviewLatest(using: store)
        XCTAssertEqual(second.baseline, first.baseline)
        XCTAssertEqual(second.draft, secondInput)
        XCTAssertNil(second.error)
        XCTAssertEqual(repository.saves, savesBeforeReview, "Review is not a save")
        try second.save(using: store)
        XCTAssertEqual(store.committed?.preferences.focusDefaultMinutes, 37)
        XCTAssertEqual(store.committed?.preferences.reduceMotion, .reduce)
        XCTAssertEqual(first.baseline?.preferences.focusDefaultMinutes, 50)
        withExtendedLifetime(observation) {}
    }

    func testSavePublishesRepositoryReceiptWithoutPostSaveRead() throws {
        let repository = PreferencesRepositorySpy()
        repository.receiptPreferences = try AppPreferences(focusDefaultMinutes: 15, reduceMotion: .reduce)
        let store = AppPreferencesStore(repository: repository)
        let editor = AppPreferencesEditorDraft(snapshot: store.editableSnapshot)
        editor.draft.focusDefaultMinutes = "50"
        try editor.save(using: store)
        XCTAssertEqual(store.committed, repository.value)
        XCTAssertEqual(store.committed?.preferences, repository.receiptPreferences)
        XCTAssertEqual(editor.baseline, repository.value)
        XCTAssertEqual(editor.draft.focusDefaultMinutes, "15")
        XCTAssertEqual(repository.loads, 1)
        XCTAssertEqual(repository.saves, 1)
    }

    func testSaveFailureRetainsAllInputsBaselineAndPriorCommittedPublication() throws {
        let repository = PreferencesRepositorySpy()
        repository.value = AppPreferencesSnapshot(preferences: try AppPreferences(focusDefaultMinutes: 15), revision: UUID())
        let original = repository.value
        let store = AppPreferencesStore(repository: repository)
        let editor = AppPreferencesEditorDraft(snapshot: store.editableSnapshot)
        editor.draft.focusDefaultMinutes = "00037"
        editor.draft.textSize = .large
        editor.draft.reduceMotion = .reduce
        let input = editor.draft
        var publications = 0
        let observation = store.$committed.dropFirst().sink { _ in publications += 1 }
        repository.saveFailure = PreferencesRepositorySpy.Injected.failed
        XCTAssertThrowsError(try editor.save(using: store)) {
            XCTAssertEqual($0 as? AppPreferencesEditorError, .preferences(.persistenceFailure))
        }
        XCTAssertEqual(editor.draft, input)
        XCTAssertEqual(editor.baseline, original)
        XCTAssertEqual(store.committed, original)
        XCTAssertEqual(store.state, .loaded)
        XCTAssertEqual(publications, 0)
        XCTAssertEqual(repository.loads, 1)
        repository.saveFailure = nil
        try editor.save(using: store)
        XCTAssertEqual(publications, 1)
        XCTAssertEqual(editor.draft.focusDefaultMinutes, "37")
        XCTAssertNil(editor.error)
        withExtendedLifetime(observation) {}
    }

    func testInvalidInputRemainsLocalWithoutCallingRepositorySave() {
        let repository = PreferencesRepositorySpy()
        let store = AppPreferencesStore(repository: repository)
        let editor = AppPreferencesEditorDraft(snapshot: store.editableSnapshot)
        editor.draft.focusDefaultMinutes = "1.5"
        XCTAssertThrowsError(try editor.save(using: store))
        XCTAssertEqual(editor.draft.focusDefaultMinutes, "1.5")
        XCTAssertEqual(editor.baseline, .defaults)
        XCTAssertNotNil(editor.error)
        XCTAssertEqual(repository.saves, 0)
        XCTAssertEqual(store.committed, .defaults)
    }

    func testReadFailureRetainsPriorValuesAndDraftAndFailedReviewCannotRebase() throws {
        let repository = PreferencesRepositorySpy()
        let store = AppPreferencesStore(repository: repository)
        let editor = AppPreferencesEditorDraft(snapshot: store.editableSnapshot)
        editor.draft.focusDefaultMinutes = "37"
        let input = editor.draft
        let external = AppPreferencesSnapshot(preferences: try AppPreferences(focusDefaultMinutes: 50), revision: UUID())
        repository.value = external
        repository.readFailure = AppPreferencesError.unsupportedPayloadVersion(2)
        var publications = 0
        let observation = store.$committed.dropFirst().sink { _ in publications += 1 }
        XCTAssertThrowsError(try editor.reviewLatest(using: store)) {
            XCTAssertEqual($0 as? AppPreferencesEditorError, .preferences(.unsupportedPayloadVersion(2)))
        }
        XCTAssertEqual(store.state, .failed(.unsupportedPayloadVersion(2)))
        XCTAssertEqual(store.committed, .defaults)
        XCTAssertNil(store.editableSnapshot)
        XCTAssertEqual(editor.draft, input)
        XCTAssertEqual(editor.baseline, .defaults)
        XCTAssertThrowsError(try editor.save(using: store))
        XCTAssertEqual(repository.saves, 0)
        XCTAssertEqual(publications, 0)
        repository.readFailure = nil
        try editor.reviewLatest(using: store)
        XCTAssertEqual(store.state, .loaded)
        XCTAssertEqual(store.committed, external)
        XCTAssertEqual(editor.baseline, external)
        XCTAssertEqual(editor.draft, input)
        XCTAssertEqual(publications, 1)
        try editor.save(using: store)
        XCTAssertEqual(store.committed?.preferences.focusDefaultMinutes, 37)
        withExtendedLifetime(observation) {}
    }

    func testInitialReadFailureDoesNotAuthorizeFallbackSaveAndRequiresExplicitReview() throws {
        let repository = PreferencesRepositorySpy()
        repository.readFailure = PreferencesRepositorySpy.Injected.failed
        let store = AppPreferencesStore(repository: repository)
        XCTAssertEqual(store.state, .failed(.persistenceFailure))
        XCTAssertNil(store.committed)
        let editor = AppPreferencesEditorDraft(snapshot: store.editableSnapshot)
        editor.draft.focusDefaultMinutes = "37"
        XCTAssertThrowsError(try editor.save(using: store)) {
            XCTAssertEqual($0 as? AppPreferencesEditorError, .preferencesUnavailable)
        }
        XCTAssertEqual(repository.loads, 1)
        XCTAssertEqual(repository.saves, 0)
        repository.readFailure = nil
        store.retry()
        XCTAssertNil(editor.baseline, "Shared retry must not authorize existing fallback editors")
        XCTAssertThrowsError(try editor.save(using: store))
        try editor.reviewLatest(using: store)
        XCTAssertEqual(editor.baseline, .defaults)
        XCTAssertEqual(editor.draft.focusDefaultMinutes, "37")
        try editor.save(using: store)
        XCTAssertEqual(store.committed?.preferences.focusDefaultMinutes, 37)
    }

    func testExternalChangeAfterReviewStillRejectsSave() throws {
        let repository = PreferencesRepositorySpy()
        let store = AppPreferencesStore(repository: repository)
        let editor = AppPreferencesEditorDraft(snapshot: store.editableSnapshot)
        editor.draft.focusDefaultMinutes = "37"
        try editor.reviewLatest(using: store)
        repository.value = AppPreferencesSnapshot(preferences: try AppPreferences(focusDefaultMinutes: 50), revision: UUID())
        XCTAssertThrowsError(try editor.save(using: store)) {
            XCTAssertEqual($0 as? AppPreferencesEditorError, .preferences(.staleRevision))
        }
        XCTAssertEqual(editor.draft.focusDefaultMinutes, "37")
        XCTAssertEqual(editor.baseline, .defaults)
        XCTAssertEqual(repository.value.preferences.focusDefaultMinutes, 50)
    }

    func testCancelOnlyResetsThisEditorWithoutChangingCommittedPreferences() throws {
        let repository = PreferencesRepositorySpy()
        let store = AppPreferencesStore(repository: repository)
        let first = AppPreferencesEditorDraft(snapshot: store.editableSnapshot)
        let second = AppPreferencesEditorDraft(snapshot: store.editableSnapshot)
        first.draft.focusDefaultMinutes = "50"
        try first.save(using: store)
        second.draft.focusDefaultMinutes = "invalid"
        XCTAssertThrowsError(try second.save(using: store))
        second.cancel()
        XCTAssertEqual(second.draft, AppPreferencesDraft())
        XCTAssertNil(second.error)
        XCTAssertFalse(second.hasChanges)
        XCTAssertEqual(store.committed, first.baseline)
        XCTAssertEqual(repository.saves, 1)
    }

    func testRealRepositorySharesReceiptsAndRetainsDraftAfterFailedCommit() throws {
        let container = try ModelContainerFactory().makeContainer(mode: .inMemory)
        var failSave = false
        let repository = SwiftDataAppPreferencesRepository(container: container, beforeSave: {
            if failSave { throw PreferencesRepositorySpy.Injected.failed }
        })
        let store = AppPreferencesStore(repository: repository)
        let editor = AppPreferencesEditorDraft(snapshot: store.editableSnapshot)
        editor.draft.focusDefaultMinutes = "37"
        try editor.save(using: store)
        let saved = try XCTUnwrap(store.committed)
        XCTAssertEqual(try repository.load(), saved)
        failSave = true
        editor.draft.focusDefaultMinutes = "50"
        XCTAssertThrowsError(try editor.save(using: store))
        XCTAssertEqual(editor.draft.focusDefaultMinutes, "50")
        XCTAssertEqual(editor.baseline, saved)
        XCTAssertEqual(store.committed, saved)
        XCTAssertEqual(try repository.load(), saved)
        let otherStore = AppPreferencesStore(repository: SwiftDataAppPreferencesRepository(container: container))
        XCTAssertEqual(otherStore.committed, saved)
    }
}
