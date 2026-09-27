# QA and release gates

[Plan](../PLAN.md) · [Function → mockup index](mockups/INDEX.md)

The deliverable is a plan and visual specification; none of the tests below are claimed to have passed in a native app yet.

## Feature gate

For each F00–F13: implement its checklist, run its own acceptance checks, compare the implemented state against every linked mockup, and record evidence in the PR/task. Sample copy in images is not production data. Validate empty, loading, error and offline outcomes where the feature uses IO. Tests should prove behavior or protect data, not mirror view implementation.

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

The package build checks that every function row points to an existing mockup, every relative Markdown link resolves, all 43 SVG sources render to PNG, and the archive contains the referenced paths. It does not verify native Swift behavior; that work belongs to the implementation gates above.
