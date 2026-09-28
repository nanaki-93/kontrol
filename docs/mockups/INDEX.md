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
| [F08](../features/F08-ai-expansion.md) | Configure, enable, test or remove provider key | [M39 · AI lessons](M39-ai-settings.png) |
| [F08](../features/F08-ai-expansion.md) | Generate a candidate | [M25 · Generate lesson](M25-generate-lesson.png) |
| [F08](../features/F08-ai-expansion.md) | Handle invalid, duplicate or failed generation | [M26 · Learning](M26-generation-failure.png) |
| [F09](../features/F09-local-projects.md) | Add a project folder | [M28 · Projects](M28-project-add.png) |
| [F09](../features/F09-local-projects.md) | Read project details, roadmap, context and rules | [M29 · Kontrol](M29-project-details.png) |
| [F09](../features/F09-local-projects.md) | Refresh, validate or reconnect | [M33 · Projects](M33-project-validation-access.png) |
| [F10](../features/F10-next-features.md) | Choose a project and next feature card | [M27 · Projects](M27-projects.png) |
| [F10](../features/F10-next-features.md) | Read full feature details | [M30 · Learning history](M30-feature-detail.png) |
| [F10](../features/F10-next-features.md) | No eligible features or all complete | [M34 · Kontrol](M34-project-empty-blocked.png) |
| [F11](../features/F11-feature-completion.md) | Mark feature complete and update cards | [M31 · Kontrol](M31-feature-completion-undo.png) |
| [F11](../features/F11-feature-completion.md) | Undo completion | [M31 · Kontrol](M31-feature-completion-undo.png) |
| [F11](../features/F11-feature-completion.md) | Recover from conflict or write failure | [M32 · Kontrol](M32-project-write-conflict.png) |
| [F12](../features/F12-news.md) | Filter topics, refresh and read at source | [M35 · News](M35-news.png) |
| [F12](../features/F12-news.md) | Select topics and add/edit/remove feed | [M36 · Topics & feeds](M36-news-topics-feeds.png) |
| [F12](../features/F12-news.md) | Offline, stale or failed refresh | [M37 · News](M37-news-offline.png) |
| [F13](../features/F13-settings-release.md) | Edit settings and focus default | [M38 · Settings](M38-settings.png) |
| [F13](../features/F13-settings-release.md) | Export local data | [M40 · Local data](M40-data-export.png) |
| [F13](../features/F13-settings-release.md) | Disconnect project folder | [M41 · Project folders](M41-remove-project.png) |
| [F13](../features/F13-settings-release.md) | Accessibility and release verification | [M42 · Appearance](M42-design-accessibility.png) |

## F05 departures from M15

[M15](M15-learning-choices.png) remains the normal-state composition reference: five topic choices in the sidebar and up to four stable lessons for the selected topic. The [F05 overview](../../.mockups/screens/f05/index.html) shows four representative Go choices with explicit objectives and concept labels, alongside the three states M15 does not depict. Its example content is illustrative, not a guarantee of slot ordering. [Inspection](../../.mockups/screens/f05/read-only-inspection.html) presents stored explanation, worked example, exercise prompt, reference response, and self-check as **read-only reference material**; opening it does not start work. [Exhaustion](../../.mockups/screens/f05/exhausted-empty.html) shows the real zero count rather than invented choices. [Loading / read failure](../../.mockups/screens/f05/loading-read-failure.html) distinguishes an in-progress read from a retryable error, neither of which means an empty catalog. M15's History/Coverage, replacement, and generation actions are not part of F05; no F06 attempt or completion workflow is depicted. Interactive behavior and rendered comparison remain deferred to F13.

## F06 supplemental flow boundaries

[Open the F06 navigator](../../.mockups/flows/f06-lesson-experience/index.html) for a choices/History hub, exercise → solution → completion path, and recovery / cross-feature branches. These static references supplement M16–M22, M07 and the *minimal* list/detail/Restore subset of M23; they do not replace the approved normal-state imagery. The F06 History has no F07 filters or coverage controls. Exhaustion shows real inventory and a Generate… **availability notice only**; provider setup, generation, validation, failures and any actual generated lesson are **F08-only** (M25–M26). The HTML links preview states, not working save/Restore/Focus actions. No interactive approval or rendered native acceptance is claimed for these new references.

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
