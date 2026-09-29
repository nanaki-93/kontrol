import Foundation
import SwiftData
import XCTest
@testable import Kontrol

final class LearningCoverageTests: XCTestCase {
    private let early = Date(timeIntervalSince1970: 100)
    private let late = Date(timeIntervalSince1970: 200)

    private func membership(_ ids: [String] = ["a", "b", "c"],
                            subtopics: [String] = ["one", "two"]) -> CatalogMembershipAvailability {
        .available(CurrentCatalogMembership(catalogID: "catalog", catalogVersion: 2,
            topicIDs: ["topic"], subtopicIDs: subtopics, conceptIDs: ids.sorted(), seededLessonIDs: []))
    }

    private var topics: [LearningTopicSnapshot] { [.init(id: "topic", name: "Topic")] }
    private var subtopics: [LearningSubtopicSnapshot] {
        [.init(id: "one", topicID: "topic", name: "One"),
         .init(id: "two", topicID: "topic", name: "Two")]
    }
    private var concepts: [LearningConceptSnapshot] {
        [.init(id: "a", subtopicID: "one", name: "A", prerequisiteConceptIDs: ["b"]),
         .init(id: "b", subtopicID: "one", name: "B", prerequisiteConceptIDs: []),
         .init(id: "c", subtopicID: "two", name: "C", prerequisiteConceptIDs: [])]
    }

    private func completion(_ id: String, _ date: Date?, _ ids: [String]?,
                            _ status: LessonProgressStatus = .completed,
                            _ provenance: TerminalMetadataProvenance = .legacyCompletedPartial) -> CoverageCompletionEvidence {
        let metadata = LessonTerminalMetadata(lessonID: id, provenance: provenance,
            title: nil, topicID: nil, subtopicID: nil, contentVersion: nil,
            objectiveKey: nil, conceptIDs: ids, normalizedContentHash: nil,
            format: nil, dismissalTimeDefinition: nil)
        return CoverageCompletionEvidence(lessonID: id, status: status, completedAt: date, metadata: metadata)
    }

    private func coverage(_ membership: CatalogMembershipAvailability? = nil,
                          _ concepts: [LearningConceptSnapshot]? = nil,
                          _ completions: [CoverageCompletionEvidence] = []) throws -> [SubtopicCoverageSnapshot] {
        let snapshot = try LearningCoverage.aggregate(membership: membership ?? self.membership(),
            topics: topics, subtopics: subtopics, concepts: concepts ?? self.concepts, completions: completions)
        guard case let .available(catalogID, version, rows, _) = snapshot else {
            XCTFail("Expected available membership"); return []
        }
        XCTAssertEqual(catalogID, "catalog")
        XCTAssertEqual(version, 2)
        return rows
    }

    func testDistinctDirectCompletionsAndLatestActualDate() throws {
        let rows = try coverage(nil, nil, [completion("first", early, ["a"]),
            completion("second", late, ["a"]), completion("older", early, ["a"]),
            completion("dismissed", late, ["b"], .dismissed),
            completion("started", late, ["b"], .started),
            completion("available", late, ["b"], .available),
            completion("reference", late, ["b"], .completed, .dismissalReference)])
        XCTAssertEqual(rows.map(\.practicedConceptCount), [1, 0])
        XCTAssertEqual(rows.map(\.topicName), ["Topic", "Topic"])
        XCTAssertEqual(rows.map(\.currentConceptCount), [2, 1])
        XCTAssertEqual(rows[0].concepts.map(\.latestCompletion), [late, nil])
        XCTAssertEqual(rows[0].latestCompletion, late)
        // The reference cannot establish practice even if erroneously labeled completed.
        let snapshot = try LearningCoverage.aggregate(membership: membership(), topics: topics,
            subtopics: subtopics, concepts: concepts,
            completions: [completion("reference", late, ["b"], .completed, .dismissalReference)])
        if case let .available(_, _, _, evidence) = snapshot {
            XCTAssertEqual(evidence, .incomplete(completedLessonIDs: ["reference"]))
        } else { XCTFail("Expected incomplete evidence") }
    }

