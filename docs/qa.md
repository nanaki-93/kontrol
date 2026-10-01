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

## F13 explicit reference reload — Step 2.2b (2026-09-30, 10:15 UTC)

**Implementation checkpoint passed; ready for review.** First incomplete task matches runner Step 2.2b. The complete cumulative task-2 review checklist has no previous findings. Initial worktree/index diffs were empty; no interrupted partial work needed recovery. Repository/target and direct-ancestor checks through `/` found no applicable `AGENTS.md`; no `.gitmodules` or configured submodules were found. Existing regression repairs remain intact. No later task, workflow state, or plan was changed; changes remain uncommitted for runner review.

### Implementation and acceptance coverage

- `ProjectStore.reloadReferences()` rejects active completion/Undo, saved-write reconciliation, reconnect, and Add before fetching. Busy attempts neither cancel their owner nor queue an automatic reload. Completion/Undo and reconnect finish successfully after rejected reload attempts.
- Reload fetches through persistence only before replacing published state. Fetch failure throws and sets `loadFailed`, retaining rows, selection/detail, and running reads; a separately invoked reload clears the failure after success. Initial failed reload is distinguishable from a successfully fetched empty list.
- Identical surviving snapshots retain inspection, timestamps, location, status, refresh bookkeeping, feature selection, and valid Undo. Changed/removed snapshots lose obsolete inspection/location/detail/notices/completion/Undo and queued follow-ups. Surviving project selection remains; missing selection falls back to display order then UUID.
- Changed/removed reads are canceled and explicitly publication-fenced, including remove/reintroduce of the same identity/revision. Occupied task/generation bookkeeping stays until `finishRefresh` releases its slot. Late inspection/location results cannot publish or call `recordSuccessfulRead`. The three-slot saturated-queue regression verifies no early capacity release, no obsolete follow-up/removed queued read, survivor progress, and explicit new-grant refresh recovery. Passive reload never drains/adopts new inspection work or admits activation inspection.
- Seven new store methods cover the above boundaries with inspector, identifier, and writer spies, deterministic noncooperative readers, delayed location, and successful completion/Undo/reconnect owners:
  - `ProjectStoreTests/testReloadBeforeEntryIsLocalOnlyAndFailedReloadRetainsRowsForExplicitRetry`
  - `ProjectStoreTests/testReloadPreservesHealthyStateSelectionAndFailedReviewDoesNotCancelRead`
  - `ProjectStoreTests/testReloadChangedAndRemovedRowsClearTransientStateAndChooseOrderedSurvivor`
  - `ProjectStoreTests/testReloadFencesNoncooperativeReadsAndRetainsCapacityUntilOwnersFinish`
  - `ProjectStoreTests/testReloadFencesDelayedLocationEvenWhenIdentityAndRevisionAreReintroduced`
  - `ProjectStoreTests/testReloadRejectsReconnectAndAddWithoutCancelingOrQueuingWork`
  - `ProjectStoreTests/testReloadRejectsCompletionUndoAndSavedWriteReconciliationAndPreservesUndoOnUnchangedReview`
- `ProjectIntegrationTests/testExplicitReloadReviewsDurableReferencesWithoutGrantAccessAndRetainsStateOnCorruptFetch` exercises real disk-backed fetch/reopen, corrupt persisted-row failure/explicit repair, out-of-band durable grant replacement/removal, unchanged survivor detail, invalidated changed detail, and explicit replacement-grant refresh. Counted grants show no resolution/creation/access during reload; store save counts remain unchanged. Whole-tree inventories preserve `.kontrol`, source, Git sentinels, and replacement-folder bytes. In-process opaque grants are not signed-sandbox/OS-bookmark acceptance.

### Exact commands and results

Discovery commands all exited **0**: `xcode-select -p`, `xcodebuild -version`, `xcrun swift --version`, `xcodebuild -list -project Kontrol.xcodeproj`, `sw_vers`, `uname -m`. Project listing: `/tmp/kontrol-f13-step2.2b-project-list.log`. Environment remains **Xcode 27.0 (27A266a), Apple Swift 6.4 (swiftlang-6.4.0.34.1; swift-driver 1.168.6), arm64 macOS 27.0 (26A428)**, developer directory `/Applications/Xcode.app/Contents/Developer`; Yams **5.4.0**. Swift 5/macOS 14 deployment remain unchanged; no macOS 14 runtime claim.

From repository root:

```sh
set -o pipefail
make build DERIVED_DATA=/tmp/kontrol-f13-derived
xcodebuild -project Kontrol.xcodeproj -scheme Kontrol \
  -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath /tmp/kontrol-f13-derived \
  -parallel-testing-enabled NO CODE_SIGNING_ALLOWED=NO \
  -only-testing:KontrolTests/ProjectStoreTests \
  -only-testing:KontrolTests/ProjectIntegrationTests \
  -only-testing:KontrolTests/ProjectCompletionStoreTests test
# After fixing the test-helper compile error, reran the exact test command above.
make build DERIVED_DATA=/tmp/kontrol-f13-derived
xcodebuild -project Kontrol.xcodeproj -scheme Kontrol \
  -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath /tmp/kontrol-f13-derived \
  CODE_SIGNING_ALLOWED=NO build-for-testing
git diff --check
```

Initial build exited **0** (`/tmp/kontrol-f13-step2.2b-build.log`). Initial test command exited **65**, before executing tests: the new mutation helper attempted `replacingOccurrences` on optional `ProjectSourceDocument.text`. Repaired the helper to decode its authored UTF-8 bytes explicitly; no behavior assertion was changed. Failed-build evidence remains `/tmp/kontrol-f13-step2.2b-tests.log` and `/tmp/kontrol-f13-derived/Logs/Test/Test-Kontrol-2026.09.30_18-12-48-+0800.xcresult`; this is not passing test evidence.

Repaired exact test command exited **0**, log `/tmp/kontrol-f13-step2.2b-repair-tests.log`, fresh bundle **`/tmp/kontrol-f13-derived/Logs/Test/Test-Kontrol-2026.09.30_18-13-08-+0800.xcresult`**. **69 source methods executed exactly once and passed: ProjectStoreTests 41, ProjectIntegrationTests 9, ProjectCompletionStoreTests 19; 0 failures, 0 skips, 0 expected failures.** Final build and additional test compilation exited **0**, logs `/tmp/kontrol-f13-step2.2b-final-build.log` and `/tmp/kontrol-f13-step2.2b-bft.log`. `git diff --check` exited **0**. No new files require project registration. Hosted fixtures compiled but were not executed.

Fresh audits (each exit **0**):

```sh
RESULT_BUNDLE=/tmp/kontrol-f13-derived/Logs/Test/Test-Kontrol-2026.09.30_18-13-08-+0800.xcresult
xcrun xcresulttool get test-results summary --path "$RESULT_BUNDLE" --format json \
  > /tmp/kontrol-f13-step2.2b-summary.json
xcrun xcresulttool get test-results tests --path "$RESULT_BUNDLE" --format json \
  > /tmp/kontrol-f13-step2.2b-test-tree.json
python3 /tmp/kontrol-f13-step2.2-audit.py /tmp/kontrol-f13-step2.2b \
  > /tmp/kontrol-f13-step2.2b-selector-audit.log
python3 /tmp/kontrol-f13-step2.2b-cleanup.py \
  | tee /tmp/kontrol-f13-step2.2b-cleanup.log
git diff --check
```

The source/selector audit verifies nonempty exact-once execution and all results `Passed`, reconciling summary totals. Summary test-failure/runtime-warning arrays are empty. Raw logs retain existing malformed-bookmark/linkd diagnostics and destination/AppIntents warnings. Diagnostic audit `/tmp/kontrol-f13-step2.2b-diagnostics.log` confirms no SQLite `vnode unlinked while in use`, `InvalidTransition`, or AX prerequisite diagnostic.

Guarded post-host cleanup enumerated the single exact printed root `/var/folders/lz/20cqfx4x2k98r89q68w3q3ch0000gn/T/KontrolProjectIntegrationTests-7354`. Confirmed PID **7354** exited, validated TMPDIR parent/process-owned name/no symlinks, enumerated **9 SQLite stores**, and checked all read-only `PRAGMA integrity_check` results as **ok**. Closed connections and rechecked host exit before removing only that root; it no longer exists. Exact store paths/results: `/tmp/kontrol-f13-step2.2b-cleanup.log`. Production data, original fixtures, and historical unlogged roots were untouched.

**No Step 2.2b blocker remains.** Accessibility gate A13 and native/sandbox/baseline/distribution release gates remain required and pending—not passed, skipped, or waived. No visible surface or hosted method changed in this checkpoint.

## F13 durable store disconnect — Step 2.3 (2026-09-30, 10:32 UTC)

**Implementation checkpoint passed; ready for review.** First incomplete task matches runner Step 2.3. The complete cumulative task-3 review checklist has no previous findings. Initial worktree/index diffs were empty, with no interrupted partial work. Repository/target and direct-ancestor checks through `/` found no applicable `AGENTS.md`; no `.gitmodules` or configured submodules were found. Existing regression repairs remain intact. No plan, workflow state, later task, schema, or presentation was changed. Changes remain uncommitted for this step's runner review.

### Implementation and acceptance coverage

- `ProjectStore.disconnect(id:expectedRevision:)` validates local identity/revision and rejects that identity's active completion (including validation), Undo execution, reconnect, and saved-write reconciliation before calling persistence. The repository independently validates the authoritative revision; missing/stale results propagate without adopting newer state or implicitly reloading.
- Deletion commits synchronously before publication or transient cleanup. Failure retains the reference, inspection, location, feature detail/selection, notices, completion outcome, and usable idle Undo. No automatic deletion/retry or cancellation of irreversible operations occurs. Busy completion/Undo owners still finish successfully after rejection; an unrelated reference can be disconnected during reconnect.
- Success removes only the reference and its row-owned inspection/location/completion plus selected detail/notices, Undo, reconnect generation, and queued follow-ups. Reconnect notices now retain their owning identity, so an unrelated notice survives. Unrelated selection/detail/inspection/location/completion/Undo remain usable. Removed selection falls back to display order then UUID; deleting the last row clears selection.
- Running refresh task/generation bookkeeping remains occupied, publication-invalidated, until the existing `finishRefresh` owner releases its slot. Waiting requests/follow-ups for the removed identity are discarded without admitting or draining new external reads. The comprehensive disconnect race/capacity and copied-tree byte-inventory checkpoint remains Step 2.4; this entry does not certify those later checks.
- New `ProjectDisconnectTests.swift` is explicitly registered in the test target/group/build phase. Eight methods exercise local-only removal with unusable opaque bookmarks, commit-before-publication, durable reopen/survivors/unrelated tasks, selection ordering/last-row cleanup, unrelated inspected detail preservation, injected durable failure/explicit retry, local and authoritative stale/missing confirmations, external access/read failures, feature/reconnect notice retention and cleanup, and reconnect busy admission. Inspector, identity, location, bookmark-creation, and writer spies show no added external calls from disconnect.
- Two additional completion methods cover rejection throughout validation/write/saved-read/Undo/saved-Undo-read, successful owner completion with no deferred deletion, failure retaining idle Undo, and successful removal clearing only the affected token/detail. Exact new identifiers:
  - `ProjectDisconnectTests/testLocalOnlyDisconnectCommitsBeforePublicationAndReopensWithSurvivors`
  - `ProjectDisconnectTests/testSelectedRemovalUsesDisplayOrderThenUUIDAndLastRemovalClearsSelection`
  - `ProjectDisconnectTests/testRemovalPreservesUnrelatedInspectedSelectionDetailAndLocation`
  - `ProjectDisconnectTests/testFailedDurableDeletionRetainsUsableDetailLocationAndRequiresExplicitRetry`
  - `ProjectDisconnectTests/testStaleAndMissingConfirmationsLeaveRowsAndDetailForExplicitReview`
  - `ProjectDisconnectTests/testRemovalClearsObsoleteFeatureNoticeAndExternalFailuresRemainRemovable`
  - `ProjectDisconnectTests/testDisconnectClearsOnlyItsReconnectNoticeAfterDurableSuccess`
  - `ProjectDisconnectTests/testReconnectBusyRejectionDoesNotCancelOwnerOrQueueDeletion`
  - `ProjectCompletionStoreTests/testDisconnectRejectsCompletionValidationWriteReconciliationAndUndoWithoutCancelingOwners`
  - `ProjectCompletionStoreTests/testDisconnectFailurePreservesIdleUndoThenSuccessClearsOnlyRemovedTokenAndDetail`

### Exact commands and results

Discovery commands all exited **0**: `xcode-select -p`, `xcodebuild -version`, `xcrun swift --version`, `xcodebuild -list -project Kontrol.xcodeproj`, `sw_vers`, `uname -m`. Environment: `/Applications/Xcode.app/Contents/Developer`, **Xcode 27.0 (27A266a), Apple Swift 6.4 (swiftlang-6.4.0.34.1; swift-driver 1.168.6), arm64 macOS 27.0 (26A428)**; Yams **5.4.0**. Swift 5/macOS 14 deployment remain unchanged; no macOS 14 runtime claim.

Commands below ran from repository root initially and again on final source after adding identity-owned reconnect-notice cleanup and strengthening failure/notice coverage. Every command exited **0**:

```sh
set -o pipefail
make build DERIVED_DATA=/tmp/kontrol-f13-derived
xcodebuild -project Kontrol.xcodeproj -scheme Kontrol \
  -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath /tmp/kontrol-f13-derived \
  CODE_SIGNING_ALLOWED=NO build-for-testing
# Exact expansion of f13_test ProjectDisconnectTests ProjectStoreTests ProjectCompletionStoreTests ProjectIntegrationTests:
xcodebuild -project Kontrol.xcodeproj -scheme Kontrol \
  -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath /tmp/kontrol-f13-derived \
  -parallel-testing-enabled NO CODE_SIGNING_ALLOWED=NO \
  -only-testing:KontrolTests/ProjectDisconnectTests \
  -only-testing:KontrolTests/ProjectStoreTests \
  -only-testing:KontrolTests/ProjectCompletionStoreTests \
  -only-testing:KontrolTests/ProjectIntegrationTests test
git diff --check
```

Initial logs: `/tmp/kontrol-f13-step2.3-{build,bft,tests}.log`. Final logs: `/tmp/kontrol-f13-step2.3-final-{build,bft,tests}.log`. Both builds and both test-compilation actions succeeded. Hosted fixtures compiled but were not executed; no visible surface/hosted identifier changed.

| Selected suite | Initial executed/passed | Final source methods/executed/passed |
| --- | ---: | ---: |
| ProjectDisconnectTests | 7 | 8 |
| ProjectStoreTests | 41 | 41 |
| ProjectCompletionStoreTests | 21 | 21 |
| ProjectIntegrationTests | 9 | 9 |
| **Total** | **78** | **79** |

Both runs have **0 failures, 0 skips, 0 expected failures**. Initial bundle: `/tmp/kontrol-f13-derived/Logs/Test/Test-Kontrol-2026.09.30_18-27-51-+0800.xcresult`; final bundle: **`/tmp/kontrol-f13-derived/Logs/Test/Test-Kontrol-2026.09.30_18-30-08-+0800.xcresult`**. Both summaries have empty runtime-warning and test-failure arrays. Raw logs retain existing malformed-bookmark/linkd and destination/AppIntents diagnostics. `/tmp/kontrol-f13-step2.3-diagnostics.log` records the diagnostic audit; no SQLite `vnode unlinked while in use`, `InvalidTransition`, or AX prerequisite diagnostic appears.

Fresh bundle audits, each exit **0**:

```sh
RESULT_BUNDLE=/tmp/kontrol-f13-derived/Logs/Test/Test-Kontrol-2026.09.30_18-27-51-+0800.xcresult
xcrun xcresulttool get test-results summary --path "$RESULT_BUNDLE" --format json \
  > /tmp/kontrol-f13-step2.3-summary.json
xcrun xcresulttool get test-results tests --path "$RESULT_BUNDLE" --format json \
  > /tmp/kontrol-f13-step2.3-test-tree.json
RESULT_BUNDLE=/tmp/kontrol-f13-derived/Logs/Test/Test-Kontrol-2026.09.30_18-30-08-+0800.xcresult
xcrun xcresulttool get test-results summary --path "$RESULT_BUNDLE" --format json \
  > /tmp/kontrol-f13-step2.3-final-summary.json
xcrun xcresulttool get test-results tests --path "$RESULT_BUNDLE" --format json \
  > /tmp/kontrol-f13-step2.3-final-test-tree.json
python3 /tmp/kontrol-f13-step2.3-audit.py /tmp/kontrol-f13-step2.3 initial \
  > /tmp/kontrol-f13-step2.3-selector-audit.log
python3 /tmp/kontrol-f13-step2.3-audit.py /tmp/kontrol-f13-step2.3-final \
  > /tmp/kontrol-f13-step2.3-final-selector-audit.log
python3 /tmp/kontrol-f13-step2.3-cleanup.py | tee /tmp/kontrol-f13-step2.3-cleanup.log
git diff --check
```

Selector audits enumerate full method identifiers/results, require nonempty exact-once execution and every result `Passed`, and reconcile summary totals. The initial audit excludes only the reconnect-notice method added after that run; final audit covers all 79 current methods.

Guarded post-host cleanup enumerated the four exact logged roots under `/var/folders/lz/20cqfx4x2k98r89q68w3q3ch0000gn/T/`: `KontrolProjectDisconnectTests-11378`, `KontrolProjectDisconnectTests-11885`, `KontrolProjectIntegrationTests-11378`, and `KontrolProjectIntegrationTests-11885`. Both host PIDs were confirmed exited; TMPDIR parent/process-owned names/no symlinks were validated. Enumerated **2 + 2 + 9 + 9 SQLite stores** and checked all **22** read-only `PRAGMA integrity_check` results as **ok**. Connections closed and PID exit rechecked before removing only these roots; all four no longer exist. Exact store paths/results: `/tmp/kontrol-f13-step2.3-cleanup.log`. Original fixtures, production data, live stores, and historical unlogged roots were untouched.

**No Step 2.3 blocker remains.** A13 Accessibility and native/sandbox/baseline/distribution acceptance remain required and pending—not passed, skipped, or waived. This non-GUI checkpoint is not F13/release acceptance.

## F13 disconnect races, capacity, and external-byte safety — Step 2.4 (2026-09-30, 10:43 UTC)

**Implementation checkpoint passed; ready for review.** The first incomplete task matches runner Step 2.4. Read the complete cumulative task-4 checklist: no previous findings. Initial worktree/index diffs were empty; no interrupted partial work existed. Repository/target searches and direct ancestor checks through `/` found no applicable `AGENTS.md`; no submodules or `.gitmodules` were found. Existing regression repairs, frozen schemas, original fixtures, and workflow state remain untouched. This checkpoint changes three existing test files and this ledger only; no production defect was exposed, so `ProjectStore.swift` needs no speculative repair.

### Acceptance coverage and exact new identifiers

- `ProjectStoreTests/testDisconnectSaturatedNoncooperativeReadsRecoverExactlyThreeSlotsAndSurvivorsProgress`: holds three noncooperative inspections in an eight-row queue; disconnects two running identities and one waiting identity; repeatedly requests removed-row follow-ups. No slot is released early. Returning success/failure owners each admits exactly one survivor. Removed callbacks cannot even **attempt** `recordSuccessfulRead` (the repository spy counts before identity validation); removed queued work never starts. All five survivors publish. A second saturated wave verifies exactly three active slots, no leaks/double release, zero active readers at finish, and no writer/identity access.
- `ProjectStoreTests/testDisconnectRetainsSaturatedDelayedLocationSlotsUntilEachOwnerReturns`: releases inspections into three suspended location lookups, then disconnects one owner. Slots remain occupied throughout location IO; returning the disconnected location admits exactly one queued survivor without publication/writeback/follow-up. All four survivors finish with inspections and locations.
- `ProjectStoreTests/testDisconnectDelayedLocationCannotPublishEvenAfterSameReferenceIsReintroduced`: disconnects during delayed location, then locally reintroduces the **same ID and revision** before releasing the old callback. Inspection/location/read date/error/detail remain absent, no old metadata attempt or follow-up occurs, and the peer progresses. `DeferredLocation` now holds per-bookmark continuations; existing reload-location tests still pass.
- `ProjectDisconnectTests/testFailedDisconnectDuringReadPreservesOwnerAndCoalescedFollowUp`: injected durable deletion failure retains the occupied reader and exactly one coalesced follow-up. Both reads subsequently publish/persist normally; no automatic deletion or external writer invocation occurs.
- `ProjectIntegrationTests/testDisconnectCopiedTreesFailedSaveAndReopenNeverAccessOrChangeExternalBytes`: copies a complete isolated tree, including `.kontrol`, hidden Git sentinels, source files, and directories. Full entry/byte inventories are compared before/after initial inspection, failed deletion, **every** successful removal, and reopen. Healthy, malformed, revoked, and missing folders remain locally removable. Bookmark resolve/create/scope counters do not change during removal/reopen; an injected forwarding `FeatureFileWriter` spy reports **zero completion and Undo admissions**. All four references are durably absent after reopen; missing folders remain absent. Neither source nor Git nor `.kontrol` entries/bytes are altered or deleted.

The tests inspect existing refresh bookkeeping behavior: disconnect fences publication and drops waiting/follow-up work, while the occupied operation remains until `finishRefresh` releases its slot once. Continuation release, not filesystem timing or cooperative cancellation, controls these races. Short bounded scheduler opportunities check negative assertions; every positive transition is synchronized on observed starts/publication.

### Exact commands, environment, and results

Discovery commands exited **0**: `xcode-select -p`, `xcodebuild -version`, `xcrun swift --version`, `xcodebuild -list -project Kontrol.xcodeproj`, `sw_vers`, `uname -m`. Project listing: `/tmp/kontrol-f13-step2.4-project-list.log`. Environment: **Xcode 27.0 (27A266a), Apple Swift 6.4 (swiftlang-6.4.0.34.1; swift-driver 1.168.6), arm64 macOS 27.0 (26A428)**, developer directory `/Applications/Xcode.app/Contents/Developer`, resolved Yams **5.4.0**. Swift 5/macOS 14 deployment are preserved; no macOS 14 runtime acceptance is claimed.

Using the unchanged plan `f13_test` helper, these commands ran initially and again on final source after adding the saturated delayed-location regression; every command exited **0**:

```sh
set -o pipefail
make build DERIVED_DATA=/tmp/kontrol-f13-derived
f13_test ProjectReferenceRepositoryTests ProjectDisconnectTests ProjectStoreTests ProjectCompletionStoreTests ProjectIntegrationTests
git diff --check
```

The test command expands to:

```sh
xcodebuild -project Kontrol.xcodeproj -scheme Kontrol \
  -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath /tmp/kontrol-f13-derived \
  -parallel-testing-enabled NO CODE_SIGNING_ALLOWED=NO \
  -only-testing:KontrolTests/ProjectReferenceRepositoryTests \
  -only-testing:KontrolTests/ProjectDisconnectTests \
  -only-testing:KontrolTests/ProjectStoreTests \
  -only-testing:KontrolTests/ProjectCompletionStoreTests \
  -only-testing:KontrolTests/ProjectIntegrationTests test
```

| Run | Fresh result bundle | Executed / passed | Failures / skips / expected failures |
| --- | --- | --- | --- |
| Initial | `/tmp/kontrol-f13-derived/Logs/Test/Test-Kontrol-2026.09.30_18-41-19-+0800.xcresult` | 92 / 92 | 0 / 0 / 0 |
| Final | `/tmp/kontrol-f13-derived/Logs/Test/Test-Kontrol-2026.09.30_18-43-04-+0800.xcresult` | **93 / 93** | **0 / 0 / 0** |

Final per-suite counts: **9 reference repository, 9 disconnect, 44 store, 21 completion store, 10 integration**. Initial store count was 43; all other counts match final. Build/test logs: `/tmp/kontrol-f13-step2.4-{build,tests}.log` and `/tmp/kontrol-f13-step2.4-final-{build,tests}.log`. Tests compiled all changed existing fixtures; no new file, protocol, target membership, or presentation change requires a separate `build-for-testing` command.

Fresh bundle audits and guarded post-host cleanup ran with these exact commands, all exit **0**:

```sh
RESULT_BUNDLE='/tmp/kontrol-f13-derived/Logs/Test/Test-Kontrol-2026.09.30_18-41-19-+0800.xcresult'
PREFIX=/tmp/kontrol-f13-step2.4
xcrun xcresulttool get test-results summary --path "$RESULT_BUNDLE" --format json > "${PREFIX}-summary.json"
xcrun xcresulttool get test-results tests --path "$RESULT_BUNDLE" --format json > "${PREFIX}-test-tree.json"
python3 /tmp/kontrol-f13-step2.4-audit.py "$PREFIX" initial > "${PREFIX}-selector-audit.log"
RESULT_BUNDLE='/tmp/kontrol-f13-derived/Logs/Test/Test-Kontrol-2026.09.30_18-43-04-+0800.xcresult'
PREFIX=/tmp/kontrol-f13-step2.4-final
xcrun xcresulttool get test-results summary --path "$RESULT_BUNDLE" --format json > "${PREFIX}-summary.json"
xcrun xcresulttool get test-results tests --path "$RESULT_BUNDLE" --format json > "${PREFIX}-test-tree.json"
python3 /tmp/kontrol-f13-step2.4-audit.py "$PREFIX" > "${PREFIX}-selector-audit.log"
python3 /tmp/kontrol-f13-step2.4-cleanup.py > /tmp/kontrol-f13-step2.4-cleanup.log
git diff --check
```

Both selector audits compare full executed identifiers/results against selected source methods, require nonempty exact-once execution and every result `Passed`, and reconcile summary counts. Only the method introduced after the initial run is excluded from that initial audit. Both summaries have empty runtime-warning/test-failure arrays. Diagnostic assertions passed for both raw test/build logs: success markers present; no `vnode unlinked while in use`, `InvalidTransition`, or AX prerequisite diagnostics. Evidence: `/tmp/kontrol-f13-step2.4-diagnostics.log`. Existing malformed-bookmark/linkd diagnostics and multiple-destination/AppIntents warnings remain in raw logs; no behavior assertion, skip, or expected failure was weakened/added.

Guarded cleanup enumerated exactly six printed process-owned roots under `/var/folders/lz/20cqfx4x2k98r89q68w3q3ch0000gn/T/`: `KontrolProjectDisconnectTests-{14220,14423}` (**2 stores each**), `KontrolProjectIntegrationTests-{14220,14423}` (**10 each**), and `KontrolProjectRemovalTests-{14220,14423}` (**9 each**). Both PIDs exited; TMPDIR parent/process-owned names/no symlinks were checked. All **42** read-only SQLite `PRAGMA integrity_check` results were **ok**. Connections closed and host exit rechecked before removing only those exact roots; all six no longer exist. Exact store paths/results are in `/tmp/kontrol-f13-step2.4-cleanup.log`.

External fixture evidence was captured before cleanup: each of four existing external trees contains **14 entries**. Final fixture workspace was `/var/folders/lz/20cqfx4x2k98r89q68w3q3ch0000gn/T/KontrolProjectIntegrationTests-14423/B84B5452-78AC-4E09-920A-8B6D95F3D118/`, with `disconnect-{original,copy,malformed,revoked}` and absent `disconnect-missing`. The XCTest performs the before/after full-byte comparisons; additionally, post-run original/copy full-entry SHA-256 inventories matched in **both** runs. After-run entry kinds/sizes/hashes and exact paths are retained at `/tmp/kontrol-f13-step2.4-external-inventories.json`; this file is after-run evidence, not a separate before-capture. Original checked-in fixtures, production data, live stores, and historical unlogged roots were untouched.

**No Step 2.4 blocker remains.** No hosted identifiers or visible surfaces changed. A13 Accessibility/full-suite/native observations, S13 signed sandbox and real OS-bookmark journeys, B13 runtime matrix, and D13 distribution acceptance remain mandatory and pending—not passed, skipped, or waived. This checkpoint verifies non-GUI disconnect safety, not unconditional F13/release acceptance.

## F13 shared folder Settings and named confirmation — Step 2.5 (2026-09-30, 11:07 UTC)

**Implementation checkpoint passed; ready for review.** The first incomplete task matches runner Step 2.5. Read the complete cumulative task-5 checklist; it has no previous findings. Initial worktree/index were clean; no interrupted source changes existed. Target/repository searches and ancestor checks through `/` found no applicable `AGENTS.md`; no submodules were configured. Existing regression repairs, external fixtures, schemas, and workflow state are preserved. The workflow runner retains responsibility for approved-task commits; this execution leaves changes uncommitted.

### Implementation and acceptance coverage

- `Kontrol/Features/Settings/ProjectFoldersSettingsView.swift` introduces the folder section and its per-client presentation state. Both Settings entry points receive the existing graph-owned `ProjectStore`; no new reference/IO owner is created. Hub summaries and folder loading use `loadReferencesIfNeeded()`, and explicit review uses `reloadReferences()` only. No listing/review operation admits external inspection.
- The native semantic `ConfirmationAffordance` captures display name, UUID, and revision independently of subsequent store publications. Copy names the target, states project/.kontrol/Git files remain on disk, and explains picker-authorized re-add. Cancel never calls disconnect; confirmation submits only the captured revision. Stale/missing results require successful explicit reload, review, and a separate new confirmation. That review gate survives Back/re-entry within the Settings client. Failed reload preserves usable rows and the gate.
- Empty, load-unavailable, canceled, stale/missing, busy, failed, and successful outcomes use explicit text (with status icons). Failed/busy results never queue or automatically retry removal. A successful later initial load retires old unavailable copy. A failed reload does not present an empty-list success.
- Add reuses `ProjectAddView`; Reconnect reuses its folder-only native picker configuration and the existing `ProjectStore.reconnect` authorization/validation owner. Construction/listing never requests a picker. Re-add does not recover an old grant or bypass preview/authorization.
- `FoundationSettingsView.swift` observes that same store, adds the folder route/count summary and Back routing, and retains per-client review state across section changes. General preference draft behavior and scene scroll ownership remain unchanged. No Local Data/export or later adaptive/folder-focus task is implemented here.
- Explicit target membership is registered in `Kontrol.xcodeproj/project.pbxproj`. `ProjectsPresentationTests.swift` adds a compiled shared-store fixture: Cancel preserves selected detail; successful Settings removal clears detail and selects a survivor; normal Add/picker owners remain shared. Its repository double now performs identity/revision-checked removal, rather than claiming success.

Fresh non-GUI presentation-state coverage (all executed):

- `SettingsSceneTests/testFolderConfirmationCapturesNameIdentityRevisionCancelAndDurableSuccessAcrossClients`: frozen name/ID/revision, no-effect Cancel, durable publication, shared clients, missing second confirmation, separate review/reconfirmation, selection/empty counts, and zero inspection/bookmark calls.
- `SettingsSceneTests/testFolderStaleConfirmationRequiresSuccessfulExplicitReloadAndSeparateReconfirmation`: newer store publication cannot rebase confirmation; stale removal is blocked; failed review retains rows/gate; successful review never deletes; separate confirmation captures the new name/revision.
- `SettingsSceneTests/testFolderUnavailableMissingBusyAndFailedOutcomesNeverAutomaticallyDelete`: failed initial load and later successful entry, explicit review, busy/failed outcomes, no automatic retry, authoritative missing reference, and local review to an empty list.

### Exact commands, environment, and results

Discovery commands exited **0**: `xcode-select -p`, `xcodebuild -version`, `xcrun swift --version`, `xcodebuild -list -project Kontrol.xcodeproj`, `sw_vers`, `uname -m`. Project-list output: `/tmp/kontrol-f13-step2.5-project-list.log`. Toolchain: **Xcode 27.0 (27A266a), Apple Swift 6.4 (swiftlang-6.4.0.34.1; swift-driver 1.168.6), arm64 macOS 27.0 (26A428)**, developer directory `/Applications/Xcode.app/Contents/Developer`. Resolved Yams remains **5.4.0**; macOS 14 deployment/Swift 5 language mode are unchanged. No baseline-runtime acceptance is claimed.

