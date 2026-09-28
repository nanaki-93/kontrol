# Kontrol — F00 executable foundation

Kontrol is a local-first macOS SwiftUI app. F00 provides seven destinations (Today, Learning, Projects, Focus, Tasks, News, Settings), a native Settings scene, a small offline starter catalog, and non-destructive startup recovery. F02 provides persistent task creation, editing, completion/reopening, confirmed deletion, Today/Upcoming/Completed filters, optional notes and due dates, and quick capture on Today. The first launch contains no sample personal records. The mockups are visual references, not live data.

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

The app bundle includes `Kontrol/Resources/starter-catalog.json` (installed in `Kontrol.app/Contents/Resources/starter-catalog.json`): versioned, validated definitions with one complete offline starter lesson for each of Go, Java, System Design, Performance, and Security. Catalog definitions are imported by version without overwriting personal progress. This resource contains no personal tasks or lesson attempts.

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
  Kontrol/Data/Persistence/KontrolMigrationPlan.swift \
  Kontrol/Data/Persistence/ModelContainerFactory.swift \
  Kontrol/Data/Persistence/StoreLocation.swift \
  KontrolTests/Fixtures/GenerateV1.swift
base=$(mktemp -d)
/tmp/kontrol-v1-writer "$base/V1"  # new, nonexistent path; refuses overwrite
ls -la "$base/V1"                 # inspect complete file set before any manual capture
```

There is no V0 fixture or claimed V0 migration; future schemas require separate versioned fixtures and migration tests.

## F00 boundaries and verification status

At the F00 checkpoint, Today offered title-only quick capture (planned for the local current day, no due date) and Today and Tasks displayed saved tasks. F02 has since added editing, completion/reopening, confirmed deletion, filters, optional notes and due dates; quick capture still defaults to Today but can also set a plan and due date. The F00 evidence below describes that historical checkpoint, not the current F02 gate. Learning shows the five offline starter topics and summaries, not interactive lessons, four active slots per topic, rotation, or the **F05** 40-lesson catalog. Projects, Focus, and News are honest foundation states; **F13** preferences, export, credential management, and release packaging/notarization are not implemented. The Settings scene currently shares the same no-settings-yet content as its destination.

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

The full suite covers 100 tests including navigation keyboard/AX order and ≥32-point target bounds at both 1000×700 and 1440×940 content sizes at 100%, 130%, 160% and 240%; real imported Learning summaries; enlarged capture and Settings; reduced-motion loading; failed-save draft retention, serialized recovery, temporary-store reopening and copied fixture bytes. Test persistence uses isolated in-memory/temporary stores and defaults suites. `DesignSystemTokenTests` checks approved sRGB channels and actual pairings: primary text on background/surface/raised **14.48/13.70/12.47:1**, secondary **7.72/7.31/6.65:1**, accent/error text **5.63/5.33/4.85:1**, dark label on accent **5.63:1**; success/warning on background **10.02/11.08:1** and surface **9.49/10.49:1** (all ≥4.5:1). Focus ring **14.48/13.70/12.47:1** and essential boundary **7.72/7.31/6.65:1** exceed 3:1; the 1.39:1 decorative border is never an essential outline. Exact ratios and role mappings are in [palette.html](.mockups/design-system/palette.html).

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