    func testCurrentMembershipAdditionRemovalRetirementAndReassignment() throws {
        let historical = [completion("historical", early, ["a", "c", "retired"])]
        let original = try coverage(nil, nil, historical)
        XCTAssertEqual(original.map(\.practicedConceptCount), [1, 1])
        let changed = [LearningConceptSnapshot(id: "a", subtopicID: "two", name: "Moved", prerequisiteConceptIDs: []),
                       LearningConceptSnapshot(id: "b", subtopicID: "one", name: "B", prerequisiteConceptIDs: []),
                       LearningConceptSnapshot(id: "added", subtopicID: "one", name: "Added", prerequisiteConceptIDs: ["a"]),
                       LearningConceptSnapshot(id: "c", subtopicID: "two", name: "Retired", prerequisiteConceptIDs: [])]
        let rows = try coverage(membership(["a", "added", "b"]), changed, historical)
        XCTAssertEqual(rows.map(\.currentConceptCount), [2, 1])
        XCTAssertEqual(rows.map(\.practicedConceptCount), [0, 1])
        XCTAssertEqual(rows[1].concepts.first?.latestCompletion, early)
        XCTAssertNil(rows[0].concepts.first?.latestCompletion) // prerequisites do not count
    }

    func testZeroDenominatorAndUnavailableMembershipAreDifferent() throws {
        let zero = try coverage(membership([], subtopics: ["one"]), nil,
                                [completion("old", early, ["a"])])
        XCTAssertEqual(zero[0].currentConceptCount, 0)
        XCTAssertEqual(zero[0].practicedConceptCount, 0)
        XCTAssertEqual(zero[0].concepts, [])
        XCTAssertEqual(try LearningCoverage.aggregate(membership: .unavailable,
            topics: topics, subtopics: subtopics, concepts: concepts, completions: []), .membershipUnavailable)
    }

    func testUnknownLegacyEvidenceIsNotPresentedAsZeroOrInferredFromDefinitions() throws {
        let missing = CoverageCompletionEvidence(lessonID: "unknown", status: .completed,
                                                  completedAt: early, metadata: nil)
        let snapshot = try LearningCoverage.aggregate(membership: membership(), topics: topics,
            subtopics: subtopics, concepts: concepts, completions: [missing,
                completion("partial", late, nil), completion("no-date", nil, ["a"]),
                completion("known", early, ["b"])])
        guard case let .available(_, _, rows, evidence) = snapshot else { return XCTFail("Unavailable") }
        XCTAssertEqual(rows[0].practicedConceptCount, 1)
        XCTAssertNil(rows[0].concepts[0].latestCompletion)
        XCTAssertEqual(evidence, .incomplete(completedLessonIDs: ["no-date", "partial", "unknown"]))
    }

    func testOverviewGroupsCurrentSubtopicsAndDistinguishesKnownFromIncompleteCounts() throws {
        let rows = try coverage(membership([], subtopics: ["one", "two"]))
        XCTAssertEqual(LearningCoverageView.groups(rows).map(\.id), ["topic"])
        XCTAssertEqual(LearningCoverageView.groups(rows)[0].subtopics.map(\.id), ["one", "two"])
        XCTAssertEqual(LearningCoverageView.countLabel(rows[0], evidence: .complete),
                       "0 of 0 concepts practiced")
        XCTAssertEqual(LearningCoverageView.countLabel(rows[0],
            evidence: .incomplete(completedLessonIDs: ["legacy"])),
            "0 of 0 concepts practiced (known evidence only)")
    }