The plan's unchanged `f13_test` helper ran the required selection, followed by three explicit non-GUI state methods. Standard build and test compilation ran initially, after retaining the review gate across Back, and on final source after repairing stale initial-unavailability copy; **every command exited 0**:

```sh
set -o pipefail
make build DERIVED_DATA=/tmp/kontrol-f13-derived
xcodebuild -project Kontrol.xcodeproj -scheme Kontrol \
  -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath /tmp/kontrol-f13-derived \
  CODE_SIGNING_ALLOWED=NO build-for-testing
f13_test ProjectDisconnectTests ProjectStoreTests ProjectIntegrationTests
f13_test \
  'SettingsSceneTests/testFolderConfirmationCapturesNameIdentityRevisionCancelAndDurableSuccessAcrossClients' \
  'SettingsSceneTests/testFolderStaleConfirmationRequiresSuccessfulExplicitReloadAndSeparateReconfirmation' \
  'SettingsSceneTests/testFolderUnavailableMissingBusyAndFailedOutcomesNeverAutomaticallyDelete'
git diff --check
plutil -lint Kontrol.xcodeproj/project.pbxproj
```

The combined 66-method selection ran twice, including the final verified source. Its exact expanded command is:

```sh
xcodebuild -project Kontrol.xcodeproj -scheme Kontrol \
  -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath /tmp/kontrol-f13-derived \
  -parallel-testing-enabled NO CODE_SIGNING_ALLOWED=NO \
  -only-testing:KontrolTests/ProjectDisconnectTests \
  -only-testing:KontrolTests/ProjectStoreTests \
  -only-testing:KontrolTests/ProjectIntegrationTests \
  -only-testing:KontrolTests/SettingsSceneTests/testFolderConfirmationCapturesNameIdentityRevisionCancelAndDurableSuccessAcrossClients \
  -only-testing:KontrolTests/SettingsSceneTests/testFolderStaleConfirmationRequiresSuccessfulExplicitReloadAndSeparateReconfirmation \
  -only-testing:KontrolTests/SettingsSceneTests/testFolderUnavailableMissingBusyAndFailedOutcomesNeverAutomaticallyDelete test
```

| Selection | Fresh result bundle | Executed / passed | Failures / skips / expected failures |
| --- | --- | --- | --- |
| Required suites | `/tmp/kontrol-f13-derived/Logs/Test/Test-Kontrol-2026.09.30_19-00-01-+0800.xcresult` | 63 / 63 | 0 / 0 / 0 |
| Non-GUI Settings state | `/tmp/kontrol-f13-derived/Logs/Test/Test-Kontrol-2026.09.30_19-00-18-+0800.xcresult` | 3 / 3 | 0 / 0 / 0 |
| Combined intermediate | `/tmp/kontrol-f13-derived/Logs/Test/Test-Kontrol-2026.09.30_19-03-01-+0800.xcresult` | 66 / 66 | 0 / 0 / 0 |
| Combined final verified source | `/tmp/kontrol-f13-derived/Logs/Test/Test-Kontrol-2026.09.30_19-07-27-+0800.xcresult` | **66 / 66** | **0 / 0 / 0** |

Final counts: **9 disconnect, 44 store, 10 integration, 3 Settings state**. Logs are `/tmp/kontrol-f13-builder2.5-{build,bft,required-tests,state-tests,final-build,final-bft,final-tests,verified-build,verified-bft,verified-tests}.log`. Hosted fixtures compile in the final `verified-bft.log`; none of the hosted fixtures were executed in this checkpoint.

Bundle audit commands (all exit **0**): for each table bundle set `RESULT_BUNDLE` to its exact path and `PREFIX` to `/tmp/kontrol-f13-builder2.5-{required,state,final,verified}` respectively, then run:

```sh
xcrun xcresulttool get test-results summary --path "$RESULT_BUNDLE" --format json > "${PREFIX}-summary.json"
xcrun xcresulttool get test-results tests --path "$RESULT_BUNDLE" --format json > "${PREFIX}-test-tree.json"
python3 /tmp/kontrol-f13-builder2.5-audit.py > /tmp/kontrol-f13-builder2.5-selector-audit.log
python3 /tmp/kontrol-f13-builder2.5-cleanup.py > /tmp/kontrol-f13-builder2.5-cleanup.log
python3 /tmp/kontrol-f13-builder2.5-verified-cleanup.py > /tmp/kontrol-f13-builder2.5-verified-cleanup.log
git diff --check
```

The selector audit enumerates every executed full identifier/result, compares exact-once/nonempty selection against current source methods, and reconciles summary counts. All four summaries have empty failure/runtime-warning arrays. Raw-log diagnostic assertions pass: no `vnode unlinked while in use`, `InvalidTransition`, or hosted AX-window failure. Existing malformed-bookmark/linkd diagnostics and multiple-destination/AppIntents warnings are retained; no assertion was weakened and no skip/expected failure was added.

Guarded post-host cleanup enumerated exactly six printed roots under `/var/folders/lz/20cqfx4x2k98r89q68w3q3ch0000gn/T/`: `KontrolProjectDisconnectTests-{17276,17656,18267}` (**2 stores each**) and `KontrolProjectIntegrationTests-{17276,17656,18267}` (**10 each**). Each PID had exited, each root's TMPDIR parent/process-owned name and absence of symlinks were validated, and all **36** read-only SQLite integrity checks returned **ok**. Connections closed and PID exit rechecked before removing only those exact roots; all six no longer exist. Exact paths/results remain in the cleanup logs. After-run original/copy full-entry SHA-256 inventories matched in each run (14 entries per external tree); evidence is `/tmp/kontrol-f13-builder2.5-external-inventories.json` and `/tmp/kontrol-f13-builder2.5-verified-external-inventories.json`. These are after-run inventories, not native screenshots or independent before-captures. The existing integration tests perform before/after external-byte comparisons. No original, production, live, or unlogged historical store was removed.

### A13 — exact changed hosted identifiers and required observations

**Compiled, execution/native acceptance pending; not passed or waived.** Run these changed/additional identifiers with the authorized actual rebuilt host in the reserved desktop, alongside the previously deferred ledger/full-suite requirements:

- `SettingsSceneTests/testNativeFolderRouteNamedCancelStaleReviewFailureAndSuccessUseSharedStore`
- `SettingsSceneTests/testNativeFolderUnavailableRetryAndBusyOutcomeRetainReferences`
- `SettingsSceneTests/testKeyboardHubOrderEditorHandoffNamesTargetsAndFocusReturn`
- `SettingsSceneTests/testNativeAndInlineSettingsGeometryAtCompactDesktopAndAccessibilitySizes`
- `SettingsSceneTests/testSettingsReadFailureRetryAndRetainedEditorGuidanceReflowAtAllNativeSizes`
- `SettingsSceneTests/testSettingsOpenedDuringInitializationAndWindowReopenUseOneGraph`
- `ProjectsPresentationTests/testSettingsRemovalUpdatesSharedProjectsSelectionDetailAndPickerOwnership`

Reference paths: `.mockups/flows/f13-settings-release/{01-settings-hub,12-project-unavailable,13-project-empty,14-removal-confirmation,15-removal-busy,16-removal-failed,17-removal-stale,18-removal-canceled,19-removal-success,22-project-read-failed}.html`, `docs/mockups/M41-remove-project.png`, and existing M28/M33 Add/access-recovery references linked from those HTML pages. Required native observations remain: both real Settings entry points, actual named native Cancel/confirm and unchanged files, stale review after Back/re-entry, busy/failure recovery, surviving Projects selection/detail, normal folder picker Add/Reconnect/re-add, compact/enlarged reachability, keyboard/Escape/focus, independent spoken VoiceOver, and capture/reference comparisons at specified sizes/scales. No capture, GUI authorization, human observation, or VoiceOver attestation was supplied or claimed here. Steps 2.6/2.7 retain their dedicated folder layout/focus fixtures and implementation scope.

**No Step 2.5 implementation blocker remains.** A13 Accessibility/full-suite/native, S13 signed sandbox/picker lifecycles, B13 runtime matrix, and D13 distribution acceptance remain mandatory and pending. This checkpoint is not unconditional F13/release approval.

## F13 folder adaptive layout — current Step 1.1 (2026-09-30, 13:12 UTC)

**Implementation verification passed; native acceptance remains pending A13.** The current plan's first top-level incomplete item and runner task both identify folder reflow Step 1.1 (not the historical foundation Step 1.1 above). Read the full cumulative task-1 checklist; it contains no prior findings. Initial worktree/index were clean, with no interrupted changes to preserve. Repository/target searches (including ignored directories) and direct ancestor checks through `/` found no applicable `AGENTS.md`; `git submodule status` was empty. No plan checkbox, workflow state, staging, commit, schema, fixture, picker owner, removal state transition, or preference resolver was changed.

### Implementation and compiled coverage

- `ProjectFoldersSettingsView.swift`: long names, row status, guidance, reconnect feedback, and outcome labels take their full wrapped height at the proposed document width. Add/review and Reconnect/Remove action groups try their ideal horizontal widths, then fall back to vertical wrapping, following the existing header pattern. Shared `ActionButton` styling/minimum targets are unchanged. All actions remain in the original scene/shell scroll document, with no fixed bars, nested scroll host, or extra text-scale calculation.
- The native `ConfirmationAffordance` remains platform-owned; captured name/identity/revision and Cancel/confirm semantics are unchanged. Re-add guidance is separated into a paragraph for native wrapping. No custom modal, fixed alert dimensions, or duplicate scaling was introduced.
- `FoundationSettingsView.swift` was inspected but needed no change: it already provides the adaptive Back header, full-width document, single scene-owned scroll, and retained per-client review state.
- `SettingsSceneTests.swift`: five dedicated hosted methods cover populated, empty, unavailable (failed reload with retained rows), stale, and removal states. Each uses real native/inline scene roots and navigation: native at **520×340, 1000×700, 1440×940**; inline at its supported **1000×700, 1440×940** minimums. Each combination covers standard text, committed Large at **130%**, and committed Large plus a larger system size at **160%**: **15 combinations per state, 75 total**.
- Fixtures require exactly one scroll document/no horizontal overflow, unchanged viewport size, onscreen vertical-scroll reachability, nonoverlap, ≥32-point document action targets, full spaced/unbroken names, and actual multiline compact name bounds. A short peer name's rendered-height ratio checks single scaling and preservation of larger system text. Native removal coverage checks complete captured title/message, sheet content/action bounds and minimum targets, then Cancel and durable success with surviving rows. Failed assertions cancel any attached native sheet during cleanup, never confirm. Recovery and removal fixtures assert zero external inspection/feed requests and zero preference saves.
- Existing state regressions continue to cover canceled, removed, stale/missing, busy, failed, and unavailable outcomes. They executed here; the new window/AX fixtures did **not** execute. Their geometry/target assertions are deferred, not credited as observed passes.

References inspected: `docs/mockups/M41-remove-project.png` and `.mockups/flows/f13-settings-release/{12-project-unavailable,13-project-empty,14-removal-confirmation,17-removal-stale,20-compact-navigation,21-enlarged-text}.html`. Existing references cover this reflow; no uncovered state or redesign was introduced.

### Exact commands and fresh evidence

Discovery (all exit **0**): `git status --short`, `git diff --stat`, `git diff --cached --stat`, `git submodule status`, `xcode-select -p`, `xcodebuild -version`, `xcrun swift --version`, `xcodebuild -list -project Kontrol.xcodeproj`, `sw_vers`, `uname -m`. Repeated environment output is `/tmp/kontrol-f13-folder-layout1.1.EhACgw/preflight.log`: **Xcode 27.0 (27A266a), Swift 6.4 (swiftlang-6.4.0.34.1; driver 1.168.6), arm64 macOS 27.0 (26A428)**; developer directory `/Applications/Xcode.app/Contents/Developer`. Yams resolved to unchanged **5.4.0**. Source base: `87faaf8c70a965c10f66437b45bac11e56c6278b`; final two-source-file patch is `final-source.diff` in that evidence directory, SHA-256 **`8c970a90690cd2d5f732a085b470ad70e63b36d3a08eb3b08a920afb64a89ed6`**.

Required commands ran initially and again after final fixture cleanup changes; final commands below all exited **0**:

```sh
set -o pipefail
make build DERIVED_DATA=/tmp/kontrol-f13-derived
xcodebuild -project Kontrol.xcodeproj -scheme Kontrol \
  -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath /tmp/kontrol-f13-derived \
  CODE_SIGNING_ALLOWED=NO build-for-testing
xcodebuild -project Kontrol.xcodeproj -scheme Kontrol \
  -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath /tmp/kontrol-f13-derived \
  -parallel-testing-enabled NO CODE_SIGNING_ALLOWED=NO \
  -only-testing:KontrolTests/DesignSystemTokenTests \
  -only-testing:KontrolTests/ProjectDisconnectTests \
  -only-testing:KontrolTests/SettingsSceneTests/testFolderConfirmationCapturesNameIdentityRevisionCancelAndDurableSuccessAcrossClients \
  -only-testing:KontrolTests/SettingsSceneTests/testFolderStaleConfirmationRequiresSuccessfulExplicitReloadAndSeparateReconfirmation \
  -only-testing:KontrolTests/SettingsSceneTests/testFolderUnavailableMissingBusyAndFailedOutcomesNeverAutomaticallyDelete test
git diff --check
```

The test command is exactly the plan's `f13_test` selection expanded. **19/19 passed**: seven token methods, nine disconnect methods, three explicitly selected non-GUI Settings methods; **0 failures, skips, expected failures, or result-bundle runtime warnings**. Final logs: `/tmp/kontrol-f13-folder-layout1.1.EhACgw/{final-build,final-bft,final-tests,final-diffcheck,final-exit-codes}.log`. Final bundle: `/tmp/kontrol-f13-derived/Logs/Test/Test-Kontrol-2026.09.30_21-12-12-+0800.xcresult`; independently retained copy: `/tmp/kontrol-f13-folder-layout1.1.EhACgw/verified-final.xcresult`. Earlier passing selections: `Test-Kontrol-2026.09.30_21-05-26-+0800.xcresult` and `Test-Kontrol-2026.09.30_21-09-07-+0800.xcresult`, each 19/19. Intermediate audited bundle is also copied to the unique evidence directory as `final.xcresult`; it is not the final source's bundle.

Final result audit commands (all exit **0**):

```sh
EVIDENCE=/tmp/kontrol-f13-folder-layout1.1.EhACgw
RESULT_BUNDLE='/tmp/kontrol-f13-derived/Logs/Test/Test-Kontrol-2026.09.30_21-12-12-+0800.xcresult'
xcrun xcresulttool get test-results summary --path "$RESULT_BUNDLE" --format json > "$EVIDENCE/final-summary.json"
xcrun xcresulttool get test-results tests --path "$RESULT_BUNDLE" --format json > "$EVIDENCE/final-test-tree.json"
python3 "$EVIDENCE/final-audit.py" > "$EVIDENCE/final-selector-audit.log"
ditto "$RESULT_BUNDLE" "$EVIDENCE/verified-final.xcresult"
```

Audit enumerates every executed identifier, compares suite methods/exact selectors against source, and verifies exact-once/nonempty selection and counts. Raw logs contain no live-store unlink or `InvalidTransition` diagnostic; existing multiple-destination/AppIntents/linkd warnings remain recorded, not hidden. Six process-owned disk stores and sidecars remain intact under `/var/folders/lz/20cqfx4x2k98r89q68w3q3ch0000gn/T/KontrolProjectDisconnectTests-{32015,33116,33927}` (two stores per root). Their actual paths and exited host-PID checks are in `final-selector-audit.log`. No temporary-store cleanup was performed; no production/external folder was used.

**Evidence retention incident:** the initial fresh command reused the historical foundation Step 1.1 `/tmp/kontrol-f13-step1.1-{tests.log,summary.json,test-tree.json}` names, inadvertently overwriting those raw exports. Fresh outputs were moved to the distinct `/tmp/kontrol-f13-folder-layout1.1-*` prefix and subsequent runs use the unique evidence directory above. Recovery from historical `Test-Kontrol-2026.09.30_16-01-30-+0800.xcresult` was attempted with `xcresulttool get test-results summary/tests` and `get log --type console/action`; each exited **64**, because that old bundle is no longer on disk. The empty failed-recovery outputs were removed, not represented as recovered evidence. Original raw exports cannot be restored here; the unchanged historical ledger and `/tmp/kontrol-f13-step1.1-selector-audit.log` still preserve all 22 failed identifiers/messages and 111-method counts, and the historical toolchain/diff-check artifacts remain. This is an artifact-retention limitation, **not** closure or conversion of the historical failed gate. Final fresh bundles were copied outside Xcode's result-retention directory to avoid further evidence loss.

### A13 — exact newly deferred selectors and observations

Compiled in final `build-for-testing`, **not executed or waived**:

- `SettingsSceneTests/testFolderPopulatedLongNamesAndActionsReflowAtAllSettingsSizes`
- `SettingsSceneTests/testFolderEmptyGuidanceAndActionsReflowAtAllSettingsSizes`
- `SettingsSceneTests/testFolderUnavailableRecoveryAndRetainedRowsReflowAtAllSettingsSizes`
- `SettingsSceneTests/testFolderStaleReviewAndDisabledRemovalReflowAtAllSettingsSizes`
- `SettingsSceneTests/testFolderRemovalConfirmationCancelAndSuccessReflowAtAllSettingsSizes`

Run these alongside the existing deferred ledgers with a human-reserved uncontended desktop and actual rebuilt host AX authorization. Fixtures attach captures with content-point/pixel dimensions and backing scale; **none was produced here**. Required independent observations remain: long names/recovery/confirmation wrapping, fully reachable actions at all sizes/scales, native alert target geometry, visible keyboard focus and Escape/Cancel, spoken VoiceOver, reduced motion, contrast/non-color status, and rendered comparisons against the listed references. No user attestation was supplied. Surviving-control focus implementation remains current Step 1.2, not implemented by this task. A13/S13/B13/D13 and historical evidence limitations remain release concerns; this is not unconditional F13 or V1 completion.

## F13 folder surviving-control focus — current Step 1.2 (2026-09-30, 13:28 UTC)

**Implementation verification passed; hosted/native acceptance remains pending A13.** The first top-level incomplete task matches runner Step 1.2. The complete cumulative task-2 checklist has no previous findings. Initial worktree/index were clean; no interrupted changes existed. Repository/target and direct ancestor instruction checks found no applicable `AGENTS.md`; no submodule was identified. No plan checkbox, workflow state, staging, commit, schema, fixture, disconnect state model, picker owner, or preference draft behavior was changed.

### Implementation and coverage

- `ProjectFoldersSettingsView.swift`: stable Add, review, and UUID-keyed Reconnect/Remove focus targets use the existing native `ActionButton` focus ring. Confirmation dismissal restores the captured origin only if it remains enabled and present. Stale/unavailable removal restores review; successful deletion chooses a surviving row by display order then UUID, or Add for an empty list. Failed/busy removal and canceled confirmation return to the surviving origin. Resolution happens after a UI yield against current rows, with presentation/modal guards, not against the frozen confirmation. Row publications also revalidate current focus.
- Add sheet dismissal (Cancel or Escape) restores Add via `onDismiss`. Escape only dismisses the existing Add presentation; its existing `onDisappear` cancellation remains the owner. Reconnect picker cancellation restores the current row or a survivor. Approved selection restores Add while Reconnect is disabled, then a surviving Reconnect action after validation finishes. No picker grant, reconnect validation, or persistence semantics changed.
- Row status and reconnect feedback now use text plus native symbols; existing outcome labels remain text plus symbol. No new status state, color-only feedback, animation, announcement loop, scroll host, or text-scale calculation was introduced.
- `FoundationSettingsView.swift` was inspected and intentionally unchanged. Its Back handoff and per-client folder-review owner already satisfy this task. The hub keyboard-order test now checks Back → Add → review → Back inside the empty folder route, then the existing Back → folders hub action → next hub action return.
- `SettingsSceneTests.swift`: the three required non-GUI state methods now assert focus policy for Cancel, durable survivor/last-row removal, stale review, failed reload, and failed/busy deletion without changing state assertions. Three new hosted fixtures cover logical row order, meaningful role/name/target size, Cancel and Escape with zero deletion, failed/busy removal, survivor and last-row focus, stale/failed/successful review and separate reconfirmation, Add Cancel/Escape, native Reconnect cancellation, and another client's deletion while that panel is open. These fixtures compile; **their native responder assertions and captures have not run**.
- `ProjectsPresentationTests.swift`: a new explicitly non-GUI focus-policy method verifies fetch-order independence, display-order/UUID survivor choice, surviving origins, disabled Remove/Reconnect recovery, last-row fallback, and Add/review targets. It executed and passed.

Inspected references: `docs/mockups/M41-remove-project.png` and `.mockups/flows/f13-settings-release/index.html` (removal decision branches and existing focus/status conventions). Existing references cover these states; no redesign or uncovered state was introduced. General drafts, shared ownership, and independent stale-review gates remain covered by the required preference and folder-state regressions.

### Exact commands and fresh evidence

Environment: **Xcode 27.0 (27A266a), Swift 6.4 (swiftlang-6.4.0.34.1; driver 1.168.6), arm64 macOS 27.0 (26A428)**; `/Applications/Xcode.app/Contents/Developer`; unchanged Yams **5.4.0**. Source base: **`3c542acbcfe000d553affd0c22fc2f2edbeb8031`**. Evidence directory: **`/tmp/kontrol-f13-folder-focus1.2.hHI3lh`**. Three-file source/test patch: `source.diff`, SHA-256 **`223cd748ea06a9eac5633caad9e52aed275b8cdf85f21bb80a610c824a052397`** (excludes this QA append).

Discovery commands: `git status --short`, `git diff --stat`, `git diff --cached --stat`, `git submodule status`, `xcode-select -p`, `xcodebuild -version`, `xcrun swift --version`, `xcodebuild -list -project Kontrol.xcodeproj`, `sw_vers`, `uname -m`; successful outputs retained in `preflight.log` (initial clean status was inspected before edits; that log captures post-edit status).

All following validation commands exited **0**; results and exit codes are retained in `{build,bft,required-tests,focus-policy-tests,diffcheck,exit-codes}.log`:

```sh
set -o pipefail
EVIDENCE=/tmp/kontrol-f13-folder-focus1.2.hHI3lh
make build DERIVED_DATA=/tmp/kontrol-f13-derived
xcodebuild -project Kontrol.xcodeproj -scheme Kontrol \
  -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath /tmp/kontrol-f13-derived \
  CODE_SIGNING_ALLOWED=NO build-for-testing
xcodebuild -project Kontrol.xcodeproj -scheme Kontrol \
  -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath /tmp/kontrol-f13-derived \
  -parallel-testing-enabled NO CODE_SIGNING_ALLOWED=NO \
  -resultBundlePath "$EVIDENCE/required.xcresult" \
  -only-testing:KontrolTests/ProjectDisconnectTests \
  -only-testing:KontrolTests/AppPreferencesStoreTests \
  -only-testing:KontrolTests/SettingsSceneTests/testFolderConfirmationCapturesNameIdentityRevisionCancelAndDurableSuccessAcrossClients \
  -only-testing:KontrolTests/SettingsSceneTests/testFolderStaleConfirmationRequiresSuccessfulExplicitReloadAndSeparateReconfirmation \
  -only-testing:KontrolTests/SettingsSceneTests/testFolderUnavailableMissingBusyAndFailedOutcomesNeverAutomaticallyDelete test
xcodebuild -project Kontrol.xcodeproj -scheme Kontrol \
  -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath /tmp/kontrol-f13-derived \
  -parallel-testing-enabled NO CODE_SIGNING_ALLOWED=NO \
  -resultBundlePath "$EVIDENCE/focus-policy.xcresult" \
  -only-testing:KontrolTests/ProjectsPresentationTests/testFolderFocusPolicyUsesCurrentRowsDisplayOrderAndEnabledSurvivors test
git diff --check
```

The required selection is the plan's `f13_test` command expanded, with a unique retained result path: **25/25 passed** (13 preferences, nine disconnect, three Settings state methods). The additional policy selection passed **1/1**. Both bundles have zero failures, skips, expected failures, or runtime warnings. `build-for-testing` compiles all hosted tests, not just these selections.

Fresh audit commands, all exit **0**:

```sh
for name in required focus-policy; do
  xcrun xcresulttool get test-results summary \
    --path "$EVIDENCE/$name.xcresult" --format json > "$EVIDENCE/$name-summary.json"
  xcrun xcresulttool get test-results tests \
    --path "$EVIDENCE/$name.xcresult" --format json > "$EVIDENCE/$name-test-tree.json"
done
python3 "$EVIDENCE/audit.py" > "$EVIDENCE/selector-audit.log"
```

Audit compares executed identifiers with source suite methods and exact selectors: each expected method executed once, with nonempty counts and Passed results. Test hosts **38812/38884** exited (`ps -p 38812,38884 -o pid=,stat=,command=` returned 1 with no processes). Two isolated stores and sidecars remain intact under `/var/folders/lz/20cqfx4x2k98r89q68w3q3ch0000gn/T/KontrolProjectDisconnectTests-38812/{4A706585-132A-4898-B4CE-63D63DF1C3CF,C9BC53C4-FE7E-45ED-A8F7-72258C027BED}/Kontrol.store`; inventory is recorded in `selector-audit.log`. No cleanup, production-store use, or external project IO was performed. Fresh logs contain no `InvalidTransition` or live-store unlink diagnostic. Existing multiple-destination, AppIntents, linkd, and optional-value interpolation diagnostics are retained in logs (the interpolation warning is in the unchanged geometry capture helper); no historical failure was erased or converted into acceptance.

### A13 — exact deferred selectors and spoken observations

Compiled, **not executed or waived**:

- `SettingsSceneTests/testKeyboardFolderOrderCancelFailureBusyAndRemovalRestoreOnlySurvivingActions`
- `SettingsSceneTests/testKeyboardFolderStaleAndFailedReviewKeepReviewFocusUntilSeparateReconfirmation`
- `SettingsSceneTests/testKeyboardFolderAddAndReconnectDismissalRestoreSurvivingActions`
- Updated `SettingsSceneTests/testKeyboardHubOrderEditorHandoffNamesTargetsAndFocusReturn`
- Existing `ProjectsPresentationTests/testSettingsRemovalUpdatesSharedProjectsSelectionDetailAndPickerOwnership` remains compile-only here; its prior deferred status is unchanged.

Run these with the existing geometry/deferred selectors in a reserved, uncontended desktop with Accessibility authorization for the actual rebuilt host. Capture points/pixels/backing scale and compare the existing folder/removal references at the required sizes/text scales. **No native capture or spoken VoiceOver observation was produced in this task, and no user attestation was supplied.** Independently observe visible focus, Tab/Shift-Tab order, named Reconnect/Remove roles, captured target spoken in confirmation, Escape/Cancel without deletion, focus on enabled survivors after removal/panel dismissal, review/reconfirmation announcements, status without reliance on color, reduced motion, enlarged text reachability, and contrast. A13/S13/B13/D13 and historical release concerns remain pending; this is implementation verification only, not F13/V1 release approval.

## F13 Step 2.1 — detached version-1 export contract (2026-09-30)

The first incomplete task matched runner task 3, **Step 2.1**. The cumulative
review checklist had no previous findings. Initial worktree/index were clean;
repository/target and direct ancestor checks found no applicable `AGENTS.md` or
submodule. Changes are limited to `Kontrol/Domain/LocalDataExport.swift`,
`KontrolTests/LocalDataExportTests.swift`, `docs/export-format.md`, explicit source/
test membership in `Kontrol.xcodeproj/project.pbxproj`, and this evidence append.
No workflow state, frozen schema, dependency pin, fixture, or later export task
was changed. Projections, persisted capture, file IO/service, and UI remain later
checkpoints; this is not F13/release completion.

The contract includes all required envelope fields/nine Learning collections,
detached `Codable`/`Sendable` values, typed finite UTC millisecond instants,
required nullable keys, identity/version validation, deterministic identity/set
ordering, exact authored section/self-check/answer text, allowlisted provenance,
and honest legacy nulls. No SwiftData object, opaque blob, credential reference,
project grant/path, article cache/transport, diagnostics, or unsaved editor owner
exists in the DTO graph. The format document enumerates every field/default/null/
validation/ordering rule and explicitly disclaims encrypted backup and restore.

Environment: **Xcode 27.0 (27A266a), Swift 6.4 (swiftlang-6.4.0.34.1; driver
1.168.6), arm64 macOS 27.0 (26A428)**; developer directory
`/Applications/Xcode.app/Contents/Developer`; unchanged Yams **5.4.0**. Source
base: **`9af422eeee72f9100ade8c95d133ae7b981ac7b0`**. Evidence directory:
**`/tmp/kontrol-f13-contract2.1.hxbnhK`**. Four-file patch (including new untracked
files, excluding this QA append): `source.diff`, SHA-256
**`ba34d8ed752a025121fec8a2179bd007cf77c85a887ec7ca093cef7b60cfcdd6`**.
Discovery outputs are retained in `preflight.log`: `git status --short`,
`git diff --stat`, `git diff --cached --stat`, `git submodule status`,
`git rev-parse HEAD`, `xcode-select -p`, `xcodebuild -version`,
`xcrun swift --version`, `xcodebuild -list -project Kontrol.xcodeproj`, `sw_vers`,
`uname -m`. Initial clean status was inspected before edits; the saved preflight
captures post-edit status.

### Commands and fresh results

Final source validation, all exit **0** (logs `build-final.log`, `bft-final.log`,
`tests-final.log`, `diffcheck.log`, and `exit-codes.log`):

```sh
set -o pipefail
EVIDENCE=/tmp/kontrol-f13-contract2.1.hxbnhK
make build DERIVED_DATA=/tmp/kontrol-f13-derived
xcodebuild -project Kontrol.xcodeproj -scheme Kontrol \
  -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath /tmp/kontrol-f13-derived \
  CODE_SIGNING_ALLOWED=NO build-for-testing
xcodebuild -project Kontrol.xcodeproj -scheme Kontrol \
  -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath /tmp/kontrol-f13-derived \
  -parallel-testing-enabled NO CODE_SIGNING_ALLOWED=NO \
  -resultBundlePath "$EVIDENCE/contract-final.xcresult" \
  -only-testing:KontrolTests/LocalDataExportTests test
git diff --check
```

The test command is `f13_test LocalDataExportTests` expanded with a fresh retained
result bundle. **19/19 methods passed**, zero failures, skips, expected failures,
or xcresult runtime warnings. `build-for-testing` compiled all existing hosted
coverage as well as the new tests; no UI/AX/native acceptance was executed or
inferred. The new suite is pure value serialization/validation, with no test
store, external project, credentials, network, or destination access.

Fresh audits and documented JSON parsing, all exit **0**:

```sh
xcrun xcresulttool get test-results summary \
  --path "$EVIDENCE/contract-final.xcresult" --format json \
  > "$EVIDENCE/contract-final-summary.json"
xcrun xcresulttool get test-results tests \
  --path "$EVIDENCE/contract-final.xcresult" --format json \
  > "$EVIDENCE/contract-final-test-tree.json"
python3 "$EVIDENCE/audit.py" > "$EVIDENCE/selector-example-audit.log"
python3 -m json.tool "$EVIDENCE/example-1.json" >/dev/null
plutil -lint Kontrol.xcodeproj/project.pbxproj
```

`audit.py` extracts every JSON fence from `docs/export-format.md`, parses it,
checks the exact envelope/nine collection keys, and saves the actual example as
`example-1.json`: **1/1 parsed**. It compares fresh executed identifiers with all
source test methods, requiring every expected method exactly once with Passed
results: **19/19**, nonempty. Full method identifiers/results are recorded in
`selector-example-audit.log` and `contract-final-test-tree.json`. Coverage includes
empty/rich round trips, every nullable key, required empty arrays, all collection
identities and set duplicates, malformed UUIDs/versions/dates, pin/slot/terminal
identity mismatches, planned zone/components, every persisted Focus state,
complete deterministic collection ordering, ordered teaching/self-check content,
exact whitespace/Unicode/secret-looking strings, allowlisted fields, and legacy
absence without substitution.

