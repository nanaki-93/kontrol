# Kontrol — V1 implementation plan

Status: product and implementation plan · 27 September 2026

## Start here

This package is the full V1 implementation plan, with 14 feature specifications and 43 linked desktop mockups. The PNGs are precise implementation references; the three earlier concept pictures are retained separately for visual direction. Every page and user-facing function has a mapping in the index. This is a specification package, not a built Swift app.

- [All functions and their mockups](docs/mockups/INDEX.md)
- [Architecture, state and data contracts](docs/architecture.md)
- [Initial 40-lesson curriculum](docs/learning-curriculum.md)
- [QA and release gates](docs/qa.md)
- [Example .kontrol project](examples/.kontrol/project.yaml)
- [Today concept](docs/reference/today-concept.png) · [Projects concept](docs/reference/projects-concept.png) · [Learning concept](docs/reference/learning-concept.png)

For portable links, extract the ZIP before opening PLAN.md. The self-contained HTML guide can also be opened directly and includes all specification images.

### Feature index

| ID | Feature | Main visual |
| --- | --- | --- |
| F00 | [Bootstrap and persistence](docs/features/F00-foundation.md) | [M00 · Today](docs/mockups/M00-app-shell.png) |
| F01 | [Design system and interaction patterns](docs/features/F01-design-system.md) | [M42 · Appearance](docs/mockups/M42-design-accessibility.png) |
| F02 | [Tasks and quick capture](docs/features/F02-tasks.md) | [M02 · Tasks](docs/mockups/M02-tasks.png) |
| F03 | [Today and manual schedule](docs/features/F03-today-schedule.md) | [M06 · Today](docs/mockups/M06-today.png) |
| F04 | [Focus sessions](docs/features/F04-focus.md) | [M10 · Focus](docs/mockups/M10-focus-ready.png) |
| F05 | [Structured learning catalog](docs/features/F05-learning-catalog.md) | [M15 · Learning](docs/mockups/M15-learning-choices.png) |
| F06 | [Learning choices and lesson experience](docs/features/F06-lesson-experience.md) | [M16 · Context cancellation](docs/mockups/M16-lesson-learn.png) |
| F07 | [Learning history, deduplication, and coverage](docs/features/F07-history-coverage.md) | [M23 · History](docs/mockups/M23-learning-history.png) |
| F08 | [Optional AI lesson expansion](docs/features/F08-ai-expansion.md) | [M25 · Generate lesson](docs/mockups/M25-generate-lesson.png) |
| F09 | [Add and inspect a local project](docs/features/F09-local-projects.md) | [M28 · Projects](docs/mockups/M28-project-add.png) |
| F10 | [Next-feature cards](docs/features/F10-next-features.md) | [M27 · Projects](docs/mockups/M27-projects.png) |
| F11 | [Complete a project feature](docs/features/F11-feature-completion.md) | [M31 · Kontrol](docs/mockups/M31-feature-completion-undo.png) |
| F12 | [Topic news](docs/features/F12-news.md) | [M35 · News](docs/mockups/M35-news.png) |
| F13 | [Settings, accessibility, and V1 release](docs/features/F13-settings-release.md) | [M38 · Settings](docs/mockups/M38-settings.png) |

## Product promise

Kontrol helps answer three daily questions: **What should I do today? What should I learn next? What should I build next?** It is a calm, local-first macOS app for one person. The first release must work for tasks, planning, learning, focus, and local projects without an account or network connection. News and optional AI lesson expansion use the network when available.

## Scope and decisions

| In V1 | Deferred |
| --- | --- |
| Today: manual time blocks, due tasks, learning suggestions, quick capture | Calendar sync and an AI daily planner |
| Tasks and simple project-independent task lists | Team task management |
| Focus timer and session history | Global shortcuts and menu bar companion |
| Learning: five topics, four choices per topic, exercises, history, duplicate prevention, seeded catalog plus optional AI expansion | Spaced repetition, automatic code grading, achievements |
| Projects: select local folder, read `.kontrol`, show information and up to three next-feature cards, mark a feature complete | GitHub, branches, issues, PRs, CI, automated implementation |
| News: selected topics, RSS/Atom metadata, links to source sites | Article scraping, recommendation engine, “Learn about this” action |
| macOS, Swift, SwiftUI, SwiftData, local-first | Chess (V2), iPhone, iCloud sync, Windows/Linux |