    @MainActor
    func testConceptInspectionListsOnlyOfferedWorkAndNeverRetainedOrTerminalDefinitions() throws {
        let container = try ModelContainerFactory().makeContainer(mode: .inMemory)
        let repository = SwiftDataCatalogRepository(container: container)
        _ = try repository.importIfNeeded(BundledCatalogLoader.load())
        let before = try repository.loadSnapshot()
        let lesson = try XCTUnwrap(before.slots.first)
        let definition = try XCTUnwrap(before.definitions.first { $0.id == lesson.lessonID })
        let conceptID = try XCTUnwrap(definition.conceptIDs.first)
        let initial = LearningCoverage.lessons(for: conceptID, in: before, history: [])
        XCTAssertTrue(initial.contains { $0.lessonID == lesson.lessonID && $0.slot == lesson && !$0.started })
        XCTAssertTrue(initial.allSatisfy { choice in
            before.slots.contains(where: { $0 == choice.slot }) ||
                before.progress.contains(where: { $0.lessonID == choice.lessonID && $0.status == .started && $0.dismissedAt != nil })
        })
        XCTAssertEqual(try repository.loadSnapshot(), before)
        XCTAssertTrue(try repository.loadHistory().isEmpty)
        XCTAssertTrue(try ModelContext(container).fetch(FetchDescriptor<LessonAttempt>()).isEmpty)

        _ = try repository.dismiss(lessonID: lesson.lessonID, expectedSlot: lesson, now: late)
        let after = try repository.loadSnapshot()
        let history = try repository.loadHistory()
        XCTAssertFalse(LearningCoverage.lessons(for: conceptID, in: after, history: history)
            .contains { $0.lessonID == lesson.lessonID })
        XCTAssertTrue(LearningCoverage.completedReferences(for: conceptID, in: history).isEmpty,
                      "Dismissal is not direct practice or a completed reference")
        XCTAssertEqual(try repository.loadSnapshot(), after)
        XCTAssertEqual(try repository.loadHistory(), history)
        XCTAssertTrue(try ModelContext(container).fetch(FetchDescriptor<LessonAttempt>()).isEmpty)
        // Exhaust the topic through real replacement transactions, not by
        // deleting definitions. Browsing must not resurrect a dismissal.
        for index in 0..<20 {
            let current = try repository.loadSnapshot()
            guard let next = current.slots.first(where: { $0.topicID == lesson.topicID }) else { break }
            _ = try repository.dismiss(lessonID: next.lessonID, expectedSlot: next,
                                       now: Date(timeIntervalSince1970: 300 + Double(index)))
        }
        let exhausted = try repository.loadSnapshot()
        let saved = try repository.loadHistory()
        XCTAssertTrue(exhausted.slots.filter { $0.topicID == lesson.topicID }.isEmpty)
        XCTAssertTrue(LearningCoverage.lessons(for: conceptID, in: exhausted, history: saved).isEmpty)
        XCTAssertTrue(LearningCoverage.completedReferences(for: conceptID, in: saved).isEmpty)
        XCTAssertEqual(try repository.loadSnapshot(), exhausted)
        XCTAssertEqual(try repository.loadHistory(), saved)
    }

    @MainActor
    func testRestoredUnslottedStartedWorkIsVisibleWithoutAssigningAChoice() throws {
        let container = try ModelContainerFactory().makeContainer(mode: .inMemory)
        let repository = SwiftDataCatalogRepository(container: container)
        _ = try repository.importIfNeeded(BundledCatalogLoader.load())
        let slot = try XCTUnwrap(repository.loadSnapshot().slots.first)
        let conceptID = try XCTUnwrap(repository.loadSnapshot().definitions.first { $0.id == slot.lessonID }?.conceptIDs.first)
        let opened = try repository.openLesson(lessonID: slot.lessonID, now: early)
        XCTAssertNotNil(opened.detail.attempt)
        _ = try repository.dismiss(lessonID: slot.lessonID, expectedSlot: slot, now: late)
        _ = try repository.restoreDismissed(lessonID: slot.lessonID, now: Date(timeIntervalSince1970: 300))
        let snapshot = try repository.loadSnapshot()
        let history = try repository.loadHistory()
        XCTAssertFalse(snapshot.slots.contains { $0.lessonID == slot.lessonID })
        let choices = LearningCoverage.lessons(for: conceptID, in: snapshot, history: history)
        XCTAssertTrue(choices.contains { $0.lessonID == slot.lessonID && $0.started && $0.slot == nil })
        XCTAssertEqual(try repository.loadSnapshot(), snapshot)
        XCTAssertEqual(try repository.loadHistory(), history)
        XCTAssertEqual(try ModelContext(container).fetch(FetchDescriptor<LessonAttempt>()).count, 1)
    }