### Intermediate failures and repairs (preserved)

- Initial `make build` passed (`build.log`, exit 0).
- Initial `build-for-testing` failed (`bft.log`, exit **65**) with two new-test
  diagnostics: `call can throw but is not marked with 'try'` on the second
  arguments of encoding equality assertions. Added the two missing `try`
  keywords; the same command passed (`bft-repair.log`, exit 0), followed by
  **15/15** initial tests (`tests.log`, `contract.xcresult`, exit 0). These original
  logs/results remain intact; final validation above supersedes them.
- Timestamp inspection found Foundation's default Gregorian formatter switches
  to Julian dates before 1582. Set `gregorianStartDate` to the lower allowed
  instant, then added lower-bound/proleptic-date regressions and more null,
  state, UTF-8 slot-key, and all-collection ordering tests. The final build,
  compilation, and **19/19** test run validate those changes.
- Additional new-file whitespace checks used
  `git diff --no-index --check /dev/null <new-file>` for the three new files.
  Each emitted no whitespace diagnostics (`newfile-diffcheck.log`); exit **1**
  denotes file differences under `--no-index`, not a whitespace error. The final
  tracked `git diff --check` passed with exit 0.

Existing multiple-destination/AppIntents/linkd host diagnostics are retained in
logs, not treated as new contract failures. Test hosts **45207/46463** exited:
`ps -p 45207,46463 -o pid=,stat=,command=` returned 1 with no rows
(`host-exit.log`). No fixture/store cleanup was needed or performed. No historical
failed/skipped evidence was removed. There are **no remaining Step 2.1 blockers**;
A13/S13/B13/D13, native observations, migration investigation, and later export
implementation remain separate mandatory checkpoints.

## F13 Step 2.2 — Read-only Daily export projection (2026-09-30)

Confirmed the first top-level incomplete task in `.pi/PLAN.md` matches runner
Step 2.2. The cumulative task-4 review checklist had no previous findings.
Initial worktree/index were clean; no applicable ancestor or target `AGENTS.md`
or submodule was found. No workflow state, frozen schema, fixture, dependency pin,
feature owner, or external project was changed.

Added `Kontrol/Data/Export/DailyDataExportProjection.swift` with explicit app-target
membership. Its main-actor synchronous mapping copies every persisted task, block,
and Focus field, preserving exact authored bytes, original planned-day calendar/
zone, optional legacy absence, historical links/titles, checkpoints and recovery
flags. Shared contract validation and the pure `FocusSessionSnapshot` validator
reject damaged records, duplicate IDs and multiple active sessions, without
repair/omission. The mapper has no context, clock, save, timer transition,
reconciliation, service, network, credential, or folder-access boundary. Fetching
a coherent committed snapshot remains Step 2.6, not a claim made by this mapper.
Configuration/Learning projection remains later work. Updated the format document
with the actual mapper API and storage-specific validation rules.

Environment: **Xcode 27.0 (27A266a), Swift 6.4 (swiftlang-6.4.0.34.1; driver
1.168.6), arm64 macOS 27.0 (26A428)**; developer directory
`/Applications/Xcode.app/Contents/Developer`; unchanged Yams **5.4.0**.
Source base: **`bdf2e6e497dc4820d01af52e61e00f4728b64ff0`**.
Evidence: **`/tmp/kontrol-f13-daily2.2.7bvrVR`**. Four-file implementation/test/
format/project patch (including the new untracked source, excluding this QA
append): `source.diff`, SHA-256
**`8cf6bf588bfd2461c5bb5afe19069a33c96878b2678307836b5d7b61c2c5df4e`**.
`preflight.log` records `git status --short`, `git diff --stat`,
`git diff --cached --stat`, `git submodule status`, `git rev-parse HEAD`,
`xcode-select -p`, `xcodebuild -version`, `xcrun swift --version`,
`xcodebuild -list -project Kontrol.xcodeproj`, `sw_vers`, and `uname -m`.
The retained preflight status is post-edit; initial clean status was checked
before implementation.

### Exact commands and fresh results

All required commands exited **0**; no intermediate build/test failures:

```sh
set -o pipefail
EVIDENCE=/tmp/kontrol-f13-daily2.2.7bvrVR
xcodebuild -project Kontrol.xcodeproj -scheme Kontrol \
  -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath /tmp/kontrol-f13-derived \
  CODE_SIGNING_ALLOWED=NO build-for-testing
xcodebuild -project Kontrol.xcodeproj -scheme Kontrol \
  -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath /tmp/kontrol-f13-derived \
  -parallel-testing-enabled NO CODE_SIGNING_ALLOWED=NO \
  -resultBundlePath "$EVIDENCE/daily.xcresult" \
  -only-testing:KontrolTests/LocalDataExportTests \
  -only-testing:KontrolTests/FocusRepositoryTests test
make build DERIVED_DATA=/tmp/kontrol-f13-derived
git diff --check
```

The test command expands `f13_test LocalDataExportTests FocusRepositoryTests`
with an explicit fresh bundle. Logs: `bft.log`, `tests.log`, `build.log`,
`diffcheck.log`, `exit-codes.log`. **53/53 passed**: **27 LocalDataExportTests**
(including eight new projection methods), **26 FocusRepositoryTests**; zero
failures, skips, expected failures, or xcresult runtime warnings.
`build-for-testing` compiled all existing hosted coverage; these selections
exercise no native UI/AX assertions. A13/S13/B13/D13 remain separate mandatory
gates, not inferred passes.

Fresh audit/static commands also exited **0**:

```sh
xcrun xcresulttool get test-results summary \
  --path "$EVIDENCE/daily.xcresult" --format json > "$EVIDENCE/summary.json"
xcrun xcresulttool get test-results tests \
  --path "$EVIDENCE/daily.xcresult" --format json > "$EVIDENCE/test-tree.json"
python3 "$EVIDENCE/audit.py" > "$EVIDENCE/audit.log"
python3 -m json.tool "$EVIDENCE/example-1.json" >/dev/null
plutil -lint Kontrol.xcodeproj/project.pbxproj
```

`audit.py` compared fresh method identifiers with all source methods in both
selected suites: **53/53 executed exactly once**, all Passed, nonempty selection.
Every identifier/result is retained in `audit.log` and `test-tree.json`.
The documented JSON example also parsed **1/1**. New-file whitespace inspection
used `git diff --no-index --check /dev/null
Kontrol/Data/Export/DailyDataExportProjection.swift`: exit **1** denotes added
file differences, with no whitespace diagnostics (`newfile-diffcheck.log`).

New methods (all `KontrolTests/LocalDataExportTests/`, Passed):

- `testDailyProjectionMapsEveryTaskAndBlockFieldWithoutAuthoredNormalization`
- `testDailyProjectionMapsEveryFocusStateTimingLinkAndRecoveryFieldWithoutAdvancement`
- `testDailyProjectionSortsByIdentityAndDetachesValuesWithoutReplacingOtherEnvelopeFields`
- `testDailyProjectionRejectsDamagedTasksIncludingBothOneSidedPlannedDayCases`
- `testDailyProjectionRejectsDamagedBlocksAndBoundsCollapsedByMillisecondRounding`
- `testDailyProjectionRejectsCorruptFocusRecordsInsteadOfRepairingOrDroppingThem`
- `testDailyProjectionRejectsDuplicateRecordIDsAndConflictingActiveRows`
- `testDailyProjectionLeavesPersistedInventoryActiveSessionAndAnotherOwnersDraftUntouched`

These cover complete-field DTO equality, all four stored states, paused recovery,
wall rollback anchors, missing scalar targets, retained unlinked titles, null/
empty notes, Buddhist planned dates, exact UTF-8 authored strings, deterministic
UUID order, independence from later edits, every corrupt date field, invalid
state/timing/link combinations, and rejection of both one-sided planned-day
fields. The isolated in-memory fixture confirms no context changes, task or
Learning completion, timer advancement/recovery, persisted inventory changes,
or another owner's draft save/overwrite. Production projection performs no IO.

Existing Focus tests created **10 isolated disk-store roots**, recorded exactly
in `focus-test-store-roots.txt` under
`/var/folders/lz/20cqfx4x2k98r89q68w3q3ch0000gn/T/` (birth times within the fresh
result interval). The initial `/tmp` before/after directory enumerations did not
locate those Foundation temporary roots; the post-run audit records their actual
paths. All roots/sidecars remain preserved; no cleanup was performed. Test host
**51941** exited: `ps -p 51941 -o pid=,stat=,command=` returned **1** with no rows
(`host-exit.log`). Existing multiple-destination and linkd/AppIntents diagnostics
remain in logs, not new projection failures. No historical failed/skipped
evidence was removed. **No remaining Step 2.2 blockers.**

### F13 Step 2.3 — effective configuration projection (2026-09-30)

Implemented read-only general/AI/News configuration mapping in
`Kontrol/Data/Export/DailyDataExportProjection.swift`; added nine non-GUI methods
in `KontrolTests/LocalDataExportTests.swift` and documented the storage boundary
in `docs/export-format.md`. The cumulative task-5 checklist had no prior findings.
No UI, schema, feature-owner, Keychain, or News initialization changes were made.

Evidence root: **`/tmp/kontrol-f13-step2-3-20260930T223136/`**. Baseline HEAD:
`8a693249752f7b6d1c1124a9bacbf8c657d82e91`; initial worktree/index were clean.
`source.diff` captures the three implementation/format files tested; SHA-256:
`884048110d7263952160262082454d435d53a0f5878c64219472438055bb2a44`.
This ledger addition is the only later change. `environment.log` records macOS
27.0 (26A428), arm64, Xcode 27.0 (27A266a), Swift compiler 6.4, and the selected
Xcode path. Swift 5 project language mode and macOS 14 deployment remain unchanged.

Exact commands (from repository root; `EVIDENCE` is the root above):

```sh
set -o pipefail
xcodebuild -project Kontrol.xcodeproj -scheme Kontrol \
  -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath /tmp/kontrol-f13-derived \
  -parallel-testing-enabled NO CODE_SIGNING_ALLOWED=NO \
  -resultBundlePath "$EVIDENCE/configuration.xcresult" \
  -only-testing:KontrolTests/LocalDataExportTests \
  -only-testing:KontrolTests/AppPreferencesRepositoryTests \
  -only-testing:KontrolTests/NewsRepositoryTests \
  -only-testing:KontrolTests/AISettingsStoreTests test
make build DERIVED_DATA=/tmp/kontrol-f13-derived
git diff --check
xcrun xcresulttool get test-results summary \
  --path "$EVIDENCE/configuration.xcresult" --format json > "$EVIDENCE/summary.json"
xcrun xcresulttool get test-results tests \
  --path "$EVIDENCE/configuration.xcresult" --format json > "$EVIDENCE/test-tree.json"
python3 "$EVIDENCE/audit.py" > "$EVIDENCE/audit.log"
python3 -m json.tool "$EVIDENCE/example-1.json" >/dev/null
plutil -lint Kontrol.xcodeproj/project.pbxproj
```

All final commands exited **0**. Logs: `tests.log`, `build.log`, `diffcheck.log`,
`plutil.log`, and `exit-codes.log`; fresh results: `configuration.xcresult`,
`summary.json`, `test-tree.json`, and `audit.log`. **87/87 methods Passed**:
36 LocalDataExportTests, 17 AppPreferencesRepositoryTests, 17 NewsRepositoryTests,
17 AISettingsStoreTests. Zero failures, skips, expected failures, or xcresult
runtime warnings. The source-identifier audit confirms every expected method
executed exactly once. Its initial regex incorrectly included the test transport
stub's `testConnection()` (exit 1); restricting discovery to each XCTestCase class
corrected the audit, which then exited 0. No XCTest failed or was excluded.
The format's JSON example parsed **1/1**. `test` compiled the hosted test target;
no UI was introduced and no hosted/native selectors were required by Step 2.3.
A13/S13/B13/D13 remain separate mandatory release gates, not inferred passes.

New methods (all `KontrolTests/LocalDataExportTests/`, Passed):

- `testConfigurationProjectionMissingRowsUsesBundledEffectiveDefaultsNotEmptyDTO`
- `testConfigurationProjectionAllPersistedDefaultCombinationsAndExplicitEmptyNews`
- `testConfigurationProjectionMapsAllowlistedFieldsExactlyAndNeverEmitsExcludedMetadata`
- `testConfigurationProjectionRejectsDamagedGeneralAndAIRowsWithoutFallback`
- `testConfigurationProjectionRejectsDuplicateAndForeignSingletonsOrOrphanedFeeds`
- `testConfigurationProjectionRejectsCorruptUnsupportedOversizedAndDuplicateTopicPayloads`
- `testConfigurationProjectionRejectsInvalidFeedsEndpointsMappingsAndLimits`
- `testConfigurationProjectionSortsDetachesAndPreservesOtherEnvelopeContent`
- `testConfigurationProjectionNeverInsertsDefaultsSavesOrChangesOtherOwnersDrafts`

Coverage includes all 12 missing/persisted general/AI/News combinations, actual
bundled defaults only for absent preference AND feeds, explicit empty selection/
feeds, exact allowlisted values and secret-looking names/endpoints, disabled
configured AI models, supported maximum Focus duration, detached deterministic
ordering, unrelated envelope preservation, malformed included fields and payload
versions, orphaned feeds, singleton/record duplication, foreign keys, endpoint
policy/normalized uniqueness, topic mappings, and feed limits. In-memory fixtures
confirm defaults insert no rows, projection leaves its context clean, persisted
inventories/values remain unchanged, and another owner's unsaved feed draft is
neither saved nor overwritten. Excluded feed diagnostics/validators/timestamps
are not read or emitted, even when malformed. Production mapping has no context,
feature-store, network, credential-resolution, or Keychain dependency.

The unchanged disk-backed NewsRepositoryTests reproduced **45 SQLite unlink
API-violation messages** across **15 store roots** (store/WAL/SHM), retained in
`tests.log` and enumerated in `sqlite-diagnostic-paths.txt`. These originate from
existing test cleanup while contexts remain alive; this task added only in-memory
fixtures and did not alter those tests or perform store cleanup. The test host
PID **57864** exited: `ps -p 57864 -o pid=,stat=,command=` returned **1** with no
rows (`host-exit.log`). Existing multiple-destination/linkd diagnostics also remain
in logs. No historical failed/skipped evidence was removed. **No remaining Step
2.3 blockers.**

### F13 Step 2.4 — stored Learning taxonomy and definitions (2026-09-30)

Implemented `Kontrol/Data/Export/LearningExportProjection.swift`, explicitly
registered in `Kontrol.xcodeproj/project.pbxproj`. Added eleven non-GUI methods
to `KontrolTests/LocalDataExportTests.swift`; documented the storage-specific
validation/provenance allowlist in `docs/export-format.md`. The cumulative task-6
checklist had no previous findings. No schema, UI, feature-owner, or generation
behavior changed; personal evidence/capture/delivery remain separate tasks.

Evidence root: **`/tmp/kontrol-f13-step2-4-20260930T224814/`**. Baseline HEAD:
`436e437da42bf082f8498fda12f6287f2b3f3673`; initial worktree/index were clean.
Ancestor checks through `/` and target-directory instruction searches found no
applicable `AGENTS.md`; no submodule was listed. `source.diff` includes the new
untracked projection plus the three changed implementation/format files tested;
SHA-256 **`615dfa84b6c13dfff92253620329349ebd839fa44117d508a9d0a62672bc1857`**.
`source-hashes.json` records per-file identities. This QA addition is the only
later edit. `environment.log` and `diagnostic-audit.log` record macOS 27.0
(26A428), arm64, Xcode 27.0 (27A266a), Swift compiler 6.4, and selected Xcode path.
Swift 5 language mode, macOS 14 deployment, and the Yams pin remain unchanged.

Exact verification commands (repository root; `EVIDENCE` is the root above):

```sh
set -o pipefail
f13_test() {
  local flags=()
  local suite
  for suite in "$@"; do
    flags+=("-only-testing:KontrolTests/$suite")
  done
  xcodebuild -project Kontrol.xcodeproj -scheme Kontrol \
    -configuration Debug -destination 'platform=macOS' \
    -derivedDataPath /tmp/kontrol-f13-derived \
    -parallel-testing-enabled NO CODE_SIGNING_ALLOWED=NO \
    -resultBundlePath "$RESULT_BUNDLE" "${flags[@]}" test
}
# Initial selection before the NFC-byte repair:
RESULT_BUNDLE="$EVIDENCE/learning.xcresult"
f13_test LocalDataExportTests GeneratedLessonRepositoryTests
# Fresh selection after repair (same methods, no exclusions):
RESULT_BUNDLE="$EVIDENCE/learning-repaired.xcresult"
f13_test LocalDataExportTests GeneratedLessonRepositoryTests
make build DERIVED_DATA=/tmp/kontrol-f13-derived
xcodebuild -project Kontrol.xcodeproj -scheme Kontrol \
  -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath /tmp/kontrol-f13-derived \
  CODE_SIGNING_ALLOWED=NO build-for-testing
# Both initial and repaired bundles were audited:
for name in learning learning-repaired; do
  RESULT_BUNDLE="$EVIDENCE/$name.xcresult"
  xcrun xcresulttool get test-results summary \
    --path "$RESULT_BUNDLE" --format json > "$EVIDENCE/$name-summary.json"
  xcrun xcresulttool get test-results tests \
    --path "$RESULT_BUNDLE" --format json > "$EVIDENCE/$name-test-tree.json"
done
python3 "$EVIDENCE/audit.py" > "$EVIDENCE/audit.log"
python3 -m json.tool "$EVIDENCE/example-1.json" >/dev/null
plutil -lint Kontrol.xcodeproj/project.pbxproj
git diff --check
```

Initial test command exited **65**: 57 passed/1 failed method out of 58, with
three failed `XCTAssertThrowsError` assertions in
`LocalDataExportTests/testLearningDefinitionsProjectionRejectsDamagedTaxonomyIdentitiesAndNames`.
Swift String equality accepts canonically equivalent decomposed/NFC strings,
so the shared DTO check could not enforce its documented NFC storage boundary.
The new projection now compares ID UTF-8 bytes against trimmed/NFC bytes and
rejects rather than normalizing. The original failing assertions remain, with
additional decomposed definition/link/reference cases. Initial failure evidence
is preserved in `tests.log`, `learning.xcresult`, and `learning-summary.json`.

**Final verification passed:** fresh repaired selection exited **0**, **58/58**
methods Passed: 47 LocalDataExportTests and 11 GeneratedLessonRepositoryTests.
Zero failures, skips, expected failures, or xcresult runtime warnings. The
source-to-xcresult identifier audit confirms every expected method ran exactly
once (`audit.log`, `learning-repaired-test-tree.json`). Build, final explicit
test compilation, plist lint, JSON example parsing (**1/1**), and whitespace
validation all exited **0**. Logs: `tests-repaired.log`, `build.log`,
`compile-repaired.log`, `plutil.log`, `diffcheck.log`, `exit-codes.log`. Initial
explicit test compilation also passed (`compile.log`). No native selectors are
required by this content-only task; A13/S13/B13/D13 remain separate release gates.

New methods (all `KontrolTests/LocalDataExportTests/`, Passed):

- `testLearningDefinitionsProjectionMapsEveryTaxonomyAndSeedFieldExactly`
- `testLearningDefinitionsProjectionMapsAcceptedGeneratedAllowlistAndNilReturnedModel`
- `testLearningDefinitionsProjectionIncludesRetiredSeedTaxonomyWithoutCurrentMembershipFiltering`
- `testLearningDefinitionsProjectionPreservesLegacyEmptyObjectiveAttributionAndMissingScalarLinks`
- `testLearningDefinitionsProjectionSortsDetachesAndPreservesOtherEnvelopeFields`
- `testLearningDefinitionsProjectionRejectsDuplicateCollectionsAndReferenceSetsWithoutDeduplication`
- `testLearningDefinitionsProjectionRejectsDamagedTaxonomyIdentitiesAndNames`
- `testLearningDefinitionsProjectionRejectsCorruptIncludedDefinitionContentWithoutRepair`
- `testLearningDefinitionsProjectionRejectsMalformedUnsupportedAndUnknownGeneratedProvenance`
- `testLearningDefinitionsProjectionEnforcesGeneratedAcceptanceContentBounds`
- `testLearningDefinitionsProjectionNeverSeedsReconcilesSavesOrChangesAnotherOwnersDraft`

Fixtures cover exact complete-field seed mapping, real locally validated generated
metadata (nil/present returned model), all bundled seed rows and retired Go
content retained after catalog upgrade, ordered/repeated self-checks, authored
whitespace/decomposed Unicode/secret-looking text, legacy empty objectives and
attribution, positive content versions, fingerprint mismatch without repair,
stable sorting, detachment, duplicates, corrupt/unsupported metadata, operation-ID
mismatch, generated content limits, and excluded provider fields. In-memory
contexts prove empty capture inserts nothing, successful/failed mapping does not
save or mutate inventories, no membership/slots/progress/attempts/terminal/import
state is synthesized, and another owner's unsaved definition draft stays unsaved
and unchanged. The mapper has no context, catalog resource, generation service,
network, Keychain, or external-folder dependency. No original fixtures were edited.

The repaired selected-run log has **0 SQLite API-violation/unlink diagnostics**
(`diagnostic-audit.log`). Existing linkd/AppIntents and multiple-destination
messages remain in logs. Test host PID **65404** exited: `ps -p 65404 -o
pid=,stat=,command=` returned **1** with no rows (`host-exit.log`). No agent store
cleanup was performed; new persistence fixtures are in-memory. Historical
failed/skipped evidence remains intact. **No remaining Step 2.4 blockers.**

### F13 Step 2.5 — historical personal Learning export (2026-09-30)

First incomplete task confirmed as Step 2.5, matching runner task 7/27. The
cumulative review checklist has no prior findings. Starting worktree/index were
clean; no applicable ancestor or repository `AGENTS.md` was found. Base revision:
`042069dfe30d4b1350363f4a6f43c55a684270c8`. Implementation/format patch preserved at
`/tmp/kontrol-f13-step2-5/implementation.patch`, SHA-256
`51ff22d41f7b0844fcd3bdb4432404c318d439ad7d8570e5a86cb2d0da666eb8`
(excludes this QA ledger). No schema, project membership, fixture, or dependency
changes were required.

Environment: macOS **27.0 (26A428)**, arm64 MacBook Pro, Xcode **27.0 (27A266a)**,
`/Applications/Xcode.app/Contents/Developer`; Apple Swift **6.4**, project Swift 5
language mode. Evidence directory: `/tmp/kontrol-f13-step2-5`.

Exact validation commands (repository root; all exit **0**):

```sh
set -o pipefail
EVIDENCE=/tmp/kontrol-f13-step2-5
xcodebuild -project Kontrol.xcodeproj -scheme Kontrol \
  -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath /tmp/kontrol-f13-derived \
  -parallel-testing-enabled NO CODE_SIGNING_ALLOWED=NO \
  -only-testing:KontrolTests/LocalDataExportTests \
  -only-testing:KontrolTests/LearningHistoryTests \
  -only-testing:KontrolTests/LessonExperienceRepositoryTests \
  -only-testing:KontrolTests/GeneratedLessonRepositoryTests test \
  > "$EVIDENCE/tests-final.log" 2>&1
make build DERIVED_DATA=/tmp/kontrol-f13-derived > "$EVIDENCE/build.log" 2>&1
xcodebuild -project Kontrol.xcodeproj -scheme Kontrol \
  -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath /tmp/kontrol-f13-derived CODE_SIGNING_ALLOWED=NO \
  build-for-testing > "$EVIDENCE/compile.log" 2>&1
RESULT_BUNDLE=/tmp/kontrol-f13-derived/Logs/Test/Test-Kontrol-2026.09.30_23-08-10-+0800.xcresult
xcrun xcresulttool get test-results summary --path "$RESULT_BUNDLE" \
  --format json > "$EVIDENCE/summary.json"
xcrun xcresulttool get test-results tests --path "$RESULT_BUNDLE" \
  --format json > "$EVIDENCE/test-tree.json"
python3 "$EVIDENCE/audit.py" > "$EVIDENCE/audit.log"
python3 -m json.tool "$EVIDENCE/example-1.json" >/dev/null
git diff --check
```

The initial identical test selection also passed **107/107** (log `tests.log`,
bundle `/tmp/kontrol-f13-derived/Logs/Test/Test-Kontrol-2026.09.30_23-05-40-+0800.xcresult`).
After adding explicit inner terminal/catalog byte-identity validation and its
regressions, the final fresh selection passed **107/107**: **54** LocalDataExportTests,
**11** LearningHistoryTests, **31** LessonExperienceRepositoryTests, **11**
GeneratedLessonRepositoryTests. Zero failures, skips, expected failures, or
xcresult runtime warnings. Source-to-result audit confirms every expected method
executed exactly once; full selectors are in `executed-identifiers.txt` and the
result tree. Debug build, explicit compilation of all hosted tests, JSON example
parsing (**1/1**), and whitespace validation passed. No native selector is required
for this data-only task; compilation is not A13/S13/B13/D13 acceptance.

Seven new methods (all `KontrolTests/LocalDataExportTests/`, Passed):

- `testPersonalLearningProjectionMapsEveryFieldAndPreservesHistoricalContentAgainstChangedDefinition`
- `testPersonalLearningProjectionLegacyNilAndEmptySentinelNeverUseCurrentDefinition`
- `testPersonalLearningProjectionMapsEveryTerminalProvenanceAndGeneratedPins`
- `testPersonalLearningProjectionRejectsPresentCorruptPinsEvenWithValidPartialSnapshot`
- `testPersonalLearningProjectionRejectsCorruptUnsupportedAndMismatchedEvidencePayloads`
- `testPersonalLearningProjectionRejectsDuplicatesInvalidScalarsDatesSlotsAndPartialContent`
- `testPersonalLearningProjectionSortsAllEvidenceCollectionsWithoutMutationOrReconciliation`

The mapper covers all stored progress/attempt milestones, byte-exact saved answers,
ordered studied content, pins, partial completed snapshots, slots, terminal records,
and retired catalog membership. It reuses `PinnedLessonContent.decode`, `metadata()`,
and `membership()`, sharing definition/provenance validation for embedded historical
content. Nil and released empty-pin sentinels map to null; missing historical content
never uses today's changed definition. Present corruption, unsupported evidence
versions, duplicates, invalid dates/content, key mismatches, and outer/inner or
embedded metadata mismatches abort with safe categories. The format documents
legacy gaps and storage decoder rules; no opaque payload is exported.

In-memory fixtures prove detached results survive later row edits; capture mapping
leaves contexts unchanged, preserves a separate owner's unsaved answer, retains
inventories, and synthesizes no definitions/import state. There is no save, answer
mutation, slot rotation, catalog reconciliation, resource load, or external access.
The final log contains no SQLite API-violation/unlink diagnostics; existing multiple
matching destinations, AppIntents metadata, and linkd connection diagnostics remain
in the logs. Test host PID **71025** exited; no original stores were edited and no
agent cleanup was performed. Historical evidence is retained. **No Step 2.5 blockers.**

## F13 Step 2.6 — coherent read-only persisted capture (2026-09-30)

Task 8 matches the first unchecked implementation item. The cumulative review
checklist has no previous findings. Initial worktree/index were clean; repository,
target directories, and direct ancestors have no applicable `AGENTS.md`; no
submodule is configured. No later export lifecycle or UI task was implemented.

Source base: `50960a23856f24308f134687380cc08d7455177b`, with uncommitted changes to
`SwiftDataExportRepository.swift`, `LocalDataExportTests.swift`, project membership,
and this ledger. Tested source SHA-256 values (also `source-sha256.txt` below):

- Repository: `e9f9c3c5549dae58c101bcfaff8b4d76ccdae293c976478766d0dd68df0d7b78`
- Tests: `f98f43e65afe91e9194ab39e4cd315b0acf94511c9b91219022e95daa089e0f8`
- Project: `df3e2c03fd8a0fa54fb772bc26f420bdf2486e5854feff55213c06467f4a1e9d`

Environment: arm64 MacBook Pro, macOS 27.0 (`26A428`), Xcode 27.0 (`27A266a`),
Apple Swift 6.4 (`swiftlang-6.4.0.34.1`); project remains Swift 5/macOS 14. Developer
path `/Applications/Xcode.app/Contents/Developer`. Fresh `xcodebuild -list` resolved
only Yams 5.4.0 and listed Kontrol/KontrolTests targets and Kontrol scheme. Initial
`git status --short`, `git diff --stat`, `git diff --cached --stat`,
`git submodule status`, `xcode-select -p`, `xcodebuild -version`,
`xcrun swift --version`, `xcodebuild -list -project Kontrol.xcodeproj`, `sw_vers`,
and `uname -m` all completed successfully.

Commands from repository root (all final commands exit **0**):

```sh
set -o pipefail
EVIDENCE=/tmp/kontrol-f13-step2-6
xcodebuild -project Kontrol.xcodeproj -scheme Kontrol \
  -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath /tmp/kontrol-f13-derived \
  -parallel-testing-enabled NO CODE_SIGNING_ALLOWED=NO \
  -only-testing:KontrolTests/LocalDataExportTests \
  -only-testing:KontrolTests/NewsRepositoryTests \
  -only-testing:KontrolTests/FocusRepositoryTests \
  -only-testing:KontrolTests/LessonExperienceRepositoryTests test \
  > "$EVIDENCE/tests-final.log" 2>&1
make build DERIVED_DATA=/tmp/kontrol-f13-derived > "$EVIDENCE/build.log" 2>&1
xcodebuild -project Kontrol.xcodeproj -scheme Kontrol \
  -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath /tmp/kontrol-f13-derived CODE_SIGNING_ALLOWED=NO \
  build-for-testing > "$EVIDENCE/compile.log" 2>&1
RESULT_BUNDLE=/tmp/kontrol-f13-derived/Logs/Test/Test-Kontrol-2026.09.30_23-23-50-+0800.xcresult
xcrun xcresulttool get test-results summary --path "$RESULT_BUNDLE" \
  --format json > "$EVIDENCE/summary.json"
xcrun xcresulttool get test-results tests --path "$RESULT_BUNDLE" \
  --format json > "$EVIDENCE/test-tree.json"
python3 "$EVIDENCE/audit.py" > "$EVIDENCE/audit.log"
shasum -a 256 Kontrol/Data/Persistence/SwiftDataExportRepository.swift \
  KontrolTests/LocalDataExportTests.swift Kontrol.xcodeproj/project.pbxproj \
  > "$EVIDENCE/source-sha256.txt"
plutil -lint Kontrol.xcodeproj/project.pbxproj
git diff --check
```

Fresh result: **133/133 passed** — **59** LocalDataExportTests, **17**
NewsRepositoryTests, **26** FocusRepositoryTests, **31** LessonExperienceRepositoryTests.
Zero failures/skips/expected failures; xcresult reports no runtime warnings. The
source-to-result audit confirms every selected method executed exactly once;
`executed-identifiers.txt` and `test-tree.json` retain complete identifiers. Debug
build, explicit compilation of all hosted tests, project plist lint, and whitespace
validation passed. No native selector is required by this data-only task;
compilation does not close A13/S13/B13/D13 or their deferred observations.

Five added methods, all `KontrolTests/LocalDataExportTests/` and Passed:

- `testRepositoryEmptyPersistentStoreUsesDefaultsWithoutSeedingAcrossReopen`
- `testRepositoryRichCompleteCapturePreservesInventoriesExcludedRowsAndReopen`
- `testRepositoryIgnoresUnsavedOwnersAndReturnsValuesIndependentOfLaterCommittedEdits`
- `testRepositoryRejectsCorruptionInEveryIncludedCollectionWithoutRepairOrOmission`
- `testRepositoryRejectsInvalidEnvelopeAndOrphanedFeedsWithoutSeeding`

