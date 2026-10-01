# Kontrol UI hierarchy discovery

## Status and scan boundary

Planning only. No implementation approval. Source-based audit of the seven destinations and shared design system; representative primary views inspected, not an exhaustive review of every editor. No app launch, screenshot, rendered layout inspection, AX interaction or hosted presentation test was performed during this discovery.

Stack: SwiftUI / SwiftData, macOS 14 minimum, Swift language mode 5. Yams resolves to 5.4.0. Evidence: `Kontrol.xcodeproj/project.pbxproj`, `Kontrol.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`, `README.md`, `docs/architecture.md`.

The working tree already contains edits to Learning, tests, Makefile, instructions and documentation. They are not part of this design exploration and must not be overwritten or credited to it.

## Inventory

| Surface | Current implementation | Exploration status |
|---|---|---|
| Global navigation | `Kontrol/App/AppShell.swift`, `Kontrol/App/NavigationStore.swift` | Preserve seven destinations and horizontal navigation |
| Today / schedule / capture | `Kontrol/Features/Today/TodayView.swift`, `ScheduleEditorView.swift`, `QuickCaptureView.swift` | Two main-page alternatives; editors retain semantics |
| Learning / practice / history / coverage | `Kontrol/Features/Learning/LearningView.swift`, `LessonExperienceView.swift`, `LearningHistoryView.swift`, `LearningCoverageView.swift` | Two choices-page alternatives; other layouts pending |
| Projects / feature details / project information | `Kontrol/Features/Projects/ProjectsView.swift`, `ProjectDetailsView.swift`, `ProjectFeatureDetailView.swift` | Two workspace alternatives; mutation guards unchanged |
| Tasks | `Kontrol/Features/Tasks/TasksView.swift`, `TaskEditorView.swift` | Selected supporting reference: `flows/ui-hierarchy/b-tasks.html` |
| Focus / session history | `Kontrol/Features/Focus/FocusView.swift`, `FocusHistoryView.swift` | Selected ready-screen reference: `flows/ui-hierarchy/b-focus.html`; session/history structure unchanged |
| News / topics / feeds | `Kontrol/Features/News/NewsView.swift`, `NewsManagementView.swift` | Selected reference: `flows/ui-hierarchy/b-news.html`; management flow unchanged |
| Settings | `Kontrol/Features/Settings/FoundationSettingsView.swift` and existing section views | Selected hub reference: `flows/ui-hierarchy/b-settings.html`; section flows unchanged |

Peer navigation is already established. The explored flow is Today ↔ Learning ↔ Projects, not a wizard. Existing lesson, project and settings subflows under `.mockups/flows/f06-lesson-experience/`, `f09-local-projects/`, `f10-next-features/`, `f11-feature-completion/`, `f13-settings-release/` remain references, not newly approved layouts.

### Shared system

Reuse `Kontrol/DesignSystem/AppColors.swift`, `AppTypography.swift`, `AppMetrics.swift` and `Components/ActionButton.swift`, `PageHeader.swift`, `SectionHeader.swift`, `AppListRow.swift`, `NextActionCard.swift`, feedback components. Existing mock references: `.mockups/design-system/tokens.css`, `components.css`, `components.html`. No palette, typography, motion or shared primitive redesign is needed for these alternatives. Inline preview CSS handles composition only; native disclosures/selectors stand in for existing system controls. There are no external fonts or assets.

## Findings

Heuristic design opportunities, not empirically measured usability failures.

### F-401 · important · prominence is not consistently tied to the primary activity

- `Kontrol/Features/Focus/FocusView.swift:459`: Start follows Duration and two separate optional linkage sections. The draft allows a task OR a lesson, not both.
- `Kontrol/Features/Projects/ProjectsView.swift:513`: progress, refresh state, project information and next features share the workspace; next actionable features deserve clearer grouping without suppressing stale/partial status.
- `Kontrol/Features/Today/TodayView.swift:171`: lessons precede schedule/tasks. This is compatible with the user's chosen learning-first priority, but each section needs clearer boundaries.

Proposal: primary activity first, optional setup/information separate; keep explicit state and actionable recovery near the affected area.

### F-501 · important · verbose or inconsistent action copy

- `Kontrol/Features/Learning/LearningView.swift:305`: lesson titles repeat in Open/Resume and Show another button labels.
- `Kontrol/Features/Today/TodayView.swift:470`: Start now is used even for started suggestions; Learning already distinguishes Open/Resume.
- `Kontrol/Features/Tasks/TasksView.swift:64`: row metadata includes calendar and timezone internals.
- `Kontrol/Features/Settings/GeneralPreferencesView.swift:86`: normal-state text explains implementation-level draft rules.

Proposal: concise visible labels plus item-specific accessibility names; retain complete technical data in appropriate details. Use Open/Resume consistently for lesson entry, Start/Pause/Resume for the timer, and preserve distinct meanings of Delete, Remove, Dismiss/Show another and Mark complete.

### F-402 · important · primary and infrequent row controls compete

- `Kontrol/Features/Tasks/TasksView.swift:92`: Complete, Edit and Delete are stacked on each row.
- `Kontrol/Features/Learning/LearningView.swift:285`: full objective, concept labels, Open/Resume and replacement are all expanded.
- `Kontrol/Features/Projects/ProjectDetailsView.swift:144`: detailed validation precedes project content when present.

Proposal: keep core item identity/status/action visible, move secondary options/details behind explicit disclosure or existing detail routes. Keep error summaries, partial counts and mutation risk visible; do not hide important problems as cosmetic cleanup.

