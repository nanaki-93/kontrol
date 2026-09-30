# QA and release gates

[Plan](../PLAN.md) · [Function → mockup index](mockups/INDEX.md)

This page defines feature and release gates. Observed native non-GUI results are recorded separately in the README's [F02 ledger](../README.md#f02-task-lifecycle-and-non-gui-gate-2026-09-28), [F03 ledger](../README.md#f03-manual-schedule-non-gui-gate-ledger-2026-09-28), [F04 ledger](../README.md#f04-focus-sessions-non-gui-gate-ledger-2026-09-28), [F05 ledger](../README.md#f05-structured-learning-catalog-implementation-gate-2026-09-28), [F06 ledger](../README.md#f06-lesson-experience-non-gui-gate-2026-09-29), [F07 ledger](../README.md#f07-history-and-coverage-non-gui-gate-2026-09-29), [F08 ledger](../README.md#f08-optional-ai-lesson-expansion-non-gui-integration-gate-2026-09-29), [F09 ledger](../README.md#f09-local-projects-non-gui-integration-gate-2026-09-29), [F10 ledger](../README.md#f10-next-feature-cards-non-gui-integration-gate-2026-09-29), [F11 ledger](../README.md#f11-project-feature-completion-non-gui-implementation-gate-2026-09-30), and [F12 ledger](../README.md#f12-topic-news-non-gui-implementation-gate-2026-09-30); they do not certify interactive acceptance.

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
| Projects | Reopen bookmark, move/revoke folder, duplicate IDs, cycle, missing dependency, path escape | [M28](mockups/M28-project-add.png), [M29](mockups/M29-project-details.png), [M33](mockups/M33-project-validation-access.png), [F09 supplemental states](../.mockups/flows/f09-local-projects/index.html) |
| Completion | Minimal byte diff, atomic failure, concurrent editor, undo conflict, reread validation | [M31](mockups/M31-feature-completion-undo.png), [M32](mockups/M32-project-write-conflict.png) |
| News | RSS/Atom variants, malformed feed, entities, duplicates, missing date, offline cache | [M35](mockups/M35-news.png)–[M37](mockups/M37-news-offline.png) |
| Settings | Export parses; no key/bookmark; canceled save; disconnected folder left intact | [M38](mockups/M38-settings.png)–[M41](mockups/M41-remove-project.png) |
| Accessibility | Keyboard-only, VoiceOver, focus order, increased text, reduced motion | [M42](mockups/M42-design-accessibility.png) |

## F13 foundation regression ledger — Step 1.1 (2026-09-30, incomplete)

**Initial attempt: failed, not ready for approval; escalation update below.** This checkpoint verifies existing preferences, Focus, and accessibility behavior; it does not implement folder removal/export or certify hosted, native, sandbox, or distribution acceptance. The worktree was clean before inspection and after test execution. The cumulative task-1 review checklist contained no previous findings. No production sources, fixtures, test assertions, project membership, or plan checkboxes were changed.

### Environment and prerequisites

Commands run from the repository root (all completed successfully):

```sh
xcode-select -p
xcodebuild -version
xcrun swift --version
xcodebuild -list -project Kontrol.xcodeproj
sw_vers
uname -m
find . -name AGENTS.md -print
git submodule status
git status --short
```

Ancestor instruction checks covered `/`, `/Users`, `/Users/marcoandreose`, `/Users/marcoandreose/DEV`, and `/Users/marcoandreose/DEV/lab`; repository-wide enumeration found no `AGENTS.md`, and no submodule was listed. Toolchain: `/Applications/Xcode.app/Contents/Developer`, **Xcode 27.0 (27A266a)**, **Apple Swift 6.4 (swiftlang-6.4.0.34.1; swift-driver 1.168.6)**; **arm64 macOS 27.0 (26A428)**. Project listing resolved **Yams 5.4.0**, the `Kontrol` scheme, `Kontrol`/`KontrolTests` targets, and Debug/Release configurations. Swift 5 language mode/macOS 14 deployment remain existing project settings, not evidence of a macOS 14 runtime.

Preflight at **08:00:55 UTC** found console user `marcoandreose`, one screen, a logged-in on-console session, and no competing xcodebuild/xctest/Kontrol process (only the system testmanagerd). The following shell probe reported `AXIsProcessTrusted=true`; it was repeated at 08:02:26 UTC. Frontmost app was `com.microsoft.rdc.macos`. These observations do **not** establish AX permission for the unsigned Kontrol test host or a human-reserved/uncontended desktop for consolidated GUI acceptance:

```sh
/usr/bin/stat -f '%Su' /dev/console
pgrep -alf 'xcodebuild|xctest|Kontrol.app|testmanagerd'
/usr/bin/swift -e 'import AppKit; import ApplicationServices; print("AXIsProcessTrusted=\(AXIsProcessTrusted())"); print("session=\(String(describing: CGSessionCopyCurrentDictionary()))"); print("frontmost=\(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "none")"); print("screens=\(NSScreen.screens.count)")'
```

Recorded toolchain/preflight output: `/tmp/kontrol-f13-step1.1-toolchain.log` (08:02:26 UTC repeat). No instruction installation or visual redesign was performed.

### Required verification and result audit

The plan's `f13_test` helper expanded to the following command, run with `set -o pipefail` and output piped through `tee /tmp/kontrol-f13-step1.1-tests.log`:

```sh
xcodebuild -project Kontrol.xcodeproj -scheme Kontrol \
  -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath /tmp/kontrol-f13-derived \
  -parallel-testing-enabled NO CODE_SIGNING_ALLOWED=NO \
  -only-testing:KontrolTests/AppPreferencesRepositoryTests \
  -only-testing:KontrolTests/AppPreferencesStoreTests \
  -only-testing:KontrolTests/FocusPreferencesTests \
  -only-testing:KontrolTests/FocusTimingTests \
  -only-testing:KontrolTests/FocusServiceTests \
  -only-testing:KontrolTests/DesignSystemComponentTests \
  -only-testing:KontrolTests/DesignSystemTokenTests test
```

**Exit 65, `TEST FAILED`.** Fresh result: `/tmp/kontrol-f13-derived/Logs/Test/Test-Kontrol-2026.09.30_16-01-30-+0800.xcresult` (08:01:30 UTC). Tests ran 08:01:32–08:01:34 UTC. Result-bundle audit commands (exit 0):

```sh
xcrun xcresulttool get test-results summary --path '/tmp/kontrol-f13-derived/Logs/Test/Test-Kontrol-2026.09.30_16-01-30-+0800.xcresult' --format json > /tmp/kontrol-f13-step1.1-summary.json
xcrun xcresulttool get test-results tests --path '/tmp/kontrol-f13-derived/Logs/Test/Test-Kontrol-2026.09.30_16-01-30-+0800.xcresult' --format json > /tmp/kontrol-f13-step1.1-test-tree.json
```

A Python audit walked every `Test Case` node, compared its method identifier against every `func test…` in each selected source, and checked the summary totals; **all seven selectors actually executed all their source methods**, with no extra/empty selection. Counts and all 22 failing identifiers/messages are preserved in `/tmp/kontrol-f13-step1.1-selector-audit.log`. Audit passed; the test gate did not.

| Selected suite | Executed | Passed | Failed | Skipped |
| --- | ---: | ---: | ---: | ---: |
| AppPreferencesRepositoryTests | 17 | 17 | 0 | 0 |
| AppPreferencesStoreTests | 13 | 13 | 0 | 0 |
| FocusPreferencesTests | 7 | 7 | 0 | 0 |
| FocusTimingTests | 16 | 16 | 0 | 0 |
| FocusServiceTests | 29 | 29 | 0 | 0 |
| DesignSystemComponentTests | 22 | 0 | 22 | 0 |
| DesignSystemTokenTests | 7 | 7 | 0 | 0 |
| **Total** | **111** | **89** | **22** | **0** |

Expected failures: **0**. All component failures report `XCTUnwrap failed: expected non-nil value of type "AXUIElementRef"`: 20 at the common title-based window lookup (`DesignSystemComponentTests.swift:31`), keyboard focus at `:407`, and native confirmation at `:691`. They fail **before** the intended component/scene/sheet assertions, so none of those behaviors is validated by this run. Shell AX trust is not a diagnosis of these failures; host authorization, activation, and window registration/timing require investigation.

### Inspected contracts and acceptance coverage

