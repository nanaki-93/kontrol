# Local data export — schema version 1

`LocalDataExport` in `Kontrol/Domain/LocalDataExport.swift` defines a detached,
plain JSON serialization contract. `Kontrol/Data/Export/DailyDataExportProjection.swift`
now maps supplied persisted tasks, blocks, Focus sessions, and effective configuration.
Learning projection, coherent capture, destination selection, and delivery remain
separate implementation tasks. No import/restore is provided. This is **not an encrypted
backup**; the JSON contains personal authored content and saved answers.

## Common rules

- Every field listed below is required as a JSON key. There are no implicit decode
  defaults, even for empty arrays or nullable fields. `T?` means `T` or explicit
  JSON `null`, never an omitted key. `ExportNull` enforces this for nested values.
- Strings retain exact UTF-8 authored content (including whitespace, newlines,
  decomposed Unicode, and secret-looking text). Nonblank validation does not trim
  or rewrite the value. Privacy is a structural allowlist, not string redaction.
- **ID** means a nonblank string with no surrounding whitespace, already in NFC.
  ID comparisons are case-sensitive. **UUID** means a UUID string; output uses
  Foundation's uppercase, hyphenated canonical representation.
- **Instant** means `YYYY-MM-DDTHH:mm:ss.SSSZ`, UTC, proleptic Gregorian years 0001–9999 (no pre-1582 Julian switch).
  Capture rounds finite absolute `Date` values to the nearest millisecond (ties
  away from zero relative to the Unix epoch). Values that round outside the range
  fail. Decode requires exactly three fractional digits and `Z`, rejects invalid
  calendar dates, leap seconds, offsets, missing fractions, and normalization.
  Subsequent encode/decode preserves the canonical string exactly. No local
  timezone is inferred for an absolute instant.
- Numbers are JSON integers unless marked `number`; integer fields must fit the
  Swift `Int` range. All floating-point numbers must be finite. Booleans are JSON
  `true`/`false`, never numeric flags.
- Top-level record arrays sort by their identity below, ascending. UUID sorting
  uses the canonical UUID string. String sorting uses Swift's locale-independent
  lexicographic comparison. Set-like ID arrays sort ascending and reject duplicate
  identities rather than deduplicating. Property keys sort lexicographically in
  `encoded()`; formatting is pretty-printed with unescaped slashes, no required
  trailing newline. Timestamps, IDs, and `appVersion` must be held constant for
  deterministic byte comparison.
- Teaching sections retain their named positions: explanation → workedExample →
  exercise → referenceAnswer. `selfCheckCriteria` is an **ordered sequence**, not
  a set: its order and repeated authored text are preserved. No content is sorted,
  normalized, or redacted.
- Unsupported schema/envelope versions, duplicate identities, malformed dates,
  invalid values, and internal identity mismatches fail the **whole** export.
  Error categories never carry authored text, IDs, paths, or raw diagnostics.
  The root's `encode(to:)` and `init(from:)` both validate all nested records.
  A standalone nested DTO's synthesized Codable is not an independent validation
  boundary. Standard Codable ignores unknown input keys; they are never retained
  or re-emitted. Export is not a general-purpose ingestion API.
- Scalar historical links may point to records no longer present. The contract
  does not require current definitions/tasks/taxonomy to exist for historical
  evidence and does not perform foreign-key reconstruction. Internal embedded
  identity/version matches **are** required. Persisted projection tasks will add
  storage-specific validation using the existing payload boundaries.

## Required envelope

| Field | Type | Validation/default for constructing an empty value |
| --- | --- | --- |
| schemaVersion | integer | Exactly `1`; construction defaults to 1, decode requires it. |
| exportedAt | Instant | Capture time supplied by the caller; no clock lookup. |
| appVersion | string | Nonblank bundle marketing version, supplied by caller; no hardcoded production value. |
| tasks | Task[] | Required, default `[]`; identity `id`. |
| blocks | Block[] | Required, default `[]`; identity `id`. |
| learning | Learning | Required object; nine arrays below, all default `[]`. |
| sessions | Session[] | Required, default `[]`; identity `id`. |
| feedPreferences | FeedPreferences | Required object; detached construction defaults to empty selections/feeds. |
| generalPreferences | GeneralPreferences | Required object; detached construction defaults described below. |

The empty structural example is not seed data or a promise that a new store's
*effective* News configuration is empty:

