# Screen and function index

Each row links a function to an actual PNG mockup. SVG sources sit beside the PNG files. Background services use the UI state through which their behavior is observed; they do not acquire artificial pages.

| Feature | Function / page | Mockup |
| --- | --- | --- |
| [F00](../features/F00-foundation.md) | Launch and navigation | [M00 · Today](M00-app-shell.png) |
| [F00](../features/F00-foundation.md) | Browse imported offline starter topics and lesson summaries (no active choices or progress) | [M43 · Learning starter summary](M43-learning-starter-summary.png) |
| [F00](../features/F00-foundation.md) | Store open, migration and failure recovery | [M01 · Kontrol](M01-store-recovery.png) |
| [F01](../features/F01-design-system.md) | Typography, colors and icons | [M42 · Appearance](M42-design-accessibility.png) · [Selected palette + contrast](../../.mockups/design-system/palette.html) · [Type scale (100% / 130%)](../../.mockups/design-system/typography.html) · [Component states](../../.mockups/design-system/components.html) · [Shared tokens](../../.mockups/design-system/tokens.css) · [Shared component styles](../../.mockups/design-system/components.css) |
| [F01](../features/F01-design-system.md) | Navigation, keyboard and focus | [M00 · Today](M00-app-shell.png) · [Selected palette + focus roles](../../.mockups/design-system/palette.html) · [Focus / selected / enlarged examples](../../.mockups/design-system/components.html) |
| [F02](../features/F02-tasks.md) | Browse today/upcoming and overdue tasks | [M02 · Tasks](M02-tasks.png) |
| [F02](../features/F02-tasks.md) | Create or edit task, notes and due date | [M03 · Tasks](M03-task-editor.png) |
| [F02](../features/F02-tasks.md) | Complete or reopen | [M04 · Completed](M04-task-complete-reopen.png) |
| [F02](../features/F02-tasks.md) | Delete task | [M05 · Tasks](M05-task-delete.png) |
| [F02](../features/F02-tasks.md) | Quick capture | [M09 · Today](M09-quick-capture.png) |
| [F03](../features/F03-today-schedule.md) | Select day and open linked items | [M06 · Today](M06-today.png) |
| [F03](../features/F03-today-schedule.md) | Add, move, edit or delete a schedule block | [M07 · Today](M07-schedule-editor.png) · [Endpoint/validation states](../../.mockups/screens/f03/schedule-editor-endpoints.html) |
| [F03](../features/F03-today-schedule.md) | Resolve overlap | [M08 · Today](M08-schedule-overlap.png) · [Multiple-conflict decision](../../.mockups/screens/f03/schedule-overlap-multiple.html) |
| [F04](../features/F04-focus.md) | Configure duration and optional link | [M10 · Focus](M10-focus-ready.png) · [Custom duration validation](../../.mockups/screens/f04/custom-duration-validation.html) · [No open tasks](../../.mockups/screens/f04/no-available-tasks.html) |
| [F04](../features/F04-focus.md) | Run session | [M11 · Focus](M11-focus-running.png) · [Read/Start persistence failure](../../.mockups/screens/f04/persistence-failure.html) |
| [F04](../features/F04-focus.md) | Pause or resume | [M12 · Focus](M12-focus-paused.png) |
| [F04](../features/F04-focus.md) | Recover after relaunch | [M13 · Focus](M13-focus-recovery.png) |
| [F04](../features/F04-focus.md) | End/completed session and history | [M14 · Sessions](M14-focus-history.png) · [Completion pending save](../../.mockups/screens/f04/completion-pending.html) · [F04 variant overview](../../.mockups/screens/f04/index.html) |
| [F05](../features/F05-learning-catalog.md) | Choose topic and inspect seeded lessons | [M15 · Learning](M15-learning-choices.png) · [F05 state overview](../../.mockups/screens/f05/index.html) · [Reference-only inspection](../../.mockups/screens/f05/read-only-inspection.html) · [Exhausted inventory](../../.mockups/screens/f05/exhausted-empty.html) · [Loading / read failure](../../.mockups/screens/f05/loading-read-failure.html) |
| [F06](../features/F06-lesson-experience.md) | Learn format | [M16 · Context cancellation](M16-lesson-learn.png) |
| [F06](../features/F06-lesson-experience.md) | Code format | [M17 · Table-driven tests](M17-lesson-code.png) |
| [F06](../features/F06-lesson-experience.md) | Question format | [M18 · Benchmarking Go](M18-lesson-question.png) |
| [F06](../features/F06-lesson-experience.md) | Design format | [M19 · Design a rate limiter](M19-lesson-design.png) |
| [F06](../features/F06-lesson-experience.md) | Reveal solution | [M20 · Context cancellation](M20-lesson-solution.png) |
| [F06](../features/F06-lesson-experience.md) | Complete and refill a slot | [M21 · Learning](M21-lesson-completion-rotation.png) |
| [F06](../features/F06-lesson-experience.md) | Dismiss and replace | [M22 · Learning](M22-lesson-dismiss.png) |
| [F06](../features/F06-lesson-experience.md) | Add lesson to Today | [M07 · Today](M07-schedule-editor.png) · [Today suggestions, linked editor and Focus entry](../../.mockups/flows/f06-lesson-experience/08-today-focus.html) |
| [F06](../features/F06-lesson-experience.md) | Choices / History hub and practice path | [F06 flow navigator](../../.mockups/flows/f06-lesson-experience/index.html) · [Exercise / saving / retry](../../.mockups/flows/f06-lesson-experience/01-exercise.html) · [Stale answer recovery](../../.mockups/flows/f06-lesson-experience/02-stale-answer.html) |
| [F06](../features/F06-lesson-experience.md) | Persisted reveal, acknowledgement and completion gates | [Solution / self-check](../../.mockups/flows/f06-lesson-experience/03-solution.html) · [Completion / one-slot feedback](../../.mockups/flows/f06-lesson-experience/04-completion.html) · [Lesson action not saved](../../.mockups/flows/f06-lesson-experience/09-action-failure.html) |
| [F06](../features/F06-lesson-experience.md) | Exhaustion and generation-unavailable notice | [Real zero inventory / F08 notice](../../.mockups/flows/f06-lesson-experience/05-exhaustion.html) |
| [F06](../features/F06-lesson-experience.md) | Minimal History, explicit Restore, unslotted resume and unavailable historical content | [History / restored started work](../../.mockups/flows/f06-lesson-experience/06-history.html) · [Unavailable studied content](../../.mockups/flows/f06-lesson-experience/07-unavailable-content.html) |
| [F06](../features/F06-lesson-experience.md) | Today Start now and Focus lesson selection | [Today / Focus entries](../../.mockups/flows/f06-lesson-experience/08-today-focus.html) · [M10 · Focus ready](M10-focus-ready.png) |
| [F07](../features/F07-history-coverage.md) | Filter and open history | [M23 · History](M23-learning-history.png) |
| [F07](../features/F07-history-coverage.md) | Restore a dismissed lesson | [M23 · History](M23-learning-history.png) |
| [F07](../features/F07-history-coverage.md) | Inspect coverage and concepts | [M24 · Coverage](M24-concept-coverage.png) |
| [F07](../features/F07-history-coverage.md) | Deduplicate and select replacement | [M21 · Learning](M21-lesson-completion-rotation.png) |
| [F07](../features/F07-history-coverage.md) | Invalid custom range and filtered-empty History | [F07 state overview](../../.mockups/screens/f07/index.html) · [Reversed date range](../../.mockups/screens/f07/invalid-custom-range.html) · [No matching lessons](../../.mockups/screens/f07/filtered-empty-history.html) |
| [F07](../features/F07-history-coverage.md) | Coverage read failure, incomplete legacy evidence, and no eligible concept lessons | [Coverage unavailable](../../.mockups/screens/f07/coverage-read-failure.html) · [Partial historical evidence](../../.mockups/screens/f07/incomplete-legacy-evidence.html) · [No eligible lessons](../../.mockups/screens/f07/no-eligible-concept-lessons.html) |
| [F08](../features/F08-ai-expansion.md) | Configure, enable, test or remove provider key | [M39 · AI lessons](M39-ai-settings.png) |
| [F08](../features/F08-ai-expansion.md) | Generate a candidate | [M25 · Generate lesson](M25-generate-lesson.png) |
| [F08](../features/F08-ai-expansion.md) | Handle invalid, duplicate or failed generation | [M26 · Learning](M26-generation-failure.png) · [F08 state map](../../.mockups/flows/f08-ai-expansion/index.html) · [Local save failure](../../.mockups/flows/f08-ai-expansion/06-local-save-failure.html) · [Timeout / rate limit](../../.mockups/flows/f08-ai-expansion/07-network-recovery.html) |
| [F08](../features/F08-ai-expansion.md) | Disabled / no key; configuration, connection-test and removal failures | [Disabled / no key](../../.mockups/flows/f08-ai-expansion/01-disabled-no-key.html) · [Settings recovery](../../.mockups/flows/f08-ai-expansion/02-settings-recovery.html) |
| [F08](../features/F08-ai-expansion.md) | Canonical scope, no objective, generating / cancel | [Scope / no objective](../../.mockups/flows/f08-ai-expansion/03-scope.html) · [Generating / cancel](../../.mockups/flows/f08-ai-expansion/04-generating.html) |
| [F08](../features/F08-ai-expansion.md) | Committed vacancy vs full-slot save | [Saved outcomes](../../.mockups/flows/f08-ai-expansion/05-saved.html) |
| [F09](../features/F09-local-projects.md) | Add a project folder | [M28 · Projects](M28-project-add.png) · [Add sequence and failure branch](../../.mockups/flows/f09-local-projects/index.html) |
| [F09](../features/F09-local-projects.md) | Read project details, roadmap, context and rules | [M29 · Kontrol](M29-project-details.png) · [Partial details](../../.mockups/flows/f09-local-projects/04-partial.html) |
| [F09](../features/F09-local-projects.md) | Refresh, validate or reconnect | [M33 · Projects](M33-project-validation-access.png) · [Unsupported source](../../.mockups/flows/f09-local-projects/05-unsupported.html) · [Reconnect mismatch](../../.mockups/flows/f09-local-projects/06-reconnect-mismatch.html) |
| [F10](../features/F10-next-features.md) | Choose a project and next feature card | [M27 · Projects](M27-projects.png) · [F10 state map](../../.mockups/flows/f10-next-features/index.html) · [Partial-valid suggestions](../../.mockups/flows/f10-next-features/03-partial-valid.html) |
| [F10](../features/F10-next-features.md) | Read full feature details | [M30 · Learning history](M30-feature-detail.png) · [Read-only detail](../../.mockups/flows/f10-next-features/07-feature-detail.html) · [Retained stale detail](../../.mockups/flows/f10-next-features/07-feature-detail.html#stale) · [Removed vs invalid notices](../../.mockups/flows/f10-next-features/06-selection-notices.html) |
| [F10](../features/F10-next-features.md) | No eligible features or all complete | [M34 · Kontrol](M34-project-empty-blocked.png) · [All complete](../../.mockups/flows/f10-next-features/01-all-complete.html) · [Zero features](../../.mockups/flows/f10-next-features/02-zero-features.html) · [Unavailable](../../.mockups/flows/f10-next-features/04-unavailable.html) · [Retained stale](../../.mockups/flows/f10-next-features/05-retained-stale.html) |
| [F11](../features/F11-feature-completion.md) | Mark feature complete and update cards | [M31 · Kontrol](M31-feature-completion-undo.png) · [F11 state map](../../.mockups/flows/f11-feature-completion/index.html) · [Saving](../../.mockups/flows/f11-feature-completion/01-saving.html) · [Saved, refresh failed](../../.mockups/flows/f11-feature-completion/06-saved-refresh-failed.html) |
| [F11](../features/F11-feature-completion.md) | Undo completion | [M31 · Kontrol](M31-feature-completion-undo.png) · [Undo conflict](../../.mockups/flows/f11-feature-completion/03-undo-conflict.html) · [Expired](../../.mockups/flows/f11-feature-completion/04-undo-expired.html) |
| [F11](../features/F11-feature-completion.md) | Recover from conflict or write failure | [M32 · Kontrol](M32-project-write-conflict.png) · [Write failure](../../.mockups/flows/f11-feature-completion/02-write-failure.html) · [Unpatchable source](../../.mockups/flows/f11-feature-completion/05-unpatchable-source.html) |
| [F12](../features/F12-news.md) | Filter topics, refresh and read at source | [M35 · News](M35-news.png) · [F12 state map](../../.mockups/flows/f12-topic-news/index.html) · [Browser-open failure](../../.mockups/flows/f12-topic-news/06-browser-open-failure.html) |
| [F12](../features/F12-news.md) | Select topics and add/edit/remove feed | [M36 · Topics & feeds](M36-news-topics-feeds.png) · [Editor validation / save failure](../../.mockups/flows/f12-topic-news/04-editor-failure.html) · [Confirm removal](../../.mockups/flows/f12-topic-news/05-confirm-removal.html) |
| [F12](../features/F12-news.md) | Offline, stale or failed refresh | [M37 · News](M37-news-offline.png) · [Local loading](../../.mockups/flows/f12-topic-news/01-loading.html) · [Empty / filtered states](../../.mockups/flows/f12-topic-news/02-empty.html) · [Partial / rate-limited](../../.mockups/flows/f12-topic-news/03-partial-rate-limited.html) · [Cache read failure](../../.mockups/flows/f12-topic-news/07-cache-read-failure.html) |
| [F13](../features/F13-settings-release.md) | Edit settings and focus default | [M38 · Settings](M38-settings.png) · [F13 state navigator](../../.mockups/flows/f13-settings-release/index.html) · [General draft](../../.mockups/flows/f13-settings-release/02-general-editor.html) |
| [F13](../features/F13-settings-release.md) | Export local data | [M40 · Local data](M40-data-export.png) |
| [F13](../features/F13-settings-release.md) | Disconnect project folder | [M41 · Project folders](M41-remove-project.png) |
| [F13](../features/F13-settings-release.md) | Accessibility and release verification | [M42 · Appearance](M42-design-accessibility.png) |

## F05 departures from M15

[M15](M15-learning-choices.png) remains the normal-state composition reference: five topic choices in the sidebar and up to four stable lessons for the selected topic. The [F05 overview](../../.mockups/screens/f05/index.html) shows four representative Go choices with explicit objectives and concept labels, alongside the three states M15 does not depict. Its example content is illustrative, not a guarantee of slot ordering. [Inspection](../../.mockups/screens/f05/read-only-inspection.html) presents stored explanation, worked example, exercise prompt, reference response, and self-check as **read-only reference material**; opening it does not start work. [Exhaustion](../../.mockups/screens/f05/exhausted-empty.html) shows the real zero count rather than invented choices. [Loading / read failure](../../.mockups/screens/f05/loading-read-failure.html) distinguishes an in-progress read from a retryable error, neither of which means an empty catalog. M15's History/Coverage, replacement, and generation actions are not part of F05; no F06 attempt or completion workflow is depicted. Interactive behavior and rendered comparison remain deferred to F13.

## F06 supplemental flow boundaries

[Open the F06 navigator](../../.mockups/flows/f06-lesson-experience/index.html) for a choices/History hub, exercise → solution → completion path, and recovery / cross-feature branches. These static references supplement M16–M22, M07 and the *minimal* list/detail/Restore subset of M23; they do not replace the approved normal-state imagery. The F06 History has no F07 filters or coverage controls. Exhaustion shows real inventory and a Generate… **availability notice only**; provider setup, generation, validation, failures and any actual generated lesson are **F08-only** (M25–M26). The HTML links preview states, not working save/Restore/Focus actions. No interactive approval or rendered native acceptance is claimed for these new references.

## F07 supplemental state boundaries

[Open the F07 state overview](../../.mockups/screens/f07/index.html) for five static extensions of M23 (History), M24 (Coverage), and M21 (Learning replacement). A reversed local-date range has inline validation and is not silently swapped. A filtered-empty History has saved records but no matches and offers Clear filters; it is not “No history yet.” A failed Coverage read shows neither an empty catalog nor `0 of 0`, and Retry affects only coverage. Legacy records with missing studied metadata or concept evidence show what is known without borrowing new definitions or claiming zero practice. An empty eligible-lesson list does not Restore dismissals, assign work, or offer excluded duplicates. Sample names, dates and counts are illustrative. Interactive review, native/keyboard/VoiceOver checks, enlarged text and visual comparisons at 1000×700 and 1440×940 remain **open for F13**; these standalone references are not interactive approval.

## F08 supplemental state boundaries

[Open the F08 state map](../../.mockups/flows/f08-ai-expansion/index.html) for the Learning → explicit Generate → committed or unsaved branches, with Settings ↔ Learning cross-jumps. These static HTML references extend M25 (scope), M26 (failure), and M39 (Settings), not replace their approved compositions. Disabled/no-key and exhausted objectives cannot submit. Saving configuration and enabling AI do not submit; only an explicit Test connection uses the non-generating metadata endpoint. Cancel, local-save failure, timeout and rate limit do **not** save a lesson or move current choices. A committed vacancy adds one choice; a committed full-slot lesson is saved unslotted with guarded Open. Retry-After disables Retry until permitted and never schedules a request. Examples are illustrative; links preview states, not working provider calls or persistence. Interactive review, native accessibility and rendered comparisons remain **deferred to F13**, not approved.

## F09 supplemental flow boundaries

[Open the F09 state map](../../.mockups/flows/f09-local-projects/index.html) for empty versus loading, the folder-selection → inspection → explicit Add sequence, persistent navigation between saved folders, partial counts, unsupported read-only source, reconnect mismatch and failed Add. These standalone references supplement M28, M29 and M33; they do not replace the approved parent compositions. Refresh is for repaired content or inconsistent reads; Reconnect is for unavailable authorization; choose another folder in Add preview is reselection, not restoration; a failed bookmark/save does not create a row. Same-ID folders remain distinct by location. Sample names, paths and counts are illustrative, never production defaults. Created unattended as design references, **not interactive sign-off**. Native picker, signed sandbox, keyboard/VoiceOver, enlarged-text and rendered comparisons remain deferred to F13.

## F10 supplemental state boundaries

[Open the F10 state map](../../.mockups/flows/f10-next-features/index.html) for seven peer states supplementing M27 (cards), M30 (detail) and M34 (no-ready work). All-complete means 3 of 3 valid completed; zero features requires a successful enumeration and is not an all-complete result. A current partial inspection shows valid candidates with its excluded-file count; failed enumeration shows no progress, while failed refresh labels retained counts stale and suppresses actionable suggestions. Removed and invalid selected features have separate notices after an authoritative refresh, never after a failed read. Read-only detail shows full local Markdown and Back, with View feature rather than F11 completion/undo. Folder navigation, Add, Refresh, project details/validation and Reconnect previews remain accessible. Counts, names and paths are illustrative. Links preview states, not working file operations. Created unattended as **static references, not interactive sign-off**; rendered/native, keyboard/VoiceOver, enlarged-text and sandbox checks remain for F13.

## F11 supplemental state boundaries

[Open the F11 state map](../../.mockups/flows/f11-feature-completion/index.html) for six peer states extending M31 (verified save / Undo) and M32 (changed-on-disk dialog). Saving and Undoing are pending operations, not success. Pre-replacement write failure and unpatchable frontmatter leave the feature unchanged and provide no new Undo; an unverified post-replacement outcome instead requires Refresh without claiming unchanged bytes. Undo conflict preserves external edits and invalidates that Undo, while expiry causes no write. A verified save followed by failed inspection is still saved on disk, but previous counts are stale and no new progress/cards are inferred. Conflict Refresh only rereads for review; it does not retry completion or Undo. Reconnect is for revoked folder authorization, not a content conflict. Sample counts and names are illustrative. HTML links navigate previews; buttons are not live operations. Created unattended as **static guidance, not interactive sign-off or native acceptance**; rendered comparisons, keyboard/VoiceOver, enlarged-text and signed-sandbox checks remain open for F13.

## F12 supplemental state boundaries

[Open the F12 state map](../../.mockups/flows/f12-topic-news/index.html) for seven peer references extending M35 (headlines), M36 (management/editor) and M37 (offline cached reading), not replacing their approved normal-state compositions. Local loading is neither empty nor a network request; never-successful, successfully empty, zero topics, zero enabled feeds and filtered-empty have distinct copy and recovery. A partial refresh preserves cached headlines and separates the last successful check from the failed attempt and server Retry-After deadline. Editor validation and local save failure retain the draft without changing the saved endpoint/cache. Removal requires explicit confirmation; browser-open failure leaves the row and safe HTTPS retry available. A local cache read failure is never shown as an empty feed. Names, URLs, counts and times are illustrative, not bundled feeds or production articles. Buttons are static; links navigate previews only. Created unattended as **HTML guidance, not interactive sign-off or native acceptance**. Rendered/native, keyboard/VoiceOver, enlarged-text and signed-sandbox checks remain open for F13.

## F13 supplemental state boundaries

[Open the F13 navigator](../../.mockups/flows/f13-settings-release/index.html) for a **hub-and-spoke** Settings area with grouped export/removal decision branches. Numeric filenames identify references, not a wizard order. These pages supplement M38/M40/M41/M42; AI and News retain M39/M36 and their existing owners/recovery references. No alternate palette, shared-component changes, production code, or new agent instructions are introduced.

| Surface | Standalone supplemental references |
| --- | --- |
| Settings and local draft | [Hub](../../.mockups/flows/f13-settings-release/01-settings-hub.html) · [General editor](../../.mockups/flows/f13-settings-release/02-general-editor.html) |
| Preference failures | [Validation](../../.mockups/flows/f13-settings-release/03-preference-validation.html) · [Read failure / identified fallback](../../.mockups/flows/f13-settings-release/04-preference-read-failed.html) · [Save failure / retained draft](../../.mockups/flows/f13-settings-release/05-preference-save-failed.html) · [Stale edit / explicit review](../../.mockups/flows/f13-settings-release/06-preference-stale.html) |
| Export decision and outcomes | [Inclusions / exclusions / native-panel boundary](../../.mockups/flows/f13-settings-release/07-export-decision.html) · [Preparing / Cancel](../../.mockups/flows/f13-settings-release/08-export-preparing.html) · [Canceled before commit](../../.mockups/flows/f13-settings-release/09-export-canceled.html) · [Failed before commit](../../.mockups/flows/f13-settings-release/10-export-failed.html) · [Saved after commit](../../.mockups/flows/f13-settings-release/11-export-success.html) |
| Project references | [Unavailable folder](../../.mockups/flows/f13-settings-release/12-project-unavailable.html) · [Successfully empty](../../.mockups/flows/f13-settings-release/13-project-empty.html) · [Reference read failure](../../.mockups/flows/f13-settings-release/22-project-read-failed.html) |
| Removal decisions | [Named confirmation](../../.mockups/flows/f13-settings-release/14-removal-confirmation.html) · [Busy / no automatic retry](../../.mockups/flows/f13-settings-release/15-removal-busy.html) · [Failed / row retained](../../.mockups/flows/f13-settings-release/16-removal-failed.html) · [Stale / reload and review](../../.mockups/flows/f13-settings-release/17-removal-stale.html) · [Canceled / focus return](../../.mockups/flows/f13-settings-release/18-removal-canceled.html) · [Disconnected / surviving selection](../../.mockups/flows/f13-settings-release/19-removal-success.html) |
| Layout and accessibility guidance | [Compact local navigation](../../.mockups/flows/f13-settings-release/20-compact-navigation.html) · [130% enlarged text / recovery reflow](../../.mockups/flows/f13-settings-release/21-enlarged-text.html) |

Preference failures never overwrite damaged or newer records. Save/Cancel are local-editor decisions; existing sessions and explicit Focus drafts do not change. Export requires destination authorization, successful pending-answer save, coherent capture, private validation and atomic delivery. Panel cancellation creates no artifact or answer flush; confirmed pre-commit cancellation/failure preserves an existing destination, while post-commit cancellation still reports Saved. Import/restore is unavailable. Folder removal deletes only the revision-matched local reference, never project/Git files or grants through hidden reuse; busy writes are not canceled or queued for automatic retry. Missing references are not recreated by late reads. Empty references and failed reads are distinct.

Names, dates, values and summaries are illustrative, **not production counts or data**. Links navigate static states; no native dialog, persistence, network or folder IO is simulated. Generated unattended as **design guidance, not interactive sign-off**. Static browser rendering is not native acceptance: actual content-point/backing-scale captures, keyboard/VoiceOver, focus restoration, larger system sizes, reduced motion and sandbox/distribution checks remain open in later F13 tasks.

### F13 static-reference validation evidence

Step 1.5 browser checks used Google Chrome 154.0.8037.58 in headless mode, device scale factor 1 (CSS pixels, **not native content points**). Commands: `python3 /tmp/kontrol-f13-validate.py`, `node /tmp/kontrol-f13-render.mjs`, and `git diff --check` from the repository root. The temporary validation harnesses are local evidence tools, not application dependencies.

- Link/token/index audit: 23 HTML files, 601 local HTML/CSS/Markdown references resolved; existing tokens/components linked on every page; peer chrome identical apart from active state; every state indexed in both navigators.
- Rendering: all 23 pages at 1000×700, 1440×940 and 520×340 (69 page/viewport checks), plus enlarged-text captures at 160% for all three widths. The enlarged reference normally renders at 130%. Document scrolling keeps audited controls reachable without horizontal overflow; standard audits found no missing stylesheet, clipped control or primary/navigation/form target below 32 CSS pixels.
- Evidence: `/tmp/kontrol-f13-step1.5-renders/audit.json`; each size has its own directory, e.g. `/tmp/kontrol-f13-step1.5-renders/520x340/20-compact-navigation.png`, `20-compact-navigation-full.png`, `21-enlarged-text-full.png`, and `21-enlarged-text-160-full.png`. Every page has a viewport PNG at its exact requested dimensions and a separate full-document PNG (variable height) to show below-fold actions.
- Representative screenshots were visually inspected: 1440×940 hub/navigator, 1000×700 removal confirmation/export preparation, and compact navigation/130% enlarged reflow. These checks validate the static references only; they do not close native comparison, keyboard, VoiceOver, sandbox or release acceptance.

## All 44 visual states

| ID | State | Owner |
| --- | --- | --- |
| M00 | [app-shell](M00-app-shell.png) | F00 |
| M01 | [store-recovery](M01-store-recovery.png) | F00 |
| M02 | [tasks](M02-tasks.png) | F02 |
| M03 | [task-editor](M03-task-editor.png) | F02 |
| M04 | [task-complete-reopen](M04-task-complete-reopen.png) | F02 |
| M05 | [task-delete](M05-task-delete.png) | F02 |
| M06 | [today](M06-today.png) | F03 |
| M07 | [schedule-editor](M07-schedule-editor.png) | F03 |
| M08 | [schedule-overlap](M08-schedule-overlap.png) | F03 |
| M09 | [quick-capture](M09-quick-capture.png) | F02 |
| M10 | [focus-ready](M10-focus-ready.png) | F04 |
| M11 | [focus-running](M11-focus-running.png) | F04 |
| M12 | [focus-paused](M12-focus-paused.png) | F04 |
| M13 | [focus-recovery](M13-focus-recovery.png) | F04 |
| M14 | [focus-history](M14-focus-history.png) | F04 |
| M15 | [learning-choices](M15-learning-choices.png) | F05 |
| M16 | [lesson-learn](M16-lesson-learn.png) | F06 |
| M17 | [lesson-code](M17-lesson-code.png) | F06 |
| M18 | [lesson-question](M18-lesson-question.png) | F06 |
| M19 | [lesson-design](M19-lesson-design.png) | F06 |
| M20 | [lesson-solution](M20-lesson-solution.png) | F06 |
| M21 | [lesson-completion-rotation](M21-lesson-completion-rotation.png) | F06 |
| M22 | [lesson-dismiss](M22-lesson-dismiss.png) | F06 |
| M23 | [learning-history](M23-learning-history.png) | F07 |
| M24 | [concept-coverage](M24-concept-coverage.png) | F07 |
| M25 | [generate-lesson](M25-generate-lesson.png) | F08 |
| M26 | [generation-failure](M26-generation-failure.png) | F08 |
| M27 | [projects](M27-projects.png) | F10 |
| M28 | [project-add](M28-project-add.png) | F09 |
| M29 | [project-details](M29-project-details.png) | F09 |
| M30 | [feature-detail](M30-feature-detail.png) | F10 |
| M31 | [feature-completion-undo](M31-feature-completion-undo.png) | F11 |
| M32 | [project-write-conflict](M32-project-write-conflict.png) | F11 |
| M33 | [project-validation-access](M33-project-validation-access.png) | F09 |
| M34 | [project-empty-blocked](M34-project-empty-blocked.png) | F10 |
| M35 | [news](M35-news.png) | F12 |
| M36 | [news-topics-feeds](M36-news-topics-feeds.png) | F12 |
| M37 | [news-offline](M37-news-offline.png) | F12 |
| M38 | [settings](M38-settings.png) | F13 |
| M39 | [ai-settings](M39-ai-settings.png) | F08 |
| M40 | [data-export](M40-data-export.png) | F13 |
| M41 | [remove-project](M41-remove-project.png) | F13 |
| M42 | [design-accessibility](M42-design-accessibility.png) | F01 |
| M43 | [learning-starter-summary](M43-learning-starter-summary.png) | F00 |
