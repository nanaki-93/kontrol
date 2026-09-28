# F13 — Settings, accessibility, and V1 release

**Depends on:** all previous features.

**Build**

- Settings: the fixed Black / Red Terminal theme, focus default duration, news topics/feeds, optional AI provider credential and generation opt-in, project folder management, and local data export.
- Support VoiceOver labels, full keyboard navigation, visible focus, dynamic type where practical on macOS, reduced motion, and text plus color for status. Check text and focus contrast in the selected palette.
- Add a simple export of user-owned app data (tasks, schedule, lesson progress, focus history, feed preferences) with a versioned format. Project files are already in their folders and are not included in that export.
- Package/notarize the Mac app after validating entitlements and bookmarks in a sandboxed build; write installation and local `.kontrol` authoring instructions.

**Done when:** a fresh install can complete the three core loops without a network connection; optional News/AI fail gracefully; a sandboxed packaged build can reopen and update a selected project.

## Function → mockup contract

| Function / page | Dedicated visual | Expected behavior |
| --- | --- | --- |
| Edit settings and focus default | [M38 · Settings](../mockups/M38-settings.png) | Apply changes locally; current running focus session keeps its original duration. |
| Export local data | [M40 · Local data](../mockups/M40-data-export.png) | Use a save dialog; versioned JSON excludes secrets and folder grants. |
| Disconnect project folder | [M41 · Project folders](../mockups/M41-remove-project.png) | Remove the bookmark only; leave every project file on disk. |
| Accessibility and release verification | [M42 · Appearance](../mockups/M42-design-accessibility.png) | Verify all screens with keyboard, VoiceOver, text scaling and reduced motion. |

## Implementation checklist

- [ ] Keep preferences typed and versioned; reuse feed/provider/project screens rather than duplicate business logic.
- [ ] Export schemaVersion, exportedAt, appVersion, tasks, blocks, learning definitions/progress, sessions, feed preferences and general preferences.
- [ ] Exclude Keychain data, bookmark blobs, diagnostics with sensitive paths, and external project contents.
- [ ] Write export to a temp file, validate JSON and then save; canceled export creates no artifact. Import/restore is deferred and must not be advertised.
- [ ] Reserve an active, uncontended GUI session and run the consolidated F00–F13 interactive GUI acceptance ledger in [qa.md](../qa.md): full/hosted suites, previously failed or skipped checks, keyboard and VoiceOver, enlarged text/reduced motion, live sandbox journeys/relaunch, and screenshot comparisons against all linked feature mockups. Fix failures rather than treating deferral as approval.
- [ ] Run the remaining release matrix in qa.md on a real Mac; signed/notarized distribution is a release step, not evidence this planning package is an app.

## Acceptance checks

- [ ] JSON export parses and contains the required fields with no credentials/bookmarks.
- [ ] Disconnecting a project changes no project files.
- [ ] The packaged sandboxed build can reopen and complete a feature in a selected folder.
- [ ] Every deferred F00–F12 GUI check has recorded results and evidence; full hosted test suites pass, including F02's outstanding AX visibility, sheet dismissal, and native alert keyboard confirmation; live keyboard/VoiceOver, reduced motion, text sizes, mockup comparisons, and macOS 14 runtime (if available) are independently recorded. Unavailable manual observations are labeled unavailable, never passed, and automatable failures remain release blockers.

## Visual references

![M38 · Settings](../mockups/M38-settings.png)

![M40 · Local data](../mockups/M40-data-export.png)

![M41 · Project folders](../mockups/M41-remove-project.png)

![M42 · Appearance](../mockups/M42-design-accessibility.png)

[Back to PLAN](../../PLAN.md) · [All screens](../mockups/INDEX.md) · [Data contracts](../architecture.md)