The main-actor `ExportRepository.snapshot(exportedAt:appVersion:)` uses the existing
container and a single fresh non-autosaving context. It synchronously fetches only
the 16 included model kinds, composing validated detached projections with no
suspension, save, seeding, timer recovery/advancement, catalog reconciliation,
feature-store initialization, network, credentials, or external folder access.
Bundled News defaults are loaded as pure resource configuration. Coherence relies
on the existing single-process main-actor persistence ownership, not a claimed
cross-process transaction. Construction only retains the supplied container.

Empty and rich persistent fixtures capture twice, close their local owners, and
reopen without inventory changes. The rich fixture represents every V10 model,
including intentionally invalid excluded article/bookmark data, stored generated
content, retired membership, pinned/completed content, exact answers, legacy nulls,
and an expired-but-still-running Focus session. Entire DTO equality covers every
included field; auxiliary checks preserve revisions, raw pins/provenance,
terminal/catalog/topic payload bytes, News transport metadata, excluded rows, and
import state across capture/reopen. Tests retain separate owners' unsaved task,
answer, and preference edits; later committed edits/deletions affect fresh captures
but cannot alter previously returned values. Corruption in each of the 16 included
model kinds aborts twice without repair/omission; invalid envelope inputs and
orphaned feeds cannot seed missing preference rows.

Earlier local failures are preserved, not counted as passes:

- `tests.log`, identical four-suite command, exit **65**, bundle
  `/tmp/kontrol-f13-derived/Logs/Test/Test-Kontrol-2026.09.30_23-21-15-+0800.xcresult`:
  133 executed, three fixture failures (`invalidValue`). The fixture incorrectly
  set both task and lesson links on one Focus session. Clearing its lesson link
  makes it valid without weakening the production validator.
- `tests-repair.log`, same xcodebuild options but only LocalDataExportTests,
  exit **65**, bundle
  `/tmp/kontrol-f13-derived/Logs/Test/Test-Kontrol-2026.09.30_23-22-15-+0800.xcresult`:
  59 executed, two rich-fixture assertions failed comparing separately encoded
  unordered pin JSON. The fix compares decoded pin content and separately captures
  the actual stored raw bytes before export, checking those same bytes unchanged
  afterward and after reopen. The final 133-method run validates both repairs.

Final fixture roots (under `/var/folders/lz/20cqfx4x2k98r89q68w3q3ch0000gn/T/`):

- Empty: `kontrol-export-capture-E37B19BC-4CBF-4E9D-A9D5-B2641BD9B88E/`
- Rich: `kontrol-export-capture-C8C6FDF2-F0FF-4327-AC95-916DE78A4562/`

After host PID **77722** exited, the audit enumerated each root's `Kontrol.store`,
`Kontrol.store-wal`, and `Kontrol.store-shm` and ran read-only SQLite
`PRAGMA integrity_check`: **ok** for both. No agent cleanup was performed; earlier
attempt roots remain logged and preserved. Existing News regression tests emitted
**45** SQLite vnode-unlinked diagnostics in the final log; none reference these new
capture fixtures. This does not close the separately tracked historical
store-lifetime/migration investigation. Existing multiple-matching-destination,
AppIntents extraction, and linkd diagnostics remain in the logs. No original
fixtures, production stores, dependency pins, frozen schemas, or external project
files were edited. **No Step 2.6 blockers.**

## F13 Step 3.1 — validated private JSON preparation (2026-09-30)

Confirmed the first incomplete item matches runner task 9. The cumulative review
checklist has no prior findings. Initial worktree/index were clean; direct ancestor
and repository searches found no applicable `AGENTS.md`; no submodule was listed.
Implemented only private preparation, not destination delivery, panels, or lifecycle.

Changed files: new `Kontrol/Data/Export/ExportFileWriter.swift`, new
`KontrolTests/ExportServiceTests.swift`, explicit source/test membership in
`Kontrol.xcodeproj/project.pbxproj`, and this evidence ledger. Base revision:
`d641ae6d7b40708886ec61a67807571b311ccabd`. Tested implementation (including new
untracked files) is preserved as `implementation.patch`, SHA-256
`7d7b7f647ec47dd7a0fc41a731c7f6bea22e9084061131e66d5b93bab8c04481`.
Per-file SHA-256 identities are in `source-sha256.txt`; this QA addition is the
only later edit. Evidence root: **`/tmp/kontrol-f13-step3-1.qFNXOw/`**.
Environment: macOS 27.0 (`26A428`), arm64 MacBook Pro, Xcode 27.0 (`27A266a`),
Apple Swift 6.4, `/Applications/Xcode.app/Contents/Developer`; project remains
Swift 5/macOS 14 with unchanged Yams 5.4.0 pin. `environment.log` records versions
and source identity; `xcodebuild -list -project Kontrol.xcodeproj` also passed.

`ExportFilePreparing` accepts only detached `LocalDataExport` values and returns
an unforgeable, single-use `PreparedExportArtifact`. Encoding, filesystem work,
read-back decoding/validation, and cancellation cleanup execute in a detached
utility task. Private directories are exclusively created with `mkdtemp` (0700);
files use exclusive, no-follow creation (0600), checked chunked writes, and checked
close. Stored JSON must decode/validate and match both written bytes and the
canonical input encoding. There is no destination argument or destination access.
Errors are finite categories without content, paths, or underlying errors; neither
writer nor new tests log exported content/private paths.

Cancellation propagates to the worker and waits for actual completion even during
noncooperative encoding/checkpoints; checks surround stages and chunked writes.
No canceled caller receives an artifact. Artifacts serialize consume/discard across
aliases, clean on successful/throwing consumption, support idempotent explicit
discard, and clean on abandonment. Explicit cleanup failures report a safe category
and retain ownership for retry; deinit is a best-effort fallback because it cannot
throw (no claim of cleanup after process termination or filesystem denial).

Exact final verification commands (repository root; all exit **0**):

```sh
set -o pipefail
EVIDENCE=/tmp/kontrol-f13-step3-1.qFNXOw
xcodebuild -project Kontrol.xcodeproj -scheme Kontrol \
  -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath /tmp/kontrol-f13-derived \
  -parallel-testing-enabled NO CODE_SIGNING_ALLOWED=NO \
  -resultBundlePath "$EVIDENCE/preparation-final.xcresult" \
  -only-testing:KontrolTests/ExportServiceTests \
  -only-testing:KontrolTests/LocalDataExportTests test
make build DERIVED_DATA=/tmp/kontrol-f13-derived
xcodebuild -project Kontrol.xcodeproj -scheme Kontrol \
  -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath /tmp/kontrol-f13-derived CODE_SIGNING_ALLOWED=NO \
  build-for-testing
xcrun xcresulttool get test-results summary \
  --path "$EVIDENCE/preparation-final.xcresult" --format json \
  > "$EVIDENCE/summary-final.json"
xcrun xcresulttool get test-results tests \
  --path "$EVIDENCE/preparation-final.xcresult" --format json \
  > "$EVIDENCE/test-tree-final.json"
python3 "$EVIDENCE/audit.py"
plutil -lint Kontrol.xcodeproj/project.pbxproj
git diff --check
```

Fresh final results: **71/71 Passed**, **12** ExportServiceTests and **59**
LocalDataExportTests, zero failures/skips/expected failures/runtime warnings.
`audit.log` confirms every expected source identifier executed exactly once;
`executed-identifiers.txt` and `test-tree-final.json` preserve full selectors.
Logs: `tests-final.log`, `build-final.log`, `compile.log`, `plutil.log`,
`diffcheck.log`, `exit-codes.log`. Initial identical selection also passed **69/69**
(`tests.log`, `preparation.xcresult`, `summary.json`, `test-tree.json`); two extra
regressions were then added, and the new weak-variable compiler warning was fixed.
No test failed, was weakened, or excluded.

New coverage verifies private permissions, canonical/exact authored round trips,
unchanged unrelated destination bytes, invalid input/encoder failures, malformed/
unsupported/valid-but-wrong output, actual stored-file corruption, injected failures
at every stage, real exclusive-file creation failure, unavailable storage, pre-start
and every-stage cancellation, single-use concurrent aliases, explicit discard,
abandonment, and throwing consumption cleanup. A 2.3 MB fixture and a deliberately
blocked off-main encoder prove unrelated main-actor work runs before encoding
finishes; all encoding/IO checkpoints assert they are not on the main thread.
All private preparation tests use isolated temporary roots and assert owned cleanup.

No UI selectors are required for Step 3.1; all hosted coverage compiled. Native
geometry/keyboard/VoiceOver and A13/S13/B13/D13 remain separate mandatory gates.
Existing multiple-destination and AppIntents/linkd diagnostics remain in logs;
no final writer/test compiler warnings or SQLite vnode-unlinked diagnostics occurred.
Test host PID **85623** exited (`ps -p 85623 -o pid=,stat=,command=` returned **1**,
no rows; `host-exit.log`). The unchanged LocalDataExportTests capture fixtures were
retained under `/var/folders/lz/20cqfx4x2k98r89q68w3q3ch0000gn/T/`:

- `kontrol-export-capture-156945DD-6242-4B13-950D-3745CBD9FE93/`
- `kontrol-export-capture-C1078EB6-E987-432B-81DE-7E8A76E0A9F4/`

After host exit, both store/WAL/SHM inventories were enumerated and read-only SQLite
`PRAGMA integrity_check` returned **ok** (`store-integrity.log`). No agent store
cleanup, schema/fixture edits, production data access, network/credential/folder
access, or dependency changes occurred. Historical evidence is preserved.
**No remaining Step 3.1 blockers.**

## F13 atomic export delivery — Step 3.2 (2026-09-30, 15:55 UTC)

**Implementation verification passed; native/release gates remain separate.** The
first incomplete task matched runner task 10, and its cumulative review checklist
had no previous findings. Initial worktree/index were clean; repository/target and
ancestor instruction checks found no applicable `AGENTS.md`, and no submodule was
listed. Only `ExportFileWriter.swift`, `ExportServiceTests.swift`, and this required
QA ledger changed. No workflow state, plan checkbox, project membership, schema,
dependency, or historical fixture changed.

Source base: `a5642cbf7910cdf13fdb99da41bc40752a0b1e26`; implementation/test
`git diff -- Kontrol/Data/Export/ExportFileWriter.swift KontrolTests/ExportServiceTests.swift | shasum -a 256`:
`9a8fb4001bbeee2054eada186f8c3614d5bb3ad112aa08dafcb5838c374c8fd7`.
Evidence directory: **`/tmp/kontrol-f13-step3-2.crM1aj`**. `environment.log` records
Xcode 27.0 (27A266a), Swift 6.4, arm64 macOS 27.0 (26A428), source identity and diff
hash; `project-list.log` records the unchanged project/scheme/Yams 5.4.0 resolution.
Swift 5 language mode and macOS 14 deployment remain unchanged, not baseline-runtime
acceptance.

### Delivery boundary and covered acceptance

- Added an opaque, transient approved-destination value and `ExportFileDelivering`
  boundary. Approval captures absent/existing intent with `lstat` device/inode,
  size, modification/change seconds and nanoseconds. Non-file URLs, directories,
  symlinks (including dangling links), and other nonregular targets are rejected.
  This is the writer boundary for the later native-panel task, not a claim that
  NSSavePanel has already been implemented.
- Off-main delivery uses `NSFileCoordinator` with replacing intent and revalidates
  destination identity both on entry and immediately before atomic IO. A restrictive
  0600, exclusive sibling is staged on the destination volume, written in chunks,
  synced, closed, and compared with validated private JSON. Private artifact cleanup
  completes before commit. Creation uses `renamex_np(..., RENAME_EXCL)` so an appeared
  target is never overwritten; existing approved files use atomic `rename`.
- Cancellation is checked immediately before commit. The caller awaits actual worker
  completion even with noncooperative checkpoints. A successful rename is committed
  success regardless of later cancellation/checkpoint errors; no post-await check
  falsely reports canceled. Sibling/private staging is removed on covered success,
  failure, and cancellation paths. Filesystem cleanup denial reports a safe category;
  no promise is made about process termination or impossible filesystem cleanup.
- Security-scoped access is transient and balanced only when acquired, on approval
  and delivery paths. A false start result is normal for nonscoped accessible files;
  coordination/IO determines actual access. No bookmark or authorization is persisted.
  Failures carry no raw paths/content/errors. Coordination and identity checks do
  **not** exclude all races with uncoordinated external editors.
- Fourteen new non-GUI methods cover creation/replacement round trips, authorization
  balance, nonscoped access, directory/symlink rejection, changed inode/in-place edit,
  changes during staging, appeared/removed/unsafe targets, injected access denial,
  failures at every precommit stage, disk/replacement failure, a real partial sibling
  write followed by injected ENOSPC, missing-parent IO failure, exclusive-creation
  race, cancellation before delivery and at every delivery stage, sibling permissions
  and location, private cleanup before commit, and late-error committed success.
  Existing preparation/privacy/projection/capture regressions remain unchanged.

### Exact verification and fresh result audit

Commands below ran from the repository root, each exit **0** (the test command is
`f13_test ExportServiceTests LocalDataExportTests` expanded with a fresh bundle):

```sh
EVIDENCE=/tmp/kontrol-f13-step3-2.crM1aj
xcodebuild -project Kontrol.xcodeproj -scheme Kontrol \
  -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath /tmp/kontrol-f13-derived \
  -parallel-testing-enabled NO CODE_SIGNING_ALLOWED=NO \
  -resultBundlePath "$EVIDENCE/delivery-final.xcresult" \
  -only-testing:KontrolTests/ExportServiceTests \
  -only-testing:KontrolTests/LocalDataExportTests test
make build DERIVED_DATA=/tmp/kontrol-f13-derived
xcodebuild -project Kontrol.xcodeproj -scheme Kontrol \
  -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath /tmp/kontrol-f13-derived CODE_SIGNING_ALLOWED=NO \
  build-for-testing
xcrun xcresulttool get test-results summary \
  --path "$EVIDENCE/delivery-final.xcresult" --format json \
  > "$EVIDENCE/summary-final.json"
xcrun xcresulttool get test-results tests \
  --path "$EVIDENCE/delivery-final.xcresult" --format json \
  > "$EVIDENCE/test-tree-final.json"
python3 "$EVIDENCE/audit.py"
git diff --check
```

Logs: `tests-final.log`, `build-final.log`, `compile-final.log`, `audit.log`,
`diffcheck.log`. Fresh final result: **85/85 Passed**, **26 ExportServiceTests** and
**59 LocalDataExportTests**, zero failures/skips/expected failures/runtime warnings.
The audit compares every selected source method against fresh test-tree identifiers
and proves exact-once, nonempty selection; full selectors are retained in
`executed-identifiers.txt`. All hosted coverage compiled; no GUI methods were
required or deferred by this delivery-only task. Native panel/sandbox, geometry,
keyboard/VoiceOver and A13/S13/B13/D13 remain pending their own required gates.

Historical attempt evidence is retained: the initial identical `build-for-testing`
command exited **65** (`compile-initial.log`), with async XCTest autoclosure and
missing-`try` errors in new assertions. Fix: await outcomes before asserting and
mark encoding calls `try`. The first complete selection then passed **83/83**
(`delivery.xcresult`, `tests.log`, `summary.json`, `test-tree.json`); after adding
partial-write and sibling-lifetime tests, the full fresh final selection passed
**85/85**. No assertions were weakened or skipped. Both builds and final test
compilation passed. Existing multiple-destination, AppIntents and linkd diagnostics
remain in logs; no writer/test compiler warning or SQLite vnode-unlinked diagnostic
occurred in the final test run.

After hosts **90249** (initial selection) and **90932** (final selection) exited,
`audit.py` checked `ps -p PID -o pid=,stat=,command=` (exit **1**, no rows), enumerated
all four exact logged capture roots and their store/WAL/SHM inventories, and ran
read-only SQLite `PRAGMA integrity_check`: **all four `ok`**. Roots retained under
`/var/folders/lz/20cqfx4x2k98r89q68w3q3ch0000gn/T/`:

- `kontrol-export-capture-3D0C0B75-6002-46DC-818B-CCA32E594E7B/`
- `kontrol-export-capture-5A9A4B56-637C-40D9-ACB1-4EA0BDADEF93/`
- `kontrol-export-capture-C16EE805-AB61-4142-9FFB-2199186DDD8B/`
- `kontrol-export-capture-5F4E6C66-F466-4365-B073-DF8E7ED9938C/`

Exact inventories/results are in `audit.log`. No capture store was removed; writer
fixtures clean their owned isolated non-SwiftData directories after each operation.
No production-data access or native signing/authorization acceptance was attempted.
**No remaining Step 3.2 blockers.**

## F13 Step 3.3 — native JSON destination approval (2026-09-30, 16:10 UTC)

First unchecked task matches runner task 11/27. The cumulative checklist has no
previous findings. Initial worktree/index were clean; repository/target and direct
ancestor checks found no applicable `AGENTS.md`; no submodule was listed. Only the
panel boundary, its tests/project membership, and this required ledger changed.
No lifecycle service, dependency ownership, Local Data routing, or later task was
implemented; workflow state and `.pi/PLAN.md` were not modified.

Source base: `bcdfbea0c1e6c93acca4e2b7fc708c4b381f2b59`. Evidence root:
**`/tmp/kontrol-f13-step3-3/`**. Tested implementation/test/membership patch
(including the new untracked source, excluding this ledger): `implementation.patch`,
SHA-256 `c23485f28d4add598e4071050d9169beff03151649cd92001a8a33da3dd39950`.
Per-file hashes are in `source-sha256.txt`. Environment: arm64 MacBook Pro,
macOS 27.0 (`26A428`), Xcode 27.0 (`27A266a`), Apple Swift 6.4,
`/Applications/Xcode.app/Contents/Developer`. Project remains Swift 5/macOS 14;
Yams 5.4.0 pin is unchanged. Environment/source checks and
`xcodebuild -list -project Kontrol.xcodeproj` succeeded (`environment.log`,
`project-list.log`).

### Implemented and covered boundary

- `ExportDestinationSelecting` is main-actor injectable; `ExportSavePanel` returns
  cancellation or the writer's opaque transient destination/replacement identity.
  Native UI is constructed lazily, only for an uncanceled selection. Approval
  capture runs only after `.OK` and a caller cancellation check. No flush, snapshot,
  preparation, file creation, bookmark generation, or persisted authorization is
  introduced by the adapter. The existing writer balances transient access while
  capturing identity; end-to-end tests verify approval alone leaves bytes unchanged.
- `NativeExportSavePanel` configures `NSSavePanel.allowedContentTypes = [.json]`,
  disallows other types, shows the extension, permits directory creation, and uses
  injected-date `kontrol-export-YYYY-MM-DD.json`. Formatting explicitly uses UTC,
  Gregorian calendar, and POSIX locale. No delegate/accessory validation override
  bypasses AppKit's native replacement confirmation.
- Cancellation calls native Cancel with no arbitrary timer. Ownership remains
  until the dismissal callback actually arrives, even if noncooperative; concurrent
  selection is rejected. Duplicate/obsolete callbacks cannot resume twice or affect
  explicit retry. A callback/cancellation race is checked in the caller's task
  before destination identity capture. Missing/unsafe approved URLs fail safely.
- Seven added non-GUI `ExportServiceTests` methods cover configuration/date bounds,
  cancellation with a stray URL and no artifacts, pre-canceled caller with zero
  panel construction/approval, new/existing intent through actual writer delivery,
  transient access balance, invalid approval/retry, delayed dismissal/overlap/old
  callbacks, and accepted-callback cancellation races. All use injected presenters
  and isolated temporary destinations; no actual native panel is opened.

### Exact verification and audit

From repository root, all final commands below exited **0**:

```sh
set -o pipefail
EVIDENCE=/tmp/kontrol-f13-step3-3
xcodebuild -project Kontrol.xcodeproj -scheme Kontrol \
  -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath /tmp/kontrol-f13-derived \
  -parallel-testing-enabled NO CODE_SIGNING_ALLOWED=NO \
  -resultBundlePath "$EVIDENCE/panel-final.xcresult" \
  -only-testing:KontrolTests/ExportServiceTests test
make build DERIVED_DATA=/tmp/kontrol-f13-derived
xcodebuild -project Kontrol.xcodeproj -scheme Kontrol \
  -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath /tmp/kontrol-f13-derived CODE_SIGNING_ALLOWED=NO \
  build-for-testing
xcrun xcresulttool get test-results summary \
  --path "$EVIDENCE/panel-final.xcresult" --format json \
  > "$EVIDENCE/summary-final.json"
xcrun xcresulttool get test-results tests \
  --path "$EVIDENCE/panel-final.xcresult" --format json \
  > "$EVIDENCE/test-tree-final.json"
python3 "$EVIDENCE/audit.py"
plutil -lint Kontrol.xcodeproj/project.pbxproj
git diff --check
```

Fresh final result: **33/33 ExportServiceTests Passed**, zero failures, skips,
expected failures, or xcresult runtime warnings. `audit.log` compares the complete
source selection against fresh identifiers, confirming each ran exactly once;
`executed-identifiers.txt` records all selectors. Logs: `tests-final.log`,
`build-final.log`, `compile-final.log`, `plutil.log`, `diffcheck.log`,
`exit-codes.log`. All hosted tests, including the new native adapter fixture,
compiled. New source has explicit app Sources membership.

Historical local attempt evidence is retained: initial identical test-compilation
command exited **65** (`compile.log`), because the nested selection owner's
`cancel()` was not explicitly main-actor isolated. Adding `@MainActor` to that
owner fixed the actual isolation error; `compile-repaired.log` exited **0**. The
first complete selection also passed **33/33** (`panel.xcresult`, `tests.log`,
`summary.json`, `test-tree.json`). After removing test-spy closure cycles and an
unnecessary pre-presentation URL assumption, the fresh final selection passed
**33/33** again. No assertions were weakened to bypass acceptance, no tests were
skipped, and no production errors were suppressed.

Deferred native selector (compiled, **not executed**):
`KontrolTests/SettingsSceneTests/testNativeExportPanelAppliesJSONConfigurationWithoutOverridingReplacementConfirmation`.
Actual native Cancel/Escape, replacement confirmation accept/cancel, real sandbox
picker authorization, and keyboard/VoiceOver observations remain required A13/S13
acceptance; this non-GUI checkpoint does not claim those observations. There is no
Step 3.3 implementation blocker; A13/S13/B13/D13 remain separate mandatory gates.

Existing multiple-destination, AppIntents/linkd diagnostics and the pre-existing
Settings geometry optional-interpolation compiler warning remain in logs. No new
panel/export compiler warnings or SQLite unlink/API-violation diagnostics occurred.
Final host PID **95303** exited (`ps -p 95303 -o pid=,stat=,command=` exit **1**, no
rows; `audit.log`). This selection uses no SwiftData fixtures; writer tests assert
cleanup of only their owned non-store temporary directories. No original fixture,
frozen schema, external project, production store, or dependency was changed.
Final ledger whitespace check initially exited **2** (extra blank line at EOF);
removing that blank line restored `git diff --check` exit **0**.

## F13 Step 3.4 — export lifecycle and pending-answer barrier (2026-09-30 UTC)

First incomplete task confirmed as runner task 12/Step 3.4. The cumulative review
checklist has no previous findings. Initial worktree/index were clean; repository
and ancestor instruction checks found no applicable `AGENTS.md`. No submodule was
listed. Changes are limited to new `Kontrol/Features/Settings/ExportService.swift`,
`KontrolTests/ExportServiceTests.swift`, explicit app Sources membership in
`Kontrol.xcodeproj/project.pbxproj`, and this required evidence ledger. Dependency
graph wiring and Local Data UI remain the separate subsequent tasks, not part of
this checkpoint.

Base revision: `c00a14bdc26d364e0276bf3f5b206150e0e75678`. Implementation including
untracked source is captured in `implementation.patch`, SHA-256
`923e7e663913f480b8ff1b88f748f7cc607ef158c53ebae6746ea653022c3a50`;
`source-sha256.txt` identifies each tested file. This ledger is the only subsequent
source-tree edit. Evidence: **`/tmp/kontrol-f13-step3-4.e4SsUa/`**. Environment and
project listing logs record macOS 27.0 (26A428), arm64 MacBook Pro, Xcode 27.0
(27A266a), Swift 6.4, `/Applications/Xcode.app/Contents/Developer`, and unchanged
Yams resolution. Project remains macOS 14/Swift 5; this is not baseline-runtime
acceptance.

The main-actor observable service injects repository, panel, writer, clock,
version, and a synchronous answer-flush closure (supplied with the existing
`LessonDraftStore.flushAll` in integration tests). It publishes
idle/selecting/preparing/saved/canceled/category-only failed states. Approval and
cancellation checks precede flush, which completes synchronously before persisted
capture. Only detached values reach off-main preparation and delivery. An owned
operation UUID fences publication; duplicate actions are rejected. Cancel retains
ownership until real callback/worker/cleanup completion, with no timeout or
automatic retry. A committed delivery receipt always reports saved, including
post-commit cancellation. Late artifacts are explicitly discarded off-main and
awaited. No URL, grant, raw error, or exported content is observable/logged by the
service; construction only retains supplied boundaries.

Nine new non-GUI methods cover:

- Panel cancellation/selection failure with zero flush, version, capture, prepare,
  or delivery calls; real canceled dirty buffers remain untouched.
- Exact approval/flush/version/capture ordering, injected selection/capture dates,
  captured app version, complete state sequence, duplicate rejection, and real
  destination JSON/cleanup.
- Flush/capture/preparation/delivery failure categories, unchanged existing bytes,
  private artifact cleanup even for a failing non-cleaning writer double, and
  explicit retry without automatic re-entry.
- Three real pending answer buffers with a failure on the second ordered save:
  the first save stays durable, failed/unvisited answers stay dirty with exact
  text, capture/preparation/delivery never begin, and retry exports all answers.
- Delayed panel cancellation, duplicate/obsolete callbacks during a later explicit
  request, accepted-callback races, pre-start cancellation, and cancellation during
  synchronous state publication, flush, and capture barriers.
- Deliberately noncooperative preparation returning a late artifact; no overlap or
  delivery occurs, and cleanup finishes before canceled publication.
- Every real writer delivery checkpoint: cancellation retains service ownership,
  pre-commit bytes survive, staging is cleaned, and post-commit reports saved.

Exact final verification commands (repository root; each exit **0**):

```sh
set -o pipefail
EVIDENCE=/tmp/kontrol-f13-step3-4.e4SsUa
xcodebuild -project Kontrol.xcodeproj -scheme Kontrol \
  -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath /tmp/kontrol-f13-derived \
  -parallel-testing-enabled NO CODE_SIGNING_ALLOWED=NO \
  -resultBundlePath "$EVIDENCE/lifecycle-final.xcresult" \
  -only-testing:KontrolTests/ExportServiceTests \
  -only-testing:KontrolTests/LocalDataExportTests \
  -only-testing:KontrolTests/LessonExperienceStoreTests test
make build DERIVED_DATA=/tmp/kontrol-f13-derived
xcodebuild -project Kontrol.xcodeproj -scheme Kontrol \
  -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath /tmp/kontrol-f13-derived CODE_SIGNING_ALLOWED=NO \
  build-for-testing
xcrun xcresulttool get test-results summary \
  --path "$EVIDENCE/lifecycle-final.xcresult" --format json \
  > "$EVIDENCE/summary-final.json"
xcrun xcresulttool get test-results tests \
  --path "$EVIDENCE/lifecycle-final.xcresult" --format json \
  > "$EVIDENCE/test-tree-final.json"
python3 "$EVIDENCE/audit.py"
plutil -lint Kontrol.xcodeproj/project.pbxproj
git diff --check
```

Fresh result: **131/131 Passed** — **42** ExportServiceTests, **59**
LocalDataExportTests, **30** LessonExperienceStoreTests. Zero failures, skips,
expected failures, or xcresult runtime warnings. Source-to-result audit confirms
each selected method executed exactly once; `executed-identifiers.txt` records
complete identifiers. Logs: `tests-final.log`, `build-final.log`,
`compile-final.log`, `audit.log`, `plutil.log`, `diffcheck-final.log`. All hosted
coverage compiled; no new UI selector is required for this state-machine task.
Previously deferred native panel/geometry/keyboard/VoiceOver and A13/S13/B13/D13
observations remain pending, not satisfied by these checks.

Earlier failures are preserved: identical three-suite test command using
`lifecycle.xcresult` exited **65**, 130 executed with one fixture failure in
`testServiceCancellationBeforeStartAndRacingApprovalNeverFlushesOrCaptures`
(`tests.log`, initial summary/test tree). The pre-start case created an unwaited
"Panel begun" expectation although no panel should open. Creating that expectation
only for the racing-approval case fixes the harness, without weakening the zero-call
assertions. One additional synchronous-barrier regression was then added. Initial
`git diff --check` exited **2** on two new project entries with space-before-tab
indentation; matching tab indentation repaired it. Final full selection, build,
compilation, plist lint, and whitespace check pass. Existing AppIntents extraction,
linkd and multiple-destination diagnostics remain; no new export compiler warning
or SQLite vnode-unlinked diagnostic occurred.

Both test hosts exited (initial PID **549**, final PID **1046**; `ps` exit **1**
with no rows). `store-integrity.log` records enumerated store/WAL/SHM inventories
and read-only SQLite integrity **ok** for all retained capture fixture roots under
`/var/folders/lz/20cqfx4x2k98r89q68w3q3ch0000gn/T/`:

- Initial: `kontrol-export-capture-61151DD4-6C5B-4AAC-B02F-E0D35D8F5C90/`,
  `kontrol-export-capture-CFD5709B-3D2E-4A8C-82A5-7D003B7F92D4/`.
- Final: `kontrol-export-capture-5D7761BE-2F7C-46F8-9572-138262781D33/`,
  `kontrol-export-capture-62ECC665-DCDD-41BD-ADB7-32D6B2CCAD89/`.

No agent store cleanup occurred. New draft integration uses an in-memory container;
writer/service tests clean only owned non-store destinations/artifacts. No original
fixture, frozen schema, dependency pin, external project, production store, workflow
file, or plan checkbox changed. **No remaining Step 3.4 blockers.**

## F13 Step 3.5 — one graph-owned export service (2026-09-30, 16:38 UTC)

First incomplete task matched runner task 13/27. The cumulative checklist had no
previous findings. Initial worktree/index were clean; repository/target and direct
ancestor checks found no applicable `AGENTS.md`; no submodule was listed. Changed
only `Kontrol/App/AppDependencies.swift`, ownership/integration coverage in
`KontrolTests/{ExportServiceTests,LaunchCoordinatorTests,AppShellTests}.swift`, and
this required ledger. No Local Data route/UI or later task was implemented.

Base revision: `1bbe589461e6608d9c92d2cfb99d73da4a6ca58a`. Evidence directory:
**`/tmp/kontrol-f13-step3-5.ctokSG/`**. Tested implementation/test patch:
`implementation.patch`, SHA-256
`63a6a7968926880b32f1d7ecc7fef445507aaa3848cb1fd8ffb75f3d1733e2b9`.
This QA addition is the only subsequent tree edit. `environment.log` records
macOS 27.0 (26A428), arm64 MacBook Pro, Xcode 27.0 (27A266a), Apple Swift 6.4,
`/Applications/Xcode.app/Contents/Developer`, source identity and worktree state.
`xcodebuild -list -project Kontrol.xcodeproj` passed with the existing two targets,
one scheme, and Yams 5.4.0. Swift 5/macOS 14 settings remain unchanged; this does
not establish macOS 14 runtime acceptance.

### Implemented ownership and coverage

- `AppDependencies.exportService` is constructed once from the graph's existing
  container, existing `LessonDraftStore.flushAll`, lazy native panel adapter, and
  private/atomic writer. The panel's default approval uses the same injected writer
  boundary. Narrow optional repository/panel and writer/clock/bundle seams retain
  production defaults without requiring another container, answer owner, or service.
- Export marketing version is read from `CFBundleShortVersionString`, not the build
  number or a hardcoded version. Missing metadata supplies an invalid empty version
  to the existing validator rather than inventing one; release metadata configuration
  remains Step 5.2. Injected real bundle fixtures prove `9.8.7` and `2.3.4` survive
  exported JSON, distinct from their `456` build number.