The initial app has **Today, Focus, Learning, Projects, News, Tasks, Settings**. No account or server is required. No feature silently writes to a local repository: the Projects completion action is the single deliberate write to a selected project's `.kontrol/features/*.md` file.

### Stack and boundaries

- **UI:** SwiftUI, with a small shared design system and native macOS menus, window behavior, and keyboard navigation.
- **Local app data:** SwiftData for tasks, manual schedule blocks, focus sessions, lesson catalog and history, feed preferences and cached article metadata, and project references. Plan a schema migration whenever these models change.
- **Project data:** the selected folder's `.kontrol` files remain authoritative for project descriptions, roadmap, and feature status. Do not mirror those values as a second editable database. Store the folder bookmark and display preferences locally.
- **Files:** user-selected folder access via security-scoped bookmarks; scoped access is opened only around reads/writes and released afterward. Request read/write access because completion updates one file. Handle moved, stale, or revoked bookmarks by asking the user to select the folder again.
- **YAML:** use a parser adapter around Yams. Keep unknown frontmatter keys and Markdown body untouched when updating status. Validate schema before showing feature cards.
- **Networking:** URLSession for feeds and an optional lesson generator; offline cached content stays available. AI credentials, if configured, go in Keychain.
- **Architecture:** one app target, feature-oriented folders, small domain services and repository protocols; no separate service process.

```text
Kontrol/
  App/                App entry, navigation, dependency wiring
  DesignSystem/       Colors, typography, components
  Features/
    Today/  Tasks/  Focus/  Learning/  Projects/  News/  Settings/
  Domain/             Scheduling, lesson selection, feature selection
  Data/               SwiftData, ProjectFiles, Feeds, AI
  Resources/          Seed curriculum and initial feed catalog
```

## Milestones and order

| Milestone | Features | Usable result |
| --- | --- | --- |
| M0 — Foundation | F00, F01 | Navigable Mac app with persistent local data and final design tokens |
| M1 — Daily loop | F02, F03, F04 | Capture a task, plan the day, run a focus session |
| M2 — Learning loop | F05, F06, F07, F08 | Pick, practice, complete, replace, and find a lesson in history |
| M3 — Project loop | F09, F10, F11 | Open a local project, choose among next features, mark one complete |
| M4 — Companion + release | F12, F13 | Topic news, resilient offline behavior, packaged V1 |

Implement one vertical slice at a time. Each feature below has observable acceptance checks. For F00–F12, compile and run non-GUI checks per feature; defer hosted/interactive GUI acceptance, mockup screenshot comparison, keyboard/VoiceOver and live accessibility checks to the final F13 release gate in `docs/qa.md`. This is not a pass or a waiver of previously failed GUI tests. Keep a per-feature deferred-check ledger and reserve an uncontended GUI session for F13. The release gate also covers interactions between features.

---

## F00 — Bootstrap and persistence

**Detailed feature:** [F00 specification](docs/features/F00-foundation.md)  
**Own mockups:** [M00 · Today](docs/mockups/M00-app-shell.png) · [M01 · Kontrol](docs/mockups/M01-store-recovery.png)

**Depends on:** none.

**Build**

- Create a macOS SwiftUI app with a horizontal icon-and-label navigation bar matching the approved mockups, the seven destinations, a Settings scene, and app-level dependency wiring.
- Set the minimum macOS version supported by all chosen APIs before implementing models; record it in the README and Xcode project. Use a single SwiftData `ModelContainer` with in-memory configuration for previews and tests.
- Add a persistent store, model migration strategy, local error reporting, and launch checks. Do not make normal launch depend on a feed or AI request.
- Seed representative, explicitly labeled sample data only in previews. The real first launch starts with useful empty states and a starter lesson catalog.

**Done when:** the app launches, navigation works, persisted sample user actions survive a relaunch, and offline launch succeeds.

## F01 — Design system and interaction patterns

**Detailed feature:** [F01 specification](docs/features/F01-design-system.md)  
**Own mockups:** [M42 · Appearance](docs/mockups/M42-design-accessibility.png) · [M00 · Today](docs/mockups/M00-app-shell.png)

**Depends on:** F00.

**Build**

