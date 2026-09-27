# Architecture and behavioral contracts

[Plan](../PLAN.md) · [Function / mockup index](mockups/INDEX.md)

## Application boundaries

One SwiftUI macOS app, one SwiftData store, one personal user, no app account or backend. The deployment baseline is macOS 14; verify availability before using newer APIs. Use the approved horizontal icon navigation. Learning and Projects can use split views inside their destination. Keep UI state on the main actor and parsing/networking off it.

| Boundary | Responsibility | Failure surface |
| --- | --- | --- |
| ModelContainerFactory | Open/version local app store | [M01](mockups/M01-store-recovery.png) |
| TaskRepository / ScheduleRepository | Local durable task/block changes | [M03](mockups/M03-task-editor.png), [M07](mockups/M07-schedule-editor.png) |
| FocusService | One active timer and historical sessions | [M13](mockups/M13-focus-recovery.png) |
| CatalogRepository / LessonSelector | Definitions, history, persistent slots | [M15](mockups/M15-learning-choices.png), [M21](mockups/M21-lesson-completion-rotation.png) |
| LessonGenerator | Optional remote candidate content | [M26](mockups/M26-generation-failure.png) |
| ProjectFolderAccess / ManifestParser | User-selected folder and validated file snapshots | [M33](mockups/M33-project-validation-access.png) |
| FeatureSelector / FeatureFileWriter | Local candidate ordering and one-file completion | [M32](mockups/M32-project-write-conflict.png) |
| FeedService | Fetch, parse, merge, trim metadata cache | [M37](mockups/M37-news-offline.png) |
| ExportService / CredentialStore | Versioned export and Keychain-backed provider credential | [M40](mockups/M40-data-export.png), [M39](mockups/M39-ai-settings.png) |

Use protocols only at IO boundaries. Domain selectors and validators are plain Swift value types. No microservices, plugin framework, custom event bus or generic Candidate superclass is required. Learning and project state machines share small UI components, not one forced domain model.

## Source of truth

- SwiftData: personal tasks, schedule, lesson definitions and progress, attempts, slots, focus sessions, feed preferences/cache and project bookmark references.
- `.kontrol`: project metadata, roadmap, feature descriptions, dependencies, priority and completion. Re-read files before mutations. A cache is disposable and never independently editable.
- Keychain: provider credentials. Preferences contain a credential reference, never the secret.
- App resources: versioned seed curriculum and default feed catalog. Validate default feed URLs during implementation; example URLs in mockups are placeholders, not production feeds.

## Local models

| Model | Required fields and invariants |
| --- | --- |
| TaskItem | id UUID; title nonempty after trim; notes optional; dueAt optional UTC instant; plannedDay optional local date plus timeZoneID; createdAt; completedAt optional. Completion derives from completedAt. |
| ScheduleBlock | id; title; startAt/endAt UTC instants; end > start; optional note; optional lessonID; linkedTitleSnapshot. Deleting a lesson never deletes a block. |
| FocusSession | id; state; plannedSeconds; accumulatedActiveSeconds; activeSegmentStartedAt; deadline; pausedAt; startedAt/endedAt; linkedTaskID or linkedLessonID optional; linkedTitleSnapshot. At most one running/paused session. |
| Topic / Subtopic / Concept | stable string ids; parent ids; display names; prerequisite concept ids. Cycles are invalid. |
| LessonDefinition | stable id; objectiveKey; title; topic/subtopic; conceptIDs; difficulty; format; estimate; prerequisites; structured sections; contentVersion; normalized hash; source/provenance. |
| LessonProgress | unique lessonID; status; firstShownAt; startedAt; completedAt; dismissedAt; lastOpenedAt. Dismissal and completion remain distinct. |
| LessonAttempt | id; lessonID; contentVersion; immutable content snapshot once completed; answer draft; solutionRevealedAt; selfCheckAcknowledgedAt; completedAt. Reading history does not create a new completion. |
| LessonSlot | topicID; index 0...3; lessonID; assignedAt. Unique topic/index and one slot per lesson. |
| ProjectReference | local UUID; project manifest id; bookmarkData; display order; lastSuccessfulReadAt; optional last-good cache digest. Filesystem URL is resolved through the bookmark. |
| FeedSource | id; name; URL; topicIDs; enabled; etag; lastModified; lastAttemptAt; lastSuccessAt; lastError. |
| ArticleMetadata | id; sourceIDs; canonicalURL; title; publishedAt optional; fetchedAt; plainTextSummary optional; topicIDs. |
| AppPreferences | schemaVersion; focus default; reducedMotion; text scale; enabled news topics; AI enabled; provider/model; Keychain item reference. |

Use migrations from the beginning. Do not delete user data when an automatic migration fails. Test upgrades against an earlier fixture store; use in-memory stores for isolated repository tests.

## Task and schedule semantics

Today shows open tasks explicitly planned for the selected date plus due/overdue tasks for that date. Completed items can be revealed separately. A due time is not the same thing as a scheduled block. Editing a block never changes a task's due date. Add to Today on a lesson opens the same block editor and saves only after a valid time range is chosen.

