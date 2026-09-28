# Kontrol — F00 executable foundation

Kontrol is a local-first macOS SwiftUI app. F00 provides seven destinations (Today, Learning, Projects, Focus, Tasks, News, Settings), a native Settings scene, an offline starter catalog, and non-destructive startup recovery. F02 provides persistent task creation, editing, completion/reopening, confirmed deletion, Today/Upcoming/Completed filters, optional notes and due dates, and quick capture on Today. F03 adds selected-day browsing and persistent manual schedule blocks with explicit overlap review. The first launch contains no sample personal records. The mockups are visual references, not live data.

## Requirements and build

Selected toolchain observed on this machine: `/Applications/Xcode.app/Contents/Developer`, **Xcode 27.0 (27A266a)**, **Apple Swift 6.4 (swiftlang-6.4.0.34.1)**. The project uses Swift language mode **5.0** and targets **macOS 14.0 or newer** for both targets. Select full Xcode (not only Command Line Tools); no third-party packages or network access are needed for the F00 build.

From the repository root:

```sh
xcode-select -p
xcodebuild -version
xcrun swift --version
xcodebuild -list -project Kontrol.xcodeproj
xcodebuild -project Kontrol.xcodeproj -scheme Kontrol -configuration Debug \
  -destination 'platform=macOS' -derivedDataPath /tmp/kontrol-f00-derived \
  CODE_SIGNING_ALLOWED=NO build
xcodebuild -project Kontrol.xcodeproj -scheme Kontrol -configuration Debug \
  -destination 'platform=macOS' -derivedDataPath /tmp/kontrol-f00-derived \
  CODE_SIGNING_ALLOWED=NO test
xcodebuild -project Kontrol.xcodeproj -scheme Kontrol -configuration Debug \
  -destination 'platform=macOS' -derivedDataPath /tmp/kontrol-f00-derived \
  CODE_SIGNING_ALLOWED=NO analyze
git diff --check
```

Open `Kontrol.xcodeproj`, choose the shared **Kontrol** scheme and run the app in Xcode for local interaction. For a locally ad-hoc-signed sandboxed build (not a distribution signature), run:

```sh
xcodebuild -project Kontrol.xcodeproj -scheme Kontrol -configuration Debug \
  -destination 'platform=macOS' -derivedDataPath /tmp/kontrol-f00-sandbox \
  CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual \
  DEVELOPMENT_TEAM= build
codesign --display --entitlements :- \
  /tmp/kontrol-f00-sandbox/Build/Products/Debug/Kontrol.app
open /tmp/kontrol-f00-sandbox/Build/Products/Debug/Kontrol.app
```

The `CODE_SIGNING_ALLOWED=NO` commands build/test without an app signature; use the signed build to check real sandbox behavior. Signing, GUI/VoiceOver checks, and visual comparisons are separate integration checks, **not** established by a successful `xcodebuild -list`.

## Local data and catalog

The app bundle includes `Kontrol/Resources/starter-catalog.json` (installed in `Kontrol.app/Contents/Resources/starter-catalog.json`): catalog version 2 with 40 validated offline lessons, eight each for Go, Java, System Design, Performance, and Security. V4 imports definitions and persists four initial slots per topic without overwriting personal progress. This resource contains no personal tasks, progress, slots, or lesson attempts.

The production SwiftData store resolves to `Application Support/Kontrol/Kontrol.store` in the app's **user-domain sandbox container**; for the signed app with bundle ID `com.kontrol.app`, the usual path is `~/Library/Containers/com.kontrol.app/Data/Library/Application Support/Kontrol/Kontrol.store`. Keep the database and any `-wal`/`-shm` sidecars together. Do not delete or move them to troubleshoot launch: a failed open displays a blocking recovery screen with Try again or Quit, not an automatic reset. An unsigned local build may resolve Application Support outside a sandbox; do not use that location for tests. Automated tests use isolated in-memory or unique temporary stores. Only the selected destination is stored in `UserDefaults` (`com.kontrol.app.selectedDestination`), not the SwiftData database.

The frozen V1 fixture is `KontrolTests/Fixtures/V1/` (database and sidecars). `KontrolTests/Fixtures/README.md` documents its exact record, generator, and reproduction safeguards. To reopen it without altering the checked-in copy:

```sh
xcodebuild -project Kontrol.xcodeproj -scheme Kontrol -destination 'platform=macOS' \
  -derivedDataPath /tmp/kontrol-f00-derived CODE_SIGNING_ALLOWED=NO \
  -only-testing:KontrolTests/V1FixtureTests test
```

The test copies **all** fixture files into a unique temporary directory, releases owners between opens, and checks identity and original fixture bytes. To generate a *new candidate* using the frozen V1 definitions (never silently replace the historical fixture):

```sh
xcrun swiftc -o /tmp/kontrol-v1-writer \
  Kontrol/Data/Persistence/KontrolSchemaV1.swift \
  KontrolTests/Fixtures/GenerateV1.swift
base=$(mktemp -d)
/tmp/kontrol-v1-writer "$base/V1"  # new, nonexistent path; refuses overwrite
ls -la "$base/V1"                 # inspect complete file set before any manual capture
```

There is no V0 fixture or claimed V0 migration. F03 added a separate frozen V2 fixture and V1→V2 migration tests; see [fixture documentation](KontrolTests/Fixtures/README.md). Future schemas require separate versioned fixtures and migration tests.

## F00 boundaries and verification status

At the F00 checkpoint, Today offered title-only quick capture (planned for the local current day, no due date) and Today and Tasks displayed saved tasks. F02 has since added editing, completion/reopening, confirmed deletion, filters, optional notes and due dates; quick capture still defaults to Today but can also set a plan and due date. The F00 evidence below describes that historical checkpoint, not the current F02 gate. At the F00 checkpoint Learning showed five offline starter summaries, before F05 introduced the 40-lesson catalog and four persisted choices per topic. F05 still does not include interactive attempts or rotation. Projects, Focus, and News are honest foundation states; **F13** preferences, export, credential management, and release packaging/notarization are not implemented. The Settings scene currently shares the same no-settings-yet content as its destination.

### F00 integration evidence (2026-09-27, Xcode 27.0)

`xcodebuild -list -project Kontrol.xcodeproj` lists exactly `Kontrol` and `KontrolTests` with shared scheme `Kontrol`. After `xcodebuild ... CODE_SIGNING_ALLOWED=NO clean`, the **exact build, test, analyze, signed build, entitlements, and `git diff --check` commands above** completed successfully in that order. The full suite ran **62 tests, 0 failures**. The ad-hoc-signed bundle at `/tmp/kontrol-f00-sandbox/Build/Products/Debug/Kontrol.app` has `com.apple.security.app-sandbox = true` (`get-task-allow = true` for this debug build). Command logs: `/tmp/kontrol-f00-{clean,build,test,analyze,signed,entitlements,diffcheck}.log`; the clean rerun of all six verification commands is logged at `/tmp/kontrol-f00-clean-current.log` and `/tmp/kontrol-f00-{build,test,analyze,signed,entitlements,diffcheck}-current.log` (62 tests, zero failures again). `codesign --verify --deep --strict --verbose=2` also verified the signed bundle; its packaged catalog exists, bundle ID is `com.kontrol.app`, and minimum system version is 14.0. AppIntents metadata extraction was skipped (no AppIntents dependency); no source deprecation warnings remain.

Before launching the signed app, `~/Library/Containers/com.kontrol.app` did not exist. Launch created a sandbox store and displayed the empty Today state, without seeded personal records. UI automation selected each of the seven destinations and opened native Settings with Command-comma. A title-only task saved once, appeared on Today and Tasks, and remained after quitting/relaunching; Settings remained selected after quitting/relaunching. Cancelling a second draft did not create a row. Matching Tasks screenshots before/after relaunch at `/tmp/kontrol-f00-evidence/{before/Tasks-before-relaunch,after/Tasks-after-relaunch}.png` have the same 2092×1556 dimensions and **zero different pixels in a sampled 8-pixel grid (51,090 samples)**; the rendered list and task title are identical. These automated checks used this machine's initially absent sandbox container, **not** a separate test macOS account or a physically disconnected network. The user separately confirmed the offline fresh-account and keyboard/VoiceOver observations; those are **user-verified**, not observations made by automation.