- New graph integration method
  `ExportServiceTests/testGraphSettingsClientsShareExportOwnerAndRejectOverlapDuringSelectionAndPreparation`
  constructs two Settings clients, asserts identical service/draft/container owners,
  and verifies zero initial panel/capture/writer/clock calls or artifacts. Actions
  from either client cannot overlap selection or deliberately suspended preparation;
  there is exactly one panel, capture, preparation, and delivery, with shared saved
  publication and complete owned staging cleanup.
- The existing real answer-flush regression now uses `graph.exportService` and its
  default export repository. Cancel leaves three pending buffers dirty, a second
  answer-save failure retains failed/unvisited text and the first durable save,
  and explicit retry exports exact answers from that same container/draft owner.
- Launch tests now cover the default service remaining idle and injected boundaries
  receiving zero export calls across repeated starts. They also assert zero
  credential reads/saves/removals, project inspections/reference fetches, AI
  generations/connection tests, News refreshes/validations, and no draft buffers.
  The AppShell ownership selector checks main/native Settings and two window clients
  share the export/draft owners, while a separate graph has independent owners.
- Inspected production routes: `KontrolApp.SettingsSceneContent` and
  `AppShell` both pass the same launch-owned dependencies to
  `FoundationSettingsView`. No export action is wired into presentation in this
  task; that remains Step 4.1.

### Exact validation and audited results

Commands ran from the repository root; final commands each exited **0**:

```sh
set -o pipefail
EVIDENCE=/tmp/kontrol-f13-step3-5.ctokSG
xcodebuild -project Kontrol.xcodeproj -scheme Kontrol \
  -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath /tmp/kontrol-f13-derived \
  -parallel-testing-enabled NO CODE_SIGNING_ALLOWED=NO \
  -resultBundlePath "$EVIDENCE/ownership.xcresult" \
  -only-testing:KontrolTests/ExportServiceTests \
  -only-testing:KontrolTests/LaunchCoordinatorTests \
  -only-testing:KontrolTests/LessonExperienceStoreTests \
  -only-testing:KontrolTests/NewsStoreTests \
  -only-testing:KontrolTests/AISettingsStoreTests test
xcodebuild -project Kontrol.xcodeproj -scheme Kontrol \
  -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath /tmp/kontrol-f13-derived \
  -parallel-testing-enabled NO CODE_SIGNING_ALLOWED=NO \
  -resultBundlePath "$EVIDENCE/shell.xcresult" \
  -only-testing:KontrolTests/AppShellTests/testOneStorePerDependencyGraphAcrossRoutesAndWindows test
make build DERIVED_DATA=/tmp/kontrol-f13-derived
xcodebuild -project Kontrol.xcodeproj -scheme Kontrol \
  -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath /tmp/kontrol-f13-derived CODE_SIGNING_ALLOWED=NO \
  build-for-testing
for bundle in ownership shell; do
  xcrun xcresulttool get test-results summary \
    --path "$EVIDENCE/$bundle.xcresult" --format json \
    > "$EVIDENCE/$bundle-summary.json"
  xcrun xcresulttool get test-results tests \
    --path "$EVIDENCE/$bundle.xcresult" --format json \
    > "$EVIDENCE/$bundle-tests.json"
done
python3 "$EVIDENCE/audit.py"
git diff --check
```

Fresh results: **119/119 Passed** (43 ExportServiceTests, 7 LaunchCoordinatorTests,
30 LessonExperienceStoreTests, 22 NewsStoreTests, 17 AISettingsStoreTests), plus
**1/1 Passed** for the exact AppShell ownership selector. Zero failed/skipped/
expected-failure methods. The source-to-result audit proves each required method
executed exactly once; full identifiers are in `executed-identifiers.txt`.
Logs: `tests.log`, `shell.log`, `build.log`, `compile.log`, `audit.log`,
`diffcheck.log`, `exit-codes.log`; both fresh summaries/test trees are retained.
The initial audit script exited **1** because its regex also counted non-XCTest
`testConnection` protocol doubles. Restricting enumeration to each XCTest class
fixed the audit; the final audit passes without changing any tests/selections.
No build or test command failed.

Both xcresult summaries report no runtime-warning entries, but console diagnostics
are preserved in `diagnostics.log`: five continuation-leak events from existing
News tests (`testEligibilityManualOverrideRetryDeadlineAndNextScheduledCheck`,
`testScheduledCheckRunsWhenForegroundAndBecomesEligible`, printed twice each),
existing `SettingsSceneTests.swift:1200` optional-interpolation compiler warning,
AppIntents metadata extraction warnings, multiple-destination and linkd messages.
These are not new export findings or evidence of native release acceptance; no
assertion was weakened and no out-of-scope diagnostic was silently repaired.
No SQLite vnode-unlinked diagnostic occurred in this selection.

Test hosts **7012** and **7282** exited (`ps -p 7012,7282 -o pid=,stat=,command=`
returned **1**, no rows; `host-exit.log`). New graph tests use in-memory SwiftData
and isolated non-store bundle/destination fixtures, cleaning only their owned
non-store artifacts. No agent store cleanup, production-data access, historical
fixture/schema edits, external project changes, dependency changes, workflow state
changes, staging, or commits occurred. All hosted tests compiled; this graph-only
step adds no native UI selector or manual observation. Previously deferred native
panel, rendering/keyboard/VoiceOver and A13/S13/B13/D13 remain mandatory separate
gates. **No remaining Step 3.5 blockers.**

## F13 Step 4.1 — shared Local Data route and truthful outcomes (2026-10-01)

### Scope and implementation

- Confirmed the first top-level incomplete task is Step 4.1, matching runner task
  14. Read the complete cumulative checklist: no prior findings. Initial worktree
  and index were clean; repository/target and ancestor instruction checks found no
  applicable `AGENTS.md` or affected submodule.
- Inspected `docs/mockups/M40-data-export.png` and supplemental references
  `.mockups/flows/f13-settings-release/{07-export-decision,08-export-preparing,09-export-canceled,10-export-failed,11-export-success}.html`
  plus their index. Reused existing semantic typography and native actions; no
  design-system changes or new mockup states were required.
- `LocalDataSettingsView.swift` observes the existing graph-owned `ExportService`.
  Guidance appears before selection: included saved collections, excluded grants,
  paths, credentials, cache and drafts, pending-answer save barrier, personal-data
  protection, no encryption and no import/restore. Shared selecting/preparing
  states offer Cancel, terminal states offer explicit retry/another export.
  Cancellation remains a request until the service reports its actual result.
  Each failure category has safe recovery copy; cleanup failure does not promise
  successful cleanup. No raw error, destination path or invented record count is
  displayed. Saved is presented only for the service's committed outcome.
- `FoundationSettingsView.swift` adds Local Data after folders in hub order, a
  live actual-state summary, section routing, and Back restoration to its hub
  action. Back/re-entry does not reset or cancel an active export. Both production
  entry points already use this same hub and dependency graph; no owner, container,
  save barrier or draft lifecycle was changed. Registered the new file in the
  application group and Sources build phase.
- Updated `SettingsSceneTests.swift` hub capability, navigation/order and existing
  reachability assertions. Added an executed non-GUI state/category presentation
  contract and a compiled hosted fixture using both actual ready scene roots,
  injected panel/preparation gate, in-memory persistence and isolated destinations.
  The hosted fixture covers shared selection/preparation, cross-client Cancel,
  no capture/artifact after panel cancellation, safe capture failure, explicit
  retry, committed parsed JSON, cleanup, Back/re-entry, and an independent retained
  General editor draft. It is **not executed or credited as native acceptance**.
- Updated `AppShellTests.swift` native hub traversal to include folders and Local
  Data. Its executed Settings save-barrier selector now also checks Local Data
  uses the same service and retains the exact successfully saved answer buffer.
  Existing window-close save guards are unchanged; no new close-guard pass is
  claimed in this selection.

### Environment, source identity and exact validation

Evidence: `/tmp/kontrol-f13-step4-1.QRjeQP/`. Base revision
`053cef319d5d3437b33d95f731c69a1eaa5bf79d`; final implementation file hashes are in
`implementation-sha256.txt`, tracked patch in `implementation.patch`, and new
source copy in `LocalDataSettingsView.swift`. `source.txt` records the initial
implementation diff, and `environment.log` records worktree/index/submodule and
all requested toolchain commands. Host: macOS **27.0 (26A428)**, arm64 MacBook Pro,
Xcode **27.0 (27A266a)**, Swift **6.4** in the project's retained Swift 5 mode;
resolved Yams remains **5.4.0**. This is not macOS 14 runtime evidence.

Final commands ran from the repository root, each exited **0**:

```sh
set -o pipefail
EVIDENCE=/tmp/kontrol-f13-step4-1.QRjeQP
xcodebuild -project Kontrol.xcodeproj -scheme Kontrol \
  -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath /tmp/kontrol-f13-derived \
  -parallel-testing-enabled NO CODE_SIGNING_ALLOWED=NO \
  -resultBundlePath "$EVIDENCE/final-service.xcresult" \
  -only-testing:KontrolTests/ExportServiceTests \
  -only-testing:KontrolTests/AppPreferencesStoreTests test
xcodebuild -project Kontrol.xcodeproj -scheme Kontrol \
  -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath /tmp/kontrol-f13-derived \
  -parallel-testing-enabled NO CODE_SIGNING_ALLOWED=NO \
  -resultBundlePath "$EVIDENCE/final-routing.xcresult" \
  -only-testing:KontrolTests/AppShellTests/testSettingsDestinationRetainsLessonSaveBarrierAndRetryUsesTheSameGraph \
  -only-testing:KontrolTests/SettingsSceneTests/testLocalDataPresentationUsesActualStateAndSafeFailureCategories test
make build DERIVED_DATA=/tmp/kontrol-f13-derived
xcodebuild -project Kontrol.xcodeproj -scheme Kontrol \
  -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath /tmp/kontrol-f13-derived CODE_SIGNING_ALLOWED=NO \
  build-for-testing
for bundle in final-service final-routing; do
  xcrun xcresulttool get test-results summary \
    --path "$EVIDENCE/$bundle.xcresult" --format json \
    > "$EVIDENCE/$bundle-summary.json"
  xcrun xcresulttool get test-results tests \
    --path "$EVIDENCE/$bundle.xcresult" --format json \
    > "$EVIDENCE/$bundle-tests.json"
done
python3 "$EVIDENCE/audit.py"
plutil -lint Kontrol.xcodeproj/project.pbxproj
git diff --check
```

Fresh audited results: **58/58 Passed** — 43 ExportServiceTests, 13
AppPreferencesStoreTests, one exact AppShell save-barrier method and one exact
SettingsScene presentation method. Zero failed/skipped/expected-failure methods;
source-to-result audit checks every selected method executed exactly once.
Full identifiers: `executed-identifiers.txt`. Logs: `final-service.log`,
`final-routing.log`, `final-build.log`, `final-compile.log`, `audit.log`,
`diffcheck.log`, `exit-codes.log`; summaries/test trees and xcresults retained.
Earlier same selections also passed (56+2), retained as `service.*`/`routing.*`;
final rerun follows the small hosted status-settling helper adjustment.

Warnings remain visible in `diagnostics.log` and `final-diagnostics.log`: existing
optional interpolation in the folder fixture (now line 1395), initial full test
compilation's existing unused/weak-variable warnings, AppIntents extraction and
linkd connection diagnostics. Both final summaries have no runtime-warning
entries; no assertion failed, and no SQLite vnode-unlinked diagnostic occurred.
Hosts 12900/12967 and final hosts 13409/13426 exited: recorded `ps -p ... -o
pid=,stat=,command=` returned **1** with no rows (`initial-host-exit.log`,
`final-host-exit.log`). No production data, historical stores/fixtures/schemas,
external projects, permissions or dependency pins were changed. No store cleanup,
staging or commits occurred during this Builder step; approved-task commits remain
runner-owned. `.pi/PLAN.md` and workflow state were not modified.

### Deferred native observations (A13, not Step 4.1 implementation blockers)

All hosted coverage compiled. Execute these new/changed selectors with the
reserved active desktop and rebuilt host Accessibility authorization:

- `SettingsSceneTests/testNativeLocalDataRoutesShareSelectingPreparingCanceledFailureRetryAndSavedResults`
- `SettingsSceneTests/testKeyboardHubOrderEditorHandoffNamesTargetsAndFocusReturn`
- `SettingsSceneTests/testNativeAndInlineSettingsGeometryAtCompactDesktopAndAccessibilitySizes`
- `SettingsSceneTests/testSettingsReadFailureRetryAndRetainedEditorGuidanceReflowAtAllNativeSizes`
- `SettingsSceneTests/testSettingsOpenedDuringInitializationAndWindowReopenUseOneGraph`
- `AppShellTests/testRenderedNavigationAccessibilityAndKeyboardOrder`

Actual picker dismissal/replacement, visible Back focus, spoken VoiceOver,
rendered comparisons and geometry observations are not established by this
checkpoint. Local Data's dedicated compact/enlarged layout fixtures and export
focus/accessibility transitions remain Steps 4.2/4.3, not implemented early.
Existing A13/S13/B13/D13 obligations and historical findings remain pending.
**No remaining Step 4.1 implementation blockers.**

## F13 Step 4.2 — Local Data adaptive document (2026-10-01 local)

First incomplete task matched runner task 15/27, Step 4.2. Read the complete
cumulative checklist; no previous findings. Initial worktree/index were clean.
Repository/target and direct ancestor checks found no applicable `AGENTS.md` or
submodule. Reused M40 and supplemental export decision/preparing/canceled/failed/
saved references (`.mockups/flows/f13-settings-release/07` through `11`, plus
`index.html`); no new visible state or redesign was introduced.

### Changes and fixture coverage

- `Kontrol/Features/Settings/LocalDataSettingsView.swift`: headings/subtitle and
  actions retain natural vertical height under constrained width. Status text is
  explicitly proposed the remaining document width beside its symbol, allowing
  long outcomes to wrap. Existing guidance/recovery wrapping, semantic typography
  and ≥32-point `ActionButton` targets remain unchanged. All controls remain in the
  enclosing scroll document; no scroll view, viewport-height form, fixed bar,
  scaling multiplier, owner or export behavior was added. The existing adaptive
  header and single-host contract in `FoundationSettingsView.swift` needed no edit.
- `KontrolTests/SettingsSceneTests.swift`: six hosted selectors cover idle,
  selecting, preparing, saved, canceled, and **every** failure category (selection,
  answer-save, capture, preparation, delivery, cleanup). The matrix uses real
  `SettingsSceneContent` / `MainWindowContent` roots and Local Data navigation,
  not a fixed-height surrogate or a service-state override. Native Settings covers
  520×340, 1000×700 and 1440×940; inline covers its supported desktop sizes
  1000×700 and 1440×940. Each state uses standard system text, a committed Large
  preference resolving to 130%, and larger system text resolving to 160% without
  compounding or shrinking. This defines **165** state/root/size/text combinations.
- Injected panel/preparation gates hold real selecting/preparing states. Real
  answer-save failure retains an exact dirty buffer; repository/writer boundaries
  produce the remaining failures. Cleanup failure removes only the owned private
  fixture directory, forcing the real artifact boundary's cleanup confirmation to
  fail without leaving personal-data bytes. Saved uses actual validated delivery.
- Fixtures assert complete guidance/recovery text, visible compact wrapping,
  nonoverlap, full viewport containment after native vertical scrolling, ≥32-point
  Back/Cancel/export/retry targets, one scroll host and no horizontal scrolling,
  exact content-point dimensions, single text scaling and retained pending answers.
  They actually press Cancel or explicit retry, await lifecycle completion, parse
  committed JSON and check owned-artifact cleanup. Capture attachments include
  content points, pixel dimensions and backing scale when executed. Geometry,
  keyboard/VoiceOver and rendered comparisons are **not credited by compilation**.

### Exact validation and evidence

Base revision: `4d0fc2bdfe4ec500637ab1ca83411c630acf7ae1`. Evidence:
**`/tmp/kontrol-f13-step4-2.MAmRA4/`**. Tested implementation/test patch:
`final-implementation.patch`, SHA-256
`842b1f95df436b4d941ad3dcc6dd3a64f4a4cbe309d067e45b0336df528c6126`.
`final-source-sha256.txt` identifies both tested files; this ledger is the only
subsequent tree edit. `environment.log` records worktree/index/submodule, source
identity, project listing and toolchain: macOS 27.0 (26A428), arm64 MacBook Pro,
Xcode 27.0 (27A266a), Swift 6.4, `/Applications/Xcode.app/Contents/Developer`.
Swift 5/macOS 14 project settings and Yams 5.4.0 resolution remain unchanged;
this is not macOS 14 runtime acceptance.

Commands from repository root (each final validation command exited **0**):

```sh
set -o pipefail
EVIDENCE=/tmp/kontrol-f13-step4-2.MAmRA4
xcodebuild -project Kontrol.xcodeproj -scheme Kontrol \
  -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath /tmp/kontrol-f13-derived \
  -parallel-testing-enabled NO CODE_SIGNING_ALLOWED=NO \
  -resultBundlePath "$EVIDENCE/validation.xcresult" \
  -only-testing:KontrolTests/ExportServiceTests \
  -only-testing:KontrolTests/DesignSystemTokenTests \
  -only-testing:KontrolTests/SettingsSceneTests/testLocalDataPresentationUsesActualStateAndSafeFailureCategories test
make build DERIVED_DATA=/tmp/kontrol-f13-derived
xcodebuild -project Kontrol.xcodeproj -scheme Kontrol \
  -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath /tmp/kontrol-f13-derived CODE_SIGNING_ALLOWED=NO \
  build-for-testing
xcrun xcresulttool get test-results summary \
  --path "$EVIDENCE/validation.xcresult" --format json \
  > "$EVIDENCE/summary.json"
xcrun xcresulttool get test-results tests \
  --path "$EVIDENCE/validation.xcresult" --format json \
  > "$EVIDENCE/test-tree.json"
python3 "$EVIDENCE/audit.py"
git diff --check
```

Fresh audited result: **51/51 Passed** — 43 ExportServiceTests, 7
DesignSystemTokenTests and the exact non-GUI Settings presentation method. Zero
failed/skipped/expected-failure tests or xcresult runtime-warning entries. Audit
compares source methods against fresh test identifiers, checking each selected
method ran exactly once (`executed-identifiers.txt`, `audit.log`). All hosted
coverage compiled. Logs: `tests.log`, `build.log`, `final-compile.log`,
`diffcheck.log`, `diagnostics.log`, `exit-codes.log`; the earlier compilation also
passed (`compile.log`). No command or assertion failed. Existing folder-fixture
optional-interpolation warning (now line 1605), AppIntents extraction warning,
multiple-destination and linkd diagnostics remain recorded, not silently repaired.
No new Local Data compiler warning or SQLite vnode-unlinked diagnostic occurred.
Test host PID 17664 exited (`ps -p 17664 -o pid=,stat=,command=` returned **1**,
no rows; `host-exit.log`). Executed export tests use in-memory persistence and
owned non-store destinations; no agent store cleanup was performed. Original
fixtures, frozen schemas, external projects, production data, dependency pins,
permissions, workflow files and `.pi/PLAN.md` were not changed. Changes remain
uncommitted for review; approved-task commits remain runner-owned.

### Exact new hosted selectors deferred to A13

Compiled, **not executed** (requires the reserved active desktop and actual rebuilt
host Accessibility authorization):

- `SettingsSceneTests/testLocalDataIdleGuidanceReflowsAtAllSettingsSizes`
- `SettingsSceneTests/testLocalDataSelectingProgressAndCancelReflowAtAllSettingsSizes`
- `SettingsSceneTests/testLocalDataPreparingProgressAndCancelReflowAtAllSettingsSizes`
- `SettingsSceneTests/testLocalDataSavedResultAndActionsReflowAtAllSettingsSizes`
- `SettingsSceneTests/testLocalDataCanceledResultAndActionsReflowAtAllSettingsSizes`
- `SettingsSceneTests/testLocalDataEveryFailureRecoveryAndRetryReflowAtAllSettingsSizes`

Existing deferred Local Data route, folder, General, full-suite and historical
native selectors remain required. No rendered attachment/comparison, native
geometry or spoken VoiceOver result is claimed here. Export focus/accessibility
transition implementation remains Step 4.3; A13/S13/B13/D13 remain mandatory
separate acceptance gates. **No remaining Step 4.2 implementation blockers.**

## F13 Step 4.3 — Export keyboard and accessible status transitions (2026-10-01 local)

First incomplete task matched runner task 16/27, Step 4.3. Read SPEC, ANALYSIS,
PLAN and the complete cumulative task-16 checklist (no prior findings). Worktree
and index were clean; repository/target and direct ancestor checks found no
applicable `AGENTS.md` or submodule. Reused M40 and supplemental export decision /
preparing / canceled / failed / saved references under
`.mockups/flows/f13-settings-release/`; no new visible state or redesign.

### Implementation and coverage

- `Kontrol/Features/Settings/LocalDataSettingsView.swift`: one persistent native
  `ActionButton` changes between Export/Retry and Cancel. The same focus target
  survives every publication, including commit; there is no removed conditional
  action to restore to. Reuses the existing visible focus ring and ≥32pt targets.
  Panel ownership temporarily clears local focus. Per-client restoration returns
  to the operation action after approval, dismissal or failure. The observation
  includes the local request as well as state, covering fast repeated failures
  whose selecting publication can be coalesced by SwiftUI. Deferred restoration
  is canceled/fenced on section disappearance; background shared results do not
  initiate focus changes in clients that did not request restoration.
- Escape requests cancellation while selecting/preparing and waits for the real
  outcome without leaving the section or claiming success. At idle/terminal
  states it only returns to the hub. Cancel remains keyboard-addressable; retry
  explicitly opens the same shared picker, never automatically retries.
- Status exposes a single named `Export status` element with a readable state
  value and a decorative symbol. Action labels/roles remain native; safe hints
  explain destination approval and pre-commit cancellation. No live announcement,
  ticking progress, animation or duplicate motion/text-scale resolution added.
- `Kontrol/Features/Settings/FoundationSettingsView.swift`: the existing Back
  callback is shared with Local Data Escape, preserving hub focus return to
  `settings-local-data`. Folder/General handoffs and hub ordering are unchanged.
- `KontrolTests/SettingsSceneTests.swift`: non-GUI presentation assertions now
  cover every state's action identity/title/hint. The full hub-order fixture also
  tabs through Local Data Back → Export → Back. Three new hosted fixtures cover
  panel cancellation, immediate and repeated selection failure, capture failure,
  explicit retry, selecting and preparing Escape, approval → Cancel focus,
  committed success → Export focus, backward Tab, native button roles/names and
  targets, textual status, and leaving/reopening a section without stealing
  General focus. Both real scene roots are exercised for the main transition
  journey under the committed Reduce motion preference. Real injected service
  boundaries hold transitions; committed output is parsed and owned-file cleanup
  checked. Hosted compilation does **not** establish those native observations.

### Exact validation and evidence

Base revision: `b9687db4f20bc627729a80578f73a4008cfa57c5`. Evidence:
**`/tmp/kontrol-f13-step4-3.7Aqnom/`**. Tested source/test patch:
`final-implementation.patch`, SHA-256
`df516db3dcd9dd480051bde761320150fbb9a44a461f890332ef0b5bcbaf62d4`.
`final-source-sha256.txt` identifies the three tested files; this ledger is the
only subsequent source-tree edit. `environment.log`: macOS 27.0 (26A428), arm64
MacBook Pro, Xcode 27.0 (27A266a), Swift 6.4,
`/Applications/Xcode.app/Contents/Developer`, project listing and Git identity.
Swift 5/macOS 14 project settings, dependency pin and permissions are unchanged;
this is not baseline-runtime acceptance.

Commands from repository root (final executions each exited **0**):

```sh
set -o pipefail
EVIDENCE=/tmp/kontrol-f13-step4-3.7Aqnom
xcodebuild -project Kontrol.xcodeproj -scheme Kontrol \
  -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath /tmp/kontrol-f13-derived \
  -parallel-testing-enabled NO CODE_SIGNING_ALLOWED=NO \
  -resultBundlePath "$EVIDENCE/validation.xcresult" \
  -only-testing:KontrolTests/ExportServiceTests \
  -only-testing:KontrolTests/AppPreferencesStoreTests \
  -only-testing:KontrolTests/SettingsSceneTests/testLocalDataPresentationUsesActualStateAndSafeFailureCategories test
make build DERIVED_DATA=/tmp/kontrol-f13-derived
xcodebuild -project Kontrol.xcodeproj -scheme Kontrol \
  -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath /tmp/kontrol-f13-derived CODE_SIGNING_ALLOWED=NO \
  build-for-testing
xcrun xcresulttool get test-results summary \
  --path "$EVIDENCE/validation.xcresult" --format json \
  > "$EVIDENCE/summary.json"
xcrun xcresulttool get test-results tests \
  --path "$EVIDENCE/validation.xcresult" --format json \
  > "$EVIDENCE/test-tree.json"
python3 "$EVIDENCE/audit.py"
git diff --check
```

Fresh audited result: **57/57 Passed** — 43 ExportServiceTests, 13
AppPreferencesStoreTests, one exact non-GUI Settings presentation method. No
failed/skipped/expected-failure tests or xcresult runtime-warning entries.
`audit.py` compares source method names with fresh result identifiers, checking
that each selected method executed exactly once (`audit.log`,
`executed-identifiers.txt`). All hosted coverage compiled. Final logs:
`tests.log`, `final-build.log`, `final-compile.log`, `diffcheck.log`,
`diagnostics.log`, `exit-codes.log`. Before the final focus-request refinement,
the same 57-method selection passed too (`pre-final-validation.xcresult`,
`pre-final-tests.log`).

Two earlier test-compilation attempts exited **65**: the new fixture initially
tried to write read-only `accessibilityReduceMotion`, then omitted the required
`focusDefaultMinutes` initializer argument (`compile.log`, `compile-retry.log`).
Fixed by injecting a committed `.reduce` preference through the existing owner
with explicit 25-minute duration. Subsequent test compilation, selected tests,
Debug build and final test compilation all passed against the final patch.
Existing folder-fixture optional-interpolation warning (now line 1836),
AppIntents metadata-extraction warning, multiple-destination and linkd diagnostics
remain recorded, not silently repaired. No new production compiler warning or
SQLite vnode-unlinked diagnostic occurred. Test host PID 23208 exited (final
process scan returned **1**, no rows, `host-exit.log`). No agent store cleanup
was performed. Frozen schemas, fixtures, external projects, production data,
workflow files and `.pi/PLAN.md` were not changed. Changes remain uncommitted for
review; approved-task commits remain runner-owned.

### A13 hosted selectors and spoken-observation ledger

Compiled, **not executed** here; require the reserved active desktop and actual
rebuilt-host Accessibility authorization:

- `SettingsSceneTests/testKeyboardLocalDataPanelDismissalFailuresRetryAndSuccessRestoreStableAction`
- `SettingsSceneTests/testKeyboardLocalDataPreparingEscapeWaitsForResultAndRestoresExportAgain`
- `SettingsSceneTests/testKeyboardLocalDataLeavingSectionFencesRestorationAndDoesNotStealGeneralFocus`
- Updated `SettingsSceneTests/testKeyboardHubOrderEditorHandoffNamesTargetsAndFocusReturn`

Existing deferred Local Data route/geometry, folder, General and historical
native selectors remain required. **No spoken VoiceOver observations were made.**
At A13, independently record actual utterances for `Export status` and each
ready/selecting/preparing/saved/canceled/failed value; Export/Retry/Cancel button
names and roles; cancellation/recovery hints; and panel dismissal/restored focus.
Check no duplicate decorative-symbol reading or repeated unsolicited progress
announcements, non-color comprehension, visible focus/ring and logical order at
standard/130%/larger sizes, with inherited system/app reduced motion. Real panel
Escape/replacement and post-commit cancellation still need native observation;
injected callbacks do not substitute. Capture/rendered comparisons and spoken
results are pending, not inferred from builds or tests. A13/S13/B13/D13 remain
separate mandatory acceptance gates. **No remaining Step 4.3 implementation
blockers.**

## F13 Step 5.1 — Migration preservation and snapshot investigation (2026-10-01)

**Scope:** `AppPreferencesMigrationTests.swift`, `ContainerFactoryTests.swift`,
`V1FixtureTests.swift`, and this ledger only. First unchecked task matched runner
Step 5.1; cumulative task-17 checklist had no previous review findings. Initial
worktree/index were clean, no submodule or applicable ancestor/target `AGENTS.md`
was found. HEAD **`bdbf1d5451dd`** (full identity in `source-head.txt` below).
Environment: Xcode **27.0 / 27A266a**, Apple Swift **6.4**, macOS **27.0 / 26A428**,
arm64; existing macOS 14 deployment and Swift 5 mode unchanged.

Evidence directory **`/tmp/kontrol-f13-migration5.1.kZNVRO`** (`EVIDENCE` below).
Final test patch: `test-source.diff`, SHA-256
**`c0155e718a4ad15ccfbbc11540718a46ddd655408abecc68fa95cca3263c42ed`**.
`environment.txt` records status/index/submodules/toolchain/OS; initial
`xcodebuild -list -project Kontrol.xcodeproj` exited 0, reporting Kontrol and
KontrolTests targets, Debug/Release, Kontrol scheme and unchanged Yams 5.4.0.

### Explained fixture-boundary cause and repair

The historical F11 record remains unchanged: **188/189**, exit 65, three
source-file byte assertion failures in
`ContainerFactoryTests/testCopiedV3DefinitionMigratesWithIdentityAndObjectiveDefault`
(including WAL 0 versus 86,552 bytes), followed by isolated/full passing retries.
Enumerated `/private/tmp` and explicitly checked all five recorded F11 raw log/
result paths: **unavailable** (`historical-paths.txt`,
`historical-artifact-check.log`). Thus this investigation does not claim to have
re-read the missing failure bundle or identified that historical worker's exact
schedule. Git source/history is retained in `historical-container-test.swift`
and `container-history.diff`: the generated V3 source had a live SwiftData/Core
Data origin, and the older checkpoint workaround (introduced in `de3198f`) did
not create a separately owned closed source. Leaving a function/autoreleasepool
is not a synchronous Core Data close; byte comparisons against that file set
can observe later checkpoint/sidecar lifecycle activity. SHM read marks are also
not immutable user data. This is a test-fixture boundary defect, not evidence
that migration of the separate copy deletes committed source records.

New regression:
`ContainerFactoryTests/testCheckpointChangesLiveV3BytesButClosedBackupPreservesCommittedWALAndMigrationSource`.
It uses a real V3 container and an independent SQLite read transaction to pin
pre-save WAL visibility, verifies a nonempty WAL with SQLite magic and SHM,
and backs up committed data to a separate closed database. After releasing the
reader, successful TRUNCATE checkpointing **deterministically changes the main
file and WAL bytes without changing saved user records or invoking source
migration**: **61,832 → 0 WAL bytes**, checkpoint counts **0/0**. An initial
successful checkpoint is deliberately included: it cannot freeze a still-owned
store against subsequent SQLite work. The closed backup remains byte-identical
while its copy migrates/reopens twice with the exact task ID, timestamps and
multiline notes. No timing sleep or an unexplained passing retry is the evidence
for this cause. Actual live/snapshot paths and measured transitions are printed
in every test log; e.g. final run:

- Live: `$TMPDIR/KontrolContainerTests-27566/667558DF-CED2-4D53-BA46-9AD4155DCD83/live`.
- Closed source: same parent, `snapshot/Kontrol.store`.
- Migrated destination: same parent, `copy/Kontrol.store`.

The implicated existing selector now writes to a distinct `writer/` location,
keeps its container alive while SQLite's backup API captures the committed
transaction, closes both backup connections successfully, then copies only the
closed `source/` artifact. **All existing identity/content/objective-default,
answer/revision/progress/import-marker, repeated-open and source filename/byte
assertions remain.** Frozen bundled fixtures still copy every original file,
including WAL and SHM; they are never opened in place. All three changed suites
now log PID-owned UUID roots and retain opened stores/sidecars until host exit,
rather than unlinking them in `defer`. This fixes the fixture lifetime, not
production recovery. No schema, migration stage, factory behavior, store-reset
path, assertion skip/expected failure, or production file was changed.