- **Duration parsing:** `FocusDuration.seconds()` trims surrounding whitespace, accepts positive ASCII whole minutes, checks decimal parsing and multiplication overflow, and preserves presets 15/25/50. Repository/timing tests passed for custom values, leading zeros/whitespace, `Int.max / 60`, overflow, and rejected signs/decimals/exponents/non-ASCII digits. No smaller limit was introduced.
- **Revision publication and drafts:** the repository uses a fresh non-autosaving context, validates the authoritative revision, saves before returning its receipt, and rolls back failure. Store publication uses that receipt without a post-save read. Independent editor baselines/inputs survive shared publications, stale saves, failed saves, and failed review. Explicit successful review retains input and authorizes only a separately revision-checked save. The corresponding repository/store regressions passed.
- **Focus transitions/session isolation:** following drafts adopt readable defaults; even reselecting the current default is an override. Submission freezes duration and link for failed-Start retry; reset uses the latest readable default, and unavailable preferences use an identified 25-minute fallback. The selected Focus tests passed for task-linked submitted retry, full-range timing, and unchanged running/paused/recovered/completed/ended persisted rows after preference commits. Source inspection also found task/lesson selection mutually exclusive and neither cleared by `followPreferences`; a dedicated preference-change/failed-Start **lesson-link** regression remains to be added before declaring that branch covered.
- **Accessibility resolver:** `AppAccessibilityPreferences.resolve` combines app/system reduction with OR and uses `max(systemTextSize, .xxLarge)` for Large. Store tests passed the motion truth table, all 12 system text sizes, idempotence, and unreadable/unsaved-value behavior. Token tests passed typography scaling, off-window glyph sizing, text contrast ≥4.5:1 and essential boundaries ≥3:1. These are not spoken VoiceOver or live visual acceptance.
- **Both ready roots:** inspected `KontrolApp.swift:169,213`; main and native Settings install the resolver using the same graph-owned preferences store. Sheets inherit effective inputs. The real-root shared typography, native controls/metrics, and live sheet tests were selected but failed at AX lookup, leaving their intended assertions **unverified**.

### Required narrow repair before continuing

Stay on Step 1.1. Investigate the test-host AX/activation/window-readiness boundary, establish host-specific permission in an active uncontended GUI session, and make any necessary **narrow hosted harness repair** while preserving all behavior assertions (no skip/reclassification). Rerun the exact seven-suite selection and audit a fresh bundle. If those assertions expose a production behavior defect, introduce a separate behavior-plus-regression repair before later F13 implementation; do not infer 22 production defects from missing AX windows. Add the submitted lesson-link regression in `FocusPreferencesTests.swift` to complete link coverage.

Also preserve and investigate the passing repository suite's runtime diagnostic at 08:01:32.198 UTC: `BUG IN CLIENT OF libsqlite3.dylib: database integrity compromised by API violation: vnode unlinked while in use` for a temporary `KontrolPreferencesRepository-…/Kontrol.store-shm` file. Test cleanup already uses autoreleasepool; coordinator lifetime/cleanup remains unresolved and is not proof of production or checked-in fixture corruption. The original test log is retained. Other diagnostics include linkd/AppIntents connection failures and the arm64/x86_64 destination warning.

`git diff --check` passed (exit 0; `/tmp/kontrol-f13-step1.1-diffcheck.log`); `git status --short` lists only `docs/qa.md`. Changes remain uncommitted.

No separate `make build`/`build-for-testing` was required or run: this attempt changed only this ledger, not production sources, test membership, or protocols; xcodebuild's required test action built/validated its existing host and test bundle before executing. Full `make test`, native captures/comparisons, VoiceOver, live reduced-motion/layout journeys, signed sandbox journeys, macOS 14 runtime, Developer ID signing and notarization remain **unverified**, not passes. Historical F02/F06 failures/skips and F11 fixture concerns below remain open. No release approval or human attestation is claimed.

### Step 1.1 escalation repair (08:09–08:17 UTC; still incomplete)

**Required gate remains FAILED; do not advance or approve Step 1.1.** Read the prior execution stdout, both execution sessions, latest failed-review feedback, and cumulative checklist. They contain one actual seven-suite run and repeated unresolved findings, not three independent passing/failing validations. Preserved the initial ledger/evidence above. At takeover only `docs/qa.md` was modified; the ancestor/repository rules rescan again found no applicable `AGENTS.md` or submodule. Repeated `xcode-select -p`, `xcodebuild -version`, `xcrun swift --version`, and `xcodebuild -list -project Kontrol.xcodeproj` all passed with the same toolchain/Yams versions above. No production source, schema, fixture, membership, workflow state, or plan checkbox changed.

#### Diagnosis and narrow repairs

- **AX root cause now measured inside the host:** the single action test with a two-second title-based wait returned `AXWindows status=0`, `trusted=false`, `active=false`, `running=true`, `visible=true`, `key=false`, AX titles `[]`, while AppKit listed both Kontrol and the inspection window. Explicit activation/order-front plus the same wait did not change that result. This disproves shell trust as sufficient evidence and a short readiness delay as the sole cause. Diagnostic commands used the exact xcodebuild flags above with only `-only-testing:KontrolTests/DesignSystemComponentTests/testActionVariantsAreNativeNamedButtonsWithTargetsAndSingleCallbacks`; both exited **65**, one failure each. Logs: `/tmp/kontrol-f13-escalation-ax-diagnostic.log`, `/tmp/kontrol-f13-escalation-ax-activation.log`; bundles: `Test-Kontrol-2026.09.30_16-09-15-+0800.xcresult` and `Test-Kontrol-2026.09.30_16-10-28-+0800.xcresult` under `/tmp/kontrol-f13-derived/Logs/Test/`.
- **Hosted harness:** `KontrolTests/DesignSystemComponentTests.swift` now checks host-specific trust **before constructing hosting windows**, provides an actionable prerequisite failure, and uses bounded window-readiness/error diagnostics plus explicit activation for common, keyboard, real-root, and confirmation fixtures. All original component, sheet, scene, action-count, geometry, and focus assertions remain. No `XCTSkip`, expected failure, alternate AppKit-only assertion, or TCC modification was introduced. A guard after window construction exposed SwiftUI `InvalidTransition { phase: idle; targetPhase: failed(deinit) }` in the interim 16:13:24 run. A setup-level throwing guard then made XCTest additionally mark 22 bodies skipped in the interim 16:14:30 run. Both approaches were replaced by pre-construction, test-body checks; the final audited run has **22 prerequisite failures, no skips, and no InvalidTransition**. Neither interim run is credited as a pass.
- **Submitted lesson-link coverage:** `KontrolTests/FocusPreferencesTests.swift` adds a real-repository failed-Start/retry regression using an isolated bundled catalog and durable preference commits. It verifies 37 minutes and the lesson ID survive a new 50-minute preference and unreadable preferences, unavailable inventory does not silently unlink, retry creates exactly one linked session/title snapshot, Learning remains unchanged with no opened attempt, and reset uses the latest default with cleared links. This new method passed in the required run and independent non-GUI rerun.
- **SQLite cleanup:** the old helper unlinked temporary stores immediately after autoreleasepool, despite Core Data/SQLite worker-owned handles outliving the test-owned values. `KontrolTests/AppPreferencesRepositoryTests.swift` now retains UUID-isolated stores in an explicitly printed process-owned temporary root until the host exits. It preserves every reopen, byte-integrity, stale-save, and rollback assertion; no sleep/private SwiftData close API or production cleanup was added. Post-host cleanup below verified all **60 stores in four process roots** with SQLite `PRAGMA integrity_check=ok`, then removed only those logged roots after confirming their PIDs had exited. All four repaired repository runs passed; their logs contain **no `vnode unlinked while in use` warning**. This is a test-fixture lifecycle repair, not certification of historical fixtures or production storage.

#### Final commands/results and evidence

The required command is the same seven-selector expansion printed above, executed via the plan's unchanged `f13_test` helper:

```sh
f13_test AppPreferencesRepositoryTests AppPreferencesStoreTests FocusPreferencesTests FocusTimingTests FocusServiceTests DesignSystemComponentTests DesignSystemTokenTests
# Supplemental non-GUI repeat, not a substitute for the required gate:
f13_test AppPreferencesRepositoryTests AppPreferencesStoreTests FocusPreferencesTests FocusTimingTests FocusServiceTests DesignSystemTokenTests
make build DERIVED_DATA=/tmp/kontrol-f13-derived
xcodebuild -project Kontrol.xcodeproj -scheme Kontrol \
  -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath /tmp/kontrol-f13-derived CODE_SIGNING_ALLOWED=NO build-for-testing
git diff --check
```

| Suite | Required run passed / selected | Supplemental passed / selected |
| --- | ---: | ---: |
| AppPreferencesRepositoryTests | 17 / 17 | 17 / 17 |
| AppPreferencesStoreTests | 13 / 13 | 13 / 13 |
| FocusPreferencesTests | 8 / 8 | 8 / 8 |
| FocusTimingTests | 16 / 16 | 16 / 16 |
| FocusServiceTests | 29 / 29 | 29 / 29 |
| DesignSystemComponentTests | 0 / 22 — host prerequisite failures | Not selected |
| DesignSystemTokenTests | 7 / 7 | 7 / 7 |
| **Total** | **90 / 112; 22 failed, 0 skipped** | **90 / 90; 0 failed, 0 skipped** |