Rendered M00 and injected-store-failure M01 captures from XCTest are `/tmp/kontrol-shell-captures/today-{1000x700,1440x940}.png` and `/tmp/kontrol-recovery-captures/store-{1000x700,1440x940}.png` (plus `catalog-520x340.png`). Compared with `docs/mockups/M00-app-shell.png` and `M01-store-recovery.png`: both sizes keep seven visible navigation labels and a selected underline; M00 uses genuine empty Today content rather than the mockup's illustrative schedule/lesson; M01 blocks navigation and shows preservation guidance and Quit/Try again. The app uses native titlebar controls rather than imitation controls. A sampled 8-pixel-grid image comparison at 1440×940 found 2,653/21,240 differing pixels for M00 and 4,765/21,240 for M01, consistent with actual empty content, native chrome, and rendering differences; these are **visual review references, not pixel-equality gates**. Native-sheet M09 screenshots are `/tmp/kontrol-f00-evidence/before/M09-1000x700.png` and `/tmp/kontrol-f00-evidence/before/M09-live-1440x860.png`, compared with `docs/mockups/M09-quick-capture.png`: title, Today plan, None due, Cancel/Add, and dimmed Today context are visible; the fixed indications are labels, not editable selectors. **The latter is a 1440×860-point live window (2972×1812 pixels including chrome), not a 1440×940-point capture:** this machine's physical display limited the window's height. The user separately confirmed the full-height M09 check on a capable display; no path to that user screenshot was provided, so it is recorded as user-verified, not as an agent-captured image. The 1000×700-point live window capture has a 32-point native titlebar. Do not treat these as pixel-identical images.

XCTest covers injected store failure on a *closed copy* of the V1 fixture, compares every store file and sidecar's bytes before Retry, and verifies no partially ready dependencies. Recovery presentation tests exercise accessible Retry during a serialized attempt and an injected Quit callback; task tests exercise failed-save draft retention and no false success, catalog tests exercise atomic marker/definition writes. AX tests check navigation roles, descriptions, selected state, keyboard focus order, and recovery controls at the specified sizes; only the user's attestation covers spoken VoiceOver behavior.

For a signed-app recovery smoke run, Debug builds alone support `open -n --env KONTROL_F00_RECOVERY_TEST=1 /tmp/kontrol-f00-sandbox/Build/Products/Debug/Kontrol.app`. This explicit flag makes the **first** open fail before disk IO and Retry open a unique store under the sandbox's `Data/tmp/KontrolF00Recovery-<UUID>/` (never the production store); it is excluded from Release. This run captured the initial signed recovery screen at `/tmp/kontrol-f00-evidence/before/M01-signed-injected-1000x700.png`, clicked **Try again** and observed the ready shell, quit, launched a second injected instance and clicked its **Quit** button. The second process terminated normally. SHA-256 manifests of every existing production-store file and sidecar are `/tmp/kontrol-f00-evidence/before/production-store.sha256` and `/tmp/kontrol-f00-evidence/after/production-store{,-after-quit}.sha256`; both `diff -u` comparisons returned zero. The new isolated store directory was `/Users/marcoandreose/Library/Containers/com.kontrol.app/Data/tmp/KontrolF00Recovery-CC113835-4BFD-4C2D-84DA-724644E18A31` (a temporary smoke artifact, not production). XCTest also verifies first failure creates no file and Retry saves to only the injected temporary location. No real store was intentionally failed or reset. A further native smoke launched the current ad-hoc-signed app with the isolated Debug failure flag, confirmed a running process, then terminated that smoke instance; `shasum -a 256 -c /tmp/kontrol-f00-evidence/before/production-store.sha256` still matched the production database and both sidecars. This process check alone does not establish a GUI interaction; the preceding capture and interactive run are separate evidence. Human offline, accessibility, and full-height M09 checks are credited solely as user-verified, without inventing image files or claiming this agent performed them.

Contracts: [F00](docs/features/F00-foundation.md), [architecture](docs/architecture.md), [QA gates](docs/qa.md), [mockup index](docs/mockups/INDEX.md), [product plan](PLAN.md), and related [F01](docs/features/F01-design-system.md), [F02](docs/features/F02-tasks.md), [F05](docs/features/F05-learning-catalog.md), [F13](docs/features/F13-settings-release.md), [curriculum briefs](docs/learning-curriculum.md).

## F01 design system and integration evidence (2026-09-28)

F01 adds the fixed-dark semantic palette, monospaced scalable typography, shared controls, status/empty/error/loading presentation and accessible reflow to the **existing** seven destinations, startup states and quick capture. The approved [M00/M42 direction](docs/mockups/INDEX.md) and [selected palette/type/component reference](.mockups/design-system/components.html) are references, not production records or working appearance preferences. Confirmation and Undo are caller-owned demonstration components; F13 settings, export and theme preferences remain deferred. No new model, container or target was added. Both targets still deploy to macOS 14.0; SF Symbol names are checked at runtime by `AppShellTests` on the tested OS, **not** on macOS 14.

This run used `/Applications/Xcode.app/Contents/Developer`, Xcode **27.0 (27A266a)**, Apple Swift **6.4 (swiftlang-6.4.0.34.1)**, macOS **27.0**; the Swift language mode is 5.0. From the repository root (logs in `/tmp/kontrol-f01-integration-*.log`):

```sh
xcode-select -p
xcodebuild -version
xcrun swift --version
xcodebuild -project Kontrol.xcodeproj -scheme Kontrol -configuration Debug -destination 'platform=macOS' -derivedDataPath /tmp/kontrol-f01-derived CODE_SIGNING_ALLOWED=NO build
xcodebuild -project Kontrol.xcodeproj -scheme Kontrol -configuration Debug -destination 'platform=macOS' -derivedDataPath /tmp/kontrol-f01-derived CODE_SIGNING_ALLOWED=NO test
xcodebuild -project Kontrol.xcodeproj -scheme Kontrol -configuration Debug -destination 'platform=macOS' -derivedDataPath /tmp/kontrol-f01-derived CODE_SIGNING_ALLOWED=NO analyze
xcodebuild -project Kontrol.xcodeproj -scheme Kontrol -configuration Debug -destination 'platform=macOS' -derivedDataPath /tmp/kontrol-f01-sandbox CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= build
codesign --display --entitlements :- /tmp/kontrol-f01-sandbox/Build/Products/Debug/Kontrol.app
git diff --check
```

The full suite covers 100 tests including navigation keyboard/AX order and ≥32-point target bounds at both 1000×700 and 1440×940 content sizes at 100%, 130%, 160% and 240%; then-current imported Learning summaries; enlarged capture and Settings; reduced-motion loading; failed-save draft retention, serialized recovery, temporary-store reopening and copied fixture bytes. Test persistence uses isolated in-memory/temporary stores and defaults suites. `DesignSystemTokenTests` checks approved sRGB channels and actual pairings: primary text on background/surface/raised **14.48/13.70/12.47:1**, secondary **7.72/7.31/6.65:1**, accent/error text **5.63/5.33/4.85:1**, dark label on accent **5.63:1**; success/warning on background **10.02/11.08:1** and surface **9.49/10.49:1** (all ≥4.5:1). Focus ring **14.48/13.70/12.47:1** and essential boundary **7.72/7.31/6.65:1** exceed 3:1; the 1.39:1 decorative border is never an essential outline. Exact ratios and role mappings are in [palette.html](.mockups/design-system/palette.html).