- Implement semantic tokens for background, sidebar, surface, raised surface, primary/secondary text, border, accent, success, and warning. Use color roles instead of hex values in feature views.
- Use the selected Black / Red Terminal direction. Keep legible text contrast, clear keyboard focus, reduced-motion behavior, and native controls where they improve accessibility.
- Use short labels and useful metadata. Remove explanatory subtitles, slogans, and repeated helper text from normal screens; show guidance only for empty states, errors, or decisions that need it. Add small, consistent outline icons beside navigation labels and common actions. Keep visible text labels for navigation and accessible labels for icon-only controls.
- Reusable components: page header, section header, next-action card, list row, status pill, empty state, confirmation/undo affordance, and loading/error states.
- Set top navigation in the approved order: Today, Learning, Projects, Focus, Tasks, News, Settings. Keep topic navigation inside Learning and folder navigation inside Projects.

**Done when:** every destination has a realistic empty or seeded state, usable keyboard focus, and layouts that work in a reasonably narrow Mac window.

## F02 — Tasks and quick capture

**Detailed feature:** [F02 specification](docs/features/F02-tasks.md)  
**Own mockups:** [M02 · Tasks](docs/mockups/M02-tasks.png) · [M03 · Tasks](docs/mockups/M03-task-editor.png) · [M04 · Completed](docs/mockups/M04-task-complete-reopen.png) · [M05 · Tasks](docs/mockups/M05-task-delete.png) · [M09 · Today](docs/mockups/M09-quick-capture.png)

**Depends on:** F00, F01.

**Data:** `Task(id, title, notes?, dueAt?, status, createdAt, completedAt?)`.

**Build**

- Add, edit, complete/reopen, and delete a personal task; allow optional due date and notes. Keep task entry short and fast.
- Show `Today`, `Upcoming`, and `Completed` task views. Quick capture on Today creates the same task model.
- Sort open tasks by due time, then creation time; persist stable IDs. Task completion updates Today immediately.
- Do not auto-create tasks from project feature files or learning lessons in V1.

**Done when:** a captured task can be found, edited, completed, and recovered after relaunch; overdue tasks remain visible rather than disappearing.

## F03 — Today and manual schedule

**Detailed feature:** [F03 specification](docs/features/F03-today-schedule.md)  
**Own mockups:** [M06 · Today](docs/mockups/M06-today.png) · [M07 · Today](docs/mockups/M07-schedule-editor.png) · [M08 · Today](docs/mockups/M08-schedule-overlap.png)

**Depends on:** F02. Add lesson suggestions and lesson actions after F06 is available.

**Data:** `ScheduleBlock(id, title, startAt, endAt, note?)`; references to suggested lessons stay stable by lesson ID.

**Build**

- Show the selected day, manual time blocks, and due/overdue tasks. After F06, add at most two learning suggestions drawn from active lesson slots.
- Add, move, edit, and remove manual blocks; show an overlap clearly without silently rewriting either block. Use the device's locale and time zone; store absolute timestamps.
- After F06, provide `Start now` and `Add to Today` on a lesson. The latter creates a local schedule block only after the user picks a time; no calendar event is created.
- Show a useful empty Today state and a visible path to quick capture.

**Done when:** planning and task changes survive relaunch and the selected day changes correctly across midnight/time zones. After F06, a suggested lesson also opens from Today.

## F04 — Focus sessions

**Detailed feature:** [F04 specification](docs/features/F04-focus.md)  
**Own mockups:** [M10 · Focus](docs/mockups/M10-focus-ready.png) · [M11 · Focus](docs/mockups/M11-focus-running.png) · [M12 · Focus](docs/mockups/M12-focus-paused.png) · [M13 · Focus](docs/mockups/M13-focus-recovery.png) · [M14 · Sessions](docs/mockups/M14-focus-history.png)

**Depends on:** F02; F03 and F06 for optional links.

**Data:** `FocusSession(id, startedAt, endedAt?, plannedSeconds, actualSeconds, state, taskId?, lessonId?)`.

**Build**

- Start a 25-minute default countdown; allow a duration choice, pause/resume, stop, and a completed-session record.
- Optionally link a task or lesson before starting. Store wall-clock start/end so reopening the app does not invent elapsed time; recover an interrupted session with a clear resume/end choice.
- Show recent sessions and today's total minutes. A session never auto-completes its linked task or lesson.