- **Required command exit 65:** `/tmp/kontrol-f13-escalation-gate.log`; result `/tmp/kontrol-f13-derived/Logs/Test/Test-Kontrol-2026.09.30_16-15-19-+0800.xcresult`. All 22 failures are `DesignSystemAXPrerequisite`, code `-25211`: host `trusted=false`, `active=false`. Their intended behavior assertions remain unverified.
- **Supplemental command exit 0:** `/tmp/kontrol-f13-escalation-nongui.log`; result `/tmp/kontrol-f13-derived/Logs/Test/Test-Kontrol-2026.09.30_16-16-31-+0800.xcresult`.
- Audited both bundles using `xcrun xcresulttool get test-results {summary,tests} --path <result above> --format json`, then a Python source-method/selector/count audit. Outputs: `/tmp/kontrol-f13-escalation-{summary,tests}.json`, `/tmp/kontrol-f13-escalation-selector-audit.log`, `/tmp/kontrol-f13-escalation-nongui-{summary,tests}.json`, `/tmp/kontrol-f13-escalation-nongui-audit.log`. Every selected source method is accounted for; both have zero expected failures. Audit success does not turn the required gate green.
- **Build, final build-for-testing, whitespace checks exit 0:** `/tmp/kontrol-f13-escalation-build.log`, `/tmp/kontrol-f13-escalation-final-bft.log`, `/tmp/kontrol-f13-escalation-diffcheck.log`. The test action also compiled the final test changes. No added test membership/protocol or production changes required separate project edits.
- Interim seven-selector evidence is retained at `Test-Kontrol-2026.09.30_16-13-24-+0800.xcresult` and `Test-Kontrol-2026.09.30_16-14-30-+0800.xcresult`; logs `/tmp/kontrol-f13-escalation-required.log` and `/tmp/kontrol-f13-escalation-final-required.log`.

For future runs, retain the xcodebuild output as `TEST_LOG` and clean the **printed process-owned roots only after xcodebuild/test-host exit**. Direct Xcode execution intentionally retains these small isolated stores until the same post-host cleanup is performed. This command does not delete other historical fixtures or unlogged temporary directories:

```sh
# Set TEST_LOG to the completed run's output log; never to a live stream.
TEST_LOG=/tmp/kontrol-f13-escalation-nongui.log python3 - <<'PY'
import os, re, shutil
from pathlib import Path
lines = Path(os.environ['TEST_LOG']).read_text().splitlines()
roots = {line.split(': ', 1)[1] for line in lines
         if line.startswith('Preferences test store cleanup after host exit: ')}
assert roots
for path in sorted(roots):
    root = Path(path)
    assert re.fullmatch(r'KontrolPreferencesTests-\d+', root.name)
    assert root.parent.resolve() == Path(os.environ['TMPDIR']).resolve()
    assert not root.is_symlink()
    pid = int(root.name.rsplit('-', 1)[1])
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        pass
    else:
        raise RuntimeError(f'Refusing cleanup for live/reused PID {pid}')
    if root.exists():
        shutil.rmtree(root)
    print('Cleaned after host exit:', root)
PY
```

Actual cleanup (including integrity checks before removal): `python3 /tmp/kontrol-f13-escalation-cleanup.py`, exit 0, `/tmp/kontrol-f13-escalation-cleanup.log`. Enumerated 15 isolated stores each under `$TMPDIR/KontrolPreferencesTests-{69265,69459,69721,70242}`; all four exact roots no longer exist. Original prior-attempt evidence remains untouched.

**Outstanding external prerequisite:** a human must reserve an active uncontended desktop and authorize Accessibility for **`/private/tmp/kontrol-f13-derived/Build/Products/Debug/Kontrol.app`**, not just Terminal/the shell. Host activation must also succeed. Then rerun the exact seven-suite command and audit a fresh bundle; if component assertions fail, repair that same Step 1.1 contract before later tasks. No macOS privacy database manipulation, approval attestation, or spoken VoiceOver/native/release success is claimed. Required test failures mean this repair is **not ready for review**, even though lesson coverage, cleanup, compilation, and the non-GUI checks pass. Changes remain uncommitted and limited to the three test files above and this ledger; all initial partial work is preserved.

### Step 1.1 second escalation revalidation (08:22 UTC; required gate still FAILED)

Read both supplied execution stdout files, both failed-feedback files, and the cumulative checklist before editing. Confirmed Step 1.1 is the first incomplete task. Inspected the four existing modified files and preferences/Focus/resolver sources; no applicable ancestor or target-subdirectory `AGENTS.md` was found. **This attempt changes only this ledger**, preserving all three prior test repairs and unrelated work. No new production defect was demonstrated, and no safe code change can grant macOS host authorization or reserve the desktop. Do not advance to another task.

Unlike the initial ledger-only attempt, this revalidation audits the repaired on-disk tests and actual host identity. The required seven-suite command below (same plan helper/flags as the expansion above) ran again, **exit 65**:

```sh
f13_test AppPreferencesRepositoryTests AppPreferencesStoreTests FocusPreferencesTests FocusTimingTests FocusServiceTests DesignSystemComponentTests DesignSystemTokenTests
```

Fresh result: **`/tmp/kontrol-f13-derived/Logs/Test/Test-Kontrol-2026.09.30_16-22-46-+0800.xcresult`**; output `/tmp/kontrol-f13-escalation2-gate.log`. **112 executed: 90 passed, 22 failed, 0 skipped, 0 expected failures.** Suite counts match the preceding required-run table. All 22 failures are `DesignSystemAXPrerequisite Code=-25211`, with **`host trusted=false, active=false`**, before the intended component assertions. The retained pre-guard activation diagnostic `/tmp/kontrol-f13-escalation-ax-activation.log` independently shows visible AppKit windows but no AX windows after activation/wait. Authorization and successful activation remain prerequisites; authorization alone is not a promise that all assertions will pass.

Fresh environment checks (`xcode-select -p`, `xcodebuild -version`, `xcrun swift --version`, `xcodebuild -list -project Kontrol.xcodeproj`) passed with unchanged Xcode 27.0/Swift 6.4/Yams 5.4.0. Host inspection command `codesign -dv --verbose=4 /private/tmp/kontrol-f13-derived/Build/Products/Debug/Kontrol.app` reports a **linker ad-hoc signature, no TeamIdentifier/internal requirements** under the required unsigned build flags; no stable signed identity or host permission is inferred from shell trust. Shell probe still reports trust, one screen and an on-console session, with `com.microsoft.rdc.macos` frontmost. There is no human attestation of an uncontended desktop. Evidence: `/tmp/kontrol-f13-escalation2-environment.log`. No privacy database, entitlements, signing configuration, test assertions, or workflow state was changed.

Previous outstanding findings checked individually:

- **Submitted lesson-link/failed-Start coverage:** the added regression passed again (all eight `FocusPreferencesTests` passed); duration/links, retry, unchanged Learning, and reset assertions are retained.
- **SQLite fixture lifetime:** all 17 repository tests passed, no `vnode unlinked while in use` or `InvalidTransition` diagnostic in the fresh log. After PID **72326** exited, enumerated all **15** stores under the exact logged `$TMPDIR/KontrolPreferencesTests-72326` root, checked each with read-only SQLite `PRAGMA integrity_check` (**all `ok`**), closed connections, then removed that root. Evidence: `/tmp/kontrol-f13-escalation2-cleanup.log`. No live, historical, or checked-in store was deleted.
- **Hosted AX gate:** unresolved, not skipped/reclassified. No component/scene/sheet, spoken VoiceOver, native visual, or release approval is claimed.

Automated audit commands (exit 0):

```sh
xcrun xcresulttool get test-results summary --path /tmp/kontrol-f13-derived/Logs/Test/Test-Kontrol-2026.09.30_16-22-46-+0800.xcresult --format json
xcrun xcresulttool get test-results tests --path /tmp/kontrol-f13-derived/Logs/Test/Test-Kontrol-2026.09.30_16-22-46-+0800.xcresult --format json
make build DERIVED_DATA=/tmp/kontrol-f13-derived
xcodebuild -project Kontrol.xcodeproj -scheme Kontrol -configuration Debug -destination 'platform=macOS' -derivedDataPath /tmp/kontrol-f13-derived CODE_SIGNING_ALLOWED=NO build-for-testing
git diff --check
```

Summary/tree outputs: `/tmp/kontrol-f13-escalation2-{summary,tests}.json`. Python source-method/selector audit confirms every method in every selected suite ran exactly once and counts/failure identities agree with the summary: `/tmp/kontrol-f13-escalation2-selector-audit.log`. Builds passed; logs `/tmp/kontrol-f13-escalation2-{build,bft}.log`. Whitespace check passed. The prior supplemental six-suite pass remains historical; this attempt's 90 passes come from the fresh required run, not a substituted non-GUI command.

**Required next action on this same task:** a human must reserve the active desktop and authorize the actual test host `/private/tmp/kontrol-f13-derived/Build/Products/Debug/Kontrol.app` in System Settings → Privacy & Security → Accessibility. Then rerun the unchanged seven-suite command and audit a fresh result; diagnose activation/behavior failures if any remain. This unattended attempt cannot safely supply that approval. Because the required command actually failed, its reported status remains **REPAIR / FAILED**, with an external prerequisite, rather than READY or a fabricated pass. All changes remain uncommitted.

### Step 1.1 user-authorized Accessibility deferral (08:36 UTC)

The user explicitly requested: **“i'll do the accessibility test later”**. Hosted `DesignSystemComponentTests` are therefore deferred for this follow-up, not converted to skips, passes, or expected failures. This is a scheduling decision, **not an attestation that any Accessibility check passed**. The prior seven-suite failures above remain historical evidence; the plan and completion checkbox are unchanged.