Current F01 XCTest captures (content points = pixels in these 1:1 offscreen snapshots): `/tmp/kontrol-f01-evidence/fixtures/{today,learning}-{1000x700,1440x940}-{standard,130pct}.png`, `/tmp/kontrol-recovery-captures/store-{1000x700,1440x940}.png`, `/tmp/kontrol-recovery-captures/catalog-520x340.png`; the hosted shell also writes `/tmp/kontrol-shell-captures/today-{1000x700,1440x940}.png`. Today and Learning are actual hosted views backed by isolated stores, not mockup sample schedules or M42's future F13 controls. Visual review against [M00](docs/mockups/M00-app-shell.png), [M42](docs/mockups/M42-design-accessibility.png), [M01](docs/mockups/M01-store-recovery.png), [M09](docs/mockups/M09-quick-capture.png), and [M43](docs/mockups/M43-learning-starter-summary.png): at 130% the seven labeled destinations reflow into two ordered rows; Today has a real empty state and Add task, Learning shows the five real offline lessons, recovery blocks a decorative shell and retains Quit/Try again. M42's redundant status and focus patterns are tested via shared components, not an Appearance screen. M09's sample title and extra editable fields are illustrative; the real native sheet is title-only. Hosted AX/frame tests verify Title, plan/due labels and Cancel/Add at both sizes (including 130%); the zero-height native Title discovered in the initial GUI run was fixed by ignoring a transient zero size preference, with rendered-frame assertions at 100%, 130% and extreme scaling. This run did not recapture the earlier signed-sheet screenshot.

The rendered 1440×940 image pairs were *actually compared* by sampling RGB every 8 pixels (0.01-channel tolerance): F01 Today standard vs hosted shell Today **219/21,240** different samples; F01 Today 130% vs M00 **2,652/21,240**; F01 Learning standard vs M43 **2,515/21,240**; injected recovery vs M01 **4,534/21,240**. Differences reflect real empty content, text scaling, native chrome and non-pixel-identical reference layouts, not an equality gate. Matched standard-vs-130% captures differ at 1000×700 and 1440×940: Today **603/11,000** and **602/21,240** sampled pixels; Learning **661/11,000** and **728/21,240**, respectively (the hosted tests also assert enlarged rendered font metrics). `/tmp/kontrol-f01-evidence/before` and `/tmp/kontrol-f01-evidence/after` currently contain **only** matching production-store SHA-256 manifests (three database/sidecar files each, `diff -u` exit 0); no before/after task screenshot survives in this environment. No screenshot comparison or signed-app relaunch is inferred from missing files. XCTest separately verifies reopening temporary stores, destination preference restoration, failed-save draft preservation and store bytes on injected failure. A fresh locally signed Debug process launched with `KONTROL_F00_RECOVERY_TEST=1` stayed alive, then was terminated without touching the production store; this process smoke does not prove an interactive recovery sequence. The injected flag directs Retry to a unique sandbox `Data/tmp/KontrolF00Recovery-<UUID>/` store, never deliberately damaging user storage.

The locally ad-hoc-signed Debug bundle passes `codesign --verify --deep --strict`, packages `starter-catalog.json`, has `LSMinimumSystemVersion=14.0`, ID `com.kontrol.app`, sandbox entitlement `true` and Debug `get-task-allow=true` (see `/tmp/kontrol-f01-integration-{signed,entitlements,verify,native}.log`). This is **not** distribution signing/notarization. The user personally attested for this task/HEAD in `.pi/workflows/2026-09-27T15-40-16-780Z-XLNveA/manual-attestation.json` that “manual checks passed, you can continue and close the feature”; offline, keyboard, spoken VoiceOver, reduced motion, live layout and signed-app relaunch observations are credited **only as user-verified**, not performed or photographed in this run. The exact GUI screenshots/measurements from the user's checks were not provided. A macOS 14 runtime/API/symbol smoke remains unavailable on this macOS 27 host; runtime symbol tests on macOS 27 and the 14.0 build minimum do not substitute for testing on 14. F13 release packaging/notarization remains deferred. No F00 human attestation is counted as F01 evidence.

## F02 task lifecycle and non-GUI gate (2026-09-28)

The current Today quick-capture sheet starts with Title and a relative Today plan; Tasks provides Today, Upcoming and Completed filters, create/edit (including optional notes, due date/time and plan date), completion/reopening and task-specific confirmed deletion. Both routes use one app-owned task store; successful mutations publish committed snapshots without a second fetch. Open overdue tasks remain discoverable. No F04 focus-session model exists yet, so linked-history deletion is **not** verified. See [F02](docs/features/F02-tasks.md), [M02–M05/M09](docs/mockups/INDEX.md), and the [QA gate](docs/qa.md). The earlier F00/F01 descriptions and observations above remain historical evidence, not assertions that the current sheet is title-only.

Observed on `/Applications/Xcode.app/Contents/Developer`, Xcode **27.0 (27A266a)**, Apple Swift **6.4 (swiftlang-6.4.0.34.1)**, macOS **27.0 (26A428)**, arm64; both targets retain macOS 14.0 deployment and Swift 5 language mode. Run from the repository root:

```sh
xcode-select -p
xcodebuild -version
xcrun swift --version
make build DERIVED_DATA=/tmp/kontrol-f02-derived
xcodebuild -project Kontrol.xcodeproj -scheme Kontrol -configuration Debug -destination 'platform=macOS' -derivedDataPath /tmp/kontrol-f02-derived CODE_SIGNING_ALLOWED=NO build-for-testing
xcodebuild -project Kontrol.xcodeproj -scheme Kontrol -configuration Debug -destination 'platform=macOS' -derivedDataPath /tmp/kontrol-f02-derived CODE_SIGNING_ALLOWED=NO \
  -only-testing:KontrolTests/TaskRepositoryTests \
  -only-testing:KontrolTests/TaskSelectionTests \
  -only-testing:KontrolTests/TaskStoreTests \
  -only-testing:KontrolTests/TaskEditorDraftTests \
  -only-testing:KontrolTests/V1FixtureTests \
  -only-testing:KontrolTests/SchemaTests \
  -only-testing:KontrolTests/ContainerFactoryTests \
  -only-testing:KontrolTests/CatalogValidatorTests \
  -only-testing:KontrolTests/CatalogImportTests \
  -only-testing:KontrolTests/BundledCatalogTests \
  -only-testing:KontrolTests/LaunchCoordinatorTests \
  -only-testing:KontrolTests/LaunchRecoveryTests \
  -only-testing:KontrolTests/NavigationStoreTests \
  -only-testing:KontrolTests/ProjectSmokeTests \
  -only-testing:KontrolTests/AppShellTests/testOneStorePerDependencyGraphAcrossRoutesAndWindows \
  -only-testing:KontrolTests/AppShellTests/testNavigationMetadataAndRouting \
  -only-testing:KontrolTests/QuickCaptureTests/testBlankDraftNeverSaves \
  -only-testing:KontrolTests/QuickCaptureTests/testFailureKeepsEditableTitleAndSheetUntilSingleSuccessfulRetry \
  -only-testing:KontrolTests/QuickCaptureTests/testOvernightTodayIsResolvedAtSubmissionAndPublishesOneIdentity \
  -only-testing:KontrolTests/QuickCaptureTests/testUnplannedAndClearedDuePersistAndFailureRetainsAllSelections \
  -only-testing:KontrolTests/QuickCaptureTests/testExplicitDateAndDueAreSavedAsSelected \
  -only-testing:KontrolTests/QuickCaptureTests/testExplicitPlanKeepsSelectedCalendarDayAndZoneAfterTravelAndFailedSave test
xcodebuild -project Kontrol.xcodeproj -scheme Kontrol -configuration Debug -destination 'platform=macOS' -derivedDataPath /tmp/kontrol-f02-derived CODE_SIGNING_ALLOWED=NO analyze
xcodebuild -project Kontrol.xcodeproj -scheme Kontrol -configuration Debug -destination 'platform=macOS' -derivedDataPath /tmp/kontrol-f02-sandbox CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= build
codesign --verify --deep --strict /tmp/kontrol-f02-sandbox/Build/Products/Debug/Kontrol.app
codesign --display --entitlements :- /tmp/kontrol-f02-sandbox/Build/Products/Debug/Kontrol.app
git diff --check
```