```json
{
  "schemaVersion": 1,
  "exportedAt": "2026-09-30T00:00:00.000Z",
  "appVersion": "1.0",
  "tasks": [],
  "blocks": [],
  "learning": {
    "topics": [],
    "subtopics": [],
    "concepts": [],
    "definitions": [],
    "progress": [],
    "attempts": [],
    "slots": [],
    "terminalRecords": [],
    "catalogMembership": []
  },
  "sessions": [],
  "feedPreferences": { "selectedTopicIDs": [], "feeds": [] },
  "generalPreferences": {
    "schemaVersion": 1,
    "focusDefaultMinutes": 25,
    "textSize": "system",
    "reduceMotion": "system",
    "ai": { "enabled": false, "providerID": "openai", "modelID": null }
  }
}
```

## Daily records

### Task

| Field | Type | Meaning/validation |
| --- | --- | --- |
| id | UUID | Stable task identity; unique in tasks. |
| title | string | Exact persisted nonblank title. |
| notes | string? | Exact notes; null when absent; empty string remains empty. |
| dueAt | Instant? | Absolute due time or null. |
| plannedDay | PlannedDay? | Chosen calendar date with original zone, or null. |
| createdAt | Instant | Persisted creation time. |
| completedAt | Instant? | Persisted completion time or null. |

`PlannedDay` has **calendarIdentifier** (string), **year**, **month**, **day**
(integers >0), and **timeZoneID** (string, recognized Foundation zone ID).
`calendarIdentifier` must be one of `gregorian`, `buddhist`, `chinese`, `coptic`,
`ethiopicAmeteMihret`, `ethiopicAmeteAlem`, `hebrew`, `iso8601`, `indian`, `islamic`,
`islamicCivil`, `japanese`, `persian`, `republicOfChina`, `islamicTabular`,
`islamicUmmAlQura`. Components must round-trip in that calendar/zone without
normalization. This object is **not** a UTC midnight. The Daily projection rejects
one-sided stored components/zone absence rather than inventing the missing half.

### Block

| Field | Type | Meaning/validation |
| --- | --- | --- |
| id | UUID | Unique block identity. |
| title | string | Exact nonblank persisted title. |
| startAt, endAt | Instant | Absolute bounds; startAt < endAt at exported precision. |
| note | string? | Exact persisted note or null. |
| lessonID | ID? | Scalar lesson link or null; may outlive the definition. |
| linkedTitleSnapshot | string? | Exact saved linked title or null; never fetched from current content. |

### Session

| Field | Type | Meaning/validation |
| --- | --- | --- |
| id | UUID | Unique persisted Focus identity. |
| state | string | `running`, `paused`, `completed`, or `ended`; never ephemeral `ready`. |
| plannedSeconds | integer | >0, original persisted duration. |
| accumulatedActiveSeconds | number | Finite, ≥0; exact persisted checkpoint value, no timer advancement. |
| activeSegmentStartedAt, deadline, pausedAt | Instant? | Exact persisted optional timing fields or null. |
| startedAt | Instant | Persisted start. |
| endedAt | Instant? | Persisted termination or null. |
| checkpointAt | Instant | Persisted checkpoint time. |
| recoveryRequired | boolean | Persisted interruption/recovery flag; export does not recover. |
| linkedTaskID | UUID? | Task link or null. |
| linkedLessonID | ID? | Lesson link or null; task and lesson links cannot both be present. |
| linkedTitleSnapshot | string? | Exact historical title or null. |

All persisted states, including active/interrupted sessions, are representable.
This format is a record of stored state, not a synthesized live timer estimate.

### Persisted Daily projection

`DailyDataExportProjection.project(tasks:blocks:sessions:into:)` runs synchronously
on the main actor. It accepts already-fetched rows plus an envelope, replaces only
its three Daily collections, validates the resulting envelope, and returns
canonicalized detached values. Other envelope content remains unchanged except
for contract sorting. Fetching/coherent committed capture belongs to the caller
(the export repository will be implemented separately); this mapper does not
read unsaved editors or claim an arbitrary supplied context is committed.

- Every task field maps directly, with stored `plannedDay` components and
  `plannedTimeZoneID` combined only when both exist. Titles and notes are not
  passed through draft/constructor normalization. Nil legacy fields remain null;
  empty notes remain empty. Recognized non-Gregorian calendars are retained.
- Every block field maps directly. Invalid bounds, including bounds collapsed by
  millisecond rounding, fail. Missing historical lesson rows do not invalidate
  scalar links, and an unlinked retained title snapshot is not removed.