Non-GUI repairs revalidated with the unchanged plan helper, omitting only the deferred hosted suite:

```sh
f13_test AppPreferencesRepositoryTests AppPreferencesStoreTests FocusPreferencesTests FocusTimingTests FocusServiceTests DesignSystemTokenTests
git diff --check
```

Both commands exited **0**. Fresh result: `/tmp/kontrol-f13-derived/Logs/Test/Test-Kontrol-2026.09.30_16-36-05-+0800.xcresult`; log `/tmp/kontrol-f13-user-deferred-nongui.log`. **90 passed, 0 failed, 0 skipped, 0 expected failures** (17 repository, 13 store, 8 Focus preferences, 16 timing, 29 Focus service, 7 token tests). The submitted lesson-link regression and all duration/draft/session/resolver regressions pass. Result-summary/tree audit confirms every selected source method executed exactly once; outputs `/tmp/kontrol-f13-user-deferred-{summary,tests}.json`, audit `/tmp/kontrol-f13-user-deferred-audit.log`. No SQLite unlink or InvalidTransition diagnostic occurred. After PID 75788 exited, all 15 stores in the exact logged `$TMPDIR/KontrolPreferencesTests-75788` root passed read-only integrity checks and were removed; cleanup evidence is in that audit log.

Only this ledger changed in the follow-up; the three existing test repairs are preserved. **Non-GUI repair validation passed; Step 1.1 acceptance remains incomplete** pending the unchanged seven-suite gate in an authorized, uncontended desktop session. Real-root typography, native controls, sheets, keyboard/confirmation and other hosted AX assertions are still unverified. No test assertions were weakened, no additional GUI run was attempted, and no hosted, native, spoken VoiceOver, or release approval is claimed. Changes remain uncommitted; reported status is **REPAIR / PASSED** for the checks actually run, not READY for the full task.

## F13 continuation — Step 1.1a independent non-GUI checkpoint (2026-09-30, 09:09 UTC)

### Scheduling amendment and acceptance boundary

The continuation request explicitly splits the old Step 1.1 into **independently approvable Step 1.1a** and **deferred required release gate A13**. This amendment supersedes all historical “stay on Step 1.1,” “do not advance,” and seven-suite-before-later-implementation instructions above **for implementation scheduling only**. The original Step 1.1 remains historically incomplete; its failed runs and the historical 08:36 UTC 90-test pass remain unchanged. The fresh six-suite evidence below permits implementation to advance after approval of this checkpoint. It does not complete the remaining F13 implementation or grant release approval.

**A13 remains required, pending—not passed, skipped, or waived.** Its owner is a human reserving an active, uncontended desktop and authorizing Accessibility for the actual rebuilt Kontrol test host (historically `/private/tmp/kontrol-f13-derived/Build/Products/Debug/Kontrol.app`), with successful activation/window registration checked again after build/signing changes. No new GUI authorization or human verification is claimed here.

### Prerequisites and preserved work

Confirmed the first top-level incomplete task in `.pi/PLAN.md` matches runner task **Step 1.1a**. Read `.pi/SPEC.md`, `.pi/ANALYSIS.md`, the plan, and the entire cumulative task-1 review checklist (no previous findings listed). Inspected `git status --short`, all existing diffs, and the index: at takeover only the three repaired test files and this ledger were modified, with nothing staged. Repository-wide `find . -name AGENTS.md -print`, target scans under `Kontrol/`, `KontrolTests/`, and `docs/`, and ancestor checks through `/` found no applicable instructions. `.gitmodules` is absent; `git submodule status` returned 0 with no entries. No commit-rule conflict was found. This attempt changes **only `docs/qa.md`**; all existing repairs, assertions, fixtures, sources, and workflow state remain untouched.

Toolchain/project discovery commands, each exit **0** (output `/tmp/kontrol-f13-resume-toolchain.log`):

```sh
xcode-select -p
xcodebuild -version
xcrun swift --version
xcodebuild -list -project Kontrol.xcodeproj
sw_vers
uname -m
```

Environment: `/Applications/Xcode.app/Contents/Developer`, **Xcode 27.0 (27A266a)**, **Apple Swift 6.4 (swiftlang-6.4.0.34.1; swift-driver 1.168.6)**, **arm64 macOS 27.0 (26A428)**. Project discovery resolved **Yams 5.4.0**, `Kontrol` scheme, `Kontrol`/`KontrolTests` targets, and Debug/Release configurations. This is not macOS 14 runtime evidence.

### Fresh required verification and audit

Executed with `set -o pipefail`, using the plan's `f13_test` helper and exactly these six suites:

```sh
f13_test AppPreferencesRepositoryTests AppPreferencesStoreTests \
  FocusPreferencesTests FocusTimingTests FocusServiceTests \
  DesignSystemTokenTests \
  2>&1 | tee /tmp/kontrol-f13-resume-foundation.log
```

Exact helper expansion:

```sh
xcodebuild -project Kontrol.xcodeproj -scheme Kontrol \
  -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath /tmp/kontrol-f13-derived \
  -parallel-testing-enabled NO CODE_SIGNING_ALLOWED=NO \
  -only-testing:KontrolTests/AppPreferencesRepositoryTests \
  -only-testing:KontrolTests/AppPreferencesStoreTests \
  -only-testing:KontrolTests/FocusPreferencesTests \
  -only-testing:KontrolTests/FocusTimingTests \
  -only-testing:KontrolTests/FocusServiceTests \
  -only-testing:KontrolTests/DesignSystemTokenTests test
```

**Exit 0, TEST SUCCEEDED.** Fresh result: **`/tmp/kontrol-f13-derived/Logs/Test/Test-Kontrol-2026.09.30_17-09-51-+0800.xcresult`**. Bodies executed at 09:09:53 UTC. These results are separate from all historical runs above.

| Selected suite | Current source methods | Executed / passed | Failed / skipped / expected failures |
| --- | ---: | ---: | ---: |
| AppPreferencesRepositoryTests | 17 | 17 / 17 | 0 / 0 / 0 |
| AppPreferencesStoreTests | 13 | 13 / 13 | 0 / 0 / 0 |
| FocusPreferencesTests | 8 | 8 / 8 | 0 / 0 / 0 |
| FocusTimingTests | 16 | 16 / 16 | 0 / 0 / 0 |
| FocusServiceTests | 29 | 29 / 29 | 0 / 0 / 0 |
| DesignSystemTokenTests | 7 | 7 / 7 | 0 / 0 / 0 |
| **Total** | **90** | **90 / 90** | **0 / 0 / 0** |

Audit commands, each exit **0**:

```sh
RESULT_BUNDLE='/tmp/kontrol-f13-derived/Logs/Test/Test-Kontrol-2026.09.30_17-09-51-+0800.xcresult'
xcrun xcresulttool get test-results summary \
  --path "$RESULT_BUNDLE" --format json > /tmp/kontrol-f13-resume-summary.json
xcrun xcresulttool get test-results tests \
  --path "$RESULT_BUNDLE" --format json > /tmp/kontrol-f13-resume-tests.json
python3 /tmp/kontrol-f13-resume-audit.py \
  | tee /tmp/kontrol-f13-resume-selector-audit.log
TEST_LOG=/tmp/kontrol-f13-resume-foundation.log \
  python3 /tmp/kontrol-f13-resume-cleanup.py \
  | tee /tmp/kontrol-f13-resume-cleanup.log
git diff --check
```

The audit enumerated every `Test Case` node and compared full identifiers with every selected source `func test…`: all 90 methods executed exactly once, no missing/extra/empty selection, all `Passed`, matching summary counts. Exact identifiers/results are in `/tmp/kontrol-f13-resume-selector-audit.log`; audit scripts and JSON outputs are retained at the paths above. The fresh summary has no test failures/runtime warnings. The raw log retains AppIntents/linkd connection diagnostics and the multiple-architecture destination warning; it has **no `vnode unlinked while in use`, `InvalidTransition`, or AX prerequisite diagnostic**.

Guarded cleanup used the existing post-host procedure plus read-only SQLite checks: confirmed PID **85745** had exited; enumerated all **15** stores under the sole exact logged root **`/var/folders/lz/20cqfx4x2k98r89q68w3q3ch0000gn/T/KontrolPreferencesTests-85745`**; validated its name, TMPDIR parent, absence of symlinks, and each `PRAGMA integrity_check=ok`; closed all connections, rechecked PID exit, and removed only that root. It no longer exists. All store paths and results are in `/tmp/kontrol-f13-resume-cleanup.log`. No live, unlogged historical, production, or checked-in stores were removed.

### Contracts inspected and current coverage