Build, test-bundle compilation, **91 selected tests (0 failures, 0 skips)**, analyzer, ad-hoc-signed build, and strict signature verification succeeded. The selected tests include the complete UUID-isolated disk lifecycle across distinct opens and F02 mutations on a complete copied V1 fixture; the originals (database and sidecars) are checked byte-for-byte unchanged by `V1FixtureTests`. The selected-test result bundle is `/tmp/kontrol-f02-derived/Logs/Test/Test-Kontrol-2026.09.28_15-58-10-+0800.xcresult`; command output is `/tmp/kontrol-f02-{toolchain,build,build-for-testing,selected-tests,analyze,signed,verify,entitlements}.log`. The entitlement inspection succeeded and reported `com.apple.security.app-sandbox = true` and Debug `com.apple.security.get-task-allow = true`; this is **not** distribution signing or an offline app-open/relaunch test. `git diff --check` returned 0 after the README edit (no whitespace errors; `/tmp/kontrol-f02-diffcheck.log` is empty).

Warnings investigated: `platform=macOS` matches both arm64 and x86_64 on this machine; xcodebuild chose arm64. Metadata extraction was skipped because there is no AppIntents.framework dependency. The `codesign --display --entitlements :-` syntax emits a deprecation warning about `:` despite returning the expected entitlement XML (the command is retained as specified). Test runtime emitted `com.apple.linkd.autoShortcut` connection messages and CoreData open errors from the intentional invalid-store recovery test; its assertions passed. No new Swift compiler or analyzer diagnostic was found.

### F02 deferred/open F13 acceptance ledger (not passed by this gate)

- Run **all** `TaskPresentationTests` and the **hosted portions** of `QuickCaptureTests` in a reserved, active, uncontended GUI session on a real Mac, then `make test DERIVED_DATA=/tmp/kontrol-f13-derived` per [QA](docs/qa.md). Previous hosted runs had intermittent missing AX controls/visibility and editor-sheet dismissal failures (including `testNativeTasksEditorCreatesEditsAndCancelsWithoutWriting` and `testQuickCapturePublishesAcrossTodayAndTasksWithoutPostSaveRead`); `TaskPresentationTests/testNativeDeleteAlertKeyboardNavigationAndConfirmation` previously **skipped** because there was no active key GUI window. These are unresolved, not reclassified as passes; compilation and the selected non-GUI tests do not exercise them.
- In that session verify keyboard-only capture/edit/submit/cancel, filter and row actions, native destructive alert focus and confirmation, initial Title focus and focus restoration, independent AX row/actions and spoken VoiceOver names/roles/selected state, visible focus and ≥32-point targets, long-field scrolling, enlarged text and live reduced motion. Record failures as well as successes; no F02 manual attestation is available for these checks.
- Capture and compare the **rendered F02 states** against `docs/mockups/M02-tasks.png`, `M03-task-editor.png`, `M04-task-complete-reopen.png`, `M05-task-delete.png` and `M09-quick-capture.png` at **1000×700 and 1440×940** points; record actual before/after screenshots and differences at F13. No F02 pair of both-size screenshots or comparison is claimed here. Earlier F00/F01 M09 and Today captures are historical, not substitutes for F02 captures.
- Open the signed sandbox app on isolated test data **offline**, create/edit/complete/reopen/delete, quit and relaunch to check Today/Tasks state and unchanged unrelated records. Run the same journey on **macOS 14** when available; this macOS 27 build and ad-hoc signature do not establish either runtime check.
- After **F04** introduces focus history, delete a linked task and assert the historical optional reference becomes nil, the title snapshot remains and no history cascades. No such model or integration check exists in F02.

## F03 manual schedule non-GUI gate ledger (2026-09-28)

F03 adds a V2 SwiftData schedule model with copied-V1 migration and a separate frozen V2 fixture; one app-owned schedule store publishes committed snapshots alongside tasks. Today has window-local previous/next/relative-Today selection, selected-day tasks and half-open intersecting block rows, a native add/edit/move/delete sheet, and an explicit, fresh-review Keep both overlap decision. [F03 contract](docs/features/F03-today-schedule.md) · [architecture](docs/architecture.md) · [M06–M09 and F03 variants](docs/mockups/INDEX.md) · [QA / F13 ledger](docs/qa.md). The M06 lesson suggestions/Open lesson and M07 lesson selector are **not** present: F06 active lesson slots/actions do not exist. Lesson IDs and title snapshots are stored without a lesson dependency; after F06, integrate at most two stable-ID suggestions, Start now, shared editor prefilled from lesson title/duration, explicit save before creating a block, and completion-driven suggestion refresh without deleting scheduled blocks.

Observed from the repository root on `/Applications/Xcode.app/Contents/Developer`, Xcode **27.0 (27A266a)**, Apple Swift **6.4 (swiftlang-6.4.0.34.1)**, macOS **27.0 (26A428)**, arm64. The app and test targets use Swift language mode 5 and macOS 14.0 as their deployment minimum; a macOS 14 runtime was **not** tested. The following commands exited 0 (command output: `/tmp/kontrol-f03-{toolchain,build,build-for-testing,selected-tests,analyze,signed,verify,entitlements,diffcheck}.log`):

```sh
xcode-select -p
xcodebuild -version
xcrun swift --version
make build DERIVED_DATA=/tmp/kontrol-f03-derived
xcodebuild -project Kontrol.xcodeproj -scheme Kontrol -configuration Debug -destination 'platform=macOS' -derivedDataPath /tmp/kontrol-f03-derived CODE_SIGNING_ALLOWED=NO build-for-testing
xcodebuild -project Kontrol.xcodeproj -scheme Kontrol -configuration Debug -destination 'platform=macOS' -derivedDataPath /tmp/kontrol-f03-derived CODE_SIGNING_ALLOWED=NO \
  -only-testing:KontrolTests/ScheduleSelectionTests \
  -only-testing:KontrolTests/ScheduleRepositoryTests \
  -only-testing:KontrolTests/ScheduleStoreTests \
  -only-testing:KontrolTests/ScheduleEditorDraftTests \
  -only-testing:KontrolTests/TodayDaySelectionTests \
  -only-testing:KontrolTests/ScheduleMigrationTests \
  -only-testing:KontrolTests/TaskRepositoryTests \
  -only-testing:KontrolTests/TaskSelectionTests \
  -only-testing:KontrolTests/TaskStoreTests \
  -only-testing:KontrolTests/TaskEditorDraftTests \
  -only-testing:KontrolTests/V1FixtureTests \
  -only-testing:KontrolTests/SchemaTests \
  -only-testing:KontrolTests/ContainerFactoryTests \
  -only-testing:KontrolTests/CatalogValidatorTests \
  -only-testing:KontrolTests/CatalogImportTests \
  -only-testing:KontrolTests/BundledCatalogTests \
  -only-testing:KontrolTests/LaunchCoordinatorTests \
  -only-testing:KontrolTests/LaunchRecoveryTests \
  -only-testing:KontrolTests/NavigationStoreTests \
  -only-testing:KontrolTests/ProjectSmokeTests \
  -only-testing:KontrolTests/AppShellTests/testOneStorePerDependencyGraphAcrossRoutesAndWindows \
  -only-testing:KontrolTests/AppShellTests/testNavigationMetadataAndRouting \
  -only-testing:KontrolTests/QuickCaptureTests/testBlankDraftNeverSaves \
  -only-testing:KontrolTests/QuickCaptureTests/testFailureKeepsEditableTitleAndSheetUntilSingleSuccessfulRetry \
  -only-testing:KontrolTests/QuickCaptureTests/testOvernightTodayIsResolvedAtSubmissionAndPublishesOneIdentity \
  -only-testing:KontrolTests/QuickCaptureTests/testUnplannedAndClearedDuePersistAndFailureRetainsAllSelections \
  -only-testing:KontrolTests/QuickCaptureTests/testExplicitDateAndDueAreSavedAsSelected \
  -only-testing:KontrolTests/QuickCaptureTests/testExplicitPlanKeepsSelectedCalendarDayAndZoneAfterTravelAndFailedSave test
xcodebuild -project Kontrol.xcodeproj -scheme Kontrol -configuration Debug -destination 'platform=macOS' -derivedDataPath /tmp/kontrol-f03-derived CODE_SIGNING_ALLOWED=NO analyze
xcodebuild -project Kontrol.xcodeproj -scheme Kontrol -configuration Debug -destination 'platform=macOS' -derivedDataPath /tmp/kontrol-f03-sandbox CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= build
codesign --verify --deep --strict /tmp/kontrol-f03-sandbox/Build/Products/Debug/Kontrol.app
codesign --display --entitlements - /tmp/kontrol-f03-sandbox/Build/Products/Debug/Kontrol.app
git diff --check
```

