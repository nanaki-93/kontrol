import Foundation

/// Transient, detached inputs. The bookmark is an opaque grant, never an unscoped URL.
/// Neither requests nor receipts are SwiftData entities or persisted feature history.
struct FeatureCompletionRequest {
    let reference: ProjectReferenceSnapshot
    let featureID: String
    let source: ProjectSourceDocument // Exact inspected bytes, path and digest.
    let completedAt: Date
}

/// Byte edits are relative to the completed revision, in UTF-8 offsets. `originalBytes`
/// includes lexical quoting and whitespace; an inserted field has an empty original slice.
struct FeatureInverseEdit: Equatable {
    let completedRange: Range<Int>
    let originalBytes: Data
}

struct FeatureInversePatch: Equatable {
    let relativePath: String
    let originalSHA256: String
    let completedSHA256: String
    let edits: [FeatureInverseEdit]
}

struct FeatureMutationReceipt {
    let projectID: UUID
    /// Opaque authorization used for this write. Unlike reference.revision, this stays
    /// unchanged across successful-read metadata updates; keep it session-local.
    let grantBookmarkData: Data
    let featureID: String
    /// Exact bytes reread from the destination after replacement, not the intended output.
    /// Session-local only; never persist the source or inverse patch in app storage.
    let verifiedSource: ProjectSourceDocument
    let inverse: FeatureInversePatch

    var relativePath: String { verifiedSource.relativePath }
    var verifiedSHA256: String { verifiedSource.sha256 }
}

struct FeatureUndoRequest {
    let reference: ProjectReferenceSnapshot
    let receipt: FeatureMutationReceipt
}

/// Only safe categories cross the IO boundary; no raw OS/parser messages or source text.
enum FeatureMutationFailure: Error, Equatable {
    case conflict, undoConflict, missingTarget, changedIdentity, unpatchableSource
    case accessDenied, manifestMismatch, unsafePath, writeFailed, unverifiedWrite
    case coordinationFailed, temporaryFileFailed, temporaryWriteFailed, diskFull, flushFailed
    case canceled
}
