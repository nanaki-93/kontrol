# QA and release gates

[Plan](../PLAN.md) · [Function → mockup index](mockups/INDEX.md)

This page defines feature and release gates. Observed native non-GUI results are recorded separately in the README's [F02 ledger](../README.md#f02-task-lifecycle-and-non-gui-gate-2026-09-28), [F03 ledger](../README.md#f03-manual-schedule-non-gui-gate-ledger-2026-09-28), [F04 ledger](../README.md#f04-focus-sessions-non-gui-gate-ledger-2026-09-28), [F05 ledger](../README.md#f05-structured-learning-catalog-implementation-gate-2026-09-28), [F06 ledger](../README.md#f06-lesson-experience-non-gui-gate-2026-09-29), and [F07 ledger](../README.md#f07-history-and-coverage-non-gui-gate-2026-09-29); they do not certify interactive acceptance.

## Feature gate

For each F00–F12: implement its checklist, compile the app and test bundles, run non-GUI domain/persistence/integration checks, and record actual results. **Defer interactive GUI acceptance to the final feature F13 release gate** when the desktop can be reserved for testing. This includes hosted SwiftUI/AX suites that open windows or sheets, keyboard-only and VoiceOver checks, live reduced-motion and enlarged-text checks, sandbox app-open/relaunch journeys, and screenshot comparisons against every linked mockup. Do not run those suites in shared GUI sessions, treat a skip as a pass, hide prior failures, or certify feature-wide UI acceptance before F13. Sample copy in images is not production data. Validate non-GUI empty/error/offline behavior where feasible using isolated unit tests. Tests should prove behavior or protect data, not mirror view implementation.

This is a **scheduling change, not a waiver**. At F13, reserve an active, uncontended GUI session and execute all deferred F00–F12 GUI acceptance (including any earlier hosted test failures) plus F13 UI checks. Keep a per-feature ledger of deferred checks, test names, mockups, sizes, platform/toolchain, and required screenshots; investigate and repair failures before final release. Previously approved implementation steps are not evidence that their deferred GUI checks passed. Run full `make test` only at the final gate; meanwhile use `build-for-testing` and explicit non-GUI test selections. Preserve failed and skipped evidence verbatim.

| Area | Required checks | Visual reference |
| --- | --- | --- |
| Startup | Fresh install, catalog seed, relaunch, failed migration without reset | [M00](mockups/M00-app-shell.png), [M01](mockups/M01-store-recovery.png) |
| Tasks | Blank title, cancel edit, complete/reopen, deletion with old focus link | [M03](mockups/M03-task-editor.png), [M05](mockups/M05-task-delete.png) |
| Schedule | End before start, overnight, time-zone shift, DST, exact-boundary versus real overlap | [M07](mockups/M07-schedule-editor.png), [M08](mockups/M08-schedule-overlap.png) |
| Focus | Pause excludes time; relaunch/sleep/clocks do not duplicate or inflate elapsed; repeated End | [M11](mockups/M11-focus-running.png)–[M14](mockups/M14-focus-history.png) |
| Learning | F05: 40 offline definitions, 4 stable slots per topic, read-only inspection, empty/error states; F06: drafts, attempts and one-slot replacement | [M15](mockups/M15-learning-choices.png), [F05 variants](../.mockups/screens/f05/index.html); F06 [M16–M22](mockups/INDEX.md) |
| History | Cosmetic rename, exact duplicate, same concept/different objective, catalog upgrade | [M23](mockups/M23-learning-history.png), [M24](mockups/M24-concept-coverage.png) |
| AI | Disabled/no key/offline, timeout/cancel, malformed/duplicate output, key removal | [M25](mockups/M25-generate-lesson.png), [M26](mockups/M26-generation-failure.png), [M39](mockups/M39-ai-settings.png) |
| Projects | Reopen bookmark, move/revoke folder, duplicate IDs, cycle, missing dependency, path escape | [M28](mockups/M28-project-add.png), [M33](mockups/M33-project-validation-access.png) |
| Completion | Minimal byte diff, atomic failure, concurrent editor, undo conflict, reread validation | [M31](mockups/M31-feature-completion-undo.png), [M32](mockups/M32-project-write-conflict.png) |
| News | RSS/Atom variants, malformed feed, entities, duplicates, missing date, offline cache | [M35](mockups/M35-news.png)–[M37](mockups/M37-news-offline.png) |
| Settings | Export parses; no key/bookmark; canceled save; disconnected folder left intact | [M38](mockups/M38-settings.png)–[M41](mockups/M41-remove-project.png) |
| Accessibility | Keyboard-only, VoiceOver, focus order, increased text, reduced motion | [M42](mockups/M42-design-accessibility.png) |