**Done when:** timer state remains coherent after the window closes/reopens, and pause, stop, and completion record the correct duration.

## F05 — Structured learning catalog

**Detailed feature:** [F05 specification](docs/features/F05-learning-catalog.md)  
**Own mockups:** [M15 · Learning](docs/mockups/M15-learning-choices.png)

**Depends on:** F00, F01.

**Data contract**

```text
Topic > Subtopic > Concept > Lesson
Lesson: id, title, objective, conceptIDs[], topicID, subtopicID,
        difficulty, type, estimatedMinutes, contentVersion,
        source(seed|generated), contentFingerprint
LessonProgress: lessonID, status(available|started|completed|dismissed),
                firstShownAt?, startedAt?, completedAt?, answer?
```

**Build**

- Seed a versioned catalog for Go, Java, System Design, Performance, and Security. Give each topic enough authored lessons to fill four slots and replace completed/dismissed lessons in an initial smoke test; avoid placeholder titles with no exercise.
- Create stable concept IDs and explicit learning objectives. Keep catalog content separate from personal progress so a seed update cannot reset completion history.
- Validate prerequisite references, unique IDs, allowed types, and expected sections at build/seed import time.

**Done when:** all five topics open offline, every initial choice has actual content, and reinstalling a newer catalog preserves existing lesson progress.

## F06 — Learning choices and lesson experience

**Detailed feature:** [F06 specification](docs/features/F06-lesson-experience.md)  
**Own mockups:** [M16 · Context cancellation](docs/mockups/M16-lesson-learn.png) · [M17 · Table-driven tests](docs/mockups/M17-lesson-code.png) · [M18 · Benchmarking Go](docs/mockups/M18-lesson-question.png) · [M19 · Design a rate limiter](docs/mockups/M19-lesson-design.png) · [M20 · Context cancellation](docs/mockups/M20-lesson-solution.png) · [M21 · Learning](docs/mockups/M21-lesson-completion-rotation.png) · [M22 · Learning](docs/mockups/M22-lesson-dismiss.png) · [M07 · Today](docs/mockups/M07-schedule-editor.png)

**Depends on:** F05.

**Build**

- Show **four active lesson choices per topic** where inventory permits. They span subtopics/formats when possible and show type, difficulty, estimated time, and concept labels.
- Lesson flow: explanation → worked example → exercise → solution/explanation → explicit `Complete`. Initial formats: Learn, Code, Question, Design. For Code, show an exercise and a reference solution; V1 does not execute untrusted code. For Design, use a written prompt and self-check rubric.
- Allow `Show another`; move that exact lesson out of active choices and record it as dismissed. Keep a route back to dismissed lessons in history without counting them as completed.
- Keep started work and any typed response after navigation/relaunch. Avoid giving a completion score that implies measured mastery.

**Done when:** starting and completing a lesson updates its status, fills the empty slot with an unseen choice, and the user can resume an unfinished lesson.

## F07 — Learning history, deduplication, and coverage

**Detailed feature:** [F07 specification](docs/features/F07-history-coverage.md)  
**Own mockups:** [M23 · History](docs/mockups/M23-learning-history.png) · [M24 · Coverage](docs/mockups/M24-concept-coverage.png) · [M21 · Learning](docs/mockups/M21-lesson-completion-rotation.png)

**Depends on:** F05, F06.

**Build**

- Store completed and dismissed lesson IDs permanently. History supports date and topic filters, a lesson detail view, and explicit distinction between `Completed` and `Dismissed`.
- Reject exact ID repeats; reject a matching normalized content fingerprint; reject candidates with the same primary objective and a high concept overlap against completed/dismissed content. Version edits to the same lesson keep the same stable ID.
- Choose from eligible seeded candidates using prerequisites, lower coverage subtopics, and stable tie-breaking. Four slots should be stable across launches and only change after completion, dismissal, or a catalog update.
- Show **coverage**, e.g. practiced concepts by subtopic and recent work, rather than a fake mastery percentage. Revisit/review is a separate, explicitly labeled future flow.

**Done when:** a renamed copy of a completed lesson is filtered by metadata, finishing one lesson rotates one slot, and history stays available after a catalog upgrade.