- **Duration/overflow:** inspected `Domain/AppPreferences.swift` and `Domain/FocusSessionSnapshot.swift`. Positive ASCII whole minutes retain whitespace/leading-zero rules, presets 15/25/50, checked decimal and seconds overflow, and the full `Int.max / 60` range. Repository/timing tests cover these boundaries; no smaller limit or recreation was introduced.
- **Revision/publication/drafts:** inspected `SwiftDataAppPreferencesRepository.swift`, `AppPreferencesStore.swift`, and `AppPreferencesEditorDraft.swift`. Fresh non-autosaving contexts reject corrupt/duplicate rows and stale revisions; rollback protects failed commits; publication uses the durable receipt without a post-save read. Independent drafts/baselines survive other editors, stale saves, failure, and failed review. Review is explicit and the subsequent save rechecks revision. All repository/store methods passed.
- **Focus/link/session isolation:** inspected `FocusReadyDraft`, ready-view follow/reset/Start handling in `FocusView.swift`, and service Start/retry publication. Following drafts alone adopt defaults; override/submitted drafts remain frozen; task/lesson selection is mutually exclusive; unreadable preferences use the identified fallback; reset uses the latest readable default. `FocusPreferencesTests/testFailedStartFreezesDefaultDurationAndLessonForRetryWithoutOpeningAttempt` passed with 37-minute submitted duration/lesson retained across changed/unreadable preferences, unavailable inventory rejection, one retry session/title snapshot, unchanged Learning/no attempt, and reset. Task retry and unchanged running/paused/recovered/completed/ended rows also passed. The existing lesson-link repair is preserved.
- **Accessibility resolution:** inspected `AppAccessibilityPreferences.swift` and both ready roots in `KontrolApp.swift`. App/system motion combines with OR; Large uses `max(systemTextSize, .xxLarge)`, with a minimum 130% treatment and no shrinking of larger sizes. One resolver is installed at each ready root with inherited sheet inputs, and scaled metrics use a minimum rather than double multiplication. Store tests passed all 12 size mappings, idempotence, motion truth table, and readable-committed-only inputs; token tests passed off-window glyph scaling, contrast channels, and target constants. Root/sheet/native-control behavior is source-inspected, **not credited as hosted/native acceptance**.
- **Preserved hosted repair:** inspected `DesignSystemComponentTests.swift` and its diff. Pre-construction host-specific permission checks, explicit activation, bounded window readiness diagnostics, and original AX/component/scene/sheet/keyboard/confirmation assertions remain unchanged. No assertion weakening, `XCTSkip`, expected failure, test disabling, TCC manipulation, or unauthorized hosted rerun occurred.

### Deferred gate A13 and checkpoint decision

Once the human-owned prerequisites exist, **rerun the original seven-suite selection** with the same helper/flags:

```sh
f13_test AppPreferencesRepositoryTests AppPreferencesStoreTests \
  FocusPreferencesTests FocusTimingTests FocusServiceTests \
  DesignSystemComponentTests DesignSystemTokenTests
```

All **22 current `KontrolTests/DesignSystemComponentTests` methods** remain required under A13, including `testBothRealReadyScenesUpdateSharedTypographyFromOneCommittedStore`, `testFocusAndCallerKeyboardShortcutWorkWithoutHover`, and `testNativeConfirmationCancelAndConfirmHaveDistinctEffects`. They must establish real-root typography updates, native control and inherited-sheet geometry, AX names/roles/actions, keyboard focus and single callbacks, and distinct confirmation/cancellation effects. Also retain the deferred presentation/full-suite and F00–F13 ledgers below, required native comparisons at 1000×700/1440×940 desktop and 520×340 Settings with standard/130%/larger text, keyboard/focus restoration, spoken VoiceOver, live motion combinations, contrast, and reachability. All remain **pending**, as do signed sandbox, macOS 14/current-runtime, and distribution acceptance; compilation/token evidence cannot substitute for them.

**Step 1.1a acceptance is verified and ready for review**, with no checkpoint blocker. No later task was implemented, and no plan checkbox was changed. This ledger-only checkpoint required no separate `make build`/`build-for-testing`; the required test action built its existing host/bundle, and no new source, protocol, membership, or presentation change was made. Hosted/native and distribution release approval remain explicitly pending. The runner manages approved-task commits; this execution leaves the preserved worktree uncommitted for review.

## F13 durable reference deletion — Step 2.1 (2026-09-30)

**Implementation checkpoint passed; ready for review.** The first incomplete task matched runner Step 2.1; its cumulative checklist had no previous findings. Initial worktree was clean. Ancestor/root/target instruction checks found no applicable `AGENTS.md` or submodule. Only the repository/protocol, its four conforming test doubles, repository tests, a narrow lifetime repair in the required `ProjectIntegrationTests` validation suite, and this required QA ledger changed. No ProjectStore disconnect/loading/UI work, schema/fixture change, plan checkbox, staging, or commit occurred in this execution. The runner retains approved-task commit ownership.

### Implementation and coverage

- `ProjectReferenceRepository.remove(id:expectedRevision:)` is a required method with no default implementation. The SwiftData implementation reads authoritative identity/revision through a fresh non-autosaving context, deletes only that row, commits before returning, and explicitly rolls back/rethrows any failure. It has no folder-access, inspector, identifier, or writer dependency; opaque bookmark bytes are never resolved.
- Four new non-GUI repository methods cover matching removal with malformed/unresolvable bookmark bytes, unchanged ordered survivors and unrelated Tasks through disk reopen; stale confirmations after both successful-read revision advancement and Reconnect; a missing identity even when its revision matches another row; and injected pre-commit failure retaining exact references, revisions, pending work in another context, and disk rows before explicit retry. Successful retry survives another reopen. Missing/stale cases never invoke the save hook, and repeated removal reports `notFound` without saving.
- Mutable Store/Completion doubles validate identity/revision and delete only the matching value. Launch/read-only presentation doubles explicitly throw rather than silently succeeding. All compile with the changed protocol. No visible behavior or hosted test methods changed; no new A13 selector is introduced. Hosted/native Accessibility and other release gates remain required and pending, not passed or waived.

### Exact validation and evidence

Environment commands `xcodebuild -version`, `xcrun swift --version`, `sw_vers`, and `uname -m` exited **0**: **Xcode 27.0 (27A266a)**, **Apple Swift 6.4 (swiftlang-6.4.0.34.1; swift-driver 1.168.6)**, **arm64 macOS 27.0 (26A428)**. Existing Swift 5 language mode/macOS 14 deployment are unchanged; this is not macOS 14 runtime acceptance.

Commands ran from the repository root with `set -o pipefail` (each exit **0**). The first test execution used the plan's `f13_test ProjectReferenceRepositoryTests ProjectStoreTests ProjectCompletionStoreTests ProjectIntegrationTests` helper, expanded identically to the test command below. After tightening **new** deletion-fixture lifetime to process-owned stores until host exit, all three commands reran. A subsequent raw-log audit exposed the same hazard in older fixtures; the repair and final-source rerun are recorded below:

```sh
make build DERIVED_DATA=/tmp/kontrol-f13-derived
xcodebuild -project Kontrol.xcodeproj -scheme Kontrol \
  -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath /tmp/kontrol-f13-derived \
  CODE_SIGNING_ALLOWED=NO build-for-testing
xcodebuild -project Kontrol.xcodeproj -scheme Kontrol \
  -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath /tmp/kontrol-f13-derived \
  -parallel-testing-enabled NO CODE_SIGNING_ALLOWED=NO \
  -only-testing:KontrolTests/ProjectReferenceRepositoryTests \
  -only-testing:KontrolTests/ProjectStoreTests \
  -only-testing:KontrolTests/ProjectCompletionStoreTests \
  -only-testing:KontrolTests/ProjectIntegrationTests test
git diff --check
```

Initial logs: `/tmp/kontrol-f13-step2.1-{build,bft,tests}.log`; intermediate logs: `/tmp/kontrol-f13-step2.1-final-{build,bft,tests}.log` (the historical `final` filename predates the repair). Both builds and both `build-for-testing` actions succeeded; hosted suites were compiled, **not executed**. Both selected runs passed **63/63**, with **0 failures, 0 skips, 0 expected failures**:

| Selected suite | Executed/passed (each run) |
| --- | ---: |
| ProjectReferenceRepositoryTests | 9 |
| ProjectStoreTests | 29 |
| ProjectCompletionStoreTests | 19 |
| ProjectIntegrationTests | 6 |

Initial fresh result: `/tmp/kontrol-f13-derived/Logs/Test/Test-Kontrol-2026.09.30_17-21-18-+0800.xcresult`; intermediate fresh result: `/tmp/kontrol-f13-derived/Logs/Test/Test-Kontrol-2026.09.30_17-22-38-+0800.xcresult`. Result audits (all exit **0**) ran:

```sh
for item in '17-21-18 step2.1' '17-22-38 step2.1-final'; do
  read -r stamp suffix <<< "$item"
  RESULT_BUNDLE="/tmp/kontrol-f13-derived/Logs/Test/Test-Kontrol-2026.09.30_${stamp}-+0800.xcresult"
  PREFIX="/tmp/kontrol-f13-${suffix}"
  xcrun xcresulttool get test-results summary --path "$RESULT_BUNDLE" --format json > "${PREFIX}-summary.json"
  xcrun xcresulttool get test-results tests --path "$RESULT_BUNDLE" --format json > "${PREFIX}-test-tree.json"
  python3 /tmp/kontrol-f13-step2.1-audit.py "$PREFIX" > "${PREFIX}-selector-audit.log"
done
python3 /tmp/kontrol-f13-step2.1-cleanup.py | tee /tmp/kontrol-f13-step2.1-cleanup.log
```