**Conclusion:** the mutable generated-source snapshot contract has an explained,
controlled reproduction and is removed by an independent closed SQLite artifact.
The F11 fixture reliability concern is closed at that test-boundary level, not
by its old passing retry and not by claiming forensic access to absent artifacts.
No production migration defect was established or needs a separate repair task.
Future logical-preservation failures still block release; this checkpoint is
not A13/S13/B13/D13 approval.

### Exact commands and fresh results

From repository root (logs redirected to the evidence directory):

```bash
EVIDENCE=/tmp/kontrol-f13-migration5.1.kZNVRO
f13_test() {
  local flags=() suite
  for suite in "$@"; do flags+=("-only-testing:KontrolTests/$suite"); done
  xcodebuild -project Kontrol.xcodeproj -scheme Kontrol \
    -configuration Debug -destination 'platform=macOS' \
    -derivedDataPath /tmp/kontrol-f13-derived -parallel-testing-enabled NO \
    CODE_SIGNING_ALLOWED=NO -resultBundlePath "$RESULT_BUNDLE" "${flags[@]}" test
}
make build DERIVED_DATA=/tmp/kontrol-f13-derived
xcodebuild -project Kontrol.xcodeproj -scheme Kontrol \
  -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath /tmp/kontrol-f13-derived CODE_SIGNING_ALLOWED=NO build-for-testing
RESULT_BUNDLE="$EVIDENCE/verified.xcresult" f13_test \
  AppPreferencesMigrationTests SchemaTests ContainerFactoryTests \
  V1FixtureTests LaunchRecoveryTests
for run in 1 2 3; do
  RESULT_BUNDLE="$EVIDENCE/repeat-$run.xcresult" f13_test \
    'ContainerFactoryTests/testCopiedV3DefinitionMigratesWithIdentityAndObjectiveDefault' \
    'ContainerFactoryTests/testCheckpointChangesLiveV3BytesButClosedBackupPreservesCommittedWALAndMigrationSource' \
    'AppPreferencesMigrationTests/testRichV9MigratesWithAllFieldsAndRowIdentitiesUnchangedAcrossReopen'
done
xcodebuild -project Kontrol.xcodeproj -scheme Kontrol \
  -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath /tmp/kontrol-f13-derived -parallel-testing-enabled NO \
  CODE_SIGNING_ALLOWED=NO -resultBundlePath "$EVIDENCE/same-host.xcresult" \
  -test-iterations 10 -test-repetition-relaunch-enabled NO \
  -only-testing:KontrolTests/ContainerFactoryTests/testCopiedV3DefinitionMigratesWithIdentityAndObjectiveDefault \
  -only-testing:KontrolTests/ContainerFactoryTests/testCheckpointChangesLiveV3BytesButClosedBackupPreservesCommittedWALAndMigrationSource \
  -only-testing:KontrolTests/AppPreferencesMigrationTests/testRichV9MigratesWithAllFieldsAndRowIdentitiesUnchangedAcrossReopen test
for run in baseline verified repeat-1 repeat-2 repeat-3 same-host; do
  xcrun xcresulttool get test-results summary --path "$EVIDENCE/$run.xcresult" \
    --format json > "$EVIDENCE/$run-summary.json"
  xcrun xcresulttool get test-results tests --path "$EVIDENCE/$run.xcresult" \
    --format json > "$EVIDENCE/$run-tree.json"
done
python3 "$EVIDENCE/audit.py" > "$EVIDENCE/audit.log" 2>&1
git diff --check
```

All commands above exited **0** on the final source. Build/test compilation logs
are `build-final.log`/`compile-final.log`. Baseline before edits: `baseline.log` /
`baseline.xcresult`, **35/35**. Intermediate implementation: `final.log` /
`final.xcresult`, **36/36**. Final five-suite gate `verified.log` /
`verified.xcresult`: **36 passed, zero failed/skipped/expected failures**:
preferences migration **4**, schemas **10**, container **9**, V1 **2**, recovery
**11**. `SchemaTests` confirms **ten versions/nine stages**, retained identities
and additive V10 only. Rich V9 coverage snapshots **every persisted field and
primary row key in every V9 entity**, including opaque payloads, credentials/
bookmarks, News cache/transport and active/paused Focus; compares unchanged rows
on **three** V10 reopens, with no preference seeding/context changes. V10 custom
scalar/revision and repeated corrupt-store/sidecar preservation checks also pass.

`repeat-{1,2,3}.log` / matching `.xcresult`: **3/3 each**, fresh hosts
**27596/27622/27648**. `same-host.log` / `same-host.xcresult`: **three identifiers,
ten repetitions each = 30 passed executions**, host **27666**, not merely three
executions. Audit checks every repetition child, exact identifiers/execution
counts and source-method selection (including baseline before the added method).
All summary warning/failure arrays are empty. Raw output retains intentional
malformed-store Core Data errors, linkd/AppIntents and multiple-destination
messages; no SQLite vnode-unlinked or `InvalidTransition` diagnostic occurred.

An initial **auxiliary integrity-audit command failed**, not an XCTest:
`python3 "$EVIDENCE/audit.py" > "$EVIDENCE/audit.log"` exited **1** with
`sqlite3.OperationalError: unable to open database file` on a standalone backup
whose header retains WAL mode but which has no WAL/SHM. Partial output is
preserved as `audit-initial-partial.log` and
`store-integrity-initial-partial.log`. Repaired only the audit URI: use read-only
`immutable=1` for verified **host-exited, no-WAL closed artifacts**, ordinary
read-only SQLite for stores with WAL. This prevents sidecar creation; never use
immutable mode to hide a nonempty WAL. The full audit reran and passed (exit 0).

### Original-byte and lifetime evidence

`fixtures-before.json` and `fixtures-after.json` enumerate **all 12 original
V1–V4 files (eight sidecars)** with sizes and SHA-256. Inventories, sizes and
hashes match exactly. Tests independently byte-compare bundled originals after
copy migration. No original store was opened or regenerated. `host-exit.log`
confirms final/repeat PIDs exited (`ps` exit 1, no rows); the integrity audit also
checks each root PID, TMPDIR parent and absence of symlinks before reading.

`store-integrity.log` enumerates **14** precisely logged retained roots from
intermediate/final/repeat runs under
`/var/folders/lz/20cqfx4x2k98r89q68w3q3ch0000gn/T/`:
`KontrolContainerTests-{27155,27566,27596,27622,27648,27666}`,
`KontrolPreferencesMigration-{27155,27566,27596,27622,27648,27666}`,
`KontrolV1Reopen-{27155,27566}`. **131 valid SQLite stores: all integrity_check=ok**;
**four intentionally malformed preservation stores** are identified and retained,
not mislabeled corrupt production data. All connections closed; no agent cleanup
was performed. Exact store and sidecar paths/sizes remain in that log. Existing
baseline/LaunchRecovery cleanup outside this task was not changed; no corresponding
unlink diagnostic was observed here. No GUI/spoken/native/runtime/signing claim
is made. **No remaining Step 5.1 implementation blockers.**

## F13 Step 5.2 — Application metadata and Release hardening (2026-09-30, 17:59 UTC)

First incomplete task matched runner task **18/27, Step 5.2**. Read SPEC,
ANALYSIS, PLAN and the complete cumulative task-18 checklist (no prior findings).
Initial worktree/index were clean; repository/target and direct ancestor checks
found no applicable `AGENTS.md`, and no submodule was listed. Changed only
`Kontrol.xcodeproj/project.pbxproj` and this required evidence ledger. No workflow
state, plan checkbox, signing credential, dependency pin, fixture, schema, source
entitlement or development command changed; changes remain uncommitted for review.

Base revision **`83ddcee666663b4027719a1a952161cb1f486152`**. Evidence directory
**`/tmp/kontrol-f13-step5-2.Plb6kJ/`** (`EVIDENCE` below). `implementation.patch`
SHA-256 **`e5910270a5efb5c56fa4b04023f9087bd6237fd3e23357d552fdc019e6f82beb`**
identifies the tested configuration delta; this ledger is the only subsequent
edit. `environment.log`: macOS **27.0 / 26A428**, arm64, Xcode **27.0 / 27A266a**,
Apple Swift **6.4**, `/Applications/Xcode.app/Contents/Developer`. Initial
`xcodebuild -list -project Kontrol.xcodeproj` passed: existing Kontrol/KontrolTests
targets, one Kontrol scheme, Debug/Release and Yams 5.4.0.

### Implementation and acceptance audit

- App Debug and Release now set `MARKETING_VERSION = 1.0` and
  `CURRENT_PROJECT_VERSION = 1`. Release sets `ENABLE_HARDENED_RUNTIME = YES`
  and `CODE_SIGN_INJECT_BASE_ENTITLEMENTS = NO`, explicitly preventing Xcode base
  debugging-entitlement injection. No team or identity is embedded; existing
  unsigned defaults and external signing overrides remain intact.
- `audit.py` parses both current and HEAD project plists and asserts the **entire
  project delta** consists solely of those additions to the two app configurations.
  Target/resource membership, test configurations, signing inputs, dependency
  settings, macOS **14.0** and Swift **5.0** remain unchanged.
- Effective Release settings confirm hardening YES, base-entitlement injection NO,
  testability NO, unsigned default NO signing, and no DEBUG compilation condition.
  Inspected `makeAppLaunchCoordinator`'s existing `#if DEBUG` boundary; all **six**
  emitted Release app swiftc commands omit `-D DEBUG`. Binary byte checks find
  neither `KONTROL_F00_RECOVERY_TEST` nor `KontrolF00Recovery-` in Release, while
  both are present in Debug (positive control). No app was launched.
- Source entitlements are byte-identical to HEAD and contain **exactly four true
  values**: sandbox, outbound network, user-selected read/write, app-scope bookmarks.
  No `get-task-allow` is requested there. This is configuration/binary inspection,
  **not actual signed-entitlement acceptance**; S13/D13 remain separate gates.
- Both built Info.plists contain version/build **1.0/1** and minimum OS **14.0**.
  Release executable is **x86_64 + arm64**, SHA-256
  `d5c9e15c885f30394f482d7fe2cc88a4bc8688eaaa328d4de019ce1500c9d944`.
  Debug executable is arm64, SHA-256
  `346576705300bc0aa0942d4441c7071246167da0945247019a2c02e322c5ad79`.
- Enumerated actual `Contents/Resources` in both build products: exactly
  `starter-catalog.json`, `generation-objectives.json`, `default-feeds.json`.
  Each parses as JSON and is byte-identical to its source. Full paths/hashes are
  recorded in `audit.log`. Notices are not packaged yet and remain **Step 5.3**,
  not a missing acceptance requirement silently credited here.

### Exact validation and results

Ran from repository root; **every command exited 0**:

```sh
EVIDENCE=/tmp/kontrol-f13-step5-2.Plb6kJ
make build CONFIGURATION=Release DERIVED_DATA=/tmp/kontrol-f13-release-build
xcodebuild -showBuildSettings -project Kontrol.xcodeproj \
  -scheme Kontrol -configuration Release
plutil -lint Kontrol.xcodeproj/project.pbxproj Kontrol/Kontrol.entitlements
plutil -p /tmp/kontrol-f13-release-build/Build/Products/Release/Kontrol.app/Contents/Info.plist
make build DERIVED_DATA=/tmp/kontrol-f13-derived
xcodebuild -project Kontrol.xcodeproj -scheme Kontrol \
  -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath /tmp/kontrol-f13-derived CODE_SIGNING_ALLOWED=NO build-for-testing
for config in Release Debug; do
  xcodebuild -showBuildSettings -json -project Kontrol.xcodeproj \
    -scheme Kontrol -configuration "$config" \
    > "$EVIDENCE/$config-settings.json" 2> "$EVIDENCE/$config-settings.stderr"
done
python3 "$EVIDENCE/audit.py"
git diff --check
```

Logs: `release-build.log`, `release-settings.log`, `plist-lint.log`,
`release-info.log`, `debug-build.log`, `test-compilation.log`, `audit.log`,
`diff-check.log`, `exit-codes.log`; emitted commands retained in
`release-swift-commands.txt`. Final whitespace check reran after this ledger edit.
Debug and Release builds **SUCCEEDED**; hosted test compilation **SUCCEEDED**;
plist lint and configuration/binary/resource assertions passed. **No XCTest
methods were executed and no test result bundle is claimed**: this task requires
build-for-testing, not a test selection. Existing AppIntents/multiple-destination
messages are preserved in raw logs and warning lines in `diagnostics.log`.
No production store, external project, native desktop, or temporary test store
was accessed; no store cleanup occurred. Previously deferred A13 accessibility,
S13 signed sandbox, B13 runtime matrix and D13 distribution acceptance are not
satisfied by these checks. **No remaining Step 5.2 blockers.**

## F13 Step 5.3 — Pinned dependency notices and bundle verification (2026-09-30, 18:16 UTC)

First incomplete task matched runner **19/27, Step 5.3**. Read SPEC, ANALYSIS,
PLAN and the complete task-19 cumulative checklist; no previous findings existed.
Initial worktree/index were clean, ancestor/repository/target instruction searches
found no applicable `AGENTS.md`, and no submodule was listed. Changed only
`Kontrol/Resources/ThirdPartyNotices.txt`, `docs/third-party-notices.md`, notice
membership in `Kontrol.xcodeproj/project.pbxproj`, and this required evidence
ledger. No later release/documentation task was implemented.

Base revision **`d467ba1b02cc31d4225b29f55207bd371cb4bd6b`**. Evidence directory:
**`/tmp/kontrol-f13-step5-3.UUkjkG/`** (`EVIDENCE` below). `environment.log`
records source/worktree/index/submodule checks and toolchain commands including
`xcodebuild -list -project Kontrol.xcodeproj` (exit 0). Host: macOS **27.0
(26A428)**, arm64, Xcode **27.0 (27A266a)**, Apple Swift **6.4**,
`/Applications/Xcode.app/Contents/Developer`. Project mode remains Swift 5/macOS
14; this is not macOS 14 execution evidence. Tested project patch
`implementation.patch` SHA-256:
`a64341bb18b9c7a63ce2769f3fab654085162d4cac5b4e4b5a9bac7b2557025f`.
`implementation-sha256.txt` identifies the two new files, also copied into the
evidence directory. This ledger is the only subsequent edit.

### Source provenance and packaged acceptance

- Both clean SwiftPM checkouts (Debug and Release) are at resolved Yams **5.4.0**,
  revision **`3d6871d5b4a5cd519adf233fbb576e0a2af71c17`**. The audit compares
  their tracked Sources, LICENSE, README and Package.swift bytes against pinned
  Git objects, not merely HEAD labels. `Package.resolved` is byte-identical to
  repository HEAD (SHA-256
  `a27d1749f310edb30f4a129b64ce2043aa2fc9881a2739fd4534ff4d37149471`).
- Complete Yams MIT license is copied unchanged from its pinned LICENSE
  (SHA-256 `0354b0ea403d2e78059c5ae0510a2cfae9f8eb306fcef094ac9fff5b47e20bed`).
  Inventory of all tracked shipped Sources finds **22** header copyrights,
  **three** distinct lines (2016/2017/2024 Yams); all are included with only
  comment syntax removed. Exact originating paths are in `packaging-audit.log`.
- Pinned Package.swift confirms Yams depends on embedded **CYaml/libyaml**, with
  no external package dependencies. Pinned README identifies both as MIT. Yams
  has only the top-level LICENSE, not libyaml's separate License. Traced vendor
  history in the pinned ancestry: Yams `409e565756cfdf50642a59c8f4290a6961fe7f1d`
  identifies libyaml **`acd6f6f014c25e46363e718381e0b35205df2d83`**; latest CYaml
  source update `c7a3398466895c46c875966fc9da6ad11619bce6` identifies upstream
  **`51843fe48257c6b7b6e70cdec1db634f64a40818`**,
  **`588eabff23ba2292f537872bbea5b64bce1e1a21`** and
  **`840b65c40675e2d06bf40405ad3f12dec7f35923`**. Obtained upstream Git source
  under `$EVIDENCE/libyaml` (clone exit 0); all four immutable License blobs
  match exactly, SHA-256
  **`c40112449f254b9753045925248313e9270efa36d226b22d82d4cc6c43c57f29`**.
  Included complete Ingy döt Net/Kirill Simonov copyrights and permission/warranty
  text; no licensing text was inferred from memory or a generic template.
  Original license bytes are retained as `Yams-LICENSE.txt` and
  `libyaml-License-<revision>.txt`; `source-inventory.log` and
  `packaging-audit.log` preserve filename/header searches and vendor commit bodies.
- New documentation gives immutable upstream links, absence/provenance explanation,
  hashes, reproducible source audit and Debug/Release byte comparisons. Every local
  Markdown link resolves. Project plist audit asserts the **entire configuration
  delta** is only the notice file/build references and app Resources membership;
  no dependency/signing/permission/build setting changed.
- Both actual bundle resource directories now contain exactly the three existing
  JSON resources and ThirdPartyNotices.txt. All four resources in each build
  match source bytes. Notices are **2693 bytes**, SHA-256
  **`52c4773d7710814fbf6b403fbb911b36daad3d0972a585d2664766c60e6b1d71`**.
  Verified paths:
  `/tmp/kontrol-f13-derived/Build/Products/Debug/Kontrol.app/Contents/Resources/ThirdPartyNotices.txt`
  and
  `/tmp/kontrol-f13-release-build/Build/Products/Release/Kontrol.app/Contents/Resources/ThirdPartyNotices.txt`.

### Exact commands and fresh results

Ran from repository root; final commands each exited **0**:

```sh
EVIDENCE=/tmp/kontrol-f13-step5-3.UUkjkG
python3 -m json.tool Kontrol.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved
python3 "$EVIDENCE/notice-audit.py" \
  /tmp/kontrol-f13-derived/SourcePackages/checkouts/Yams "$EVIDENCE/libyaml"
make build DERIVED_DATA=/tmp/kontrol-f13-derived
make build CONFIGURATION=Release DERIVED_DATA=/tmp/kontrol-f13-release-build
cmp Kontrol/Resources/ThirdPartyNotices.txt \
  /tmp/kontrol-f13-derived/Build/Products/Debug/Kontrol.app/Contents/Resources/ThirdPartyNotices.txt
cmp Kontrol/Resources/ThirdPartyNotices.txt \
  /tmp/kontrol-f13-release-build/Build/Products/Release/Kontrol.app/Contents/Resources/ThirdPartyNotices.txt
xcodebuild -project Kontrol.xcodeproj -scheme Kontrol \
  -configuration Debug -destination platform=macOS \
  -derivedDataPath /tmp/kontrol-f13-derived CODE_SIGNING_ALLOWED=NO build-for-testing
plutil -lint Kontrol.xcodeproj/project.pbxproj
python3 "$EVIDENCE/packaging-audit.py"
git diff --check
```

`notice-audit.py` is extracted verbatim from the new documentation's Python
block. Both builds **SUCCEEDED** and test compilation **SUCCEEDED**. Logs:
`resolved-json.log`, `notice-source-audit.log`, `debug-build.log`,
`release-build.log`, `debug-notice-cmp.log`, `release-notice-cmp.log`,
`test-compilation.log`, `project-lint.log`, `packaging-audit.log`, `diff-check.log`;
`commands.log`/`exit-codes.log` retain the exact calls/results. Whitespace check
reran after this ledger addition. No XCTest selection was required or executed;
no method count/result bundle is claimed. Existing AppIntents extraction warnings
are retained in `diagnostics.log`; multiple matching macOS destinations remain
in raw build logs.

Initial source audit exited **1** (`notice-source-audit-initial.log`): exact-byte
comparison detected a transcription typo, `this Software` instead of upstream
`the Software` in the libyaml permission paragraph. Corrected only that word;
reran the unchanged source audit (exit 0) before building and verified both final
bundles. The failure is preserved, not converted to a pass or weakened assertion.

No production data, native desktop or temporary test store was accessed; no
store cleanup occurred. No dependency pin, checkout, entitlement, schema, fixture,
external project, workflow state or plan checkbox changed. Changes remain
uncommitted for review. A13/S13/B13/D13 remain separate mandatory gates, not
satisfied by unsigned packaging verification. **No remaining Step 5.3 blockers.**

## F13 Step 5.4 — Executable release and installation runbook (2026-09-30, 18:29 UTC)

Confirmed the first top-level incomplete item is **Step 5.4**, matching runner
**20/27**. Read SPEC, ANALYSIS, PLAN and the complete task-20 cumulative checklist;
there were no prior findings. Initial worktree/index were clean. Repository/docs
and direct ancestor searches found no applicable `AGENTS.md`; no submodule was
listed. Changed only new [release runbook](release.md) and this appended ledger.
No workflow/plan state, app source/configuration, dependency, fixture or external
project changed. Changes are uncommitted for review; the runner owns approved-task
commits.

Base revision: **`f0f59a5610172bcbfa8eb54a0fe9b8c1e2aed0f6`**. Evidence root:
**`/tmp/kontrol-f13-release-evidence.8fb8jz/`**. Environment: arm64 macOS **27.0
(26A428)**, Xcode **27.0 (27A266a)**, Apple Swift **6.4**,
`/Applications/Xcode.app/Contents/Developer`; project remains Swift 5/macOS 14.
`launch.log` records the environment/project commands and complete execution;
`source-revision.txt`, `worktree.txt` and `source.patch` record the starting source
identity. New runbook is copied to `release.md`, SHA-256
**`2227c9c0cfaa7502f17543e18c74c09b355cf87e986107e162fa80572953107c`**.
The final documentation patch/file hashes are retained separately; no release
artifact or native-runtime approval is inferred from this source identity.

### Documented acceptance and command audit

- Runbook covers unsigned development/static inspection, unsigned packaging smoke,
  isolated account/data prerequisites, locally ad-hoc signed S13, actual signature/
  entitlements/hardened-runtime inspection, Developer ID archive, accepted-only
  notarization, staple/Gatekeeper, final ZIP/checksum/extraction and inspection,
  fresh install and non-destructive update/recovery. It identifies actual local
  storage, sidecars, Keychain/external-folder boundaries and export limitations.
- All externally supplied signing variables and every line of the required D13
  sequence match SPEC **verbatim and in order**. Extra bundle/identity inspections
  and a saved checksum surround the original sequence. A fail-fast Bash subshell
  stops on any command failure; the JSON guard precedes stapling and requires
  exactly `Accepted`. No embedded identity/team/credential values or privacy/
  Gatekeeper bypass is provided. Project inspection confirms unsigned defaults,
  external signing overrides, Release hardening/base-entitlement injection NO and
  the existing four narrow source permissions.
- All **eight** Bash blocks pass `bash -n`; every embedded Python body compiles.
  The unchanged notarization guard was executed against synthetic Accepted,
  Invalid, In Progress, missing-status and malformed JSON: Accepted exits **0**;
  all four unacceptable cases exit **1**, as required. Empty external prerequisites
  exit **1** before artifact creation/signing. These expected negative results are
  guard tests, **not real notarization submissions or distribution acceptance**.
  Exact fixtures/output: `guard-*.json`, `guard-*.log`,
  `missing-prerequisite-guard.log`. All new Markdown links resolve locally.

### Exact executed commands and results

The first four runbook Bash blocks were extracted verbatim, with only `set -x`
and stdout/stderr logging added after evidence creation. They ran in one Bash
process, so the documented variables/helpers have their required scope. The
executed script and all eight extracted blocks are retained in evidence. Commands
from repository root (all final checks exit **0**):

```bash
BOOTSTRAP=/tmp/kontrol-f13-step5-4-launch.uSQuDq
EVIDENCE=/tmp/kontrol-f13-release-evidence.8fb8jz
bash -n "$BOOTSTRAP/all-blocks.bash"
bash "$BOOTSTRAP/unsigned-static.bash" > "$BOOTSTRAP/launch.log" 2>&1
# The script executes the following documented build/static commands and the
# complete verbatim Python configuration/bundle inspectors in docs/release.md:
# make build DERIVED_DATA=/tmp/kontrol-f13-derived
# make build CONFIGURATION=Release DERIVED_DATA=/tmp/kontrol-f13-release-build
# xcodebuild -project Kontrol.xcodeproj -scheme Kontrol \
#   -configuration Debug -destination 'platform=macOS' \
#   -derivedDataPath /tmp/kontrol-f13-derived CODE_SIGNING_ALLOWED=NO build-for-testing
# xcodebuild -showBuildSettings -json -project Kontrol.xcodeproj \
#   -scheme Kontrol -configuration Release > "$EVIDENCE/Release-settings.json"
# plutil -lint Kontrol.xcodeproj/project.pbxproj Kontrol/Kontrol.entitlements
# plutil -p /tmp/kontrol-f13-release-build/Build/Products/Release/Kontrol.app/Contents/Info.plist
# python3 -m json.tool Kontrol/Resources/{starter-catalog,generation-objectives,default-feeds}.json
#   (three separate calls, output discarded, as shown in the runbook loop)
# python3 -m json.tool Kontrol.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved
# inspect_bundle /tmp/kontrol-f13-derived/Build/Products/Debug/Kontrol.app Debug
# inspect_bundle /tmp/kontrol-f13-release-build/Build/Products/Release/Kontrol.app Release
python3 "$EVIDENCE/audit.py" > "$EVIDENCE/audit.log" 2>&1
git diff --check
```

Debug and Release **BUILD SUCCEEDED**, hosted **TEST BUILD SUCCEEDED**. No XCTest
selection was required or executed; no method count or xcresult is claimed.
`unsigned-static.log` retains all expanded commands and results,
`Release-settings.json` retains effective signing/metadata settings, and
`audit.log` records sequence/guard/syntax/link assertions. Built metadata is
**1.0/1**, bundle ID **com.kontrol.app**, minimum OS **14.0**. All four actual
resources/notices in Debug, Release and the extracted unsigned app match source
bytes and the JSON parses. Release binaries contain neither Debug recovery
injection marker. The existing AppIntents metadata-extraction warning and multiple
matching macOS destination messages are preserved in raw logs, not hidden.

The runbook's unsigned packaging block also executed in that same script:

```bash
SMOKE_DIR=/tmp/kontrol-f13-unsigned-package.2mlRXx
APP=/tmp/kontrol-f13-release-build/Build/Products/Release/Kontrol.app
ditto -c -k --keepParent "$APP" "$SMOKE_DIR/Kontrol-unsigned.zip"
shasum -a 256 "$SMOKE_DIR/Kontrol-unsigned.zip" > "$SMOKE_DIR/Kontrol-unsigned.zip.sha256"
shasum -a 256 -c "$SMOKE_DIR/Kontrol-unsigned.zip.sha256"
ditto -x -k "$SMOKE_DIR/Kontrol-unsigned.zip" "$SMOKE_DIR/extracted"
inspect_bundle "$SMOKE_DIR/extracted/Kontrol.app" Release
diff -qr "$APP" "$SMOKE_DIR/extracted/Kontrol.app"
```

All exit **0**. ZIP SHA-256:
**`6a70927bee0d208ecc8b603357890728d38657e6e58cafd3235c6f5c154bffdd`**;
checksum verification reports **OK**; complete extracted bundle comparison has
**no differences**. Verified extracted notices path:
`/tmp/kontrol-f13-unsigned-package.2mlRXx/extracted/Kontrol.app/Contents/Resources/ThirdPartyNotices.txt`,
2693 bytes, SHA-256
`52c4773d7710814fbf6b403fbb911b36daad3d0972a585d2664766c60e6b1d71`.
The extracted Release executable hash remains
`d5c9e15c885f30394f482d7fe2cc88a4bc8688eaaa328d4de019ce1500c9d944`.
This is an **unsigned packaging smoke**, not a distributable or actual signature
inspection. The unsigned archive/extraction is retained, not installed or launched.

An initial auxiliary extraction command failed before builds: its regex counted
only seven non-indented Bash fences instead of eight including the indented
installation block (`AssertionError: 7`); the subsequent attempted `bash -n` on
its absent output exited **127**. Fix: recognize indented fences and dedent them.
The repaired extractor found all eight blocks; all syntax, builds and final audits
passed without changing the documented commands to bypass a failure. Bootstrap
scripts/logs remain at the exact path above. A later post-ledger audit exited **1**
when its `git diff --check` subprocess exited **2** for an added blank EOF line in
this ledger. Removing that extra blank line repaired the whitespace failure;
`audit-post-ledger-failed.log` preserves it and the final audit/check reran.

### Gate status and remaining prerequisites

**No Step 5.4 implementation/verification blocker.** A13 still requires the
reserved desktop, actual rebuilt-host Accessibility authorization and independent
rendering/keyboard/VoiceOver observations. S13 and native install/update require
an authorized isolated account/data and desktop. B13 requires actual macOS 14
and current-runtime journeys; this newer-host static run is not either native
journey. D13 requires external authorized Developer ID team/identity/notary profile
and final extracted-artifact native evidence. None of those authorizations/inputs
were supplied for this documentation task; signed/notary/Gatekeeper/native install
commands were **not executed**. They remain explicit blockers to their later gates,
not passes or reasons to skip independent documentation verification.
No production store, test store, Keychain, external folder or native desktop was
accessed; no fixture cleanup/reset occurred. Historical evidence is unchanged.

## F13 Step 5.5 — Product and export documentation truth (2026-09-30, 18:57 UTC)

First incomplete task matched runner **21/27, Step 5.5**. Read SPEC, ANALYSIS,
PLAN and the complete cumulative task-21 checklist (no previous findings).
Initial worktree/index were clean; no interrupted partial work was present.
Repository/docs and direct-ancestor instruction checks found no applicable
`AGENTS.md`; no submodule was listed. Changed only `README.md`, root `PLAN.md`,
`docs/architecture.md`, `docs/export-format.md`,
`docs/features/F13-settings-release.md` and this appended ledger. No workflow
state or `.pi/PLAN.md`, implementation, test assertion, fixture, schema, dependency
or permission was changed. Changes are uncommitted for runner review.

Base revision **`bd04022cba9971a97323f15c5db2577e962fc221`**. Evidence directory
**`/tmp/kontrol-f13-step5-5.XTVQtb/`** (`EVIDENCE` below).
`documentation.patch` identifies the five behavior/status documentation deltas
before this ledger addition, SHA-256
**`576128754e74ac71133c0ca61640895b4f4c715a364991522f1fa58aa6332e3c`**.
Tests ran against unchanged implementation at that revision; documentation does
not change its binaries. `environment.log` records revision/worktree/index,
submodules, Xcode selection/version, Swift, project listing and OS/hardware:
Xcode **27.0 (27A266a)**, Apple Swift **6.4**, arm64 macOS **27.0 (26A428)**,
`/Applications/Xcode.app/Contents/Developer`. Existing Swift 5/macOS 14 settings
are not macOS 14 execution evidence.

### Documentation and acceptance audit

- README/root product plan now describe the executable app and implemented shared
  Settings/General/AI/News/folders/Local Data capabilities, not the old planning
  package or empty Settings placeholder. Dated F00–F12 ledgers retain their
  historical meaning, failures, skips, counts and evidence paths. Current status
  distinguishes implementation and unsigned preparation from pending integration
  and mandatory A13/S13/B13/D13 approval; no F13/V1 release completion is claimed.
- Architecture documents one container, separate feature/credential/answer owners
  versus per-client navigation/drafts/revision/confirmation/focus, actual local
  store and sidecars, General defaults/session isolation, offline boundaries and
  local-only disconnect. Current V7–V10 configuration/reference fields replace
  the earlier composite model sketch. Authoring links now resolve to
  `docs/examples/.kontrol/` (relative from each document).
- Export documentation cross-checked the entire **23-shape** DTO graph, every
  field/type/null marker and identity, root encode/decode/canonical sorting,
  timestamp and nested validators, both projections, repository, panel, writer,
  service, bundle metadata wiring and field-complete tests. The audit retains
  `serialized-fields.json` and prints every field/type. Name presence alone is
  not semantic validation: the written rule/default/null/ordering descriptions
  were also inspected against the corresponding implementation/tests.