## F13 consolidated interactive GUI acceptance

- For F07, execute hosted `LessonExperiencePresentationTests`, `LearningPresentationTests`, affected Today/Focus/shell checks and full `make test` in the reserved GUI session. On isolated signed sandbox data offline test archived completion/dismissal, guarded Restore/drafts, topic/status/date-filtered History, Coverage concept/eligible lesson browsing, Today/Focus links and quit/relaunch persistence. Check keyboard/focus/VoiceOver, enlarged text/scrolling, reduced motion and macOS 14 runtime. Capture rendered [M23](mockups/M23-learning-history.png), [M24](mockups/M24-concept-coverage.png), [M21](mockups/M21-lesson-completion-rotation.png) and [F07 supplemental states](../.mockups/screens/f07/index.html) at **1000×700 and 1440×940 points** and record paths and differences. The [F07 non-GUI gate](../README.md#f07-history-and-coverage-non-gui-gate-2026-09-29) has no rendered pairs or interactive attestation; signing and compilation do not close these checks. Carry forward F06 hosted AX and F02 failures/skips.
- For F06, run hosted `LearningPresentationTests`, `LessonExperiencePresentationTests`, affected Today/Focus/shell presentation suites and full `make test` in the reserved GUI session. On isolated offline signed sandbox data exercise start/resume, exact-text save and navigation, reveal/acknowledge/complete, dismissal cancellation/confirmation, exhaustion, History/Restore, Today suggestions/Add to Today/linked blocks and Focus lesson links, then quit/relaunch; test close/deactivation/quit save failures and focus return. Verify keyboard-only operation, spoken VoiceOver, enlarged text/scrolling, reduced motion and **macOS 14** runtime. Capture and compare rendered M15–M22, M07, affected M06/M10/M23 and [supplemental F06 flow](../.mockups/flows/f06-lesson-experience/index.html) at **1000×700 and 1440×940 points** and record paths/differences. The [F06 non-GUI evidence](../README.md#f06-lesson-experience-non-gui-gate-2026-09-29) is not live/hosted approval; no F06 screenshots or live relaunch are claimed. Preserve earlier F02 hosted AX/sheet failures and skipped keyboard deletion, plus F03–F05 deferred runs, as open.
- For F05, run hosted `LearningPresentationTests` and the full `make test` in an active reserved GUI session. On isolated data inspect all five offline topic journeys, four persisted choices/topic, stored sections, fewer-than-four/empty and retryable read-error states without creating drafts, attempts or progress. Capture and compare rendered [M15](mockups/M15-learning-choices.png) and [read-only inspection, exhaustion and loading/read-failure variants](../.mockups/screens/f05/index.html) at **1000×700 and 1440×940 points**; record image paths/differences. Check keyboard-only topic/disclosure selection and focus, spoken VoiceOver labels/roles/selected state, enlarged text and scrolling, 32-point targets, reduced motion and macOS 14 runtime. Open the signed sandbox app offline on isolated data, quit/relaunch, verify stable slots and unchanged personal records. See the [F05 non-GUI gate](../README.md#f05-structured-learning-catalog-implementation-gate-2026-09-28); test compilation/signing is not interactive acceptance. F06–F08 answer/replacement/history/generation journeys are separate feature work.
- For F04, execute hosted `FocusPresentationTests` and the full GUI suite in a reserved session; on isolated data run signed **offline** Start/Pause/Resume/End/completion, window close/reopen, sleep/wake, quit/relaunch before/after the deadline, recovery Resume/End, task deletion and history. Capture rendered [M10–M14](mockups/INDEX.md) and [four F04 variants](../.mockups/screens/f04/index.html) at **1000×700 and 1440×940 points** and compare actual images against references. Inspect keyboard/focus, VoiceOver, enlarged text/scrolling, reduced motion and macOS 14 runtime. See the [F04 non-GUI gate and open checks](../README.md#f04-focus-sessions-non-gui-gate-ledger-2026-09-28); compilation, non-GUI tests and signing are not substitutes. F06 lesson linking and F13 persistent focus defaults remain future work.
- For F03, execute hosted Today/schedule editor/day-selection/overlap/deletion presentation checks; perform live CRUD, DST/travel browsing, multiple conflicts and signed offline sandbox relaunch with isolated data. Capture and compare rendered [M06–M09](mockups/INDEX.md) and the linked F03 endpoint/validation and multiple-conflict variants at 1000×700 and 1440×940; check keyboard, focus restoration, VoiceOver, scrolling, enlarged text, reduced motion and macOS 14 runtime. See the [F03 gate and outstanding evidence](../README.md#f03-manual-schedule-non-gui-gate-ledger-2026-09-28). F06 lesson suggestions/actions are still unimplemented and are not F03 GUI successes.
- Run every deferred hosted UI test suite (including `TaskPresentationTests` and the hosted portions of `QuickCaptureTests` for F02), the full test suite, and any GUI checks from F00/F01 previously considered complete. Revisit failures rather than reclassifying them as manual observations.
- Exercise keyboard-only actions and destructive confirmation, focus/AX naming and independence, Title focus and restoration, scrolling fields/actions, spoken VoiceOver, visible focus, 32-point targets, enlarged text and reduced motion in an active GUI session.
- Capture and compare every feature's linked mockups, including F02 M02–M05/M09, at 1000×700 and 1440×940 where applicable; record screenshots, observed differences, and whether a macOS 14 runtime was available.
- Open the signed sandbox build and complete each feature's interactive lifecycle/relaunch and failure journeys on isolated test data. Keep build/signature/entitlement checks in the implementing feature where they are noninteractive.
- Carry forward F02's intermittent hosted AX visibility and sheet-dismissal failures and the skipped native keyboard confirmation test as **open**, alongside any other deferred failures. A user attestation covers only checks it explicitly describes. Do not mark the release gate passed with unresolved failures or missing evidence.

## End-to-end user journeys

1. Capture a task → plan a block → run/pause/end focus → reopen app → verify persisted state and unchanged task completion.
2. Open each lesson format → type response → navigate away/back → reveal solution → complete → verify one replacement and one history entry.
3. Add the included sample project → open reader feature → mark complete → verify dependent history feature becomes eligible → undo → inspect the minimal disk diff.
4. Make an external edit while a feature is open → attempt completion → verify conflict prompt and no lost edit.
5. Select a news topic → refresh → disconnect network → relaunch → inspect cached headlines and last-refresh time.
6. Export data → validate schema → verify no credentials, folder grants or external project files were included.

## Release checklist

- [ ] Run supported macOS baseline and current target OS on a real Mac.
- [ ] Validate sandbox entitlements, selected folder write access and bookmark reuse in the packaged build, not only Xcode.
- [ ] Test the minimum 1000×700 desktop window and a 1440×940 reference window with text scaling.
- [ ] Check all seven destinations and each linked modal/error state visually.
- [ ] Confirm requests occur only for allowed news refreshes and explicitly enabled generation.
- [ ] Record tested toolchain, dependency versions, known limitations and installation steps.
- [ ] Sign and notarize if distributing outside the development machine.
- [ ] Keep Chess, GitHub, sync and News-to-Learning actions out of the V1 build.

## This package's validation

The package build checks that every function row points to an existing mockup, every relative Markdown link resolves, all 44 SVG sources render to PNG, and the archive contains the referenced paths. It does not verify native Swift behavior; that work belongs to the implementation gates above.
