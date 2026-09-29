import Foundation

/// UI publication contains configuration metadata only, never credential bytes.
enum AICredentialStatus: Equatable {
    case notConfigured
    case available
    case missing
    case inaccessible
}

enum AISettingsStoreError: Error, Equatable {
    case staleRevision
    case invalidConfiguration
    case missingCredential
    case inaccessibleCredential
    case storageFailure
    case credentialFailure
    case stagedCleanupFailed
    case removalFailed
    case removalFinalizationFailed
    case connectionInProgress
}

/// What a view may observe: never an opaque Keychain reference or credential bytes.
struct AISettingsPresentation: Equatable {
    let enabled: Bool
    let providerID: String
    let modelID: String?
    let hasCredential: Bool
    let revision: UUID?

    init(_ snapshot: AISettingsSnapshot, authorized: Bool = true) {
        enabled = snapshot.enabled && authorized
        providerID = snapshot.providerID
        modelID = snapshot.modelID
        hasCredential = snapshot.credentialReference != nil
        revision = snapshot.revision
    }
}

/// A successful metadata lookup establishes authentication and model visibility only.
/// It does not promise inference access or produce a lesson.
enum AIConnectionStatus: Equatable {
    case notTested
    case testing
    case modelAvailable
    case failed(LessonGenerationError)
}

@MainActor
final class AISettingsStore: ObservableObject {
    @Published private(set) var presentation = AISettingsPresentation(.disabled)
    @Published private(set) var credentialStatus: AICredentialStatus = .notConfigured
    private var settings: AISettingsSnapshot = .disabled {
        didSet { presentation = AISettingsPresentation(settings, authorized: !suspended) }
    }
    private var suspended = false {
        didSet { presentation = AISettingsPresentation(settings, authorized: !suspended) }
    }
    @Published private(set) var error: AISettingsStoreError?
    @Published private(set) var connectionStatus: AIConnectionStatus = .notTested
    let operationGate = AIOperationGate()
    private let connectionTester: (String, String) -> any OpenAIConnectionTesting

    private let repository: any AISettingsRepository
    private let credentials: any CredentialStore
    // Connected to the app-wide operation gate in Step 3.4. Must run synchronously
    // before any configuration mutation or Keychain deletion.
    var invalidateOperations: () -> Void = {}
    private var pendingCleanup: Set<String> = []

    init(repository: any AISettingsRepository, credentials: any CredentialStore,
         connectionTester: ((String, String) -> any OpenAIConnectionTesting)? = nil) {
        self.repository = repository
        self.credentials = credentials
        self.connectionTester = connectionTester ?? { model, reference in
            OpenAILessonGenerator(model: model, credentialReference: reference, credentials: credentials)
        }
        refresh()
    }

    /// Called only by an explicit Test connection action; never by refresh/save/enable.
    /// No settings or learning records are written. A revision change discards the
    /// result, including a late failure from a transport that ignores cancellation.
    func cancelConnection(owner: UUID) {
        guard operationGate.owns(owner: owner, kind: .connection) else { return }
        operationGate.invalidate(owner: owner)
        connectionStatus = .notTested
    }