- Every Focus field maps directly, with all dates converted (including optional
  fields that would be incompatible with the stored state). The pure
  `FocusSessionSnapshot` validator checks original-precision state consistency:
  elapsed is finite and in `[0, plannedSeconds]`; checkpoint is not before start;
  task/lesson links are mutually exclusive; present linked titles are nonblank.
  Running requires an active anchor, matching remaining-duration deadline
  (within the existing <1 ms tolerance), checkpoint ≥ anchor, elapsed < duration,
  no paused/end timestamp or recovery flag. A rollback anchor may predate start.
  Paused requires a paused timestamp between start and checkpoint, elapsed <
  duration, no anchor/deadline/end; either recovery flag is valid. Terminal states
  require an end between start and checkpoint, no anchor/deadline/pause/recovery;
  completed elapsed equals duration, ended elapsed is less. Unknown states and
  multiple active rows fail rather than authorizing automatic recovery.
- The shared contract checks duplicate IDs, nonblank titles, planned calendar/
  zone validity, canonical lesson IDs, and timestamp range. Any included damaged
  row fails the entire projection; no row is filtered, repaired, deduplicated,
  or replaced with a current linked title. Identity namespaces are independent.
- No context save, task/progress completion, timer estimate/transition/recovery,
  clock sample, feature loading, external folder access, or other IO occurs.
  Later row edits cannot alter the returned values. The projected envelope still
  passes root encoding/decoding validation; millisecond timestamp quantization
  follows the common rules above.

## Configuration

`FeedPreferences`: **selectedTopicIDs** (ID[], set, default empty in detached
construction) and **feeds** (Feed[], unique `id`, default empty).

`Feed`: **id** (UUID), **name** (nonblank string), **endpoint** (nonblank string,
exact configured endpoint), **topicIDs** (ID[], set), **isEnabled** (boolean).
No configuration revision, HTTP headers/validators, refresh timestamps, article
provenance, or diagnostics are present. Endpoint policy validation belongs to the
persisted projection; this DTO does not fetch or normalize URLs.

`GeneralPreferences`: **schemaVersion** (integer exactly 1),
**focusDefaultMinutes** (integer >0 with checked multiplication by 60 fitting
`Int`), **textSize** (`system` or `large`), **reduceMotion** (`system` or `reduce`),
and **ai** (AI). Validation reuses `AppPreferences`. Constructed/missing-storage
defaults are 1 / 25 / system / system, respectively, not inserted storage rows.

`AI`: **enabled** (boolean, default false for missing storage), **providerID**
(ID, default `openai`), **modelID** (nonblank string?; default null). It carries
only nonsecret configuration, never a credential or credential reference.

### Persisted configuration projection

`DailyDataExportProjection.project(general:ai:newsPreferences:feeds:catalog:into:)`
is synchronous and main-actor isolated. The caller supplies already-fetched rows
and the detached catalog from `BundledFeedCatalog.load()` (a local resource read,
not News initialization). It replaces only the two configuration objects in the
envelope, validates it, and returns canonicalized detached values. Fetching a
coherent committed snapshot remains the repository's responsibility.

- Missing general/AI rows use `AppPreferences.defaults` / `AISettingsSnapshot.disabled`
  without inserting anything. Present general rows reuse `AppPreferences` validation,
  including the entire supported custom-duration range. Present AI rows require
  payload version 1 and reuse pure `AISettingsSnapshot.validate()`: provider `openai`,
  optional model identifier of 1–128 ASCII letters/digits/`-.:_`, optional opaque
  credential-reference UUID, and model/reference presence when enabled. Only
  enabled/provider/model leave the mapper; there is no Keychain access or credential
  verification. A disabled row's configured model is retained, not reset.
- Multiple general, AI, or News singleton rows, foreign singleton keys, and duplicate
  feed IDs fail rather than choosing a row. Unsupported general/AI payload versions
  fail. Revisions are excluded, not synthesized.
- Effective bundled News defaults apply **only when both** News preference and feed
  rows are absent: initial selected topics and every stable bundled feed, enabled.
  A present preference row with zero feeds stays empty; empty selection stays empty.
  Feeds without a preference row fail. The supplied catalog must have positive
  version, unique nonempty topics (≤32), valid selection/mappings, and ≤32 feeds with
  unique UUIDs and normalized HTTPS endpoints. Persisted positive catalog versions
  are retained as storage validity information, not exported or interpreted as
  payload versions; no reconciliation to a newer catalog is performed.
