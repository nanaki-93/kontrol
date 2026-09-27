# Kontrol — F00 executable foundation

Kontrol is a local-first macOS SwiftUI app. F00 provides seven destinations (Today, Learning, Projects, Focus, Tasks, News, Settings), a native Settings scene, a small offline starter catalog, persistent quick-captured tasks, and non-destructive startup recovery. The first launch contains no sample personal records. The mockups are visual references, not live data.

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

Today offers a title-only quick-capture sheet (planned for the local current day, no due date). Today and Tasks show saved tasks, but **F02** editing, completion/reopening, deletion, filters, notes, and due dates are not implemented. Learning shows the five offline starter topics and summaries, not interactive lessons, four active slots per topic, rotation, or the **F05** 40-lesson catalog. Projects, Focus, and News are honest foundation states; **F13** preferences, export, credential management, and release packaging/notarization are not implemented. The Settings scene currently shares the same no-settings-yet content as its destination.

### F00 integration evidence (2026-09-27, Xcode 27.0)

`xcodebuild -list -project Kontrol.xcodeproj` lists exactly `Kontrol` and `KontrolTests` with shared scheme `Kontrol`. After `xcodebuild ... CODE_SIGNING_ALLOWED=NO clean`, the **exact build, test, analyze, signed build, entitlements, and `git diff --check` commands above** completed successfully in that order. The full suite ran **62 tests, 0 failures**. The ad-hoc-signed bundle at `/tmp/kontrol-f00-sandbox/Build/Products/Debug/Kontrol.app` has `com.apple.security.app-sandbox = true` (`get-task-allow = true` for this debug build). Command logs: `/tmp/kontrol-f00-{clean,build,test,analyze,signed,entitlements,diffcheck}.log`; the clean rerun of all six verification commands is logged at `/tmp/kontrol-f00-clean-current.log` and `/tmp/kontrol-f00-{build,test,analyze,signed,entitlements,diffcheck}-current.log` (62 tests, zero failures again). `codesign --verify --deep --strict --verbose=2` also verified the signed bundle; its packaged catalog exists, bundle ID is `com.kontrol.app`, and minimum system version is 14.0. AppIntents metadata extraction was skipped (no AppIntents dependency); no source deprecation warnings remain.

Before launching the signed app, `~/Library/Containers/com.kontrol.app` did not exist. Launch created a sandbox store and displayed the empty Today state, without seeded personal records. UI automation selected each of the seven destinations and opened native Settings with Command-comma. A title-only task saved once, appeared on Today and Tasks, and remained after quitting/relaunching; Settings remained selected after quitting/relaunching. Cancelling a second draft did not create a row. Matching Tasks screenshots before/after relaunch at `/tmp/kontrol-f00-evidence/{before/Tasks-before-relaunch,after/Tasks-after-relaunch}.png` have the same 2092×1556 dimensions and **zero different pixels in a sampled 8-pixel grid (51,090 samples)**; the rendered list and task title are identical. These automated checks used this machine's initially absent sandbox container, **not** a separate test macOS account or a physically disconnected network. The user separately confirmed the offline fresh-account and keyboard/VoiceOver observations; those are **user-verified**, not observations made by automation.

Rendered M00 and injected-store-failure M01 captures from XCTest are `/tmp/kontrol-shell-captures/today-{1000x700,1440x940}.png` and `/tmp/kontrol-recovery-captures/store-{1000x700,1440x940}.png` (plus `catalog-520x340.png`). Compared with `docs/mockups/M00-app-shell.png` and `M01-store-recovery.png`: both sizes keep seven visible navigation labels and a selected underline; M00 uses genuine empty Today content rather than the mockup's illustrative schedule/lesson; M01 blocks navigation and shows preservation guidance and Quit/Try again. The app uses native titlebar controls rather than imitation controls. A sampled 8-pixel-grid image comparison at 1440×940 found 2,653/21,240 differing pixels for M00 and 4,765/21,240 for M01, consistent with actual empty content, native chrome, and rendering differences; these are **visual review references, not pixel-equality gates**. Native-sheet M09 screenshots are `/tmp/kontrol-f00-evidence/before/M09-1000x700.png` and `/tmp/kontrol-f00-evidence/before/M09-live-1440x860.png`, compared with `docs/mockups/M09-quick-capture.png`: title, Today plan, None due, Cancel/Add, and dimmed Today context are visible; the fixed indications are labels, not editable selectors. **The latter is a 1440×860-point live window (2972×1812 pixels including chrome), not a 1440×940-point capture:** this machine's physical display limited the window's height. The user separately confirmed the full-height M09 check on a capable display; no path to that user screenshot was provided, so it is recorded as user-verified, not as an agent-captured image. The 1000×700-point live window capture has a 32-point native titlebar. Do not treat these as pixel-identical images.

XCTest covers injected store failure on a *closed copy* of the V1 fixture, compares every store file and sidecar's bytes before Retry, and verifies no partially ready dependencies. Recovery presentation tests exercise accessible Retry during a serialized attempt and an injected Quit callback; task tests exercise failed-save draft retention and no false success, catalog tests exercise atomic marker/definition writes. AX tests check navigation roles, descriptions, selected state, keyboard focus order, and recovery controls at the specified sizes; only the user's attestation covers spoken VoiceOver behavior.

For a signed-app recovery smoke run, Debug builds alone support `open -n --env KONTROL_F00_RECOVERY_TEST=1 /tmp/kontrol-f00-sandbox/Build/Products/Debug/Kontrol.app`. This explicit flag makes the **first** open fail before disk IO and Retry open a unique store under the sandbox's `Data/tmp/KontrolF00Recovery-<UUID>/` (never the production store); it is excluded from Release. This run captured the initial signed recovery screen at `/tmp/kontrol-f00-evidence/before/M01-signed-injected-1000x700.png`, clicked **Try again** and observed the ready shell, quit, launched a second injected instance and clicked its **Quit** button. The second process terminated normally. SHA-256 manifests of every existing production-store file and sidecar are `/tmp/kontrol-f00-evidence/before/production-store.sha256` and `/tmp/kontrol-f00-evidence/after/production-store{,-after-quit}.sha256`; both `diff -u` comparisons returned zero. The new isolated store directory was `/Users/marcoandreose/Library/Containers/com.kontrol.app/Data/tmp/KontrolF00Recovery-CC113835-4BFD-4C2D-84DA-724644E18A31` (a temporary smoke artifact, not production). XCTest also verifies first failure creates no file and Retry saves to only the injected temporary location. No real store was intentionally failed or reset. A further native smoke launched the current ad-hoc-signed app with the isolated Debug failure flag, confirmed a running process, then terminated that smoke instance; `shasum -a 256 -c /tmp/kontrol-f00-evidence/before/production-store.sha256` still matched the production database and both sidecars. This process check alone does not establish a GUI interaction; the preceding capture and interactive run are separate evidence. Human offline, accessibility, and full-height M09 checks are credited solely as user-verified, without inventing image files or claiming this agent performed them.

Contracts: [F00](docs/features/F00-foundation.md), [architecture](docs/architecture.md), [QA gates](docs/qa.md), [mockup index](docs/mockups/INDEX.md), [product plan](PLAN.md), and related [F01](docs/features/F01-design-system.md), [F02](docs/features/F02-tasks.md), [F05](docs/features/F05-learning-catalog.md), [F13](docs/features/F13-settings-release.md), [curriculum briefs](docs/learning-curriculum.md).
