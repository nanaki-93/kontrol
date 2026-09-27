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

Observed for this documentation step: the selected toolchain versions above and `xcodebuild -list -project Kontrol.xcodeproj` (targets `Kontrol`, `KontrolTests`; scheme `Kontrol`). Documentation whitespace validation: `git diff --check`. The full build/test/analyze, signed sandbox build, offline relaunch, accessibility, and M00/M01/M09 comparisons remain the **Step 5.2 integration gate**, not checks claimed by this README; no environment blocker has been observed for the documentation checks. Consult the step's verification report for executed results rather than inferring success from these example commands.

Contracts: [F00](docs/features/F00-foundation.md), [architecture](docs/architecture.md), [QA gates](docs/qa.md), [mockup index](docs/mockups/INDEX.md), [product plan](PLAN.md), and related [F01](docs/features/F01-design-system.md), [F02](docs/features/F02-tasks.md), [F05](docs/features/F05-learning-catalog.md), [F13](docs/features/F13-settings-release.md), [curriculum briefs](docs/learning-curriculum.md).