## F08 — Optional AI lesson expansion

**Detailed feature:** [F08 specification](docs/features/F08-ai-expansion.md)  
**Own mockups:** [M25 · Generate lesson](docs/mockups/M25-generate-lesson.png) · [M26 · Learning](docs/mockups/M26-generation-failure.png) · [M39 · AI lessons](docs/mockups/M39-ai-settings.png)

**Depends on:** F05–F07. This completes the agreed hybrid curriculum; it must never block the seeded offline flow.

**Build**

- Define `LessonGenerator.generate(request) -> CandidateLesson`; implement one configurable provider behind that interface. Store a user-supplied credential in Keychain, with clear disable/remove controls in Settings.
- Request a specific topic/subtopic/concept/difficulty/type; provide relevant completed concept IDs and objectives, not the entire personal history. Validate structured output, required exercise/solution, allowed concept IDs, length, and duplicate checks before saving locally.
- Generate only on an explicit action or when a topic's eligible seeded pool is exhausted and the user opts in. If generation fails or is unavailable, leave the current choices and explain why; do not silently replace a lesson.
- Save generated content and provenance locally so opening it later works offline. No AI grading in V1.

**Done when:** an opted-in user can add a valid unseen lesson, invalid/duplicate output is discarded, and the learning area still works with no provider or network.

## F09 — Add and inspect a local project

**Detailed feature:** [F09 specification](docs/features/F09-local-projects.md)  
**Own mockups:** [M28 · Projects](docs/mockups/M28-project-add.png) · [M29 · Kontrol](docs/mockups/M29-project-details.png) · [M33 · Projects](docs/mockups/M33-project-validation-access.png)

**Depends on:** F00, F01.

**Build**

- Select a folder, create a persistent security-scoped bookmark, and show project name, description, stack, goals, current focus, roadmap milestones, and feature completion count from `.kontrol`.
- Parse and validate `project.yaml`, `roadmap.yaml`, `features/*.md`. Display `context.md` and `rules.md` as optional read-only project notes. `history.yaml` may be shown when present; it is not a second status store in V1.
- Re-read on window activation or manual Refresh; never execute content from the project. Offer actionable errors for a missing `.kontrol`, duplicate IDs, malformed frontmatter, unreadable files, moved folder, and stale bookmark. Other projects remain usable if one fails.
- Store only the folder bookmark and local display preferences in SwiftData. The project files are the source of truth.

**Done when:** adding two local folders works, both reopen after relaunch, and a missing/malformed file has an understandable recovery path.

### `.kontrol` V1 contract

```text
project-root/
  .kontrol/
    project.yaml       # required
    roadmap.yaml       # optional but recommended
    context.md         # optional, read-only
    rules.md           # optional, read-only
    history.yaml       # optional, read-only in V1
    features/
      <feature-id>.md  # zero or more, frontmatter + Markdown body
```

```yaml
# .kontrol/project.yaml
schema_version: 1
id: melotrail
name: Melotrail
description: Local music creation app
stack: [Kotlin, Python]
goals:
  - Improve the quality of generated songs
current_focus: [arrangement]
```

```yaml
# .kontrol/roadmap.yaml
schema_version: 1
milestones:
  - id: core
    title: Core pipeline
    status: completed
  - id: arrangement
    title: Better arrangement
    status: active
```

```md
---
id: transitions
title: Smooth section transitions
status: ready
priority: high
effort: medium
depends_on: [structure]
areas: [arrangement]
completed_at:
---

Create musical transitions between arranged sections.

Acceptance:
- Keep the source melody recognizable.
- Avoid abrupt changes in rhythm and instrumentation.
```

Allowed feature states are `planned`, `ready`, `active`, `blocked`, `completed`; priority is `high`, `medium`, or `low`; effort is `small`, `medium`, or `large`. IDs are stable and unique within the project. A `depends_on` ID must exist in the same project. Unknown fields are preserved. Files with unsupported `schema_version` remain readable as raw text with a clear upgrade message, never rewritten blindly.

## F10 — Next-feature cards

**Detailed feature:** [F10 specification](docs/features/F10-next-features.md)  
**Own mockups:** [M27 · Projects](docs/mockups/M27-projects.png) · [M30 · Learning history](docs/mockups/M30-feature-detail.png) · [M34 · Kontrol](docs/mockups/M34-project-empty-blocked.png)