The explicit **non-GUI** selection ran **149 tests, 0 failures, 0 unexpected, 0 skipped**; result bundle: `/tmp/kontrol-f03-derived/Logs/Test/Test-Kontrol-2026.09.28_17-26-03-+0800.xcresult`. These suites cover calendar/DST/travel and relative/explicit day selection, interval boundaries and multiple conflicts, disk CRUD across opens, receipt invalidation and failure paths, store sharing/publication, copied V1 and V2 fixture integrity and non-destructive open recovery, and selected F02 task/capture/launch regressions. The app and test bundles compiled (`BUILD SUCCEEDED`, `TEST BUILD SUCCEEDED`); the analyzer returned `ANALYZE SUCCEEDED`; strict signature verification passed on `/tmp/kontrol-f03-sandbox/Build/Products/Debug/Kontrol.app`. Entitlement inspection reports `com.apple.security.app-sandbox = true` and Debug `com.apple.security.get-task-allow = true`. `git diff --check` had no output. This is an ad-hoc local signature, **not** distribution signing or an interactive sandbox relaunch. No full `make test` or hosted presentation suite was run at this gate.

Warnings/diagnostics: `platform=macOS` matched arm64 and x86_64; xcodebuild used the first (arm64). AppIntents metadata extraction was skipped because this app has no AppIntents.framework dependency. The test process logged `com.apple.linkd.autoShortcut` connection errors and CoreData format errors during the deliberately invalid-store recovery test; its assertions passed. No Swift compiler or analyzer warning was observed in these logs. The entitlement command with `-` produced no deprecation warning. Do not confuse these runtime messages with failed tests.

### F03 open F13 interactive/hosted ledger (not passed by compilation or signing)

- Reserve an active, uncontended Mac GUI session to **execute** the hosted Today/schedule presentation tests (including any hosted `AppShellTests`, `QuickCaptureTests`, and F02 `TaskPresentationTests`) and the full `make test` suite. The inherited F02 intermittent AX visibility and sheet-dismissal failures (`testNativeTasksEditorCreatesEditsAndCancelsWithoutWriting`, `testQuickCapturePublishesAcrossTodayAndTasksWithoutPostSaveRead`) and **skipped** `TaskPresentationTests/testNativeDeleteAlertKeyboardNavigationAndConfirmation` remain unresolved. Selected non-GUI tests and `build-for-testing` do not resolve them.
- On isolated data, run live day browsing, task capture/completion, schedule create/edit/move/overnight and multiple-conflict Keep both/Edit time/cancel, deletion confirmation/failure recovery, and relaunch persistence. Inspect empty/error/stale states, focus return and draft preservation. Launch the **signed sandbox app offline**, quit/relaunch, and check task/block identities and unchanged unrelated records; no signed F03 GUI journey or offline claim is made here.
- Capture **rendered** M06 Today, M07 editor, M08 overlap and M09 quick capture, plus [overnight/validation](.mockups/screens/f03/schedule-editor-endpoints.html) and [multiple conflicts](.mockups/screens/f03/schedule-overlap-multiple.html), at **1000×700 and 1440×940 points**. Compare actual pairs and record differences; no F03 before/after image pair or visual equality is claimed. Check reflow/enlarged text, long-field/action scrolling, keyboard-only navigation/Escape/default/destructive confirmation, initial Title focus/restoration, accessible row/action names and target sizes, spoken VoiceOver, reduced motion and macOS 14 runtime/API/symbol behavior. These require F13 observation; neither compilation nor ad-hoc signing certifies them.

## F04 focus sessions non-GUI gate ledger (2026-09-28)

F04 adds a V3 focus session, one app-owned timer, task linkage, relaunch reconciliation and committed history. The [F04 contract](docs/features/F04-focus.md), [M10–M14 and variant index](docs/mockups/INDEX.md), and [QA / F13 gate](docs/qa.md) define the remaining acceptance. This is **implementation/non-GUI evidence only**, not feature-wide GUI or release approval. Earlier F00/F02 statements above about Focus being a placeholder or no focus model describe their historical checkpoints, not this build.

Observed from the repository root on `/Applications/Xcode.app/Contents/Developer`, Xcode **27.0 (27A266a)**, Apple Swift **6.4 (swiftlang-6.4.0.34.1)**, macOS **27.0 (26A428)**, arm64. Both targets retain Swift 5 language mode and macOS 14.0 minimum. Step 4.1's final gate used these commands (exit 0; output in `/tmp/kontrol-f04-step41-escalation-{toolchain,build,build-for-testing,tests,analyze,sandbox,codesign-verify,entitlements}.log`):

```sh
xcode-select -p
xcodebuild -version
xcrun swift --version
make build DERIVED_DATA=/tmp/kontrol-f04-derived
xcodebuild -project Kontrol.xcodeproj -scheme Kontrol -configuration Debug -destination 'platform=macOS' -derivedDataPath /tmp/kontrol-f04-derived CODE_SIGNING_ALLOWED=NO build-for-testing
# The explicit non-GUI selection in .pi/SPEC.md §5, Executable Implementation Gate:
xcodebuild -project Kontrol.xcodeproj -scheme Kontrol -configuration Debug -destination 'platform=macOS' -derivedDataPath /tmp/kontrol-f04-derived CODE_SIGNING_ALLOWED=NO \
  -only-testing:KontrolTests/FocusTimingTests \
  -only-testing:KontrolTests/FocusRepositoryTests \
  -only-testing:KontrolTests/FocusServiceTests \
  -only-testing:KontrolTests/FocusHistorySelectionTests \
  -only-testing:KontrolTests/FocusMigrationTests \
  -only-testing:KontrolTests/FocusTaskLinkTests \
  -only-testing:KontrolTests/TaskRepositoryTests \
  -only-testing:KontrolTests/TaskSelectionTests \
  -only-testing:KontrolTests/TaskStoreTests \
  -only-testing:KontrolTests/TaskEditorDraftTests \
  -only-testing:KontrolTests/ScheduleSelectionTests \
  -only-testing:KontrolTests/ScheduleRepositoryTests \
  -only-testing:KontrolTests/ScheduleStoreTests \
  -only-testing:KontrolTests/ScheduleEditorDraftTests \
  -only-testing:KontrolTests/TodayDaySelectionTests \
  -only-testing:KontrolTests/ScheduleMigrationTests \
  -only-testing:KontrolTests/V1FixtureTests \
  -only-testing:KontrolTests/SchemaTests \
  -only-testing:KontrolTests/ContainerFactoryTests \
  -only-testing:KontrolTests/CatalogValidatorTests \
  -only-testing:KontrolTests/CatalogImportTests \
  -only-testing:KontrolTests/BundledCatalogTests \
  -only-testing:KontrolTests/LaunchCoordinatorTests \
  -only-testing:KontrolTests/LaunchRecoveryTests \
  -only-testing:KontrolTests/NavigationStoreTests \
  -only-testing:KontrolTests/ProjectSmokeTests \
  -only-testing:KontrolTests/AppShellTests/testOneStorePerDependencyGraphAcrossRoutesAndWindows \
  -only-testing:KontrolTests/AppShellTests/testNavigationMetadataAndRouting test
xcodebuild -project Kontrol.xcodeproj -scheme Kontrol -configuration Debug -destination 'platform=macOS' -derivedDataPath /tmp/kontrol-f04-derived CODE_SIGNING_ALLOWED=NO analyze
xcodebuild -project Kontrol.xcodeproj -scheme Kontrol -configuration Debug -destination 'platform=macOS' -derivedDataPath /tmp/kontrol-f04-sandbox CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= build
codesign --verify --deep --strict /tmp/kontrol-f04-sandbox/Build/Products/Debug/Kontrol.app
codesign --display --entitlements - /tmp/kontrol-f04-sandbox/Build/Products/Debug/Kontrol.app
git diff --check
```