    func testConnection(owner: UUID = UUID()) async throws {
        guard !operationGate.isBusy else { throw AISettingsStoreError.connectionInProgress }
        let current = try authoritative(expectedRevision: settings.revision)
        guard !suspended, current.providerID == "openai",
              let model = current.modelID, OpenAILessonGenerator.supportedModels.contains(model),
              let reference = current.credentialReference else { throw AISettingsStoreError.invalidConfiguration }
        try requireReadable(reference)
        guard let lease = operationGate.begin(kind: .connection, owner: owner, revision: current.revision) else {
            throw AISettingsStoreError.connectionInProgress
        }
        defer { operationGate.finish(lease) }
        connectionStatus = .testing
        let outcome: AIConnectionStatus
        do {
            let work = Task { try await connectionTester(model, reference).testConnection() }
            operationGate.attach(lease) { work.cancel() }
            try await withTaskCancellationHandler {
                try await work.value
            } onCancel: {
                Task { @MainActor in operationGate.invalidate(lease) }
            }
            outcome = .modelAvailable
        } catch let failure as LessonGenerationError {
            outcome = .failed(failure)
        } catch is CancellationError {
            outcome = .failed(.cancelled)
        } catch let failure as URLError where failure.code == .cancelled {
            outcome = .failed(.cancelled)
        } catch {
            outcome = .failed(.providerFailure)
        }
        guard operationGate.authorized(lease) else {
            connectionStatus = .notTested
            throw LessonGenerationError.cancelled
        }
        if Task.isCancelled || outcome == .failed(.cancelled) {
            connectionStatus = .notTested
            throw LessonGenerationError.cancelled
        }
        let latest: AISettingsSnapshot
        do { latest = try repository.load() }
        catch {
            connectionStatus = .notTested
            suspended = true
            self.error = .storageFailure
            throw AISettingsStoreError.storageFailure
        }
        guard latest.revision == current.revision, settings.revision == current.revision,
              !suspended else {
            connectionStatus = .notTested
            throw AISettingsStoreError.staleRevision
        }
        // Metadata success (or failure) is stale if the key disappeared or became
        // unreadable during the request. Do not publish a transport result until
        // local authorization is rechecked without another suspension.
        do { try requireReadable(latest.credentialReference) }
        catch {
            connectionStatus = .notTested
            self.error = error as? AISettingsStoreError ?? .credentialFailure
            throw error
        }
        connectionStatus = outcome
        if case .failed(let failure) = outcome { throw failure }
    }

    private func resetConnection() {
        operationGate.invalidate()
        connectionStatus = .notTested
    }

    func refresh() {
        resetConnection()
        do {
            settings = try repository.load()
            credentialStatus = Self.status(for: settings.credentialReference, in: credentials)
            error = nil
        } catch {
            // Never publish a previously enabled configuration after a failed read.
            settings = .disabled
            credentialStatus = .notConfigured
            self.error = .storageFailure
            suspended = true
        }
    }

    /// A detached, nonsecret authorization token for later request orchestration.
    /// Reading the key here verifies local access but never publishes or returns it.
    func generationConfiguration() throws -> AISettingsSnapshot {
        let current = try authoritative(expectedRevision: settings.revision)
        guard !suspended, current.enabled else { throw AISettingsStoreError.invalidConfiguration }
        try requireReadable(current.credentialReference)
        return current
    }

    func saveConfiguration(providerID: String = "openai", modelID: String,
                           credential: Data? = nil, expectedRevision: UUID?) throws {
        let current = try authoritative(expectedRevision: expectedRevision)
        let reference = credential == nil ? current.credentialReference : UUID().uuidString
        // Configuration edits never authorize generation; Enable is always explicit.
        let proposal = AISettingsSnapshot(enabled: false,
                                          providerID: providerID, modelID: modelID,
                                          credentialReference: reference, revision: current.revision)
        do { try proposal.validate() } catch { throw AISettingsStoreError.invalidConfiguration }

        var staged = false
        if let credential {
            do { try credentials.save(credential, reference: reference!) }
            catch { throw Self.credentialError(error) }
            staged = true
        }
        do {
            let saved = try repository.save(proposal, expectedRevision: current.revision)
            // No suspension occurs between commit and cancellation/publication.
            invalidateOperations()
            resetConnection()
            settings = saved
            credentialStatus = Self.status(for: saved.credentialReference, in: credentials)
            suspended = false
            error = nil
        } catch {
            if staged {
                do { try credentials.remove(reference: reference!) }
                catch {
                    pendingCleanup.insert(reference!)
                    self.error = .stagedCleanupFailed
                    throw AISettingsStoreError.stagedCleanupFailed
                }
            }
            self.error = Self.persistenceError(error)
            throw self.error!
        }
        // The old key is no longer authorized. Keep nonsecret retry information if
        // Keychain is temporarily locked; never roll back committed settings.
        if staged, let old = current.credentialReference, old != reference {
            do { try credentials.remove(reference: old) }
            catch { pendingCleanup.insert(old); self.error = .credentialFailure }
        }
    }

    func enable(expectedRevision: UUID?) throws {
        let current = try authoritative(expectedRevision: expectedRevision)
        guard current.modelID != nil, current.credentialReference != nil else {
            throw AISettingsStoreError.invalidConfiguration
        }
        try requireReadable(current.credentialReference)
        let proposal = AISettingsSnapshot(enabled: true, providerID: current.providerID,
                                          modelID: current.modelID, credentialReference: current.credentialReference,
                                          revision: current.revision)
        try persist(proposal)
        suspended = false
    }