**Depends on:** F09.

**Build**

- Show up to **three** eligible cards for the selected local project. Eligible means `ready`, every dependency completed, and no explicit blocker. `planned` work stays in the roadmap until its file is explicitly made ready; completed and active work do not appear as next-feature candidates.
- Sort deterministically: current-focus area before others, then priority, effort (smaller first), and stable ID. Display a short reason: e.g. `Ready · dependency complete` or `Matches current focus`.
- Show the full feature description and acceptance notes on selection. If no feature is eligible, explain whether all are complete or dependencies/blockers prevent suggestions.
- Keep the candidate algorithm local. AI and GitHub do not invent roadmap items in V1.

**Done when:** identical files yield identical cards, changing dependency statuses updates eligibility, and a cycle or missing dependency becomes a validation error rather than a misleading card.

## F11 — Complete a project feature

**Detailed feature:** [F11 specification](docs/features/F11-feature-completion.md)  
**Own mockups:** [M31 · Kontrol](docs/mockups/M31-feature-completion-undo.png) · [M32 · Kontrol](docs/mockups/M32-project-write-conflict.png)

**Depends on:** F09, F10.

**Build**

- A visible `Mark complete` action changes the selected feature file's frontmatter `status` to `completed` and adds `completed_at` in ISO 8601 UTC. It updates only that file; preserve its body, comments, unknown frontmatter fields, and newline style.
- Read the file immediately before writing, detect an external edit since the card was loaded, and ask to refresh rather than overwrite it. Use coordinated, atomic replacement in the selected folder; show a failure without claiming completion if the write fails.
- Refresh progress and next-feature cards after success. Provide an `Undo` action that restores the previous status and removes `completed_at` when appropriate.
- Never edit source code, roadmap, git state, or GitHub as a side effect.

**Done when:** the on-disk Markdown change is minimal and reviewable, downstream features become eligible, undo works, and conflicting external edits are never lost.

## F12 — Topic news

**Detailed feature:** [F12 specification](docs/features/F12-news.md)  
**Own mockups:** [M35 · News](docs/mockups/M35-news.png) · [M36 · Topics & feeds](docs/mockups/M36-news-topics-feeds.png) · [M37 · News](docs/mockups/M37-news-offline.png)

**Depends on:** F00, F01.

**Data:** `NewsTopic`, `FeedSource`, `ArticleMetadata(id, title, source, url, publishedAt?, summary?, topicIDs[])`, `lastRefreshAt`.

**Build**

- Provide a short curated, editable feed list by selected topic (initially Go, Java, Software Engineering, Security, System Design, AI, Japan; optional Gaming and Anime). One feed can map to multiple topics.
- Fetch RSS/Atom over HTTPS, parse metadata, deduplicate by canonical URL/feed GUID, and store a limited recent cache. Make parsing robust to missing dates and malformed items; bound refresh and storage.
- Show source, title, date, topic and a short feed-provided summary where present. `Read` opens the original HTTPS article in the default browser. No full-page extraction or embedded reader.
- Refresh manually and opportunistically with sensible rate limits. Offline/error state shows cached entries and last-refresh time.

**Done when:** topic selection changes the list, duplicate feed entries appear once, links open their source, and News remains usable from cache while offline.

## F13 — Settings, accessibility, and V1 release

**Detailed feature:** [F13 specification](docs/features/F13-settings-release.md)  
**Own mockups:** [M38 · Settings](docs/mockups/M38-settings.png) · [M40 · Local data](docs/mockups/M40-data-export.png) · [M41 · Project folders](docs/mockups/M41-remove-project.png) · [M42 · Appearance](docs/mockups/M42-design-accessibility.png)

**Depends on:** all previous features.

**Build**

- Settings: the fixed Black / Red Terminal theme, focus default duration, news topics/feeds, optional AI provider credential and generation opt-in, project folder management, and local data export.
- Support VoiceOver labels, full keyboard navigation, visible focus, dynamic type where practical on macOS, reduced motion, and text plus color for status. Check text and focus contrast in the selected palette. Run and document all deferred F00–F12 hosted/interactive GUI tests and live acceptance (including outstanding failures), as specified in `docs/qa.md`.
- Add a simple export of user-owned app data (tasks, schedule, lesson progress, focus history, feed preferences) with a versioned format. Project files are already in their folders and are not included in that export.
- Package/notarize the Mac app after validating entitlements and bookmarks in a sandboxed build; write installation and local `.kontrol` authoring instructions.