The app build, test-bundle compilation (`TEST BUILD SUCCEEDED`), selected test run (**230 tests, 0 failures, 0 unexpected**), analyzer, signed build, strict signature verification and whitespace check passed. Test result bundle: `/tmp/kontrol-f04-derived/Logs/Test/Test-Kontrol-2026.09.28_20-19-15-+0800.xcresult`; the test transcript prints the 230-test aggregate twice (not 460 tests). The signed app at `/tmp/kontrol-f04-sandbox/Build/Products/Debug/Kontrol.app` has sandbox entitlement `true` and Debug `get-task-allow=true` (ad-hoc local signature, **not** distribution signing or an offline launch). Original V1/V2/V3 fixture and sidecar hashes matched between `/tmp/kontrol-f04-step41-escalation-fixtures-before.sha` and `/tmp/kontrol-f04-step41-escalation-fixtures-after.sha` (`diff -u` exit 0). Selected tests cover disk-open transition/completion and migration copies, injected failures, integrity conflicts, task deletion and shared ownership; they do not execute hosted presentation tests.

Diagnostics: `platform=macOS` matched arm64 and x86_64 destinations and selected arm64; AppIntents metadata extraction was skipped because there is no AppIntents.framework dependency. The test process logged `com.apple.linkd.autoShortcut` connection errors and CoreData format errors from the deliberately invalid-store recovery test; its assertions passed. No Swift compiler/analyzer warning was reported in the final gate. During Step 4.1 an earlier focused run (`/tmp/kontrol-f04-step41-escalation-focused.log`) **failed 1 of 42** on the deadline timestamp regression; the repair was followed by the passing 230-test final selection above. This historical failure is not presented as a current pass without that rerun. No hosted GUI tests or full `make test` were run at the F04 gate.

### F04 outstanding F13 acceptance (not established by the non-GUI gate)

