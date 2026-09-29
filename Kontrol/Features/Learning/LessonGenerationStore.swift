import Foundation

/// One main-actor network lease shared by Settings and every Learning presentation.
/// An invalidated lease stays occupied until the transport returns, even when it
/// ignores cancellation. There is no persisted queue or relaunch restoration.
@MainActor
final class AIOperationGate {
    enum Kind { case generation, connection }
    struct Lease: Equatable {
        let id: UUID
        let owner: UUID
        let revision: UUID?
    }
    private struct Active {
        let lease: Lease
        let kind: Kind
        var cancelled: Bool
        var cancel: (() -> Void)?
    }
    private var active: Active?
    var isBusy: Bool { active != nil }

    func begin(kind: Kind, owner: UUID, revision: UUID?) -> Lease? {
        guard active == nil else { return nil }
        let lease = Lease(id: UUID(), owner: owner, revision: revision)
        active = Active(lease: lease, kind: kind, cancelled: false)
        return lease
    }

    func attach(_ lease: Lease, cancel: @escaping () -> Void) {
        guard active?.lease == lease else { cancel(); return }
        active?.cancel = cancel
        if active?.cancelled == true { cancel() }
    }

    func authorized(_ lease: Lease) -> Bool {
        active?.lease == lease && active?.cancelled == false
    }

    func owns(owner: UUID, kind: Kind) -> Bool {
        active?.lease.owner == owner && active?.kind == kind
    }

    func invalidate(owner: UUID? = nil) {
        guard let active, owner == nil || active.lease.owner == owner else { return }
        self.active?.cancelled = true
        active.cancel?()
    }

    func invalidate(_ lease: Lease) {
        guard active?.lease == lease else { return }
        active?.cancelled = true
        active?.cancel?()
    }

    func finish(_ lease: Lease) {
        if active?.lease == lease { active = nil }
    }
}

enum LessonGenerationStoreError: Error, Equatable {
    case operationInProgress
}

@MainActor
final class LessonGenerationStore: ObservableObject {
    enum State {
        case idle
        case generating(owner: UUID)
        case added(GeneratedLessonInsertionResult)
        case failed(LessonGenerationError)
    }
    @Published private(set) var state: State = .idle
    private let settings: AISettingsStore
    private let repository: any CatalogRepository
    private let learning: LearningCatalogStore
    private let generator: (String, String) -> any LessonGenerator
    private let objectives: (LessonGenerationContext) throws -> GenerationObjectives
    private let gate: AIOperationGate

    init(settings: AISettingsStore, repository: any CatalogRepository, learning: LearningCatalogStore,
         generator: @escaping (String, String) -> any LessonGenerator,
         objectives: @escaping (LessonGenerationContext) throws -> GenerationObjectives = {
             try GenerationObjectivesLoader.load(catalog: $0.catalog, membership: $0.membership)
         }) {
        self.settings = settings
        self.repository = repository
        self.learning = learning
        self.generator = generator
        self.objectives = objectives
        gate = settings.operationGate
    }

    /// The owner is the sheet/window identity, not the topic. Call this after a
    /// successful navigation away or on dismissal; never bypass draft guards.
    func cancel(owner: UUID) {
        gate.invalidate(owner: owner)
        if case .generating(let current) = state, current == owner { state = .idle }
    }

    func generate(selection: LessonGenerationSelection, owner: UUID) async throws -> GeneratedLessonInsertionResult {
        // Claim before any suspension. Reject busy actions rather than queue them.
        guard let lease = gate.begin(kind: .generation, owner: owner,
                                     revision: settings.presentation.revision) else {
            throw LessonGenerationStoreError.operationInProgress
        }
        defer { gate.finish(lease) }
        do {
            let configuration = try settings.generationConfiguration()
            try authorize(lease, revision: configuration.revision)
            guard let model = configuration.modelID, let reference = configuration.credentialReference else {
                throw LessonGenerationError.unconfigured
            }
            let context = try repository.generationContext(topicID: selection.topicID)
            let registry = try objectives(context)
            let request = try LessonGenerationRequestBuilder.make(selection: selection,
                operationID: lease.id, context: context, registry: registry)
            try authorize(lease, revision: configuration.revision)
            state = .generating(owner: owner)
            let work = Task { try await generator(model, reference).generate(request) }
            gate.attach(lease) { work.cancel() }
            let candidate = try await withTaskCancellationHandler {
                try await work.value
            } onCancel: {
                Task { @MainActor in gate.invalidate(lease) }
            }
            // No await between the last authorization and synchronous commit.
            try authorize(lease, revision: configuration.revision)
            let fresh = try repository.generationContext(topicID: selection.topicID)
            let validated = try GeneratedLessonValidator.validate(candidate, request: request,
                context: fresh, registry: registry, requestedModel: model, now: Date())
            try authorize(lease, revision: configuration.revision)
            let receipt = try learning.acceptGeneratedLesson(validated)
            state = .added(receipt)
            return receipt
        } catch {
            // A revoked lease is cancellation. An otherwise live lease must keep
            // actionable failures from the latest settings/Keychain read, even if
            // the transport returned an unrelated error at the same time.
            let failure: LessonGenerationError
            if !gate.authorized(lease) || Task.isCancelled {
                failure = .cancelled
            } else {
                do {
                    try authorize(lease, revision: lease.revision)
                    failure = Self.classify(error)
                } catch {
                    failure = Self.classify(error)
                }
            }
            // Only this operation can still own the state until its lease releases.
            if case .generating(let current) = state {
                if current == owner { state = failure == .cancelled ? .idle : .failed(failure) }
            } else {
                state = failure == .cancelled ? .idle : .failed(failure)
            }
            throw failure
        }
    }

    private func authorize(_ lease: AIOperationGate.Lease, revision: UUID?) throws {
        guard gate.authorized(lease), !Task.isCancelled else { throw LessonGenerationError.cancelled }
        let current = try settings.generationConfiguration()
        guard current.revision == revision, lease.revision == revision else {
            throw LessonGenerationError.cancelled
        }
    }

    private static func classify(_ error: Error) -> LessonGenerationError {
        if let failure = error as? LessonGenerationError { return failure }
        if error is CancellationError || (error as? URLError)?.code == .cancelled { return .cancelled }
        if let failure = error as? GenerationObjectivesError {
            return failure == .missing ? .unavailableObjectives : .corruptObjectives
        }
        if error is GenerationContextError { return .invalidScope }
        if let failure = error as? AISettingsStoreError {
            switch failure {
            case .missingCredential: return .missingCredential
            case .inaccessibleCredential, .credentialFailure: return .inaccessibleCredential
            case .storageFailure: return .persistenceFailure
            case .staleRevision: return .cancelled
            default: return .disabled
            }
        }
        return .persistenceFailure
    }
}