- Corrected stale future-capture/delivery descriptions. Documented raw Date input
  bounds as well as rounded range, Swift canonical-equivalence versus persisted
  Learning NFC-byte checks, explicit News payload limits and effective bundled
  defaults versus detached empty arrays. All unordered identity collections/sets
  sort; named sections and ordered/repeated self-checks retain author sequence.
  Legacy nulls remain distinct from corrupt present content and never substitute
  today's lesson. No opaque payload or SwiftData object enters the format.
- Documented approval → pending-answer flush → synchronous capture → private
  off-main validation → coordinated atomic delivery, duplicate ownership fencing,
  category-safe failure/cleanup, pre/post-commit cancellation and balanced transient
  authorization. No credential/grant/path/article-cache/diagnostic or unsaved-editor
  fields are promised; sensitive authored strings are preserved, not redacted.
  Plain JSON is neither encrypted backup nor import/restore. Disconnect/export
  never promise external file deletion; coordination does not promise exclusion
  of every uncoordinated editor race.
- F13 feature documentation now separates implemented contracts/compiled fixtures
  and release preparation from actual native accessibility, signed runtime,
  mandatory macOS 14/current-runtime and final extracted distribution acceptance.
  Step 5.1's explained F11 test-fixture snapshot closure is referenced without
  erasing its original failure or claiming forensic access to missing artifacts.
  Original QA bytes are preserved as one intact block; the audit compares against
  HEAD and fails if that historical block changes.

### Exact commands and fresh results

Executed from repository root (test output redirected to `tests.log`):

```bash
EVIDENCE=/tmp/kontrol-f13-step5-5.XTVQtb
set -o pipefail
f13_test() {
  local flags=() suite
  for suite in "$@"; do flags+=("-only-testing:KontrolTests/$suite"); done
  xcodebuild -project Kontrol.xcodeproj -scheme Kontrol \
    -configuration Debug -destination 'platform=macOS' \
    -derivedDataPath /tmp/kontrol-f13-derived -parallel-testing-enabled NO \
    CODE_SIGNING_ALLOWED=NO -resultBundlePath "$EVIDENCE/selected.xcresult" \
    "${flags[@]}" test
}
f13_test LocalDataExportTests ExportServiceTests
xcrun xcresulttool get test-results summary \
  --path "$EVIDENCE/selected.xcresult" --format json > "$EVIDENCE/summary.json"
xcrun xcresulttool get test-results tests \
  --path "$EVIDENCE/selected.xcresult" --format json > "$EVIDENCE/test-tree.json"
python3 "$EVIDENCE/audit.py" > "$EVIDENCE/audit.log" 2>&1
python3 -m json.tool "$EVIDENCE/export-format-example-1.json" >/dev/null
git diff --check
```

All commands exit **0**. Required test action: **TEST SUCCEEDED**, **102 passed,
zero failed/skipped/expected failures**: LocalDataExport **59**, ExportService
**43**. Fresh bundle: **`/tmp/kontrol-f13-step5-5.XTVQtb/selected.xcresult`**.
`summary.json`/`test-tree.json` and the audit verify every source method selected
in both suites executed **exactly once** and passed, with no empty selection;
`executed-identifiers.txt` lists all 102 identifiers. Tests cover structural/field
round trips, mapping/defaults/legacy/privacy, unchanged capture/reopen/detachment,
shared lifecycle/flush retention and native-adapter seams, private validation,
atomic destination safety, cleanup and cancellation races. They use isolated
stores, injected panels/services and temporary destinations, not production data.

The audit parses the **one** JSON fenced example via `python3 -m json.tool` and
checks its required envelope/nine arrays/General and AI defaults. It resolves
**all local Markdown links in all six files**, including authoring links and
heading fragments (final counts in `audit.log`), not just additions. External
URLs were not fetched. Final audit/whitespace checks rerun after this appendix;
`documentation.patch` remains the five-file pre-ledger identity above, and
`final-documentation.patch` records all six final documentation deltas.

Non-failing multiple-destination and linkd/AppIntents connection diagnostics are
retained in `tests.log`/`diagnostics.log`; summary runtimeWarnings/testFailures
are empty. No SQLite vnode-unlinked or InvalidTransition diagnostic occurred.
Capture tests printed retained roots
`$TMPDIR/kontrol-export-capture-9D0881AD-595F-499C-9316-3FE18D879220` and
`$TMPDIR/kontrol-export-capture-34798ECD-21B0-4058-9648-98275A8D948D`
(full paths in diagnostics). No cleanup/unlink was performed; stores remain for
post-host guarded inspection. No new source/presentation/protocol changed, so
separate build/test-compilation commands were not required; the required test
action built its host and bundle. No hosted GUI/full-suite/native observation,
production store, Keychain or external project was accessed.

**No Step 5.5 blocker remains.** Consolidated integration and A13 reserved-desktop/
actual-host AX/rendering/keyboard/VoiceOver, S13 isolated signed sandbox/native
picker/export/project/offline loops, B13 actual macOS 14/current-runtime journeys
and D13 externally authorized signing/notary/final extracted-artifact approval
remain pending, not passed by this documentation checkpoint. No later task was
implemented and no plan checkbox was marked.

## F13 Step 6.1 — Integrated non-GUI implementation verification (2026-09-30, 19:22 UTC)

First top-level incomplete task matched runner **22/27, Step 6.1**. Read SPEC,
ANALYSIS, PLAN and the complete task-22 cumulative checklist: **no prior findings**.
Initial worktree/index were clean; no interrupted partial work existed. Direct
ancestor and repository/target instruction searches found no applicable `AGENTS.md`
or submodule. Changed only `KontrolTests/NewsRepositoryTests.swift`,
`KontrolTests/NewsStoreTests.swift` and this appended ledger. No production source,
workflow state, `.pi/PLAN.md`, schema, original fixture, dependency, permission or
later release task changed. Changes remain uncommitted for runner review.

Base revision **`2aff12e952ea4c32278a7927c8460a6c8bdff36a`**. Evidence root
**`/tmp/kontrol-f13-step6-1.EnL6tS/`** (`EVIDENCE` below). Final test-only repair:
`test-repair.patch`, SHA-256
**`22394ef390b3b3dba6f9dbf631737745631f855ce52f9d7f915da2cfc6250c78`**.
The final integrated source is that revision plus this patch; this ledger does not
change the tested binaries. `environment.log` records revision/worktree/index,
submodules, developer directory, Xcode/Swift/project listing, OS/architecture and
UTC time: arm64 MacBook Pro, macOS **27.0 (26A428)**, Xcode **27.0 (27A266a)**,
Apple Swift **6.4**, `/Applications/Xcode.app/Contents/Developer`. Project remains
macOS 14 deployment/Swift 5 mode; this is not macOS 14 runtime evidence.

### Integrated contract audit and narrow regression-backed repairs

- Inspected all 23 detached DTO shapes, required keys/nulls, timestamp bounds,
  identity/version/canonical-order validators, both complete projections and their
  field-level tests. `serialized-fields.json` inventories every serialized field
  and type. Tasks/planned calendar-zone, blocks/links, all persisted Focus states,
  taxonomy/accepted definitions, progress/exact saved answers/attempt milestones,
  historical pins/completed snapshots, slots/terminal metadata/catalog membership,
  validated effective General/AI/feed defaults are covered. Meaningful teaching
  sequence and authored whitespace/secret-looking text remain verbatim; missing
  historical evidence is null rather than today's definition. Corrupt present
  payloads, unsupported versions, duplicates and mismatches fail, not omit data.
- Inspected structural privacy allowlists and fresh complete-field/privacy tests.
  No exported credential/reference, project/grant/path, article transport/cache,
  diagnostics/raw errors, opaque payload or unsaved editor fields appear. The
  invalid excluded project/article fixtures remain unread and unchanged. General
  and AI defaults insert nothing; News defaults apply only when both row kinds
  are absent. No export networking, Keychain, folder inspection, seeding, catalog
  reconciliation or timer advancement was introduced.
- Inspected panel/service/repository/writer and graph/routes. Native approval and
  cancellation checks precede the existing answer-owner flush; failed flush retains
  failed/unvisited exact answers and aborts capture. One fresh non-autosaving context
  performs synchronous reads without suspension/save; returned values are detached
  from later edits. Both Settings clients share one graph/container/answer/export
  owner. Fresh lifecycle/launch/shell tests verify call ordering, defaults/no initial
  side effects, shared results, duplicate rejection and retained ownership until
  actual callback/worker completion. Lesson navigation save barriers remain intact.
- Fresh IO tests verify restrictive private preparation, read-back decode/validation,
  off-main responsiveness, unsafe/symlink/directory rejection, transient access
  balance, captured/rechecked replacement identity, exclusive new-file creation,
  coordinated same-volume atomic delivery and cleanup. Every pre-commit failure or
  cancellation preserves destination bytes; post-commit cancellation reports saved.
  Coordination is not a promise against every uncoordinated editor race. Actual
  native panel/bookmark behavior remains S13/A13, not inferred from injection seams.
- Rich V9 preservation/reopen and ten-schema/nine-stage regressions passed. The
  explained live-V3-WAL versus independently closed SQLite backup reproduction
  passed again; Step 5.1's fixture-boundary closure and historical failure records
  remain intact. No production migration defect or reset/unlink recovery was added.
- The initial five-group run passed **495/495**, but raw `export.log` exposed live
  SQLite unlink diagnostics in `NewsRepositoryTests` and continuation leaks in two
  `NewsStoreTests` scheduling fixtures. These diagnostics are retained, not hidden
  by the empty xcresult warning arrays. Repository tests deleted their directory
  in `defer` while containers/contexts or asynchronous Core Data teardown still
  owned handles. They now use logged PID/UUID roots and retain all opened stores
  and sidecars until host exit, including both reopen-only helpers. New regression
  `NewsRepositoryTests/testFixtureStoreRemainsReadableAfterSwiftOwnersLeaveScope`
  checks initial store/WAL/SHM existence and exact snapshot reopen after Swift
  owners leave scope. Existing persistence/content/revision/corruption assertions
  were not weakened; unused URL bindings became `_`.
- The scheduling tests overwrote a single non-cancellation-aware sleep continuation
  during timer rescheduling, abandoning prior owners. New test-only `HeldNewsSleep`
  owns each UUID-keyed continuation independently and resumes it exactly once on
  cancellation/wake. Both existing scheduling tests retain their eligibility,
  retry-deadline, request-count and delay assertions, now also assert zero pending
  sleeps after deactivation. New regression
  `NewsStoreTests/testScheduledSleepSeamRetainsEachOwnerAcrossCancellationAndWake`
  verifies two independent owners, cancellation without disturbing the survivor,
  normal wake, duplicate wake and pre-start cancellation. Production News behavior
  was unchanged. All final selections and three same-host repetitions of these
  four implicated/new methods have **no unlink or continuation-misuse diagnostics**.

### Exact verification commands and fresh results

From repository root, all final build/test/static commands below exited **0**.
`final/run.sh`, `final/commands.log`, individual `final/*.log` and
`final/exit-codes.log` retain exact expansions and outcomes. Initial commands and
bundles remain separately at the evidence root, never overwritten by final runs.

```bash
set -o pipefail
EVIDENCE=/tmp/kontrol-f13-step6-1.EnL6tS
f13_test() {
  local name="$1"; shift
  local flags=() suite
  for suite in "$@"; do flags+=("-only-testing:KontrolTests/$suite"); done
  xcodebuild -project Kontrol.xcodeproj -scheme Kontrol \
    -configuration Debug -destination 'platform=macOS' \
    -derivedDataPath /tmp/kontrol-f13-derived -parallel-testing-enabled NO \
    CODE_SIGNING_ALLOWED=NO -resultBundlePath "$EVIDENCE/final/$name.xcresult" \
    "${flags[@]}" test
}
f13_test preferences AppPreferencesRepositoryTests AppPreferencesStoreTests \
  FocusPreferencesTests FocusTimingTests FocusServiceTests DesignSystemTokenTests
f13_test projects ProjectReferenceRepositoryTests ProjectDisconnectTests \
  ProjectStoreTests ProjectCompletionStoreTests ProjectIntegrationTests
f13_test export LocalDataExportTests ExportServiceTests NewsRepositoryTests \
  FocusRepositoryTests LearningHistoryTests LessonExperienceRepositoryTests \
  GeneratedLessonRepositoryTests LessonExperienceStoreTests \
  LaunchCoordinatorTests NewsStoreTests AISettingsStoreTests
f13_test shell AppShellTests/testOneStorePerDependencyGraphAcrossRoutesAndWindows \
  AppShellTests/testSettingsDestinationRetainsLessonSaveBarrierAndRetryUsesTheSameGraph
f13_test migration AppPreferencesMigrationTests SchemaTests ContainerFactoryTests \
  V1FixtureTests LaunchRecoveryTests
make build DERIVED_DATA=/tmp/kontrol-f13-derived
xcodebuild -project Kontrol.xcodeproj -scheme Kontrol \
  -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath /tmp/kontrol-f13-derived CODE_SIGNING_ALLOWED=NO build-for-testing
xcodebuild -project Kontrol.xcodeproj -scheme Kontrol \
  -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath /tmp/kontrol-f13-derived CODE_SIGNING_ALLOWED=NO analyze
make build CONFIGURATION=Release DERIVED_DATA=/tmp/kontrol-f13-release-build
plutil -lint Kontrol.xcodeproj/project.pbxproj Kontrol/Kontrol.entitlements
python3 -m json.tool Kontrol/Resources/starter-catalog.json >/dev/null
python3 -m json.tool Kontrol/Resources/generation-objectives.json >/dev/null
python3 -m json.tool Kontrol/Resources/default-feeds.json >/dev/null
python3 -m json.tool Kontrol.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved >/dev/null
xcodebuild -showBuildSettings -project Kontrol.xcodeproj -scheme Kontrol -configuration Release
f13_test settings-policy \
  SettingsSceneTests/testLocalDataPresentationUsesActualStateAndSafeFailureCategories \
  SettingsSceneTests/testFolderConfirmationCapturesNameIdentityRevisionCancelAndDurableSuccessAcrossClients \
  SettingsSceneTests/testFolderStaleConfirmationRequiresSuccessfulExplicitReloadAndSeparateReconfirmation \
  SettingsSceneTests/testFolderUnavailableMissingBusyAndFailedOutcomesNeverAutomaticallyDelete \
  ProjectsPresentationTests/testFolderFocusPolicyUsesCurrentRowsDisplayOrderAndEnabledSurvivors
xcodebuild -project Kontrol.xcodeproj -scheme Kontrol \
  -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath /tmp/kontrol-f13-derived -parallel-testing-enabled NO \
  CODE_SIGNING_ALLOWED=NO -resultBundlePath "$EVIDENCE/final/news-repeat.xcresult" \
  -test-iterations 3 -test-repetition-relaunch-enabled NO \
  -only-testing:KontrolTests/NewsRepositoryTests/testFixtureStoreRemainsReadableAfterSwiftOwnersLeaveScope \
  -only-testing:KontrolTests/NewsStoreTests/testEligibilityManualOverrideRetryDeadlineAndNextScheduledCheck \
  -only-testing:KontrolTests/NewsStoreTests/testScheduledCheckRunsWhenForegroundAndBecomesEligible \
  -only-testing:KontrolTests/NewsStoreTests/testScheduledSleepSeamRetainsEachOwnerAcrossCancellationAndWake test
for name in preferences projects export shell migration settings-policy news-repeat; do
  xcrun xcresulttool get test-results summary \
    --path "$EVIDENCE/final/$name.xcresult" --format json \
    > "$EVIDENCE/final/$name-summary.log"
  xcrun xcresulttool get test-results tests \
    --path "$EVIDENCE/final/$name.xcresult" --format json \
    > "$EVIDENCE/final/$name-tests.log"
done
python3 "$EVIDENCE/audit.py"
python3 "$EVIDENCE/stores.py"
git diff --check
```

| Fresh final bundle (`$EVIDENCE/final/`) | Actual passed methods/executions |
| --- | --- |
| `preferences.xcresult` | **90/90**: repository 17, store 13, Focus preferences 8, timing 16, service 29, tokens 7 |
| `projects.xcresult` | **93/93**: reference repository 9, disconnect 9, store 44, completion 21, integration 10 |
| `export.xcresult` | **276/276**: LocalDataExport 59, ExportService 43, News repository 18, Focus repository 26, Learning history 11, lesson repository 31, generated repository 11, lesson store 30, launch 7, News store 23, AI 17 |
| `shell.xcresult` | **2/2**, the exact ownership and Settings lesson-save-barrier selectors |
| `migration.xcresult` | **36/36**: preferences migration 4, schemas 10, container 9, V1 2, recovery 11 |
| `settings-policy.xcresult` | **5/5**, the exact non-GUI selectors above |
| `news-repeat.xcresult` | **4 identifiers × 3 repetitions = 12/12 executions**, not merely four executions |

Required five selections total **497 methods**, plus **5** policy/presentation
contract methods = **502 unique final methods**. Every selected source method ran
exactly once in its primary bundle and Passed; the repeat audit checks all twelve
Repetition children. Zero failed, skipped or expected-failure methods and empty
runtime-warning/failure arrays. `executed-identifiers.txt` enumerates every unique
selector. Both builds, all hosted test compilation, analyzer, plist/JSON checks,
Release settings and final whitespace validation pass. Existing multiple-destination,
AppIntents/linkd messages and intentional malformed-store Core Data errors remain
in raw logs; these are not native acceptance. No assertion skip/expected failure
or production error suppression was added.

Auxiliary audit development failures are preserved separately: first `audit.py`
exit **1** (`audit-initial-partial.log`) assumed all PBX build files have `fileRef`,
but Yams uses `productRef`; the parser now handles both. Second exit **1**
(`audit-second-partial.log`) incorrectly assumed `ENABLE_APP_SANDBOX=YES` and
`ENABLE_DEBUG_DYLIB=NO` build-setting spellings. Sandbox is supplied by the four
source entitlements, not that NO build-setting default; the Release environment
recovery injection is `#if DEBUG`, not the YES debug-dylib setting. Removed those
unsupported audit assumptions, not permissions/assertions in the app. Final
`audit.py` verifies the actual source entitlement dictionary, Release settings,
built versions/resources and source membership. `stores.py` initially exited
**1** (`store-integrity-initial-partial.log`) because `/var/folders` resolves to
`/private/var/folders`; resolving both sides repaired only the safe-root guard.
Both complete final audits exit **0**, including after this ledger append.
No XCTest/build/analyzer/static command failed in either run.

### Resources, packaging and preservation evidence

- Parsed PBX membership: **134 app Swift files**, **90 test Swift files**, all
  exactly once in the proper Sources phases; all six fixture folders are test
  Resources. All four app resources are explicitly registered. Membership lists
  are `Kontrol-membership.json` / `KontrolTests-membership.json`.
- Fresh Debug/Release Info.plists both contain **version/build 1.0/1**. Release
  hardening/macOS 14/Swift 5 settings and exactly four source permissions are
  verified; no actual signed-entitlement or runtime acceptance is claimed.
- Source and fresh Debug/Release bytes match for curriculum, generation objectives,
  feed catalog and notices (sizes/SHA-256 in `audit.log`). Both clean Yams checkouts
  remain at **5.4.0 / 3d6871d5b4a5cd519adf233fbb576e0a2af71c17**. Complete Yams
  LICENSE and three copyright headers match packaged notice bytes; libyaml License
  bytes match all four immutable revisions using the existing source checkout
  `/private/tmp/kontrol-f13-step5-3.UUkjkG/libyaml`, not guessed text.
- Available unsigned packaging smoke ran (each exit **0**):

  ```sh
  APP=/tmp/kontrol-f13-release-build/Build/Products/Release/Kontrol.app
  ditto -c -k --keepParent "$APP" "$EVIDENCE/Kontrol-unsigned-smoke.zip"
  ditto -x -k "$EVIDENCE/Kontrol-unsigned-smoke.zip" "$EVIDENCE/extracted"
  shasum -a 256 "$EVIDENCE/Kontrol-unsigned-smoke.zip"
  ```

  `package.log` records SHA-256
  **`6a70927bee0d208ecc8b603357890728d38657e6e58cafd3235c6f5c154bffdd`**.
  `extracted-audit.log` compares every one of the **seven** extracted regular files
  against the built artifact, all identical, and confirms the executable lacks
  `KONTROL_F00_RECOVERY_TEST`. `release-binary.log` identifies the arm64 executable.
  No app launch, production-store use, signed sandbox, Gatekeeper, notarization or
  distribution approval was attempted; this ZIP is **not a distributable**.
- `protected-before.json` / `protected-after.json` match **60 files** exactly:
  historical fixtures/generators/feed inputs, frozen persistence sources, example
  external `.kontrol` project, resources and dependency pin. All **12 V1–V4
  originals (eight sidecars)** remain unchanged. Fresh ProjectIntegration tests
  compare every copied external tree entry/byte including `.kontrol`, hidden Git
  and source through failure/disconnect/reopen, with zero grant/writer admission.
  Their complete post-run inventories are retained in `retained-inventories.json`.
- `host-exit.log` checks all twelve exact initial/final/auxiliary host PIDs with
  `ps -p PID -o pid=,stat=,command=`: exit **1**, no rows. `store-integrity.log`
  enumerates **20 precisely logged retained roots**, store/WAL/SHM paths/sizes and
  read-only SQLite integrity: **137 valid stores, all `ok`**; **four intentionally
  malformed preservation fixtures** are identified and retained. Roots are under
  `$TMPDIR`: `Kontrol{ContainerTests,PreferencesMigration,V1Reopen}-{57497,59501}`,
  `KontrolPreferencesTests-{57416,59249}`,
  `KontrolProject{DisconnectTests,IntegrationTests,RemovalTests}-{57428,59265}`,
  `KontrolNewsRepositoryTests-{59366,62028}`, and four UUID capture roots (full
  identities in that log). The News roots contain **18** final primary fixtures
  and **three** repeated regression fixtures. No agent cleanup occurred. The
  initial old News harness itself removed its UUID directories and emitted the
  preserved diagnostics; those removed bytes are not claimed recovered. Final
  fixtures remain intact. SQLite immutable mode is used only for host-exited,
  no-WAL closed artifacts; stores with WAL use ordinary read-only access.

### Exact outstanding hosted selectors and native observations

`build-for-testing` compiled **all** current hosted coverage. The complete source
inventory minus the 502 executed methods is recorded as **625 exact selectors** in
`$EVIDENCE/compiled-not-executed-identifiers.txt`, grouped by suite; these are
**not executed in this checkpoint**, not all necessarily GUI. This inventory is
not a new waiver and does not replace existing README/QA deferred ledgers or A13's
serial full suite. In particular, **all 22 DesignSystemComponentTests** and all
remaining Settings/Projects/Today/Focus/Learning/News presentation/native selectors
retain their earlier required acceptance status and historical failures/skips.

The **32** remaining `SettingsSceneTests` selectors are explicitly enumerated in
that file (four pure state/presentation methods ran above). Required F13 native
coverage includes panel JSON/replacement configuration; shared native Local Data
state/retry results; folder route/unavailable/review/removal; General editor and
cross-window stale/unreadable recovery; hub/General/folder/export keyboard focus;
all five folder and six Local Data geometry-state fixtures; compact/native/inline
recovery and scene reopen. Exact names remain in the preceding Steps 1.1/1.2,
3.3/4.1/4.2/4.3 ledgers, not replaced by this summary. Projects' Settings-removal
shared selection/detail/picker fixture and shell rendered-navigation selector are
also compiled but not executed here.

Before assessing evidence availability, enumerated existing capture directories
and filenames under `/tmp`, `.mockups` and `docs` into
`existing-capture-directories.txt`. Existing evidence includes
`/tmp/kontrol-f13-step2.4-final-captures/`,
`/tmp/kontrol-f13-step2.4-geometry-r1-captures/`,
`/tmp/kontrol-f13-step2.4-diagnostic-r2-captures/` and
`/tmp/kontrol-shell-captures/`; it is **not claimed missing**, newly rendered or
compared by this checkpoint. Step 6.1 requires non-GUI verification, not rendered
acceptance; no before/after visual comparison or new screenshot/native observation
is credited. Actual comparison to applicable F00–F13/supplemental references remains
A13, with recorded points/pixels/backing scale at 520×340, 1000×700 and 1440×940,
standard/130%/larger text. No human attestation was supplied.

Independently observed keyboard-only journeys, visible/restored surviving focus,
Escape/Cancel, spoken VoiceOver status/names/roles/recovery, no repeated progress
announcements, reduced motion, non-color status, ≥32-point targets, ≥4.5:1 text
and ≥3:1 essential focus/boundary contrast remain **pending A13**, not passed by
compilation/token tests. S13 isolated signed/offline/relaunch/native picker/bookmark,
project/export journeys; B13 actual macOS 14/current-runtime journeys; and D13
external signing/notary/final extracted distribution/install/update acceptance
remain separate mandatory gates. Historical F02/F06/AX findings remain open there.

**Step 6.1 implementation integration is ready for review; no remaining checkpoint
blocker. F13/V1 is not release-approved.** No later task was executed or checkbox
marked; all changes are left uncommitted.

## F13 Step 6.2 — A13 prerequisite and existing-evidence audit (2026-09-30)

**BLOCKED: A13 is not approved.** First incomplete task matches runner **23/27,
Step 6.2**. Read SPEC, ANALYSIS, PLAN and the complete cumulative task-23 checklist
(no previous findings). Initial worktree/index were clean; no partial work existed.
Repository/target and ancestor checks found no applicable `AGENTS.md`; no submodule
was listed. Changed only this ledger and README's current gate status. No test,
assertion, source, permission, fixture, workflow state or plan checkbox changed.
No later gate was executed. Changes remain uncommitted for the runner's review.

Base revision **`98779210be3caad84b08f5c3a15f762be5958dbd`**; tested implementation
is unchanged at that revision. Evidence root **`/tmp/kontrol-f13-step6-2.jqRCRV/`**
(`EVIDENCE` below). `environment.log` records revision/clean worktree/index,
submodules, Xcode selection/version, Swift, project listing, OS/hardware and console
session. Host is arm64 MacBook Pro, macOS **27.0 (26A428)**, Xcode **27.0
(27A266a)**, Apple Swift **6.4**, `/Applications/Xcode.app/Contents/Developer`.
Swift 5/macOS 14 deployment settings are not baseline-runtime evidence.

### External prerequisites and checks that did not run

No human reserved an active uncontended desktop or supplied authorization for the
actual rebuilt test host in this task. An on-console session exists, but that is
not evidence of reservation or host trust. After compilation, actual host identity
inspection (`host-identity.log`) reports:

- `/private/tmp/kontrol-f13-derived/Build/Products/Debug/Kontrol.app`
- linker ad-hoc signature, Identifier **Kontrol**, CDHash
  **`cac9216d981961310b3acfa0717bfd6f668d40fa`**, no TeamIdentifier/internal
  requirements. This is not a stable distribution signature or AX authorization.

The only on-disk attestation found is
`.pi/workflows/2026-09-30T02-41-29-672Z-I9oXGk/manual-attestation-task-10.json`,
for an earlier HEAD; its statement is **“accessibility access and tests will be deferred”**.
It attests to no passing observation and grants no current reservation/authorization. Historical F00/F01
user-verified observations remain credited only in their original ledgers, not as
F13 observations. No fresh actual-host AX trust, activation or registered-window
result is claimed; historical `trusted=false, active=false` diagnostics above are
not relabeled as a fresh probe. No TCC change, approval prompt, UI takeover, or
production-data launch was attempted.

Therefore the **required seven-suite selection**, **serial full suite**, **all
deferred hosted selectors**, and **independent native/keyboard/VoiceOver checks**
were **not run** in this attempt. Do not substitute the supplemental run below.
Once a human reserves the desktop and authorizes this rebuilt host, recheck actual
host trust/activation/AX registration, then run the unchanged plan commands:

```bash
f13_test AppPreferencesRepositoryTests AppPreferencesStoreTests \
  FocusPreferencesTests FocusTimingTests FocusServiceTests \
  DesignSystemComponentTests DesignSystemTokenTests
xcodebuild -project Kontrol.xcodeproj -scheme Kontrol \
  -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath /tmp/kontrol-f13-derived \
  -parallel-testing-enabled NO CODE_SIGNING_ALLOWED=NO test
```

`inventory.py` checked all **625 exact outstanding Step 6.1 identifiers** against
current source; all still exist and none is closed here. The retained list is
`step6-1-outstanding-identifiers.txt`. `ledger-method-references.json` records
README/QA method references and locations; the historical ContainerFactory
`testV5DiskMigratesAdditivelyAndV6EvidenceSurvivesReopen` now has the explicit
`...SurvivesV10Reopen` name in source (already covered in Step 6.1). This is not a
missing/empty selector pass. All 22 component methods, F02 missing-AX/editor-sheet
failures and skipped native delete confirmation, F06 hosted failures, all 32
remaining Settings methods including new folder/export states/focus/geometry,
and remaining Projects/shell/Today/Focus/Learning/News methods stay open.

Independent observations remain required at **520×340 native Settings** and
**1000×700/1440×940 desktop** content points, **standard/130%/larger text**:
keyboard-only journeys, visible and restored surviving focus, Escape/Cancel,
spoken VoiceOver names/roles/status, reduced motion/no countdown announcement
noise, non-color status, actual ≥32-point targets, ≥4.5:1 text and ≥3:1 essential
focus/boundaries. Token tests are not observations of these rendered states.
Native process/interaction smoke was also blocked by the unreserved desktop;
no app launch/offline/relaunch observation is credited.

### Existing captures: enumeration, actual comparison and limitations

Before claiming missing evidence, enumerated surviving capture trees and all
files/dimensions/hashes into `capture-inventory.json`. These contain **no named
before/after subdirectories**:

| Existing directory under `/private/tmp/` | PNG files |
| --- | ---: |
| `kontrol-f01-evidence/` | 4 Today fixtures |
| `kontrol-shell-captures/` | 2 Today captures |
| `kontrol-f13-step2.4-geometry-r1-captures/` | 180 |
| `kontrol-f13-step2.4-diagnostic-r2-captures/` | 5 |
| `kontrol-f13-step2.4-final-captures/` | 228 |

The unrelated `f20-native-evidence` tree belongs to another project and is not
credited. Existing Settings captures are historical General/AI/News/hub/read
failure states, **not current folder/Local Data captures**. Their 114 named final
captures' `dimensions-audit.json` was checked against actual PNG headers: points
520×340 / 1000×700 / 1440×940; pixels 1040×680 / 2000×1400 / 2880×1880; backing
scale **2**, with 100/130/160% text labels. Inline captures cover desktop sizes.
The two shell captures are 1000×700 and 1440×940 pixels; their historical offscreen
1:1 content dimensions are not evidence of a current live backing scale.

Executed **90 matching named historical state comparisons** between geometry-r1
and final directories. All 90 PNG pairs are **byte-identical**, and all have zero
differing samples on an 8-content-point RGB grid (tolerance 2/255 after sRGB
conversion and nearest-neighbor normalization to nominal content dimensions).
This is duplicate-image evidence, **not proof of independent before/after
re-rendering, changed behavior or current native acceptance**. For example:
`native-520x340-130-hub-bottom.png`: **0/2795**; and
`native-1440x940-100-hub-bottom.png`: **0/21240**. Both original paths, pixel sizes,
comparison dimensions and counts for every pair are in `image-comparisons.json`.

Also actually compared and visually inspected historical captures against
available references, not just enumerated fixture generation:

- `docs/mockups/M38-settings.png` (1440×940 reference) versus
  `/private/tmp/kontrol-f13-step2.4-final-captures/native-1440x940-100-hub-bottom.png`
  (2880×1880): **3019/21240** differing normalized samples. The capture is a
  stacked native Settings document without shell chrome; the reference is a
  two-column shell layout with illustrative Local export/project entries. The
  capture predates those implemented entries and cannot validate their presence.
  Compact `native-520x340-130-hub-bottom.png` is scrolled to Connections with
  readable wrapped News copy; its top is intentionally outside the viewport.
  A static scrolled capture does not prove keyboard/scroll reachability.