Each audit compares every executed full method identifier against the four selected source files, asserts exact-once/nonempty selection and all `Passed`, and checks summary totals. Both summaries report no test failures or runtime warnings. Build output retains multiple-destination/AppIntents warnings; raw test output retains linkd and existing Store-test malformed-bookmark diagnostics. A subsequent diagnostic assertion **failed** on `vnode unlinked while in use`: despite passed test assertions, older repository fixtures and the integration `failure.store` were being unlinked with SQLite handles still owned by Core Data. These raw diagnostics are retained, not treated as evidence of sound fixture cleanup; see the repaired current gate below. Historical foundation failures and all three existing repairs remain untouched.

Guarded post-host cleanup enumerated **no preferences-test root** in either log and **one exact project-removal root** in the intermediate log: `/var/folders/lz/20cqfx4x2k98r89q68w3q3ch0000gn/T/KontrolProjectRemovalTests-91458`. Confirmed PID **91458** exited, validated the process-owned name, TMPDIR parent, and absence of symlinks; enumerated **4** SQLite stores, checked each read-only `PRAGMA integrity_check=ok`, closed connections, rechecked PID exit, and removed only that root. It no longer exists. Exact store paths/results and the cleanup/audit scripts are retained under `/tmp/kontrol-f13-step2.1-*`; no historical, checked-in, live, or unlogged store was removed by this procedure.

### Fixture-lifetime repair and current gate

The extra diagnostic audit's `AssertionError` came from asserting absence of SQLite unlink messages in the initial log. This was repaired, not ignored: **all** `ProjectReferenceRepositoryTests` stores now use the logged process-owned helper, removing the five legacy in-test unlinks, and the required `ProjectIntegrationTests.workspace()` retains its six workspaces until host exit rather than deleting them in teardown. Existing behavior/byte-inventory assertions are unchanged. No production cleanup, private close API, delay, skip, or later-task behavior was added.

The exact three build/test commands above ran again with stdout/stderr redirected to `/tmp/kontrol-f13-step2.1-repair-{build,bft,tests}.log`; all exited **0** on the final source. Final fresh result: **`/tmp/kontrol-f13-derived/Logs/Test/Test-Kontrol-2026.09.30_17-27-36-+0800.xcresult`**, **63 passed / 0 failed / 0 skipped / 0 expected failures**, suite counts unchanged. Audit commands (all exit **0**):

```sh
RESULT_BUNDLE='/tmp/kontrol-f13-derived/Logs/Test/Test-Kontrol-2026.09.30_17-27-36-+0800.xcresult'
xcrun xcresulttool get test-results summary --path "$RESULT_BUNDLE" --format json > /tmp/kontrol-f13-step2.1-repair-summary.json
xcrun xcresulttool get test-results tests --path "$RESULT_BUNDLE" --format json > /tmp/kontrol-f13-step2.1-repair-test-tree.json
python3 /tmp/kontrol-f13-step2.1-audit.py /tmp/kontrol-f13-step2.1-repair > /tmp/kontrol-f13-step2.1-repair-selector-audit.log
python3 /tmp/kontrol-f13-step2.1-cleanup.py | tee /tmp/kontrol-f13-step2.1-repair-cleanup.log
git diff --check
```

The exact-once selector audit passed for all 63 current methods. The diagnostic assertion reran on the repaired test log and passed: **no `vnode unlinked while in use` or `InvalidTransition`**. Evidence `/tmp/kontrol-f13-step2.1-repair-diagnostics.log` also confirms both build success markers. Summary runtime warnings remain empty; this does not erase the earlier raw-log findings.

The cleanup script was extended to handle integration workspaces and the repaired run's log. It enumerated zero preferences roots and exactly two printed roots under `/var/folders/lz/20cqfx4x2k98r89q68w3q3ch0000gn/T/`: **`KontrolProjectRemovalTests-93113` (9 stores)** and **`KontrolProjectIntegrationTests-93113` (6 stores)**. After confirming PID **93113** exited and validating root names/TMPDIR parent/no symlinks, all **15** read-only SQLite integrity checks returned `ok`. Connections closed, PID exit was rechecked, and only those exact roots were removed; both no longer exist. All exact store paths/results are recorded in the repair cleanup log. No task-local blocker remains; later store-level disconnect/concurrency and hosted/native/sandbox/distribution acceptance are not claimed here.

## F12 implementation evidence (2026-09-30)