    func disable(expectedRevision: UUID?) throws {
        let current = try authoritative(expectedRevision: expectedRevision)
        suspended = true
        resetConnection()
        invalidateOperations()
        let proposal = AISettingsSnapshot(enabled: false, providerID: current.providerID,
                                          modelID: current.modelID, credentialReference: current.credentialReference,
                                          revision: current.revision)
        try persist(proposal)
    }

    func removeKey(expectedRevision: UUID?) throws {
        let current = try authoritative(expectedRevision: expectedRevision)
        suspended = true
        resetConnection()
        invalidateOperations()
        // Do not delete until the disabled state has committed. A failed delete
        // retains the reference in that disabled record for a later explicit retry.
        let disabled = AISettingsSnapshot(enabled: false, providerID: current.providerID,
                                          modelID: current.modelID, credentialReference: current.credentialReference,
                                          revision: current.revision)
        try persist(disabled)
        if let reference = disabled.credentialReference {
            do { try credentials.remove(reference: reference) }
            catch CredentialStoreError.missing { /* Already deleted on a prior attempt. */ }
            catch {
                self.error = .removalFailed
                throw AISettingsStoreError.removalFailed
            }
        }
        let cleared = AISettingsSnapshot(enabled: false, providerID: settings.providerID,
                                         modelID: settings.modelID, credentialReference: nil,
                                         revision: settings.revision)
        do { try persist(cleared) }
        catch {
            self.error = .removalFinalizationFailed
            throw AISettingsStoreError.removalFinalizationFailed
        }
    }

    /// Explicit retry for orphaned staged/replaced items in the current process.
    /// Removal's active reference uses removeKey instead and survives relaunch.
    func retryCleanup() throws {
        for reference in pendingCleanup.sorted() {
            do { try credentials.remove(reference: reference) }
            catch CredentialStoreError.missing { /* Idempotent cleanup. */ }
            catch { self.error = .credentialFailure; throw AISettingsStoreError.credentialFailure }
            pendingCleanup.remove(reference)
        }
        error = nil
    }

    private func authoritative(expectedRevision: UUID?) throws -> AISettingsSnapshot {
        let current: AISettingsSnapshot
        do { current = try repository.load() }
        catch { suspended = true; self.error = .storageFailure; throw AISettingsStoreError.storageFailure }
        guard current.revision == expectedRevision, settings.revision == expectedRevision else {
            error = .staleRevision
            throw AISettingsStoreError.staleRevision
        }
        return current
    }

    private func persist(_ proposal: AISettingsSnapshot) throws {
        do {
            settings = try repository.save(proposal, expectedRevision: proposal.revision)
            credentialStatus = Self.status(for: settings.credentialReference, in: credentials)
            resetConnection()
            error = nil
        } catch {
            let mapped = Self.persistenceError(error)
            self.error = mapped
            throw mapped
        }
    }

    private func requireReadable(_ reference: String?) throws {
        guard let reference else { credentialStatus = .notConfigured; throw AISettingsStoreError.missingCredential }
        do { _ = try credentials.read(reference: reference); credentialStatus = .available }
        catch {
            let mapped = Self.credentialError(error)
            credentialStatus = mapped == .missingCredential ? .missing : .inaccessible
            throw mapped
        }
    }

    private static func status(for reference: String?, in credentials: any CredentialStore) -> AICredentialStatus {
        guard let reference else { return .notConfigured }
        do { _ = try credentials.read(reference: reference); return .available }
        catch CredentialStoreError.missing { return .missing }
        catch { return .inaccessible }
    }

    private static func credentialError(_ error: Error) -> AISettingsStoreError {
        if case CredentialStoreError.missing = error { return .missingCredential }
        if case CredentialStoreError.inaccessible = error { return .inaccessibleCredential }
        return .credentialFailure
    }

    private static func persistenceError(_ error: Error) -> AISettingsStoreError {
        if case AISettingsPersistenceError.staleRevision = error { return .staleRevision }
        return .storageFailure
    }
}