### F-601 · important · preserve truthful failure states while shortening copy

Existing views distinguish unknown/unavailable from empty, stale project reads from current data, completion saved from verification failure, and unsaved answers from committed progress. See `ProjectsView.completionMessage`, `TodayLessonSelection.suggestions`, and Learning read-state handling. These are product semantics, not expendable explanatory text.

Proposal: short visible summary + recovery action; optional diagnostic detail where safe. Never infer success, completed progress or eligibility from stale data.

## Agreed decisions

1. Refine hierarchy and functional boundaries across the app; keep the fixed Black / Red Terminal theme and seven destinations.
2. Prioritize learning and project progress: practice/resume lessons and next project features.
3. Create two linked HTML alternatives covering Learning, Projects and Today before implementation.
4. No production code changes during discovery. Validation must follow `AGENTS.md`: non-interactive only, no full unfiltered test suite.
5. User selected **B — Browse then act** for Learning/Projects, with B's supporting Today layout. This is design direction, not implementation approval.
6. Scope is all main destination screens plus targeted supporting copy. Lesson exercises, editors, histories/coverage and configuration flows stay structurally unchanged.
7. User confirmed the supporting rules: Tasks retains visible Complete/Reopen with other actions/details disclosed; Focus emphasizes timer/Start and uses one optional activity type (None/Task/Lesson); News emphasizes headlines with disclosed feed diagnostics and visible error summaries; Settings uses concise section names/current values.
8. User confirmed first-item preview initialization: first eligible listed item, no auto-Open/Resume/completion. Selection is by stable identity, read-only, and subordinate to existing save/availability guards.

Mode: constrained reimagination of composition, retaining existing tokens and domain ownership. Not a new theme or navigation architecture.

## Alternatives and selection

### A — Direct actions (considered, not selected)

Compact lesson/feature rows retain a visible Open/Resume/View action. Secondary metadata and replacement/completion options use disclosure or existing detail routes. Lower complexity and closer to current row/action architecture; avoids new item-preview selection state. Tradeoff: multiple row actions remain visible.

### B — Browse then act (selected)

Compact list plus a separate preview/action panel. Stronger distinction between selection and action, less repeated detail. Tradeoffs: extra selection interaction, more state/reset logic, and more complex compact-layout handling. Preview selection must remain read-only, never opening attempts or writing features.

Both preserve topic/slot and feature candidate ordering; no new ranking is proposed. Today keeps at most two existing lesson suggestions and adds only a guarded route link to Projects, not project inspection or a new recommendation service. Schedule/Tasks remain distinct. These Today changes were included in the selected B design brief.

## Generated mockups

Review index: `.mockups/flows/ui-hierarchy/index.html`.

| Surface | Option A | Option B |
|---|---|---|
| Learning | `flows/ui-hierarchy/a-learning.html` | `flows/ui-hierarchy/b-learning.html` |
| Projects | `flows/ui-hierarchy/a-projects.html` | `flows/ui-hierarchy/b-projects.html` |
| Today | `flows/ui-hierarchy/a-today.html` | `flows/ui-hierarchy/b-today.html` |

Paths in this table are relative to `.mockups/`. Topic selection, B item selection, disclosure, peer navigation and preview-state controls are implemented in HTML. Domain action buttons show an explicit preview-boundary dialog; they never simulate a committed success. Option B links all seven destinations; A retains only the initial three-page comparison. Source catalog titles/objectives are reused; selected slots, started progress, projects, schedule and tasks are illustrative, never production records.

### Whose default: offline and enlarged-text mirrors

Each alternative/surface has a sibling `*-offline-large.html`, linked from the index. Learning and Today show available local content; Projects shows stale local inspection with next-feature actions unavailable pending Refresh. Large text starts at 130%; layouts stack below 900 CSS pixels. This is a design proposal for offline users and users needing larger text, not evidence of rendered geometry or native accessibility behavior.

## Constraints / non-goals

- No new account, backend, schema/migration, dependencies, recommendation algorithm, automatic AI generation, project-file mutation policy or completion semantics.
- No hidden save failures, removal of explicit consent, destructive confirmation, retry safeguards or Undo.
- Preserve keyboard and accessibility product support. No accessibility/keyboard/hosted GUI validation gates.
- Preserve 1000×700 main-window baseline, larger layouts and enlarged text; Settings also serves its compact native window.
- Existing Learning selection changes and Makefile restart changes are separate work; do not claim this design resolves their runtime behavior.
- No edits to `AGENTS.md` to install design-skill conventions during this planning-only request.

## Validation and outstanding decisions

- Mockup generator initially failed with a Python f-string syntax error; corrected before generation.
- Initial three-surface pass: 13 HTML files and 12 inline scripts passed structural/syntax checks. After extending selected B: `python3 .mockups/flows/ui-hierarchy/generate_previews.py` generated 20 preview pages plus index. `python3 .mockups/flows/ui-hierarchy/check_previews.py` passed for all 21 HTML files (local references, unique IDs, no external resources, known CSS tokens) and all 20 inline scripts using `node --check` (stdin). `git diff --check` passed. These are structural/syntax checks only. No browser was opened and no screenshot/render inspection is claimed.
- Design decisions are settled for the implementation prompt. User review of that prompt and explicit handoff remain outstanding; no workflow was started.
- Preserve existing design-token assertions; `KontrolTests/DesignSystemTokenTests.swift` mixes pure checks and hosted measurement, so select individual non-GUI methods rather than the entire suite.
- Existing non-GUI navigation/selection/store tests are useful, but do not establish native visual behavior.
