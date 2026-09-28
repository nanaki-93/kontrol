# QA and release gates

[Plan](../PLAN.md) · [Function → mockup index](mockups/INDEX.md)

This page defines feature and release gates. Observed native non-GUI results are recorded separately in the README's [F02 ledger](../README.md#f02-task-lifecycle-and-non-gui-gate-2026-09-28) and [F03 ledger](../README.md#f03-manual-schedule-non-gui-gate-ledger-2026-09-28); they do not certify interactive acceptance.

## Feature gate

For each F00–F12: implement its checklist, compile the app and test bundles, run non-GUI domain/persistence/integration checks, and record actual results. **Defer interactive GUI acceptance to the final feature F13 release gate** when the desktop can be reserved for testing. This includes hosted SwiftUI/AX suites that open windows or sheets, keyboard-only and VoiceOver checks, live reduced-motion and enlarged-text checks, sandbox app-open/relaunch journeys, and screenshot comparisons against every linked mockup. Do not run those suites in shared GUI sessions, treat a skip as a pass, hide prior failures, or certify feature-wide UI acceptance before F13. Sample copy in images is not production data. Validate non-GUI empty/error/offline behavior where feasible using isolated unit tests. Tests should prove behavior or protect data, not mirror view implementation.

This is a **scheduling change, not a waiver**. At F13, reserve an active, uncontended GUI session and execute all deferred F00–F12 GUI acceptance (including any earlier hosted test failures) plus F13 UI checks. Keep a per-feature ledger of deferred checks, test names, mockups, sizes, platform/toolchain, and required screenshots; investigate and repair failures before final release. Previously approved implementation steps are not evidence that their deferred GUI checks passed. Run full `make test` only at the final gate; meanwhile use `build-for-testing` and explicit non-GUI test selections. Preserve failed and skipped evidence verbatim.

| Area | Required checks | Visual reference |
| --- | --- | --- |
| Startup | Fresh install, catalog seed, relaunch, failed migration without reset | [M00](mockups/M00-app-shell.png), [M01](mockups/M01-store-recovery.png) |
| Tasks | Blank title, cancel edit, complete/reopen, deletion with old focus link | [M03](mockups/M03-task-editor.png), [M05](mockups/M05-task-delete.png) |
| Schedule | End before start, overnight, time-zone shift, DST, exact-boundary versus real overlap | [M07](mockups/M07-schedule-editor.png), [M08](mockups/M08-schedule-overlap.png) |
| Focus | Pause excludes time; relaunch/sleep/clocks do not duplicate or inflate elapsed; repeated End | [M11](mockups/M11-focus-running.png)–[M14](mockups/M14-focus-history.png) |
| Learning | 4 stable slots, draft recovery, each format, one-slot replacement, pool exhaustion | [M15](mockups/M15-learning-choices.png)–[M22](mockups/M22-lesson-dismiss.png) |
| History | Cosmetic rename, exact duplicate, same concept/different objective, catalog upgrade | [M23](mockups/M23-learning-history.png), [M24](mockups/M24-concept-coverage.png) |
| AI | Disabled/no key/offline, timeout/cancel, malformed/duplicate output, key removal | [M25](mockups/M25-generate-lesson.png), [M26](mockups/M26-generation-failure.png), [M39](mockups/M39-ai-settings.png) |
| Projects | Reopen bookmark, move/revoke folder, duplicate IDs, cycle, missing dependency, path escape | [M28](mockups/M28-project-add.png), [M33](mockups/M33-project-validation-access.png) |
| Completion | Minimal byte diff, atomic failure, concurrent editor, undo conflict, reread validation | [M31](mockups/M31-feature-completion-undo.png), [M32](mockups/M32-project-write-conflict.png) |
| News | RSS/Atom variants, malformed feed, entities, duplicates, missing date, offline cache | [M35](mockups/M35-news.png)–[M37](mockups/M37-news-offline.png) |
| Settings | Export parses; no key/bookmark; canceled save; disconnected folder left intact | [M38](mockups/M38-settings.png)–[M41](mockups/M41-remove-project.png) |
| Accessibility | Keyboard-only, VoiceOver, focus order, increased text, reduced motion | [M42](mockups/M42-design-accessibility.png) |

## F13 consolidated interactive GUI acceptance

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
