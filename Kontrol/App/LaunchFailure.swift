/// Only the stage is exposed to recovery presentation. Never carry a raw error
/// into UI state: its description or underlying error may contain a store path
/// or catalog/user content.
enum LaunchFailure: Equatable {
    case store
    case catalog
}