- Reserve an active, uncontended Mac GUI session to **execute** hosted `FocusPresentationTests` (compiled by `build-for-testing`), hosted shell/Focus navigation checks, and full `make test`; repair failures/skips rather than counting compilation as execution. Keep F02's intermittent hosted AX visibility and editor-sheet dismissal failures (`testNativeTasksEditorCreatesEditsAndCancelsWithoutWriting`, `testQuickCapturePublishesAcrossTodayAndTasksWithoutPostSaveRead`) and its **skipped** `TaskPresentationTests/testNativeDeleteAlertKeyboardNavigationAndConfirmation` open. F03's hosted Today/schedule tests and signed offline journeys likewise remain open in the [F03 ledger](#f03-manual-schedule-non-gui-gate-ledger-2026-09-28); no F02/F03 GUI failure is reclassified by F04.
- On isolated data with the **signed sandbox app offline**, Start/Pause/Resume/End and natural completion; navigate/close and reopen windows, sleep/wake, quit/relaunch before and after the deadline, choose recovery Resume/End, delete a linked task, then check unchanged task completion, stable identity/duration and history across relaunch. Non-GUI tests and signing alone do not establish these interactive journeys.
- Capture rendered [M10 ready](docs/mockups/M10-focus-ready.png), [M11 running](docs/mockups/M11-focus-running.png), [M12 paused](docs/mockups/M12-focus-paused.png), [M13 recovery](docs/mockups/M13-focus-recovery.png), [M14 history](docs/mockups/M14-focus-history.png) and the [custom duration](.mockups/screens/f04/custom-duration-validation.html), [no open tasks](.mockups/screens/f04/no-available-tasks.html), [persistence failure](.mockups/screens/f04/persistence-failure.html) and [completion pending](.mockups/screens/f04/completion-pending.html) variants at **1000×700 and 1440×940 points**; compare actual rendered pairs with references and record paths and differences. No F04 rendered before/after capture or screenshot comparison is claimed here.
- In the GUI session check logical keyboard order, focus/restoration, readable labels and AX state/countdown (without per-second live announcements), spoken VoiceOver, visible focus and ≥32-point targets, scrolling/enlarged text and reduced motion at both sizes. Verify runtime behavior/API/symbols on **macOS 14**; this macOS 27 host and 14.0 deployment minimum do not substitute for that check.
- **Future work, not F04 successes:** F06 lesson picker/link/navigation and progress integration; F13 persistent focus-default settings. F04 stores reserved lesson-link metadata but does not expose lesson selection.

## F05 structured learning catalog implementation gate (2026-09-28)

F05 ships the reviewed [40-lesson curriculum](docs/learning-curriculum.md) in catalog version 2, eight lessons in each ordered topic (Go, Java, System Design, Performance, Security). The per-lesson primary documentation, language/library assumptions, exercise/reference review outcomes and limitations are recorded in the five content-review tables there. The packaged-resource tests validate all 40 canonical objectives, five retained IDs, content sections, fingerprints, distinct reserves and absence of personal fields. The V4 definition/slot schema and one shared read-only Learning store are in place. This is an **implementation/non-GUI gate**, not hosted UI or release acceptance; M15 is the normal-state reference, with [F05-only references](.mockups/screens/f05/index.html) for read-only inspection, exhausted inventory and loading/read failure. No answer, Complete, Show another or Generate action is offered by F05.

Observed from the repository root on `/Applications/Xcode.app/Contents/Developer`, Xcode **27.0 (27A266a)**, Apple Swift **6.4 (swiftlang-6.4.0.34.1)**, macOS **27.0 (26A428)**, arm64 (see `/tmp/kontrol-f05-gate-toolchain.log`). Both targets still use Swift 5 language mode and a macOS 14.0 minimum; macOS 14 runtime was **not** tested. These exact gate commands exited **0**; transcripts use `/tmp/kontrol-f05-gate-{build,build-for-testing,selected-tests,analyze,signed,verify,entitlements}.log`:

```sh
xcode-select -p
xcodebuild -version
xcrun swift --version
make build DERIVED_DATA=/tmp/kontrol-f05-derived
xcodebuild -project Kontrol.xcodeproj -scheme Kontrol -configuration Debug \
  -destination 'platform=macOS' -derivedDataPath /tmp/kontrol-f05-derived \
  CODE_SIGNING_ALLOWED=NO build-for-testing
xcodebuild -project Kontrol.xcodeproj -scheme Kontrol -configuration Debug \
  -destination 'platform=macOS' -derivedDataPath /tmp/kontrol-f05-derived \
  CODE_SIGNING_ALLOWED=NO \
  -only-testing:KontrolTests/BundledCatalogTests \
  -only-testing:KontrolTests/CatalogValidatorTests \
  -only-testing:KontrolTests/CatalogImportTests \
  -only-testing:KontrolTests/LessonSelectorTests \
  -only-testing:KontrolTests/LessonSlotRepositoryTests \
  -only-testing:KontrolTests/LearningCatalogStoreTests \
  -only-testing:KontrolTests/CatalogMigrationTests \
  -only-testing:KontrolTests/SchemaTests \
  -only-testing:KontrolTests/ContainerFactoryTests \
  -only-testing:KontrolTests/V1FixtureTests \
  -only-testing:KontrolTests/ScheduleMigrationTests \
  -only-testing:KontrolTests/FocusMigrationTests \
  -only-testing:KontrolTests/LaunchCoordinatorTests \
  -only-testing:KontrolTests/LaunchRecoveryTests \
  -only-testing:KontrolTests/TaskRepositoryTests \
  -only-testing:KontrolTests/TaskSelectionTests \
  -only-testing:KontrolTests/TaskStoreTests \
  -only-testing:KontrolTests/TaskEditorDraftTests \
  -only-testing:KontrolTests/ScheduleRepositoryTests \
  -only-testing:KontrolTests/ScheduleSelectionTests \
  -only-testing:KontrolTests/ScheduleStoreTests \
  -only-testing:KontrolTests/ScheduleEditorDraftTests \
  -only-testing:KontrolTests/TodayDaySelectionTests \
  -only-testing:KontrolTests/FocusTimingTests \
  -only-testing:KontrolTests/FocusRepositoryTests \
  -only-testing:KontrolTests/FocusServiceTests \
  -only-testing:KontrolTests/FocusHistorySelectionTests \
  -only-testing:KontrolTests/FocusTaskLinkTests \
  -only-testing:KontrolTests/NavigationStoreTests \
  -only-testing:KontrolTests/ProjectSmokeTests \
  -only-testing:KontrolTests/AppShellTests/testOneStorePerDependencyGraphAcrossRoutesAndWindows \
  -only-testing:KontrolTests/AppShellTests/testNavigationMetadataAndRouting \
  test
xcodebuild -project Kontrol.xcodeproj -scheme Kontrol -configuration Debug \
  -destination 'platform=macOS' -derivedDataPath /tmp/kontrol-f05-derived \
  CODE_SIGNING_ALLOWED=NO analyze
xcodebuild -project Kontrol.xcodeproj -scheme Kontrol -configuration Debug \
  -destination 'platform=macOS' -derivedDataPath /tmp/kontrol-f05-sandbox \
  CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual \
  DEVELOPMENT_TEAM= build
codesign --verify --deep --strict /tmp/kontrol-f05-sandbox/Build/Products/Debug/Kontrol.app
codesign --display --entitlements - /tmp/kontrol-f05-sandbox/Build/Products/Debug/Kontrol.app
git diff --check
```

`make build`: BUILD SUCCEEDED; `build-for-testing`: TEST BUILD SUCCEEDED (hosted `LearningPresentationTests` **compiled, not run**); selected non-GUI test: **266 passed, 0 failed, 0 skipped**, 32 explicit selectors, result `/tmp/kontrol-f05-derived/Logs/Test/Test-Kontrol-2026.09.28_22-48-29-+0800.xcresult` (`xcrun xcresulttool get test-results summary --path …` confirmed the counts). `analyze`: ANALYZE SUCCEEDED. Ad-hoc signed build: BUILD SUCCEEDED; strict signature verification returned 0; entitlement inspection returned 0 with `com.apple.security.app-sandbox = true` and Debug `com.apple.security.get-task-allow = true`. This is not distribution signing or an offline relaunch. Whitespace verification: `git diff --check` returned 0. No hosted presentation suite or full `make test` ran at this gate.

The selected tests exercise fresh import of **40 definitions/20 unique slots** (four per topic, no fabricated progress/attempts), equal-version retry and cross-open `assignedAt` stability; completion/dismissal replacement, started recovery and exhaustion; validator rejection and upgrade/injected pre-save/save atomicity including independent unsaved edits and disk reopen. Migration tests copy complete closed V1/V2/V3/V4 fixture stores and sidecars, verify frozen originals byte-for-byte within the test, reopen copied stores, and separately verify a rich V3-only source with available/started/completed/dismissed progress, timestamps, draft answer, completed snapshot and attempt version, task, schedule and focus state intact; schema migration alone creates no slots/progress/catalog import. This is test evidence, not a live production-user-store migration. Navigation, task, schedule, focus, launch and smoke regressions are included in the selection.

Diagnostics in the transcripts: `platform=macOS` matched arm64 and x86_64 and selected arm64; AppIntents metadata extraction was skipped because no AppIntents.framework dependency exists. The test process logged `com.apple.linkd.autoShortcut` connection errors and CoreData format errors for the deliberately invalid-store recovery fixture; all assertions passed. No Swift compiler or analyzer warning was observed. A preliminary shell extraction inadvertently ran `analyze` once before the selected run (exit 0); the explicit analyze command above was run again after the tests and its log is the recorded result. The test aggregate appears twice in XCTest output, not 532 executions.

### F05 deferred F13 interactive/hosted acceptance (open)

- Execute hosted `LearningPresentationTests` and full `make test` in a reserved, active, uncontended GUI session; compilation is not execution. Check each of the **five topic journeys** on isolated offline data: four initial choices, actual counts, read-only inspection of every structured section, empty/exhausted inventory and retryable read failure. Verify no attempt/progress/draft is created by opening or inspecting lessons. F06 interactive answering, completion and replacement actions remain separate future work.
- Capture **rendered** M15 and [F05 inspection/empty/loading-error variants](.mockups/screens/f05/index.html) at **1000×700 and 1440×940 points**, compare screenshots to references and record actual paths/differences; none were captured or compared for this F05 gate. Check keyboard focus and topic/disclosure selection, spoken VoiceOver names/roles/state, ≥32-point targets, long text scrolling, enlarged text, reduced motion and macOS 14 runtime. No manual F05 attestation is available.
- Launch the **signed sandbox app offline** on isolated data, inspect all topics, quit/relaunch and verify stable slots and unchanged personal records. Neither the ad-hoc signature nor non-GUI disk tests demonstrate that live journey. Keep F02 intermittent hosted AX visibility and editor-sheet-dismissal failures (`testNativeTasksEditorCreatesEditsAndCancelsWithoutWriting`, `testQuickCapturePublishesAcrossTodayAndTasksWithoutPostSaveRead`), skipped `TaskPresentationTests/testNativeDeleteAlertKeyboardNavigationAndConfirmation`, and F03/F04 hosted/signed GUI journeys **open** as detailed above and in [QA](docs/qa.md); this gate does not resolve them.

## F06 lesson experience non-GUI gate (2026-09-29)

F06 now connects explicit Open/Resume, the pinned explanation/example/exercise and exact-text draft, persisted reveal/self-check/completion gates, exact-slot Show another, read-only History and explicit Restore, honest exhaustion, Today suggestions/linked blocks, and Focus lesson selection. See [F06 contract](docs/features/F06-lesson-experience.md), [QA/F13 ledger](docs/qa.md), and [references](docs/mockups/INDEX.md). This is an **implementation/non-GUI gate**, not interactive UI approval. Earlier F03–F05 descriptions of F06 as future work describe their historical checkpoints.

On `/Applications/Xcode.app/Contents/Developer` (Xcode **27.0 (27A266a)**, Apple Swift **6.4 (swiftlang-6.4.0.34.1)**, arm64 macOS **27.0 (26A428)**), from the repository root, the following commands all exited **0**:

```sh
xcode-select -p
xcodebuild -version
xcrun swift --version
make build DERIVED_DATA=/tmp/kontrol-f06-derived
xcodebuild -project Kontrol.xcodeproj -scheme Kontrol -configuration Debug -destination 'platform=macOS' -derivedDataPath /tmp/kontrol-f06-derived CODE_SIGNING_ALLOWED=NO build-for-testing
# Exact 39 -only-testing selectors: .pi/SPEC.md §5, Executable Implementation Gate.
# The command there was executed with stdout/stderr redirected to the log below:
f06_xcode() { xcodebuild -project Kontrol.xcodeproj -scheme Kontrol -configuration Debug -destination 'platform=macOS' -derivedDataPath /tmp/kontrol-f06-derived CODE_SIGNING_ALLOWED=NO "$@"; }
f06_xcode -only-testing:KontrolTests/LessonExperienceTests -only-testing:KontrolTests/LessonExperienceRepositoryTests -only-testing:KontrolTests/LessonExperienceStoreTests -only-testing:KontrolTests/LessonExperienceMigrationTests -only-testing:KontrolTests/LearningHistoryTests -only-testing:KontrolTests/TodayLessonIntegrationTests -only-testing:KontrolTests/FocusLessonLinkTests -only-testing:KontrolTests/BundledCatalogTests -only-testing:KontrolTests/CatalogValidatorTests -only-testing:KontrolTests/CatalogImportTests -only-testing:KontrolTests/CatalogMigrationTests -only-testing:KontrolTests/LessonSelectorTests -only-testing:KontrolTests/LessonSlotRepositoryTests -only-testing:KontrolTests/LearningCatalogStoreTests -only-testing:KontrolTests/SchemaTests -only-testing:KontrolTests/ContainerFactoryTests -only-testing:KontrolTests/V1FixtureTests -only-testing:KontrolTests/ScheduleMigrationTests -only-testing:KontrolTests/FocusMigrationTests -only-testing:KontrolTests/TaskRepositoryTests -only-testing:KontrolTests/TaskSelectionTests -only-testing:KontrolTests/TaskStoreTests -only-testing:KontrolTests/TaskEditorDraftTests -only-testing:KontrolTests/ScheduleRepositoryTests -only-testing:KontrolTests/ScheduleSelectionTests -only-testing:KontrolTests/ScheduleStoreTests -only-testing:KontrolTests/ScheduleEditorDraftTests -only-testing:KontrolTests/TodayDaySelectionTests -only-testing:KontrolTests/FocusTimingTests -only-testing:KontrolTests/FocusRepositoryTests -only-testing:KontrolTests/FocusServiceTests -only-testing:KontrolTests/FocusHistorySelectionTests -only-testing:KontrolTests/FocusTaskLinkTests -only-testing:KontrolTests/LaunchCoordinatorTests -only-testing:KontrolTests/LaunchRecoveryTests -only-testing:KontrolTests/NavigationStoreTests -only-testing:KontrolTests/ProjectSmokeTests -only-testing:KontrolTests/AppShellTests/testOneStorePerDependencyGraphAcrossRoutesAndWindows -only-testing:KontrolTests/AppShellTests/testNavigationMetadataAndRouting test
f06_xcode analyze
xcodebuild -project Kontrol.xcodeproj -scheme Kontrol -configuration Debug -destination 'platform=macOS' -derivedDataPath /tmp/kontrol-f06-sandbox CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= build
codesign --verify --deep --strict /tmp/kontrol-f06-sandbox/Build/Products/Debug/Kontrol.app
codesign --display --entitlements - /tmp/kontrol-f06-sandbox/Build/Products/Debug/Kontrol.app
git diff --check
```

Here `f06_xcode` expands to `xcodebuild -project Kontrol.xcodeproj -scheme Kontrol -configuration Debug -destination 'platform=macOS' -derivedDataPath /tmp/kontrol-f06-derived CODE_SIGNING_ALLOWED=NO` (the actual test/analyze invocations used these arguments directly). Output paths: `/tmp/kontrol-f06-gate-{build,build-for-testing,selected-tests,analyze,signed,verify,entitlements}.log`; selected result bundle `/tmp/kontrol-f06-derived/Logs/Test/Test-Kontrol-2026.09.29_02-59-43-+0800.xcresult`. `xcresulttool get test-results summary --path` reported **371 passed, 0 failed, 0 skipped, 0 expected failures**. Log suite starts and method starts were cross-checked against **all 39 selectors** (37 suites plus two AppShell methods), none missing. `BUILD SUCCEEDED`, `TEST BUILD SUCCEEDED`, `TEST SUCCEEDED`, `ANALYZE SUCCEEDED`, signed `BUILD SUCCEEDED`; signature/entitlement checks succeeded. The signed bundle contains `starter-catalog.json`, minimum OS 14.0, sandbox entitlement `true`, and Debug `get-task-allow=true`. This is ad-hoc **local signing**, not notarization, distribution signing, or a live offline relaunch. Both targets remain Swift 5 mode with macOS 14 deployment minimum; macOS 14 runtime was not exercised. No full `make test` or hosted presentation suite was executed.

Non-GUI suites exercise one pinned attempt per explicit start, exact-text and revision/debounce retry across reopen, reveal/acknowledge/complete gates, immutable studied snapshots, idempotent completion and one-slot replacement/dismissal, stale-slot protection, exhaustion, History/Restore without implicit attempts, failed-read/transaction recovery, copied V1–V4 and rich V4 migration, Today stable-ID suggestions/schedule links, Focus commit-time validation, and task/schedule/launch/navigation regressions. These are isolated in-memory or temporary-store tests, not a production-user-store migration. The selection also includes the two non-hosted AppShell assertions. Diagnostics: `platform=macOS` matched both architectures and chose arm64; AppIntents metadata extraction was skipped (no AppIntents.framework dependency). Test logs contain `com.apple.linkd.autoShortcut` connection messages and CoreData format/open errors from the deliberately invalid-store recovery test; assertions passed. No Swift compiler/analyzer warning was observed. The first *selector-audit script*, not the test run, misparsed suite-only selectors and failed; a corrected audit confirmed all 39 started. This does not change the 371/0/0 XCTest outcome. For capture evidence, `/tmp/kontrol-f06-derived`, `/tmp/kontrol-f06-review-derived`, and `/tmp/kontrol-f06-sandbox` were enumerated: none has a `before` or `after` directory or F06 PNG/JPEG images. Thus there are no matching rendered before/after images to compare; reference comparisons remain open, not passed.

### F06 open F13 acceptance (not passed by this gate)

- Execute hosted `LearningPresentationTests`, `LessonExperiencePresentationTests` and hosted Today/Focus/shell tests, plus the full `make test`, in a reserved, active, uncontended GUI session. Carry forward F02's intermittent hosted AX/sheet-dismissal failures (`testNativeTasksEditorCreatesEditsAndCancelsWithoutWriting`, `testQuickCapturePublishesAcrossTodayAndTasksWithoutPostSaveRead`) and skipped `TaskPresentationTests/testNativeDeleteAlertKeyboardNavigationAndConfirmation`, along with F03–F05 hosted checks; compilation does not clear them. F05's historical read-only active-lesson assertions have changed for F06 and must be reviewed against the current journey. Earlier F06 Step 3.3 hosted AX runs also **failed** (`/tmp/kontrol-f06-step33-ax-first.log`: 1/6 failures; `/tmp/kontrol-f06-step33-host-diagnostic.log`: missing AX window, inactive/untrusted host). A later one-test retry `/tmp/kontrol-f06-step33-ax-retry.log` passed, but did not establish stable hosted behavior; keep this failure open for F13.
- On isolated data in the **signed sandbox app offline**, perform choose → resume → answer → navigate/save/reopen → reveal → acknowledge → complete, Show another cancel/confirm, exhaustion, History/Restore, Today Start now/Add to Today/linked block after rotation, and Focus lesson selection/Start/End. Check failed save on close, deactivation and quit (Retry/Cancel), forced-termination limitation, focus return, and unchanged unrelated records after quit/relaunch; unit tests and signature checks alone do not establish live behavior.
- Check keyboard-only navigation and confirmation, spoken VoiceOver names/roles/status and focus, enlarged text and long-content scrolling, 32-point targets, visible focus and reduced motion. Run on **macOS 14** as well as the current OS. Capture actual rendered F06 [M15–M22, M07, affected M06/M10/M23 and supplemental flow](docs/mockups/INDEX.md) at **1000×700 and 1440×940 points**, compare references, and record screenshot paths/differences. No F06 before/after image pair or comparison was available or claimed in this non-GUI gate.