- Selections and feed mappings decode through `NewsRecordPayload.topics`, including
  version 1, size/count/string limits and duplicate rejection. Corrupt, oversized,
  or unsupported payloads fail. Topic IDs must belong to the supplied catalog;
  each feed needs at least one topic. There may be at most 32 persisted feeds.
- Feed names are nonempty, ≤256 UTF-8 bytes, and have no surrounding whitespace.
  Names, endpoints, mappings, IDs, and enabled flags map exactly, without applying
  editor normalization. `NewsURLPolicy` validates HTTPS endpoints (no user/password
  authority or fragment) and normalized endpoint uniqueness, **without rewriting
  the exported configured endpoint**. Secret-looking authored text is preserved.
- Excluded transport timestamps, validators, diagnostics, and article-cache data
  are neither read nor validated by this projection. Damage in an **included**
  configuration field fails the whole export and is never treated as absence.
  Errors expose only finite `LocalDataExportError` categories, not raw payloads.
- No context save/insertion, News initialization/refresh, network, Keychain,
  credential resolution, feature-store loading, or editor-draft access occurs.
  Later row edits cannot change the detached result.

## Learning

`Learning` requires **topics**, **subtopics**, **concepts**, **definitions**,
**progress**, **attempts**, **slots**, **terminalRecords**, and
**catalogMembership**. Each is an array even when empty. Identity namespaces are
collection-specific; the same lessonID may intentionally occur in several kinds
of historical evidence. Two attempts may share a lessonID but not an attempt UUID.

### Taxonomy

- `Topic`: **id** (ID, unique), **name** (nonblank string).
- `Subtopic`: **id** (ID, unique), **topicID** (ID), **name** (nonblank string).
- `Concept`: **id** (ID, unique), **subtopicID** (ID), **name** (nonblank string),
  **prerequisiteConceptIDs** (ID[], set, empty allowed).

### Definition

Accepted seed/generated definitions, including retained historical rows, have:

| Field | Type | Meaning/validation |
| --- | --- | --- |
| id | ID | Unique definition identity (embedded definitions have enclosing identity checks). |
| objectiveKey | string | Exact nonblank objective key. |
| objective | string | Exact objective; empty allowed on retained legacy rows; never synthesized from key. |
| title | string | Exact nonblank title. |
| topicID, subtopicID | ID | Stored taxonomy links. |
| conceptIDs | ID[] | Nonempty set; duplicates rejected. |
| difficulty | string | `basic`, `intermediate`, or `advanced`. |
| format | string | `learn`, `code`, `question`, or `design`. |
| estimatedMinutes | integer | >0. |
| prerequisiteConceptIDs | ID[] | Set, may be empty. |
| explanation, workedExample, exercise, referenceAnswer | string | Exact nonblank teaching sections; named order preserved. |
| selfCheckCriteria | string[] | Nonempty ordered sequence of nonblank strings. |
| contentVersion | integer | >0; author content version, independent of envelope versions. |
| normalizedContentHash | string | Stored fingerprint: `sha256:` + 64 lowercase hex digits; not recomputed by DTO serialization. |
| source | string | `seed` or `generated`; retained rows preserve original source. |
| provenance | Provenance? | Explicit allowlisted metadata, null if genuinely unavailable; never a raw JSON string/blob. |

`Provenance` fields: **schemaVersion** (integer exactly 1), **attribution**
(nonblank string?; known seed attribution, otherwise null), **generation**
(Generation?; known generated metadata, otherwise null).

`Generation` fields: **provider** (ID), **requestedModel** (nonblank string),
**returnedModel** (nonblank string?), **generatedAt** (Instant), **operationID**
(UUID), **requestSchemaVersion** (integer exactly 1), **objectiveRegistryVersion**
(integer >0). A present generation object requires definition source `generated`.
No arbitrary provider payload or transport request/response is included.
Provenance projection must interpret only recognized stored shapes and reject
present corruption, rather than dumping unknown serialized fields or treating
corruption as legacy absence.

### Progress

**lessonID** (ID, unique), **status** (`available`, `started`, `completed`, or
`dismissed`), **firstShownAt**, **startedAt**, **completedAt**, **dismissedAt**,
**lastOpenedAt** (each Instant?). Null means that persisted milestone is absent;
there is no inferred timestamp. Progress remains terminal-status authority.

### Attempt and studied content