    @MainActor
    func testStartedInspectionUsesStudiedPinAfterUpgradeEditsAndOmission() throws {
        let container = try ModelContainerFactory().makeContainer(mode: .inMemory)
        let repository = SwiftDataCatalogRepository(container: container)
        let original = try BundledCatalogLoader.load()
        try repository.importIfNeeded(original)
        let initial = try repository.loadSnapshot()
        let slots = initial.slots.prefix(2)
        XCTAssertEqual(slots.count, 2)
        let edited = try XCTUnwrap(slots.first)
        let omitted = try XCTUnwrap(slots.dropFirst().first)
        let oldEdited = try XCTUnwrap(initial.definitions.first { $0.id == edited.lessonID })
        let oldOmitted = try XCTUnwrap(initial.definitions.first { $0.id == omitted.lessonID })
        for slot in [edited, omitted] {
            _ = try repository.openLesson(lessonID: slot.lessonID, now: early)
        }
        var upgrade = original.value
        upgrade.version += 1
        upgrade.lessons.removeAll { $0.id == omitted.lessonID }
        let index = try XCTUnwrap(upgrade.lessons.firstIndex { $0.id == edited.lessonID })
        upgrade.lessons[index].title = "New installed title"
        let replacementConcept = try XCTUnwrap(upgrade.concepts.first { concept in
            !oldEdited.conceptIDs.contains(concept.id) &&
            upgrade.subtopics.contains { $0.id == concept.subtopicID && $0.topicID == oldEdited.topicID }
        })
        upgrade.lessons[index].conceptIDs = [replacementConcept.id] // changed concept ownership
        upgrade.lessons[index].contentVersion += 1
        upgrade.lessons[index].explanation = "New installed prose"
        upgrade.lessons[index].normalizedContentHash = CatalogValidator.fingerprint(for: upgrade.lessons[index])
        try repository.importIfNeeded(CatalogValidator.validate(upgrade))
        // Imports retain omitted rows for history. Simulate a later cleanup so
        // inspection proves it reads the pin even with no definition at all.
        let cleanup = ModelContext(container)
        let oldRow = try XCTUnwrap(try cleanup.fetch(FetchDescriptor<LessonDefinition>())
            .first { $0.id == omitted.lessonID })
        cleanup.delete(oldRow)
        try cleanup.save()
        let after = try repository.loadSnapshot()
        XCTAssertFalse(after.definitions.contains { $0.id == omitted.lessonID })
        XCTAssertEqual(after.slots.first { $0.key == edited.key }, edited)
        XCTAssertEqual(after.slots.first { $0.key == omitted.key }, omitted)
        for (slot, originalDefinition) in [(edited, oldEdited), (omitted, oldOmitted)] {
            let concept = try XCTUnwrap(originalDefinition.conceptIDs.first)
            let choice = try XCTUnwrap(LearningCoverage.lessons(for: concept, in: after,
                history: repository.loadHistory()).first { $0.lessonID == slot.lessonID })
            XCTAssertEqual(choice.title, originalDefinition.title)
            XCTAssertTrue(choice.started)
            XCTAssertEqual(choice.slot, slot)
        }
        if let moved = after.definitions.first(where: { $0.id == edited.lessonID })?.conceptIDs.first,
           !oldEdited.conceptIDs.contains(moved) {
            XCTAssertFalse(LearningCoverage.lessons(for: moved, in: after, history: []).contains {
                $0.lessonID == edited.lessonID
            })
        }
        XCTAssertEqual(try repository.loadSnapshot(), after)
        XCTAssertEqual(try ModelContext(container).fetch(FetchDescriptor<LessonAttempt>()).count, 2)
    }

    @MainActor
    func testConceptOpenRejectsSlotReplacedOutsideCachedProjectionWithoutCreatingAttempt() throws {
        let container = try ModelContainerFactory().makeContainer(mode: .inMemory)
        let repository = SwiftDataCatalogRepository(container: container)
        try repository.importIfNeeded(BundledCatalogLoader.load())
        let cached = try repository.loadSnapshot()
        let slot = try XCTUnwrap(cached.slots.first)
        let concept = try XCTUnwrap(cached.definitions.first { $0.id == slot.lessonID }?.conceptIDs.first)
        let choice = try XCTUnwrap(LearningCoverage.lessons(for: concept, in: cached, history: [])
            .first { $0.lessonID == slot.lessonID })
        let context = ModelContext(container)
        let row = try XCTUnwrap(try context.fetch(FetchDescriptor<LessonSlot>()).first { $0.key == slot.key })
        let replacement = try XCTUnwrap(cached.definitions.first { definition in
            definition.topicID == slot.topicID &&
            !cached.slots.contains(where: { $0.lessonID == definition.id })
        })
        row.assignedAt = late
        try context.save()
        XCTAssertThrowsError(try repository.openConceptLesson(lessonID: choice.lessonID,
            expectedSlot: choice.slot, expectedConceptID: concept, now: late)) {
            XCTAssertEqual($0 as? LessonExperienceError, .staleSlot)
        }
        row.lessonID = replacement.id
        try context.save()
        XCTAssertThrowsError(try repository.openConceptLesson(lessonID: choice.lessonID,
            expectedSlot: choice.slot, expectedConceptID: concept, now: late)) {
            XCTAssertEqual($0 as? LessonExperienceError, .staleSlot)
        }
        XCTAssertEqual(try repository.loadSnapshot().slots.first { $0.key == slot.key }?.lessonID,
                       replacement.id)
        XCTAssertTrue(try ModelContext(container).fetch(FetchDescriptor<LessonAttempt>()).isEmpty)
        XCTAssertTrue(try ModelContext(container).fetch(FetchDescriptor<LessonProgress>()).isEmpty)
    }