**Done when:** a fresh install can complete the three core loops without a network connection; optional News/AI fail gracefully; a sandboxed packaged build can reopen and update a selected project.

## End-to-end release checks

1. **Today:** capture a task, add a time block, start a linked focus session, close and reopen the app; all state is correct.
2. **Learning:** select a Go lesson, enter an answer, view solution, complete it; one new eligible lesson appears, and the completed item is findable in history.
3. **Project:** add a folder containing the schema above, mark a ready feature complete, inspect the changed Markdown, verify a dependent card becomes eligible; relaunch and confirm the state persists from disk.
4. **Offline:** disconnect the network; tasks, Today, focus, project files, seed lessons, history, and cached news remain accessible. AI and news refresh show clear unavailable states.
5. **Failure paths:** malformed feature frontmatter, missing folder, stale bookmark, duplicate lesson ID, repeated article, AI duplicate output, and external project edit never corrupt existing state.

## Selected UI direction — Black / Red Terminal

Selected on 27 September 2026. Use fewer framed cards, mostly unframed lists, and a single strong next action per screen.

| Token | Value |
| --- | --- |
| Background | `#0B0B0D` |
| Surface | `#151214` |
| Primary text | `#E1DCDB` |
| Secondary text | `#AAA0A0` |
| Divider | `#3A2B2D` |
| Accent | `#D6676B` |

Use compact navigation, terminal-inspired typography, thin dividers, and small consistent outline icons. Red is reserved for the active location, primary actions, and a small number of status cues. Keep ordinary body text neutral and readable. Do not add decorative glow, textures, or unnecessary dashboard panels.

The usual screen should contain titles, action labels, and useful metadata only. For example, show `Go · 15 min`, `3 ready`, and `Mark complete`; omit explanations of how the app stores files or rotates lessons from the normal flow. Empty states and errors may provide concise guidance.

Use familiar icons: house for Today, book for Learning, folder for Projects, timer for Focus, check-square for Tasks, newspaper for News, and gear for Settings. Pair navigation icons with their labels. Provide accessible labels on standalone add, refresh, and overflow buttons.

## Deferred backlog

- **V1.1:** “Learn about this” from a news item; it proposes a mapped lesson only after explicit user action.
- **V2:** Chess tracking/training; GitHub account and repository metadata; review scheduling; optional calendar connection.
- **Later:** iPhone companion, sync, menu bar companion, generated planning, media tracking.

## Implementation references

- Apple: SwiftData `ModelContainer` and migrations — https://developer.apple.com/documentation/swiftdata/modelcontainer/
- Apple: macOS App Sandbox and user-selected files — https://developer.apple.com/documentation/security/accessing-files-from-the-macos-app-sandbox
- Apple: SwiftUI file importer and security scope — https://developer.apple.com/documentation/swiftui/view/fileimporter%28ispresented%3Aallowedcontenttypes%3Aallowsmultipleselection%3Aoncompletion%3Aoncancellation%3A%29
- Apple: `NSFileCoordinator` — https://developer.apple.com/documentation/foundation/nsfilecoordinator
- Yams project — https://github.com/jpsim/Yams

## Required implementation handoff

For each feature, read its linked specification, inspect every linked mockup, implement the checklist, and run non-GUI acceptance checks. Record the implementation gate separately from **deferred** interactive GUI acceptance; do not claim visual/keyboard/VoiceOver checks passed before F13. The final F13 task must run all deferred hosted tests and live GUI checks against every feature's mockups, resolve outstanding failures, and record evidence before release approval. Reuse shared components; do not hard-code sample dates, counts, article headlines or lesson content from the pictures. When a behavior needs a new visible state, add its mockup and update the function index in the same change.

Keep changes in one feature at a time. F03 can be delivered with tasks and blocks before F06; integrate lesson links after F06. F04 can initially link tasks only. F08 stays optional at runtime but is included in the full V1 build. No deadline estimates are promises; assess each vertical slice after its acceptance checks pass.