The [F12 README ledger](../README.md#f12-topic-news-non-gui-implementation-gate-2026-09-30) records exact commands, per-suite counts, specification coverage, toolchain, diagnostics, historical failures and live endpoint observations. Xcode **27.0 (27A266a)** / Swift **6.4**, arm64 macOS **27.0 (26A428)**, Swift 5 language mode / macOS 14.0 minimum: `make build DERIVED_DATA=/tmp/kontrol-f12-derived` and the same unsigned macOS `xcodebuild ... build-for-testing` passed. The explicit **17 non-GUI suites plus two focused AppShell methods** ran **136 passed, 0 failed, 0 skipped, 0 expected failures**; every selector's execution was audited. Result **`/tmp/kontrol-f12-gate-selected.xcresult`**, summary `/tmp/kontrol-f12-gate-summary.json`, selector audit `/tmp/kontrol-f12-gate-selector-audit.log`, logs `/tmp/kontrol-f12-gate-{toolchain,build,bft,tests,plutil}.log`. `plutil -lint Kontrol.xcodeproj/project.pbxproj Kontrol/Kontrol.entitlements`, JSON validation and final `git diff --check` all returned 0.

**Review repair / current gate:** the initial 136-test run above missed GUID-move → old-URL reissue UUID collisions (two articles sharing one ID, with persistence overwrite) and future publication retention extending after clock advancement. `NewsSelection` now reserves persisted IDs and deterministically probes collisions while retaining existing identities, and caps publication retention at immutable first fetch regardless of the current clock. Four new selection/repository regressions cover response-order independence, repeated collisions, distinct persisted rows/aliases/IDs through owner release/reopen, publication display preservation, day 21/30/31, repeat refresh, 304 and expiry deletion. An older test permitting late-publication revival was corrected to the cap contract. The README specification audit now reflects these repairs.

Required build and `build-for-testing` reran successfully; focused tests passed **29/29** and all **19 required selectors** passed **140/140, 0 failures, 0 skips, 0 expected failures** (NewsSelection **12**, NewsRepository **17**, all other counts unchanged). Exact expanded commands: [README repair gate](../README.md#review-repair-and-current-implementation-gate-2026-09-30). Result bundles `/tmp/kontrol-f12-repair-{focused,selected}.xcresult`, summary `/tmp/kontrol-f12-repair-summary.json`, audited selector execution `/tmp/kontrol-f12-repair-selector-audit.log`, logs `/tmp/kontrol-f12-repair-{focused,build,bft,tests,plutil,signed,verify,entitlements,diffcheck}.log`. Plutil, JSON and whitespace checks passed, as did the rebuilt ad-hoc signature/entitlements and packaged/source-resource comparisons (`/tmp/kontrol-f12-repair-package.log`). Toolchain unchanged. No native capture pairs were found on re-enumeration; no signed live journey, hosted execution or F13-only acceptance is claimed. The endpoint observations below were inspected and retained, not rerun during repair. Both review findings are now regression-covered; the initial pass and prior failures remain historical evidence, not erased.

All seven bundled endpoints returned **HTTP 200**, supported Atom/RSS parsed by the production native fetcher/parser, final URLs unchanged, on **2026-09-30 02:19:46–02:19:51 UTC**; exact URLs, decoded bytes and accepted item counts are in the README and `/tmp/kontrol-f12-gate-endpoints.log`. No unresolved live-feed failure remains from this observation; future availability and signed-sandbox access are not guaranteed. Deterministic tests use intercepted fixtures, not live feeds. Additional ad-hoc-signed build, strict signature verification, entitlement inspection and packaged/source-resource byte checks passed for `/tmp/kontrol-f12-gate-sandbox/Build/Products/Debug/Kontrol.app` (logs `/tmp/kontrol-f12-gate-{signed,verify,entitlements}.log`); this was **not** a signed online/offline app or browser journey.

Preserve Step 5.1's initial **2/2 integration failures** on summary whitespace (`/tmp/kontrol-f12-step5.1-integration.log`, result `/tmp/kontrol-f12-derived/Logs/Test/Test-Kontrol-2026.09.30_10-14-06-+0800.xcresult`), corrected fixture expectation and **2/2 passing** rerun (`/tmp/kontrol-f12-step5.1-integration-rerun.log`, result `/tmp/kontrol-f12-derived/Logs/Test/Test-Kontrol-2026.09.30_10-14-38-+0800.xcresult`); both also passed in the final gate. The fresh signed build warns about `AppShell.swift:61`'s unreachable default and skipped AppIntents extraction; selected runtime logs include linkd and deliberate corrupt-store CoreData messages in passing tests. Earlier F02/F06 hosted failures/skips and F11's intermittent ContainerFactory fixture-snapshot failure remain unchanged below.

Compiled News/Settings/shell presentation fixtures and resolving standalone HTML references **are not hosted or interactive acceptance**. Existing `/private/tmp` F12 evidence was enumerated: no before/after native News captures or matching rendered pair was found under the F12 derived tree (only unrelated Yams artwork), nor a F12 capture/evidence directory in the search. No screenshot comparison or human F12 attestation is claimed. Full `make test`, hosted execution and all checks below remain open.

## F13 F12 News release ledger (open)

- **Hosted/full suite:** In an active reserved, uncontended Mac GUI session execute all `NewsPresentationTests`, affected `SettingsSceneTests`, hosted `AppShellTests`, Learning draft/navigation/close guards and Projects activation-refresh regressions, then **`make test DERIVED_DATA=/tmp/kontrol-f13-derived`**. Record actual counts, commands, failures/skips and result-bundle paths. Investigate every earlier failed/skipped hosted check and the F11 snapshot concern; a prior implementation approval or non-GUI pass does not close them.
- **Native visual evidence:** Capture M35 [News](mockups/M35-news.png), M36 [Topics & feeds](mockups/M36-news-topics-feeds.png), M37 [cached/offline](mockups/M37-news-offline.png) and **all supplemental states** in the [F12 navigator](../.mockups/flows/f12-topic-news/index.html) (loading, empty variants, partial/rate-limited, editor validation/save failure, confirmed removal, browser-open failure and local-cache-read failure), at **1000×700 and 1440×940 points**. Capture native scrollable Settings at **520×340**, including enlarged text and access to management/editor actions. Enumerate before/after directories; compare actual matching rendered images with the references, recording dimensions, paths and observed differences/missing captures. HTML guidance and compiled fixtures are not native screenshots.
- **Keyboard/focus/accessibility:** Exercise filters, collapsed plain-text summary disclosure, source-specific Read, nonblocking Refresh/Retry, topic multi-selection, enable/disable, Add/Edit, Save/Cancel and destructive confirmation. Observe initial Name focus and focus return after sheet dismissal/removal to a surviving control/heading, visible focus/target sizes, long-field scrolling, stale concurrent Settings edits, canceled validation and duplicate-submit prevention. Check spoken **VoiceOver** names/roles/selected and expanded states/status/failure announcements, **enlarged text** and **reduced motion** at both desktop sizes and compact Settings. Status must remain understandable without color.
- **Signed online → offline → browser journey:** On isolated sandbox data refresh real feeds **online**, disconnect, quit and **relaunch offline**, inspect cached headlines/topic preferences/last successful refresh, then use **Read in the actual default browser**. Verify multi-topic dedup, honest missing dates, no HTML/resource execution, independent failed/malformed/rate-limited feeds, server retry deadlines, source-safe browser failure/retry, and unchanged cache/success time on full failure. Check empty/no-topic/no-enabled-feed states, enabled endpoint validation versus disabled offline drafts, retained failure drafts, explicit removal and shared-source retention, Settings/News sharing and multiple-window coalescing. Confirm unrelated tasks/Learning/projects survive. Injected transport/browser adapters and the native endpoint CLI do not satisfy this live journey.
- **Baseline/release:** Exercise these runtime/API/SF Symbol checks on **macOS 14** and the current supported OS; macOS 27 testing and a 14.0 deployment minimum do not establish baseline behavior. Record the actual packaged sandbox entitlements, distribution signing/notarization and availability/results at the F13 release gate, without broadening feed permissions.

## F13 F11 completion release ledger (open)

- Execute hosted `ProjectsPresentationTests`, affected shell/`AppShellTests` and navigation/draft/close-guard checks, and full `make test DERIVED_DATA=/tmp/kontrol-f13-derived` in a reserved active GUI session. Record executed tests, failures/skips and result bundles. Investigate the [F11 first-run intermittent ContainerFactory fixture snapshot failure](../README.md#f11-project-feature-completion-non-gui-implementation-gate-2026-09-30), despite the passing 189-test rerun; retain earlier F09/F10 and other hosted failures/skips.
- Capture **native rendered** [M31](mockups/M31-feature-completion-undo.png), [M32](mockups/M32-project-write-conflict.png) and [F11 busy/failure/undo conflict/expiry/unpatchable/saved-but-refresh-failed variants](../.mockups/flows/f11-feature-completion/index.html) at **1000×700 and 1440×940 points**. Compare matching screenshots against references and record actual before/after paths, visible differences and missing captures. The HTML pages are guidance, not native captures; no F11 rendered pairs were found for the implementation gate.
- Test keyboard-only card/detail Mark complete and Undo, conflict Cancel/Refresh, focus return after a card disappears and after selection changes, spoken VoiceOver names/status/failure announcements, enlarged text, scrolling and reduced motion at both sizes.
- In a **signed sandbox app offline on isolated project folders**, use real selected-folder bookmarks, complete/undo/external-edit conflict, revoke and Reconnect, quit/relaunch and verify disk-derived completion with no persisted Undo. Capture actual on-disk byte diffs, permissions, unchanged other `.kontrol`/source/Git files and no temp artifacts. Exercise a **macOS 14 runtime** and record availability/results. Injected grants, `build-for-testing` and a 14.0 deployment minimum do not satisfy these checks. Account for the documented `NSFileCoordinator` limitation: it cannot exclude uncoordinated editors; detected races must not become success.

## F13 consolidated interactive GUI acceptance

- For F10, **execute** hosted `ProjectsPresentationTests`, affected `AppShellTests` and navigation/draft/close-guard checks, then full `make test DERIVED_DATA=/tmp/kontrol-f13-derived` in a reserved active GUI session; investigate failures and skips. Render and compare actual F10 captures at **1000×700 and 1440×940 points** against [M27](mockups/M27-projects.png), [M30](mockups/M30-feature-detail.png), [M34](mockups/M34-project-empty-blocked.png) and [all supplemental F10 states](../.mockups/flows/f10-next-features/index.html); record matching capture paths and differences for cards, read-only detail, roadmap, zero/complete/no-ready, partial/unavailable and stale/removed/invalid states. Check keyboard-only navigation, detail focus handoff/return/fallback, spoken VoiceOver labels/statuses, scrolling and enlarged text at both sizes, and reduced motion. In the **signed sandbox app offline on isolated data**, use two folders and native picker/bookmarks; externally edit dependency/status/focus/priority/body, exercise manual and activation refresh, quit/relaunch, stale grants and Reconnect while confirming unchanged `.kontrol` bytes. Check a **macOS 14 runtime**. The [F10 non-GUI ledger](../README.md#f10-next-feature-cards-non-gui-integration-gate-2026-09-29) records 14 executed suites/133 passing tests and compiled hosted coverage, **not** hosted execution, screenshots, live bookmarks, signed journeys or macOS 14 runtime. Preserve F09 and earlier open GUI failures/skips below.
- For F09, execute hosted `ProjectsPresentationTests`, affected `AppShellTests`/draft/close-guard checks and full `make test` in a reserved active GUI session. In the **signed sandbox app offline on isolated data**, use the native folder picker for two-folder Add, cancellation/reselection and invalid-preview repair; quit/relaunch to check real bookmark reuse and unchanged project bytes. Move/revoke a grant, verify resolvable versus stale outcomes, Reconnect the same manifest ID, reject a different ID and persistence failures, and confirm healthy projects remain usable. Exercise manual and key-window activation refresh after external edits. Check keyboard-only actions/focus return, spoken VoiceOver names/statuses, enlarged text and scrolling, reduced motion, and a **macOS 14 runtime**. At **1000×700 and 1440×940 points**, capture and compare rendered M28/M29/M33 and [F09 supplemental states](../.mockups/flows/f09-local-projects/index.html), including empty/loading, partial counts, unsupported raw text, mismatch, stale/reconnect and failed Add; record screenshot paths and differences. [F09 non-GUI evidence](../README.md#f09-local-projects-non-gui-integration-gate-2026-09-29) compiles but does not execute hosted tests and has no matching rendered capture pair or interactive attestation. Preserve the F02 hosted AX/sheet failures and skipped keyboard deletion test, the F06 hosted AX failure, and F03–F08 open checks below; neither signature verification nor injected grants closes them.
- For F08, execute hosted `SettingsSceneTests`, `LearningPresentationTests`, `LessonExperiencePresentationTests`, affected Today/Focus/shell suites and full `make test` in a reserved GUI session. Capture and **compare actual rendered pairs** against [M25](mockups/M25-generate-lesson.png), [M26](mockups/M26-generation-failure.png), [M39](mockups/M39-ai-settings.png) and the [supplemental flow](../.mockups/flows/f08-ai-expansion/index.html) at **1000×700 and 1440×940 points**; also capture native Settings at **520×340**, including enlarged text. Record screenshot paths and differences. Run keyboard-only/focus/VoiceOver and reduced-motion checks, signed sandbox Keychain save/replace/disable/removal and offline generated-lesson relaunch on isolated data, **macOS 14** runtime, and separately user-authorized live provider checks (metadata test is not inference access). None of these were performed by the [F08 non-GUI gate](../README.md#f08-optional-ai-lesson-expansion-non-gui-integration-gate-2026-09-29); no F08 matching rendered before/after pair was available. Retain F02's hosted AX/sheet failures and skipped delete-keyboard test, F06's hosted AX failure, and F03–F07 deferred failures/checks as open.
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

## F13 local reference readiness — Step 2.2 (2026-09-30, 10:00 UTC)

**Implementation checkpoint passed; ready for review.** The first incomplete task matched runner Step 2.2. Read the complete cumulative task-1 checklist; it lists no previous findings. Initial `git status --short`, `git diff`, and `git diff --cached` were empty, so no interrupted partial work was present. Applicable ancestor checks through `/` and repository/target instruction scans found no `AGENTS.md`; `.gitmodules` and submodule configuration are absent, and `git submodule status` returned no entries. An initial broad sibling-directory search timed out; the completed repository and direct-ancestor checks establish the relevant instruction boundaries instead. No commit-rule conflict was found. This execution leaves changes uncommitted for runner review; no staging, plan/state edit, or later-task implementation occurred.

### Boundary and coverage

- `ProjectStore.loadReferencesIfNeeded()` fetches detached references through persistence only, publishes successful readiness, and leaves failed fetches retryable with `loadFailed`. It performs no inspector, identifier, grant resolution/creation, location, or feature-writer calls.
- A separate private inspection-admission flag is set only after successful Projects entry. Settings-first activation remains local-only. First later entry uses the existing three-slot bounded queue; reentry neither refetches nor schedules duplicate initial work, and selection survives. Existing post-entry activation/coalescing tests remain passing.
- Add now loads local references rather than calling `enterProjects()`. Picker-authorized preview/final reinspection, duplicate-folder identity checks (including inaccessible peers), bookmark creation and identity revalidation, durable insert, and selected-folder inspection publication remain intact. Explicit Add identity comparisons can resolve existing grants; this is not passive listing or admission to inspect unrelated saved folders.
- Five new `ProjectStoreTests` methods cover local-only listing/activation and bounded later entry; failed local load/entry followed by retry; Settings Add reinspection/authorization without unrelated inspection; changed bookmark identity rejection; and duplicate selection without admission. Inspector/identifier/writer spies and persisted-write counts assert the boundary. Exact new identifiers:
  - `ProjectStoreTests/testSettingsFirstListingAndActivationRemainLocalUntilBoundedProjectsEntry`
  - `ProjectStoreTests/testFailedLocalLoadAndProjectsEntryCanRetryWithoutPrematureAdmission`
  - `ProjectStoreTests/testSettingsAddRevalidatesAndAuthorizesWithoutInspectingSavedFoldersOrAdmittingActivation`
  - `ProjectStoreTests/testSettingsAddRejectsChangedBookmarkIdentityWithoutAdmittingSavedFolderInspection`
  - `ProjectStoreTests/testSettingsAddDuplicateSelectsExistingWithoutAdmittingInspection`
- Two new disk-backed integration methods use the real repository/parser/scoped boundaries with counted in-process grants: `ProjectIntegrationTests/testSettingsFirstReopenedReferencesAndActivationDoNotAccessGrantsUntilProjectsEntry` and `ProjectIntegrationTests/testSettingsAddLeavesExistingFolderUninspectedAndUnchangedUntilProjectsEntry`. They verify reopen/local listing with a revoked peer, no access/save before admission, normal later inspection, selection, balanced scopes, and whole-tree byte preservation including `.git`, source, `.kontrol`, and absence of temporary entries. These opaque fixture grants are not OS-bookmark/signed-sandbox acceptance.
- Confirmed completed Step 1.1a/2.1 repairs in source and the prior ledger: host-specific AX prerequisite/original assertions, submitted lesson-link retry/reset regression, process-owned preference/removal/integration fixtures, and required durable revision-checked repository deletion remain unchanged. All 19 existing completion/Undo methods passed. Reload, disconnect, Settings presentation, and export belong to later tasks and are not implemented here.

### Environment and exact verification

Discovery commands (all exit **0**), output `/tmp/kontrol-f13-step2.2-toolchain.log`:

```sh
xcode-select -p
xcodebuild -version
xcrun swift --version
xcodebuild -list -project Kontrol.xcodeproj
sw_vers
uname -m
```

Environment: `/Applications/Xcode.app/Contents/Developer`, **Xcode 27.0 (27A266a)**, **Apple Swift 6.4 (swiftlang-6.4.0.34.1; swift-driver 1.168.6)**, **arm64 macOS 27.0 (26A428)**. Project discovery resolved Yams **5.4.0**, Kontrol scheme, Kontrol/KontrolTests targets, Debug/Release configurations. Swift 5/macOS 14 deployment remain unchanged; no macOS 14 runtime claim.

Commands ran from the repository root with `set -o pipefail`; each exited **0**, first on the initial implementation, then again on final source after strengthening bookmark-creation spies and adding changed-grant rejection coverage:

```sh
make build DERIVED_DATA=/tmp/kontrol-f13-derived
xcodebuild -project Kontrol.xcodeproj -scheme Kontrol \
  -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath /tmp/kontrol-f13-derived \
  CODE_SIGNING_ALLOWED=NO build-for-testing
# Exact expansion of f13_test ProjectStoreTests ProjectIntegrationTests ProjectCompletionStoreTests:
xcodebuild -project Kontrol.xcodeproj -scheme Kontrol \
  -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath /tmp/kontrol-f13-derived \
  -parallel-testing-enabled NO CODE_SIGNING_ALLOWED=NO \
  -only-testing:KontrolTests/ProjectStoreTests \
  -only-testing:KontrolTests/ProjectIntegrationTests \
  -only-testing:KontrolTests/ProjectCompletionStoreTests test
git diff --check
```

Initial logs: `/tmp/kontrol-f13-step2.2-{build,bft,tests}.log`; final logs: `/tmp/kontrol-f13-step2.2-final-{build,bft,tests}.log`. Both builds and both test-compilation actions succeeded; hosted coverage compiled but was not executed. No new source/test/resource files require project registration.

| Selected suite | Initial executed/passed | Final source methods/executed/passed |
| --- | ---: | ---: |
| ProjectStoreTests | 33 | 34 |
| ProjectIntegrationTests | 8 | 8 |
| ProjectCompletionStoreTests | 19 | 19 |
| **Total** | **60** | **61** |

Both runs have **0 failures, 0 skips, 0 expected failures**. Initial fresh bundle: `/tmp/kontrol-f13-derived/Logs/Test/Test-Kontrol-2026.09.30_17-58-38-+0800.xcresult`; final fresh bundle: **`/tmp/kontrol-f13-derived/Logs/Test/Test-Kontrol-2026.09.30_17-59-57-+0800.xcresult`**. Both summaries have empty runtime-warning and test-failure arrays. Raw logs retain existing malformed-bookmark/linkd diagnostics and destination/AppIntents warnings; no `vnode unlinked while in use`, `InvalidTransition`, or AX prerequisite diagnostic appears. Marker/diagnostic audit: `/tmp/kontrol-f13-step2.2-diagnostics.log`.

Fresh bundle audits, each exit **0**:

```sh
for item in '17-58-38 initial' '17-59-57 final'; do
  read -r stamp suffix <<< "$item"
  RESULT_BUNDLE="/tmp/kontrol-f13-derived/Logs/Test/Test-Kontrol-2026.09.30_${stamp}-+0800.xcresult"
  PREFIX="/tmp/kontrol-f13-step2.2-${suffix}"
  xcrun xcresulttool get test-results summary --path "$RESULT_BUNDLE" --format json > "${PREFIX}-summary.json"
  xcrun xcresulttool get test-results tests --path "$RESULT_BUNDLE" --format json > "${PREFIX}-test-tree.json"
  python3 /tmp/kontrol-f13-step2.2-audit.py "$PREFIX" "$suffix" > "${PREFIX}-selector-audit.log"
done
python3 /tmp/kontrol-f13-step2.2-cleanup.py | tee /tmp/kontrol-f13-step2.2-cleanup.log
git diff --check
```

Audits enumerate full method identifiers/results, compare against selected source methods, require exact-once/nonempty execution and all `Passed`, and reconcile summary totals. The initial audit excludes only the named changed-bookmark-identity method introduced after that run; final audit covers all 61 current methods. Scripts, JSON summaries/trees, and exact selector logs are retained at the paths above.

Guarded post-host cleanup enumerated exactly the two printed integration roots `/var/folders/lz/20cqfx4x2k98r89q68w3q3ch0000gn/T/KontrolProjectIntegrationTests-2831` and `/var/folders/lz/20cqfx4x2k98r89q68w3q3ch0000gn/T/KontrolProjectIntegrationTests-3364`. Confirmed both PIDs exited, validated TMPDIR parent/process-owned name/no symlinks, enumerated **8 SQLite stores per root**, and checked all **16** read-only `PRAGMA integrity_check` results as `ok`. Connections closed and PID exit rechecked before removing only those exact roots; both no longer exist. Exact store paths/results are in `/tmp/kontrol-f13-step2.2-cleanup.log`. Original fixtures, production data, live stores, and historical unlogged roots remain untouched.

**No Step 2.2 blocker remains.** No visible/hosted selectors changed. A13 Accessibility/full-suite/native observations, S13 signed-sandbox/OS-bookmark journeys, B13 baseline runtime, and D13 distribution remain required and pending—not passed, skipped, or waived. This checkpoint is not unconditional F13/release approval.