    @MainActor
    func testConceptOpenRejectsStaleDefinitionWithoutStartingAndResumesFromStudiedPin() throws {
        let container = try ModelContainerFactory().makeContainer(mode: .inMemory)
        let repository = SwiftDataCatalogRepository(container: container)
        try repository.importIfNeeded(BundledCatalogLoader.load())
        let cached = try repository.loadSnapshot()
        let slot = try XCTUnwrap(cached.slots.first)
        let definition = try XCTUnwrap(cached.definitions.first { $0.id == slot.lessonID })
        let originalConcept = try XCTUnwrap(definition.conceptIDs.first)
        let replacement = try XCTUnwrap(cached.concepts.first { concept in
            !definition.conceptIDs.contains(concept.id) &&
            cached.subtopics.contains { $0.id == concept.subtopicID && $0.topicID == definition.topicID }
        })
        let choice = try XCTUnwrap(LearningCoverage.lessons(for: originalConcept, in: cached, history: [])
            .first { $0.lessonID == slot.lessonID })
        let context = ModelContext(container)
        let row = try XCTUnwrap(try context.fetch(FetchDescriptor<LessonDefinition>())
            .first { $0.id == slot.lessonID })
        row.conceptIDs = [replacement.id] // Slot remains unchanged; cached concept is now stale.
        try context.save()

        XCTAssertThrowsError(try repository.openConceptLesson(lessonID: choice.lessonID,
            expectedSlot: choice.slot, expectedConceptID: originalConcept, now: early)) {
            XCTAssertEqual($0 as? LessonExperienceError, .staleSlot)
        }
        XCTAssertEqual(try repository.loadSnapshot().slots.first { $0.key == slot.key }, slot)
        XCTAssertTrue(try ModelContext(container).fetch(FetchDescriptor<LessonAttempt>()).isEmpty)
        XCTAssertTrue(try ModelContext(container).fetch(FetchDescriptor<LessonProgress>()).isEmpty)

        let opened = try repository.openConceptLesson(lessonID: choice.lessonID, expectedSlot: choice.slot,
                                                       expectedConceptID: replacement.id, now: early)
        XCTAssertEqual(opened.detail.attempt?.lessonID, slot.lessonID)
        // Started work remains attached to the studied pin when the definition changes again.
        row.conceptIDs = [originalConcept]
        try context.save()
        let resumed = try repository.openConceptLesson(lessonID: choice.lessonID, expectedSlot: choice.slot,
                                                        expectedConceptID: replacement.id, now: late)
        XCTAssertEqual(resumed.detail.attempt?.id, opened.detail.attempt?.id)
        XCTAssertThrowsError(try repository.openConceptLesson(lessonID: choice.lessonID,
            expectedSlot: choice.slot, expectedConceptID: originalConcept, now: late)) {
            XCTAssertEqual($0 as? LessonExperienceError, .staleSlot)
        }
    }

    func testCompletedReferencesUseArchivedConceptIDsAndStableDateOrdering() throws {
        let archived = LessonTerminalMetadata(lessonID: "old", provenance: .legacyCompletedPartial,
            title: "Archived", topicID: nil, subtopicID: nil, contentVersion: 1,
            objectiveKey: "objective", conceptIDs: ["a"], normalizedContentHash: nil,
            format: nil, dismissalTimeDefinition: nil)
        let entries = [
            LessonHistorySnapshot(lessonID: "old", status: .completed, date: late,
                title: "Archived", topicID: nil, metadata: archived, content: .unavailable, attempt: nil),
            LessonHistorySnapshot(lessonID: "other", status: .completed, date: early,
                title: "Other", topicID: nil, content: .unavailable, attempt: nil),
            LessonHistorySnapshot(lessonID: "dismissed", status: .dismissed, date: late,
                title: "Dismissed", topicID: nil, metadata: archived, content: .unavailable, attempt: nil)
        ]
        XCTAssertEqual(LearningCoverage.completedReferences(for: "a", in: entries).map(\.lessonID), ["old"])
        XCTAssertTrue(LearningCoverage.completedReferences(for: "b", in: entries).isEmpty)
    }

    func testInconsistentCurrentTaxonomyFailsRatherThanProducingFalseZero() {
        XCTAssertThrowsError(try coverage(membership(["missing"]))) { error in
            XCTAssertEqual(error as? LearningEvidenceError, .invalidPayload)
        }
    }
}