- `docs/mockups/M00-app-shell.png` versus
  `/private/tmp/kontrol-shell-captures/today-1440x940.png` (both 1440×940):
  **2733/21240** differing samples. Actual empty Today has day-browsing actions,
  Learning/Schedule/Tasks empty guidance and seven labeled navigation destinations;
  the reference contains sample schedule/lesson content and imitation chrome.

These are visual-reference differences, not pixel-equality failures or release
passes. `reference-inventory.txt` lists available mockup PNGs. No newly rendered
capture was created. Current F00–F13 and supplemental-state comparisons, including
M40 export/M41 removal/M42 accessibility and new folder/export fixtures, remain
unperformed until the authorized session; old captures cannot replace them.

### Automatable supplemental checks actually executed

From repository root, `bash "$EVIDENCE/run.sh"` executed the following (exact
expansions retained in `run.sh`/`commands.log`; all exit **0**):

```bash
EVIDENCE=/tmp/kontrol-f13-step6-2.jqRCRV
# Supplemental six-suite selection, NOT the required seven-suite A13 gate:
xcodebuild -project Kontrol.xcodeproj -scheme Kontrol \
  -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath /tmp/kontrol-f13-derived -parallel-testing-enabled NO \
  CODE_SIGNING_ALLOWED=NO -resultBundlePath "$EVIDENCE/non-gui.xcresult" \
  -only-testing:KontrolTests/AppPreferencesRepositoryTests \
  -only-testing:KontrolTests/AppPreferencesStoreTests \
  -only-testing:KontrolTests/FocusPreferencesTests \
  -only-testing:KontrolTests/FocusTimingTests \
  -only-testing:KontrolTests/FocusServiceTests \
  -only-testing:KontrolTests/DesignSystemTokenTests test
xcrun xcresulttool get test-results summary --path "$EVIDENCE/non-gui.xcresult" --format json
xcrun xcresulttool get test-results tests --path "$EVIDENCE/non-gui.xcresult" --format json
xcodebuild -project Kontrol.xcodeproj -scheme Kontrol \
  -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath /tmp/kontrol-f13-derived CODE_SIGNING_ALLOWED=NO build-for-testing
codesign -dv --verbose=4 /private/tmp/kontrol-f13-derived/Build/Products/Debug/Kontrol.app
make build CONFIGURATION=Release DERIVED_DATA=/tmp/kontrol-f13-release-build
APP=/tmp/kontrol-f13-release-build/Build/Products/Release/Kontrol.app
ditto -c -k --keepParent "$APP" "$EVIDENCE/Kontrol-unsigned.zip"
shasum -a 256 "$EVIDENCE/Kontrol-unsigned.zip"
ditto -x -k "$EVIDENCE/Kontrol-unsigned.zip" "$EVIDENCE/extracted"
diff -qr "$APP" "$EVIDENCE/extracted/Kontrol.app"
python3 "$EVIDENCE/inventory.py"
xcrun swiftc "$EVIDENCE/compare.swift" -o "$EVIDENCE/compare"
"$EVIDENCE/compare"
git diff --check
```

Fresh supplemental bundle **`/tmp/kontrol-f13-step6-2.jqRCRV/non-gui.xcresult`**:
**90/90 passed**, no failures/skips/expected failures. Counts: repository **17**,
store **13**, Focus preferences **8**, timing **16**, service **29**, tokens **7**.
`summary.log`/`test-tree.log` and source-method audit account for every selected
method exactly once; `executed-identifiers.txt` enumerates them. Test compilation
**SUCCEEDED**, Release build **SUCCEEDED**, extraction is byte-identical; actual
extracted version/build **1.0/1** and all four resources/notices match source.
ZIP SHA-256 **`6a70927bee0d208ecc8b603357890728d38657e6e58cafd3235c6f5c154bffdd`**.
This unsigned smoke is not S13/D13 or an approved distribution artifact.

`exit-codes.log`, `non-gui.log`, `test-compilation.log`, `release-build.log`,
`host-identity.log`, `package.log`, `checksum.log`, `extract.log`,
`extracted-comparison.log`, `inventory.log` and `image-comparison.log` retain
results. Existing destination/linkd/AppIntents diagnostics remain in raw logs;
no live-store unlink/InvalidTransition diagnostic occurred. Host PID **66942**
exited; the **15** precisely logged preference stores under
`$TMPDIR/KontrolPreferencesTests-66942/` all returned read-only SQLite integrity
**ok** and remain intact. No cleanup/unlink, production-store/Keychain/external
project access, paid generation or test bypass occurred. Historical ledgers remain
unchanged. Final documentation patch/whitespace evidence is retained separately.

**Continue the SAME Step 6.2 after human desktop reservation and rebuilt-host AX
authorization.** Supplemental passes and historical comparisons do not satisfy
its required full-suite/deferred/native acceptance. No current A13 approval,
F13/V1 completion or approval of later S13/B13/D13 gates is claimed.

## F13 Step 6.2 — attested manual checks and executed A13 gates (2026-10-01)

**REPAIR / FAILED: A13 automated acceptance did not pass.** This continuation
supersedes the preceding attempt's current-prerequisite/no-attestation statements,
not its historical results. First incomplete task remains Step 6.2, runner 23/27.
Read the complete cumulative task-23 checklist (no previous review findings).
Preserved the existing README/QA partial work; only those two target documents
changed. No source, test assertion, fixture, permission, plan or workflow state
changed. Repository/target and direct ancestor checks found no applicable
`AGENTS.md`; no submodule was listed. Changes remain uncommitted.

### User-verified manual acceptance versus automated results

The supplied **task-23/HEAD-specific** attestation is
`.pi/workflows/2026-09-30T12-39-35-387Z-CeCuEh/manual-attestation-task-23.json`,
recorded at **2026-09-30T23:00:41.380Z**, HEAD
**`98779210be3caad84b08f5c3a15f762be5958dbd`**, statement
**“confirm the manual check”**. Per the runner, task-23 manual observations are
credited **as user-verified**, not performed by this agent. This includes the
supplied task's manual keyboard/focus, spoken VoiceOver, text-size, motion,
contrast/target and non-color observations. No user screenshot or measurement
file was supplied; none is invented. No repeat of these manual observations is
requested. This attestation does **not** turn automated failures or unperformed
rendered-state comparisons into passes, nor approve S13/B13/D13.

Implementation remains unchanged at that HEAD. Fresh evidence root:
**`/tmp/kontrol-f13-step6-2-attested.gTpNEO/`** (`E` below). Environment/identity
logs retain macOS **27.0 (26A428)**, arm64 MacBook Pro, Xcode **27.0 (27A266a)**,
Swift **6.4**, selected `/Applications/Xcode.app/Contents/Developer`, worktree/index,
revision and submodule inspection. Actual rebuilt Debug host is
`/private/tmp/kontrol-f13-derived/Build/Products/Debug/Kontrol.app`, ad-hoc
CDHash **`cac9216d981961310b3acfa0717bfd6f668d40fa`**, no TeamIdentifier.
Fresh component errors report **`trusted=false, active=false`** from inside this
host. Successful activation/AX-window registration is not established by the
attestation or shell identity inspection. No TCC mutation or assertion bypass
was attempted.

### Required commands actually executed and audited

From repository root, `bash "$E/run-tests.sh"` ran these exact plan-equivalent
commands serially (only fresh result-bundle destinations added):

```bash
E=/tmp/kontrol-f13-step6-2-attested.gTpNEO
xcodebuild -project Kontrol.xcodeproj -scheme Kontrol \
  -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath /tmp/kontrol-f13-derived -parallel-testing-enabled NO \
  CODE_SIGNING_ALLOWED=NO -resultBundlePath "$E/seven-suite.xcresult" \
  -only-testing:KontrolTests/AppPreferencesRepositoryTests \
  -only-testing:KontrolTests/AppPreferencesStoreTests \
  -only-testing:KontrolTests/FocusPreferencesTests \
  -only-testing:KontrolTests/FocusTimingTests \
  -only-testing:KontrolTests/FocusServiceTests \
  -only-testing:KontrolTests/DesignSystemComponentTests \
  -only-testing:KontrolTests/DesignSystemTokenTests test
xcodebuild -project Kontrol.xcodeproj -scheme Kontrol \
  -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath /tmp/kontrol-f13-derived -parallel-testing-enabled NO \
  CODE_SIGNING_ALLOWED=NO -resultBundlePath "$E/full-suite.xcresult" test
for bundle in seven-suite full-suite; do
  xcrun xcresulttool get test-results summary \
    --path "$E/$bundle.xcresult" --format json
  xcrun xcresulttool get test-results tests \
    --path "$E/$bundle.xcresult" --format json
done
xcrun xcresulttool export attachments --path "$E/full-suite.xcresult" \
  --output-path "$E/attachments"
python3 "$E/audit.py"
```

Both **test commands exited 65**; summary/tree queries and attachment export
exited **0**. Seven suites: **112 executed, 90 passed, 22 failed**. All 22
component methods failed the explicit host Accessibility prerequisite, error
`DesignSystemAXPrerequisite Code=-25211`. The other six suites passed their
original **90** methods; token contrast tests passed, not a substitute for live
rendered contrast acceptance.

Serial full suite: **1127 executed, 1055 passed, 72 failed**, **0 skips / expected
failures**. Result audit accounts for every actual XCTest method exactly once,
including all **625** previously outstanding Step 6.1 identifiers: **553 passed,
72 failed**. `full-suite-identifiers.json`, `full-suite-suite-counts.json`,
`deferred-625-results.json`, and `unresolved-identifiers.txt` retain exact names
and results; raw logs and bundle failures retain every concrete assertion.

| Non-passing suite | Passed | Failed | Findings still requiring closure |
| --- | ---: | ---: | --- |
| DesignSystemComponentTests | 0 | 22 | Actual host trust/activation prerequisite |
| LearningPresentationTests | 4 | 3 | Compact/wide topic/choice geometry; topic selection and resulting lesson identity |
| LessonExperiencePresentationTests | 2 | 19 | Missing studied/history/coverage controls/content; reveal and completion interactions |
| SettingsSceneTests | 12 | 24 | AX prerequisite for folder/export geometry/keyboard; route/state interactions; native scene lifecycle |
| TaskPresentationTests | 23 | 4 | Today rows/date updates, editor commit/dismissal, native delete confirmation |

Examples are not silently assigned to the AX prerequisite: Learning geometry
reports **620 not <360** at compact width and **304 not >469** at wide width;
Settings route tests report `InvalidTransition` errors; the native Tasks editor
still reports **“New task commits and editor closes”** false. Historical F02
`testQuickCapturePublishesAcrossTodayAndTasksWithoutPostSaveRead` passed in this
full run, but `testNativeTasksEditorCreatesEditsAndCancelsWithoutWriting` failed,
and `testNativeDeleteAlertKeyboardNavigationAndConfirmation` **failed**, not
skipped: missing **Delete task**, while visible row actions include **Delete
Keyboard deletion**. Historical F06 failures have fresh failed evidence, not
explained closure. These need focused diagnosis/repairs and successful reruns
on the SAME Step 6.2. No test was weakened to make the gate pass.

The evidence audit initially miscounted three non-XCTest service-double
`testConnection()` functions as tests (exit 1). The corrected evidence parser
restricts enumeration to XCTestCase classes: **1127** actual methods, audited
exit **0**. This parser correction does not change or conceal any test failure.

### Actual rendered capture comparisons

Enumerated existing capture trees **before** claiming missing evidence:
`/private/tmp/kontrol-f01-evidence/`, `kontrol-shell-captures/`,
`kontrol-f13-step2.4-{geometry-r1,diagnostic-r2,final}-captures/`.
`capture-inventory.json` records files/dimensions/hashes and confirms no surviving
named before/after subdirectories in those trees. Fresh bundle attachment export
then produced **114 PNGs**, indexed in `fresh-capture-inventory.json` and
`attachments/manifest.json`. Host-printed geometry in `fresh-geometry.json` was
checked against PNG headers: **520×340 / 1000×700 / 1440×940 content points**,
**1040×680 / 2000×1400 / 2880×1880 pixels**, backing scale **2**, at
**100/130/160%** text; inline captures cover the desktop sizes.

Executed `xcrun swiftc "$E/compare.swift" -o "$E/compare"` and `"$E/compare"`,
exit **0**, comparing **210** historical/fresh/reference pairs. Exact inputs,
dimensions and sampled differences are in `image-pairs.json` and
`image-comparisons.json`: sRGB conversion, nearest-neighbor normalization to
content points, 8-point RGB grid, tolerance **2/255**. The **90** old matching
pairs remain byte-identical. For **114 historical versus freshly rendered
matching states**, **36** are byte-identical and **78** differ; differing samples
range **0–1684**. Unlike the old duplicate pairs, these fresh attachments are
actual current-source renderings. Differences are not automatically failures
or passes: General preference captures can remain identical, while the current
hub now includes actual folder and Local Data actions absent from the old hub.

Representative current captures were also visually inspected and actually
compared to references (all paths below are under `$E/attachments/`):

| State / reference | Actual PNG | Differing 8-point samples |
| --- | --- | ---: |
| Native 1440×940 standard hub / `docs/mockups/M38-settings.png` | `34D317AA-002F-4EBC-8FB6-D17F9301B1D2.png` | 3239/21240 |
| AI summary / `docs/mockups/M39-ai-settings.png` | `1CFB9B6A-3693-4AB6-821B-1F4D387E7C06.png` | 11026/21240 |
| AI editor / `docs/mockups/M39-ai-settings.png` | `3C8F2C82-9F44-4E9D-B439-6AA5BA869493.png` | 11952/21240 |
| Scrolled last News feeds / `docs/mockups/M36-news-topics-feeds.png` | `DA7A8362-7C7A-4036-86F2-DDDB00CC39A2.png` | 17409/21240 |

Observed differences: native Settings is a stacked document without imitation
shell chrome, not M38's illustrative two-column dashboard; it shows **0 saved
references**, fixed theme, and **Ready to export** with Manage actions. AI editor
is inline rather than the reference's dimmed modal, with real model picker,
blank replacement-key field, Save/Cancel and explicit optional/offline guidance.
The scrolled News image displays real bundled endpoints and Disable/Edit/Remove;
it is **not** the reference's edit-feed modal and does not satisfy that modal's
comparison. Compact 130% validation capture
`A3CC5D13-20E2-433D-AA66-81834A933FA9.png` (1040×680 pixels) shows wrapped
validation/recovery text, warning shape plus text and fully visible Cancel/Save;
its top is intentionally scrolled out of view. These observations are about
these actual images, not complete keyboard/VoiceOver acceptance.

Folder/Local Data geometry/keyboard methods failed before producing their new
captures. Thus fresh M40/M41 and supplemental folder/export comparisons, and
all other unrepresented applicable F00–F13 states, remain **unverified**.
User-verified manual observations are retained; the missing automated/rendered
comparisons and failing assertions are not waived by them.

### Packaging/process checks and preservation

`bash "$E/supplemental.sh"` executed Release build and unsigned packaging smoke,
not the later S13/D13 gates. These commands all exited **0**:

```bash
make build CONFIGURATION=Release DERIVED_DATA=/tmp/kontrol-f13-release-build
APP=/tmp/kontrol-f13-release-build/Build/Products/Release/Kontrol.app
ditto -c -k --keepParent "$APP" "$E/Kontrol-unsigned.zip"
shasum -a 256 "$E/Kontrol-unsigned.zip"
ditto -x -k "$E/Kontrol-unsigned.zip" "$E/extracted"
diff -qr "$APP" "$E/extracted/Kontrol.app"
codesign -dv --verbose=4 /private/tmp/kontrol-f13-derived/Build/Products/Debug/Kontrol.app
git diff --check
```

Extracted bundle matches built bytes, version/build **1.0/1**, and all four
resources/notices match current source. ZIP SHA-256:
**`6a70927bee0d208ecc8b603357890728d38657e6e58cafd3235c6f5c154bffdd`**.
After both test hosts exited, ran the available isolated Debug process smoke:
`env KONTROL_F00_RECOVERY_TEST=1 /private/tmp/kontrol-f13-derived/Build/Products/Debug/Kontrol.app/Contents/MacOS/Kontrol`.
PID **84306** remained alive after five seconds (`ps` exit **0**), then only that
process was terminated with SIGTERM (wait **143**, intentional). The opt-in Debug
path fails before production-store IO; no Retry/production-data interaction was
performed. This proves process startup only, not AX registration or a native
journey, signed-sandbox acceptance, or distribution approval.

Hosts **81218/81274** exited. Retained-store inventory covers **9 precisely logged
roots / 91 stores** with file/sidecar hashes; no cleanup/unlink was performed.
Initial broad integrity probes failed on intentional non-SQLite sentinels and
on two ContainerTests `source`/`snapshot` copies (`unable to open database file`);
those unsuccessful probes are retained, not presented as passes. Final read-only
inventory records **87 integrity-ok**, **2 exact intentional invalid-store
sentinels**, and **2 unverified read-only opens** (paths in
`retained-store-inventory.json`); original fixture files/sidecars are byte-equal
to HEAD. No fixture rewrite, production-data/credential/external-project access,
paid generation or broader permission was introduced. Historical failures and
all raw diagnostics remain intact.

Final documentation link/scope and whitespace checks are retained separately.
A diagnostic script initially tried `git show HEAD:.pi/PLAN.md` (exit 128: the
workflow inputs are untracked), then assumed the attestation's plan hash still
matched (assertion failure). Current plan SHA-256 is
`2d92284b2ee22d260d8bc9fa91e2b1098dc475c0e8c361e78cf8d3432dd24c43`,
not the attestation's `b8c59a921466ff8e07589091a56f8646965a7b6317040f38ca31357c610798f5`;
SPEC matches its attested hash. The builder made no workflow-input writes; the
runner-supplied task/HEAD manual acceptance credit is retained as instructed.
These failed diagnostic assumptions are not test passes or grounds to silently
alter the plan. Current-document link/file-scope validation is independent of
those assumptions.

**Remaining acceptance:** actual-host AX authorization/activation, diagnosis and
closure of every fresh hosted failure, then repeat the unchanged seven-suite
and serial full suite; finish missing rendered-state comparisons. Manual checks
remain user-verified and need not be repeated. Continue the SAME Step 6.2;
**not READY**, no checkbox marked, no F13/V1 or later-gate approval claimed.

## F13 Step 6.2 — escalation fixture repairs and remaining A13 failures (2026-10-01)

**REPAIR / FAILED; same task, not ready for review.** Confirmed first top-level
incomplete task is Step 6.2 (23/27). Read SPEC/ANALYSIS/PLAN, both previous
execution reports, latest skipped-review feedback, cumulative checklist and the
supplied task-23 attestation. Compared those findings to the actual working tree.
Preserved the inherited README change and all 415 appended QA lines, including
failed/unrun evidence. Repository/target and direct ancestor searches found no
applicable `AGENTS.md`; no submodule was listed. Changed only
`KontrolTests/LearningPresentationTests.swift`,
`KontrolTests/TaskPresentationTests.swift`, README and this ledger. No production
source, schema, fixture, permission, workflow state or plan checkbox changed.
Nothing was staged or committed; no later task was implemented.

Base HEAD remains **`98779210be3caad84b08f5c3a15f762be5958dbd`**. Evidence root:
**`/tmp/kontrol-f13-step6-2-escalation.UKhhdM/`** (`E` below). `inherited.patch`
preserves the entering worktree; `test-repair.patch` SHA-256
**`aec49b3461b9e1556f873707e151f1bd4e2637348a8934842bbbfc2a704463e7`**
identifies the tested delta. Environment remains arm64 macOS 27.0/26A428,
Xcode 27.0/27A266a, Swift 6.4, selected full Xcode. `environment.log`,
`project-list.log`, `commands.log`, `run.sh` and `exit-codes.log` retain details.

### Recurring cause, concrete repairs and findings still open

Earlier attempts did not repair tests: the first deferred the GUI gates, and
its continuation ran them but only recorded failures. There are distinct causes,
not one AX explanation for every assertion:

- **Actual-host permission:** all 22 component methods still fail
  `DesignSystemAXPrerequisite/-25211`, explicitly **trusted=false, active=false**.
  Twenty Settings methods still fail their host-trust guard. Actual rebuilt host
  is `/private/tmp/kontrol-f13-derived/Build/Products/Debug/Kontrol.app`, ad-hoc
  CDHash `cac9216d981961310b3acfa0717bfd6f668d40fa`, no team. Shell trust and a
  self-AX window tree are not this authorization. No TCC manipulation, removed
  prerequisite, added skip or expected failure was used. External host approval
  remains unavailable to code; the supplied manual observations remain credited
  **as user-verified**, not agent-performed, and are not requested again.
- **Confirmed stale Today oracles:** production's local-date header includes
  `.year()`, whereas two hosted tests expected a date without it. Updated only
  those date expectations, retaining all exact task/date/travel/write assertions.
  Added a bounded condition wait for the initial rendered row, retaining the exact
  count assertion: prior full-suite evidence raced the first committed layout.
  Both methods pass focused, full-suite and five same-host repetitions.
- **Confirmed compact coordinate error:** AX screen Y increases downward. The
  Learning test incorrectly asserted that a following row has a smaller Y.
  It now requires `lesson.minY >= topic.maxY`, also checking non-overlap, rather
  than removing the geometric assertion. Both compact widths pass. The unchanged
  wide assertion **still fails**: lesson `(304,516,904,151)` versus topic
  `(288,360,181,44)` at 1000×700/130%. New real captures confirm the compact
  branch at that width, not a permission-only failure. Captures and full frame
  diagnostics are retained even when the method fails; no wide assertion weakened.
- **Other historical findings:** Learning topic/choice updates, F06 studied,
  history, coverage and reveal/completion assertions, folder identifiers/dialog
  actions, Local Data transitions and Settings scene `InvalidTransition` still
  fail. The native Tasks delete alert still lacks `Delete task`. The native Tasks
  editor now passes the full run and five repetitions **without an editor repair**;
  this variability is not an explained closure of its previous failure.
- **New full-suite failure:**
  `FocusMigrationTests/testRichV1AndV2StoresPreserveEveryEntityOnUpgradeAndReopen`
  throws `persistenceFailure` at `snapshotSeed`, before any migration/reopen.
  On-disk enumeration (`focus-migration-copy-inventory.log`) identifies writer
  `KontrolFocusMigration-rich-V1-writer-988D4319-7FCF-4ACD-8DB7-0C9E13B25DC0`
  (143360-byte store, zero-byte WAL) and closed-source
  `KontrolFocusMigration-rich-V1-closed-source-EF21F3F8-D678-479E-9D70-16BC3010F52B`
  (**zero-byte backup destination**) under the logged TMPDIR. This narrows the
  failure to the test's SQLite backup boundary; its generic error does not retain
  the precise SQLite status, so BUSY/LOCKED is **not yet established**. Five passing
  isolated repetitions do not close it. Retained artifacts were not deleted,
  repaired, migrated or mistaken for damaged production data. Next repair must
  obtain the backup stage/status and regression-test the demonstrated cause.

`failure-transitions.json` checks **every** previously failing identifier against
fresh results, including new regressions. `unresolved-identifiers.txt` lists all
70 current failures. The task-specific manual attestation remains credited exactly
as in the preceding entry; it cannot satisfy these failures or absent comparisons.

### Exact verification and fresh results

From repository root, `bash "$E/run.sh"` executed the unchanged required gates
with fresh result paths, then all available source/build/packaging checks:

```bash
E=/tmp/kontrol-f13-step6-2-escalation.UKhhdM
f13_test() {
  local name="$1"; shift
  local flags=() suite
  for suite in "$@"; do flags+=("-only-testing:KontrolTests/$suite"); done
  xcodebuild -project Kontrol.xcodeproj -scheme Kontrol \
    -configuration Debug -destination 'platform=macOS' \
    -derivedDataPath /tmp/kontrol-f13-derived -parallel-testing-enabled NO \
    CODE_SIGNING_ALLOWED=NO -resultBundlePath "$E/$name.xcresult" "${flags[@]}" test
}
f13_test seven-suite AppPreferencesRepositoryTests AppPreferencesStoreTests \
  FocusPreferencesTests FocusTimingTests FocusServiceTests \
  DesignSystemComponentTests DesignSystemTokenTests
f13_test full-suite
for label in baseline focused seven-suite full-suite; do
  xcrun xcresulttool get test-results summary --path "$E/$label.xcresult" --format json
  xcrun xcresulttool get test-results tests --path "$E/$label.xcresult" --format json
done
xcrun xcresulttool export attachments --path "$E/full-suite.xcresult" --output-path "$E/attachments"
make build DERIVED_DATA=/tmp/kontrol-f13-derived
xcodebuild -project Kontrol.xcodeproj -scheme Kontrol -configuration Debug \
  -destination 'platform=macOS' -derivedDataPath /tmp/kontrol-f13-derived \
  CODE_SIGNING_ALLOWED=NO build-for-testing
make build CONFIGURATION=Release DERIVED_DATA=/tmp/kontrol-f13-release-build
codesign -dv --verbose=4 /private/tmp/kontrol-f13-derived/Build/Products/Debug/Kontrol.app
APP=/tmp/kontrol-f13-release-build/Build/Products/Release/Kontrol.app
ditto -c -k --keepParent "$APP" "$E/Kontrol-unsigned.zip"
shasum -a 256 "$E/Kontrol-unsigned.zip"
ditto -x -k "$E/Kontrol-unsigned.zip" "$E/extracted"
diff -qr "$APP" "$E/extracted/Kontrol.app"
python3 "$E/audit.py"
xcrun swiftc "$E/compare.swift" -o "$E/compare"
"$E/compare"
git diff --check
```

Both required test commands exit **65**: seven suites **90 passed / 22 failed**;
serial full suite **1057 passed / 70 failed**, **1127** methods, zero skips or
expected failures. Audited every method exactly once against source. All **625**
deferred identifiers executed: **555 passed / 70 failed**. Summary/tree outputs,
raw logs, suite counts and result bundles are retained in `E`, not substituted
with earlier passes. Failing suites: components **22**, Learning **3**, lesson
experience **19**, Settings **24**, Tasks **1**, Focus migration **1**.

Before editing, `baseline.xcresult` reproduced **3/3 failing** methods (Learning
geometry and the two Today methods). Same selectors after repair in
`focused.xcresult`: **2 passed / 1 failed**, exit **65**. Both use the same
`f13_test` arguments above and those three exact method identifiers.

Additional command (exit **0**), with summary/tree audited down to repetition
children, ran **four methods × five executions = 20 passed**, not merely four:

```bash
xcodebuild -project Kontrol.xcodeproj -scheme Kontrol -configuration Debug \
  -destination 'platform=macOS' -derivedDataPath /tmp/kontrol-f13-derived \
  -parallel-testing-enabled NO CODE_SIGNING_ALLOWED=NO \
  -resultBundlePath "$E/repetitions.xcresult" -test-iterations 5 \
  -test-repetition-relaunch-enabled NO \
  -only-testing:KontrolTests/TaskPresentationTests/testTodayUsesRealDateSharedSectionsAndHonestEmptyStateWithoutWriting \
  -only-testing:KontrolTests/TaskPresentationTests/testHostedTodayRecomputesRowsAndLocalDateAtMidnightAndAfterTravelWithoutSaving \
  -only-testing:KontrolTests/TaskPresentationTests/testNativeTasksEditorCreatesEditsAndCancelsWithoutWriting \
  -only-testing:KontrolTests/FocusMigrationTests/testRichV1AndV2StoresPreserveEveryEntityOnUpgradeAndReopen test
xcrun xcresulttool get test-results summary --path "$E/repetitions.xcresult" --format json
xcrun xcresulttool get test-results tests --path "$E/repetitions.xcresult" --format json
```

Build, test compilation, Release build, attachment export, result audits, image
comparison, unsigned packaging/extraction, source/resource byte comparison and
whitespace checks all exit **0**. Extracted version/build is **1.0/1**; all four
resources/notices match source. This is not signed/distribution acceptance.
The prior linkd/AppIntents diagnostics and QuickCapture QoS runtime warning remain
in the logs; no SQLite unlink diagnostic was observed. Hosts
**89392/89774/90525/90674/92904** exited; all opened test stores remain retained.
All **12** original V1–V4 fixture files and sidecars remain byte-equal to HEAD.

### Independent capture comparison and available smoke evidence

Enumerated historical trees, previous-attempt attachments (before), focused
captures, and full-run attachments (after) in `capture-inventory.json` before
assessing absence. Current full bundle exports **117** PNGs: **114** Settings
states plus **three** new Learning route states. Actual Settings content is
520×340 / 1000×700 / 1440×940 points at 100/130/160% text, backing scale **2**;
Learning is 420×700 / 620×700 / 1000×700 points at 130%, respectively
840×1400 / 1240×1400 / 2000×1400 pixels, backing scale **2**. Exact files,
points/pixels/scales/hashes are in `fresh-capture-inventory.json` and host logs.

Actually compared **120** pairs (`image-pairs.json`, `image-comparisons.json`):
**114** matching previous/current Settings states (**59 byte-identical**, **55**
differ; 0–213 different sampled points), **three** focused/full Learning captures
(all byte-identical, zero different samples), and **three** Learning versus
`docs/mockups/M15-learning-choices.png` comparisons. Method: sRGB, nearest-neighbor
normalization to content points, 8-point RGB grid, tolerance 2/255. Sampling is
comparison evidence, not a full-pixel or acceptance pass.

The 1000×700 Learning capture
`$E/attachments/A72F45C9-1945-4780-8761-2735027938FA.png` differs from M15 on
**5653/11000** sampled points (620: **3527/6864**; 420: **2592/4664**).
Visually inspected the focused matching capture and M15: current rendering has a
horizontal topic strip, vertically stacked lesson cards with exact objectives,
concept labels and full named Open/Show another actions; M15 has a topic rail and
a two-column illustrative card grid. Compact stacking is supported; the required
wide-rail assertion remains failed. This is an actual rendering difference, not
merely a report that fixture images were generated. Also visually inspected the
current native standard hub
`$E/attachments/24A2C242-5957-4266-932E-64911E9DA097.png`: it retains actual folder
and Local Data actions in the single stacked document, consistent with the earlier
M38 comparison's documented departure. No visual acceptance inferred from that.

M40/M41 and supplemental folder/export captures still were not produced because
their methods fail host trust; other unrepresented applicable F00–F13 states
remain unverified. Neither the attestation nor 117 renders closes those omissions.

Available isolated native **process-startup only** smoke:
`env KONTROL_F00_RECOVERY_TEST=1 /private/tmp/kontrol-f13-derived/Build/Products/Debug/Kontrol.app/Contents/MacOS/Kontrol`.
PID **93012** stayed alive for five seconds (`ps` exit 0); terminated only that
process with SIGTERM (intentional wait **143**). This Debug seam fails before
production-store IO; no Retry, real-store or native journey was performed.
`native-process-smoke.log` retains the results.

The preceding attempt's **two unverified closed-copy integrity opens** were also
checked independently with `python3 "$E/closed-copy-integrity.py"` (exit 0): host
81274 exited, owned descendants are not symlinks, no WAL/SHM exists; standalone
closed copies use read-only `immutable=1`, never stores with WAL. Both return
`integrity_check=ok`, with full directory byte inventories unchanged. Exact
canonical source/snapshot paths and hashes are in
`prior-closed-copy-integrity-final.log`. Initial guard attempt exited **1** because
it rejected macOS's system `/var → /private/var` alias; corrected only that known
ancestor handling while retaining descendant checks. The failed probe log remains.
No cleanup, original fixture open, permission broadening or paid generation occurred.

**Continue Step 6.2:** fix the remaining wide-layout/topic/AX-content/native-action
and scene failures, diagnose the newly exposed SQLite backup failure, establish
actual rebuilt-host authorization, and complete absent reference comparisons.
Rerun both required gates after repairs. Manual observations remain user-verified;
full-suite failures and missing evidence remain explicit, not release approval.