| Field | Type | Meaning/validation |
| --- | --- | --- |
| id | UUID | Unique attempt identity. |
| lessonID | ID | Historical lesson identity. |
| contentVersion | integer | >0, version studied by this attempt. |
| answerDraft | string | **Persisted saved answer**, exact, empty allowed. Not an unsaved editor draft. |
| revision | integer | ≥0, persisted answer revision. |
| solutionRevealedAt, selfCheckAcknowledgedAt, completedAt | Instant? | Persisted milestones only. |
| pinnedContent | Pin? | Full historical studied definition when available, otherwise null. |
| completedContentSnapshot | CompletedContent? | Released partial completed snapshot when available, otherwise null. |

`Pin`: **envelopeVersion** (integer exactly 1) and **definition** (Definition).
Its definition ID/contentVersion must equal the enclosing attempt's
lessonID/contentVersion, even if the currently stored definition has changed.

`CompletedContent` has **title**, **objectiveKey** (nonblank strings),
**conceptIDs** (ID[], set; may be empty for legacy partial evidence), **difficulty**,
**format** (same codes as Definition), **explanation**, **workedExample**,
**exercise**, **referenceAnswer** (nonblank strings), **selfCheckCriteria**
(nonempty ordered nonblank string[]). This is the released reduced content shape:
there are **no invented identity, version, topic, objective, estimate, source, or
provenance fields**. Its author content order and exact text remain intact.

The future projection must use `PinnedLessonContent.decode` for present pins.
Nil/known unavailable legacy pins become null; present corrupt payloads fail.
Partial completed content is exported as partial, never replaced by today's
Definition. An empty pin sentinel that explicitly records unavailable legacy
content also becomes null; arbitrary corrupt present bytes are not absence.

### Slot

**key** (ID, unique), **topicID** (ID), **slotIndex** (integer ≥0), **lessonID**
(ID, additionally unique across slots), **assignedAt** (Instant).
`key` must equal `<topicID UTF-8 byte count>:<topicID>:<slotIndex>`, including topics
containing colons or non-ASCII characters. Arrays sort by the key, not numeric
slot index. Export performs no rotation or assignment.

### TerminalRecord

| Field | Type | Meaning/validation |
| --- | --- | --- |
| schemaVersion | integer | Exactly 1, decoded metadata payload contract. |
| lessonID | ID | Unique archived identity. |
| provenance | string | `studiedPin`, `dismissalPin`, `dismissalReference`, `legacyCompletedPartial`, or `legacyRecoveredReference`. |
| title | string? | Historical title or null; never looked up from current catalog. |
| topicID, subtopicID | ID? | Historical links or null. |
| contentVersion | integer? | >0 when present, otherwise null. |
| objectiveKey | string? | Nonblank when present, otherwise null. |
| conceptIDs | ID[]? | Nonempty unique set when present, otherwise null (not an invented empty set). |
| normalizedContentHash | string? | Same fingerprint syntax as Definition when present, otherwise null. |
| format | string? | Same format code as Definition when present, otherwise null. |
| dismissalTimeDefinition | Definition? | Reference content, permitted only for dismissalReference/legacyRecoveredReference. |

Nonlegacy provenance requires all metadata fields except dismissalTimeDefinition
to be nonnull. Legacy provenance permits documented gaps. Embedded dismissal
content must match lessonID and every available contentVersion/topicID/subtopicID/
objectiveKey/conceptIDs/hash/format field. Future projection uses `metadata()` to
validate the stored outer identity and version before mapping. Stored terminal
metadata is distinct from current progress and never determines replacement
studied content.

### CatalogMembership

**schemaVersion** (integer exactly 1), **catalogID** (ID, unique),
**catalogVersion** (integer >0), **topicIDs**, **subtopicIDs**, **conceptIDs**,
**seededLessonIDs** (each ID[], unique sets, empty allowed).
Future projection uses `membership()` to validate the stored outer identity and
version. This is explicit stored membership, not a freshly reconciled catalog.
Absent rows remain an empty collection, not synthesized current membership.

## Privacy and limitations

Only the fields above exist in the DTO graph. Excluded: Keychain values and
credential references; project references/grants/bookmarks/location paths,
inspections, Undo data and external project content; News article cache,
HTTP headers/validators/transport payloads; raw errors/diagnostics; unsaved task,
schedule, feed, preference, and answer editor drafts. Persisted saved answers are
included, regardless of secret-looking authored text. Review the plain JSON
before sharing it; it is not guaranteed to be free of sensitive authored content.

No SwiftData object, `Data` blob, arbitrary dictionary, filesystem URL/grant,
network operation, store reset, generation, restore, or external-project mutation
belongs to this contract. Daily row mapping is implemented; the remaining
projections, coherent capture, and safe atomic delivery will be implemented and
verified in later checkpoints before exposing export UI.