Use the device calendar/time zone for display. Persist actual block instants, and persist task planned-day components with the zone used when choosing them. When the device zone changes, show scheduled blocks at the equivalent local time; preserve the user's selected planned task date. Detect overlap with half-open intervals. A touching boundary is not an overlap. A confirmed overlap stays visible as two blocks.

## Focus semantics

Ready → running → paused → running; either active state may end. Reaching zero completes once. During a process lifetime, use a monotonic source for elapsed active time. Persist transitions and periodic checkpoints. Paused time is excluded. A running deadline continues while the app is closed or asleep, capped at the planned duration. On relaunch reconcile once and show the recovery state when user input is needed. A backward wall-clock change must not produce negative time; clamp and offer recovery. Session completion never checks off a task or a lesson.

## Lesson slots and replacement

1. Load persisted slots; keep started lessons in their existing slots.
2. Fill only empty/invalid slots. Filter to the selected topic, supported format, valid prerequisites, and not completed/dismissed/already slotted.
3. Reject stable-ID and exact normalized-content matches.
4. For near-duplicates, normalize objectiveKey and sorted concept IDs. If the same objectiveKey AND concept Jaccard overlap >= 0.8, suppress the candidate. Jaccard = intersection size / union size. Empty concept sets are invalid.
5. This is metadata-based duplicate control, not guaranteed semantic understanding. Generated candidates must reuse canonical objective/concept IDs. Different explicit objectives on the same concept are allowed when the content is distinct.
6. Rank remaining items by fewest practiced concepts in the subtopic, a format not recently offered, supported difficulty, then stable id. Persist assignments; do not reshuffle on every launch.
7. Completion is one transaction: finalize attempt snapshot, mark progress completed, free its slot, select a replacement, save. A failed save leaves the old slot/progress coherent.
8. If the eligible pool is exhausted, display fewer than four and offer explicit generation. Never repeat a completed item to reach four.

Dismissal sets dismissedAt and suppresses the lesson until explicit Restore in History. Restore makes it eligible but does not evict a started slot. Completed lessons can be opened for reference; formal review scheduling is V2.

Coverage counts distinct practiced concept IDs in completed lessons against the current versioned topic catalog. Label it as coverage and show numerator/denominator. It is not a mastery estimate.

## AI boundary

Use a first OpenAI provider adapter behind `generate(request) -> CandidateLesson`. Verify current official API documentation during implementation rather than embedding potentially stale endpoint/model assumptions in this plan. Settings explicitly choose an available model. Keys are user-provided and saved only in Keychain.

Requests contain the selected topic, concept/objective IDs, level and format plus a compact relevant exclusion list. Do not include local project files, task notes or personal answers. Treat output as data: validate schema, safe plain text/Markdown, known IDs, section length and dedup rules before storing. No generated commands execute. Cancellation, timeout, invalid JSON, unknown concepts and duplicate results leave existing slots intact. At most one schema-repair retry; repeated duplicate failures require a new explicit action.

## Project file contract

See the valid sample in [examples/.kontrol](../examples/.kontrol/project.yaml). Project id and feature ids must be stable; folder identity is maintained through the local bookmark. Use `schema_version: 1` at project/roadmap level. Feature file states: planned, ready, active, blocked, completed. The app only offers completion/undo; other states are edited in source files.

Eligible = ready + valid + every dependency completed. Sort current-focus area match first, then priority, effort and stable id. Unknown/missing dependency, duplicate id and dependency cycle prevent the affected item from being eligible. A invalid manifest blocks the project's cards. Valid records with invalid peer files can still be inspected, but excluded files must be indicated in counts.

Completion writes only top-level `status` and `completed_at` in one feature file. Preserve comments, unknown fields, line endings and Markdown body. Parse with Yams, patch source ranges, validate new text, write a sibling temp, atomically replace, reread. Compare source digests within coordinated access. If an uncoordinated external writer still races with the operation, verification must flag a mismatch; coordination is not a promise to lock every third-party editor. Retain an undo payload only for the exact post-write revision. Undo must also check the digest. Never overwrite conflicting edits.

Do not traverse symlinks outside the authorized root. Reconnect stale folder grants through a system picker. Removing a project disconnects its reference only. `history.yaml`, if present, is read-only in V1 and does not override feature status.

## News and export

Feed item summaries are plain text and collapsed by default. Fetch limits: 2 MB/response, 15 second timeout, four concurrent feeds, 30-minute foreground refresh interval; manual refresh still respects server retry hints. Cache max 500 items / 30 days. Keep missing publication dates missing. Deduplicate by a reliable feed-scoped GUID then cross-feed canonical URL; do not strip arbitrary query parameters. Disable XML external-entity resolution. Permit only web links to source pages.

The export is versioned JSON. Include personal data and cached accepted lesson definitions; exclude credentials, bookmark blobs and external project contents. Export is not an import/restore feature. A canceled or failed save produces no success confirmation. Cached article content can be omitted; include preferences so the user can reconnect feeds later.
