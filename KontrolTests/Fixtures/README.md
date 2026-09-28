# Versioned closed SwiftData disk fixtures

## Frozen V3 disk store

`V3/` is a **closed V3-only** (3.0.0) store produced directly with `KontrolSchemaV3`, without the production factory or a migration plan. It contains a V3 task (`0C8C76A6-085B-47D7-A820-43EA0BDAB311`, title `V3 fixture task`, created Unix `1720000000`, due Unix `1720086400`, notes `Retained task`), a manual block (`88E80A72-F92B-4E9E-A38A-338F54818D9B`, start Unix `1820000000`, end Unix `1820001800`, note `Manual`), and an ended focus session (`83B6B103-03BA-4CD5-8D54-90E3398F6E00`, planned 1500 seconds, actual 72.5 seconds, start Unix `1720000000`, end/checkpoint Unix `1720000073`, linked to the task with its title snapshot). All unspecified optional fields are nil and recovery is false. The complete closed file set is `Kontrol.store`, `Kontrol.store-shm`, and `Kontrol.store-wal`. Freeze these bytes and never open this directory in place or regenerate it on later schema changes.

The standalone writer is NOT an app or test source. For an initial capture only, run from the repository root using the released V1, V2 and V3 definitions:

```sh
xcrun swiftc -o /tmp/kontrol-v3-writer \
  Kontrol/Data/Persistence/KontrolSchemaV1.swift \
  Kontrol/Data/Persistence/KontrolSchemaV2.swift \
  Kontrol/Data/Persistence/KontrolSchemaV3.swift \
  KontrolTests/Fixtures/GenerateV3.swift
base=$(mktemp -d)
/tmp/kontrol-v3-writer "$base/V3"
ls -la "$base/V3"
# Initial capture only, after writer exit: mkdir KontrolTests/Fixtures/V3 && cp "$base/V3/"* KontrolTests/Fixtures/V3/
```

`FocusMigrationTests` copies all three checked-in versions' complete closed file sets before opening copies. It checks V1/V2 values through the production V3 migration factory on two distinct disk opens and checks V3 directly using its versioned schema (no plan), then through the production factory. Rich V1- and V2-only temporary stores additionally cover every catalog and personal learning entity; original source file names and bytes, including sidecars, are compared after upgrade. Opened copies are left until OS cleanup because SwiftData can retain internal SQLite handles. `LaunchRecoveryTests` and `ScheduleMigrationTests` also exercise injected failed opens and historical stores.

```sh
xcodebuild -project Kontrol.xcodeproj -scheme Kontrol -configuration Debug \
  -destination 'platform=macOS' -derivedDataPath /tmp/kontrol-f04-derived \
  CODE_SIGNING_ALLOWED=NO -only-testing:KontrolTests/FocusMigrationTests \
  -only-testing:KontrolTests/ScheduleMigrationTests \
  -only-testing:KontrolTests/V1FixtureTests \
  -only-testing:KontrolTests/LaunchRecoveryTests test
```

## Frozen V2 disk store

`V2/` is a separate **closed, V2-only** (schema 2.0.0) test store, created on macOS from `KontrolSchemaV2` directly, with no production factory and no V1 migration. It is not an app resource or user store. The complete captured file set is `Kontrol.store`, `Kontrol.store-shm`, and `Kontrol.store-wal` (the WAL was empty on exit). Do not open the originals in place, edit them, or regenerate them when a later schema ships. Add a separately versioned fixture for a subsequent upgrade.

Persisted records (all times are UTC instants):

| Entity | ID | Fields |
| --- | --- | --- |
| TaskItem | `6E9D469D-49F7-4D66-9084-2E1AA79E5FF2` | title `V2 fixture task`, createdAt Unix `1710000000`, notes `Keep for upgrade`, dueAt Unix `1710086400`; planned day, planned zone, completedAt nil |
| ScheduleBlock | `9BA7AB1F-6349-4CDD-AF43-08FE8BA9DB13` | title `V2 fixture block`, startAt Unix `1800000000`, endAt Unix `1800005400`, note `Manual plan`; lessonID and linkedTitleSnapshot nil |

For a new capture on a Mac with full Xcode selected, compile only the released V1 and V2 model definitions with the standalone V2 writer (not the current/latest factory). Run from the repository root; the writer requires a nonexistent directory under the system temp root and refuses to overwrite a store:

```sh
xcrun swiftc -o /tmp/kontrol-v2-writer \
  Kontrol/Data/Persistence/KontrolSchemaV1.swift \
  Kontrol/Data/Persistence/KontrolSchemaV2.swift \
  KontrolTests/Fixtures/GenerateV2.swift
base=$(mktemp -d)
/tmp/kontrol-v2-writer "$base/V2"
ls -la "$base/V2"
# For initial capture only, after the writer has exited and the complete file set has been inspected:
# mkdir KontrolTests/Fixtures/V2 && cp "$base/V2/"* KontrolTests/Fixtures/V2/
```

`ScheduleMigrationTests.testFrozenV2CopyReopensTwiceWithoutChangingEitherFixtureVersion` copies *all* bundled V2 files to a UUID-isolated temp directory, opens the copy twice via the production factory, verifies every field and identity, and compares both V1 and V2 bundled filename sets and bytes afterward. SwiftData can retain SQLite descriptors after owners release, so the opened copy is left for OS cleanup, never unlinked during the test. Generated SQLite bytes need not match across runs; the captured originals are frozen.

```sh
xcodebuild -project Kontrol.xcodeproj -scheme Kontrol -configuration Debug \
  -destination 'platform=macOS' -derivedDataPath /tmp/kontrol-f03-derived \
  CODE_SIGNING_ALLOWED=NO -only-testing:KontrolTests/ScheduleMigrationTests test
```

## Frozen V1 disk store

`V1/Kontrol.store` is a **closed** SwiftData disk fixture created with `KontrolSchemaV1` (schema version 1.0.0) on macOS using the then-current production `ModelContainerFactory` and `KontrolMigrationPlan` (V1 only, no stages). The standalone generator now opens V1 directly so it cannot silently emit a newer schema. `Kontrol.store-shm` and `Kontrol.store-wal` were present at process exit and are retained alongside the database. These files are test data, not an app resource or a user store. Do not edit or reopen the checked-in originals in place. Never claim a V0 → V1 migration: there is no V0 schema.

The single task has UUID `D07A6D98-65ED-4B59-92B2-DA3CED39F3E5`, title `V1 reopen fixture`, creation time `2023-11-14T22:13:20Z` (Unix 1700000000), no planned day or completion. This identity must remain stable as future schema versions are added. Generated SQLite bytes themselves need not be identical across runs; the persisted values and schema version are the contract.

## Reproduction (Mac with full Xcode selected)

Run from the repository root, using the *released V1* source definitions. The generator is deliberately **not** compiled into the app/test target. It requires a nonexistent directory under the system temporary root and refuses to overwrite an existing store:

```sh
xcrun swiftc -o /tmp/kontrol-v1-writer \
  Kontrol/Data/Persistence/KontrolSchemaV1.swift \
  KontrolTests/Fixtures/GenerateV1.swift
base=$(mktemp -d)
/tmp/kontrol-v1-writer "$base/V1"
# After the writer exits, copy the entire file set together; inspect before replacing any frozen fixture.
ls -la "$base/V1"
# For initial capture only: cp "$base/V1/"* KontrolTests/Fixtures/V1/
```

Do not silently regenerate this historical artifact when models or migration stages change. For a new schema, add a separate versioned fixture. To verify the frozen fixture, Xcode copies the entire `V1/` folder as a test resource; `V1FixtureTests` copies all its regular files to a unique temporary directory, opens that copy twice via `ModelContainerFactory`, checks the task fields/identity, and verifies the bundled source bytes are unchanged. Run:

```sh
xcodebuild -project Kontrol.xcodeproj -scheme Kontrol -destination 'platform=macOS' \
  -derivedDataPath /tmp/kontrol-f00-derived CODE_SIGNING_ALLOWED=NO \
  -only-testing:KontrolTests/V1FixtureTests test
```

`ScheduleMigrationTests` copies every bundled V1 file (including both sidecars) before opening the copy with the production V2 factory, checks the historical task, writes a V2 manual block, releases app-owned containers, and reopens to check both records. It compares the bundled filenames and bytes afterward. A second, isolated V1-only disk store is built directly from `KontrolSchemaV1` with task, topic, subtopic, concept, lesson definition, import marker, progress, and completed attempt values. The complete closed store is copied before production migration; all fields are checked on migration and after a separate reopen and V2 write, and the V1 source is byte-compared. The launch-recovery test injects a failed first open on a separate copied V1 store, verifies every copy file is unchanged before explicit retry, and then checks that retry migrates the same location. These tests leave UUID-isolated opened temporary copies in place until the OS reclaims them: SwiftData can retain SQLite descriptors after Swift owners are released. They never open or remove the checked-in files in place.

```sh
xcodebuild -project Kontrol.xcodeproj -scheme Kontrol -configuration Debug \
  -destination 'platform=macOS' -derivedDataPath /tmp/kontrol-f03-derived \
  CODE_SIGNING_ALLOWED=NO -only-testing:KontrolTests/ScheduleMigrationTests \
  -only-testing:KontrolTests/V1FixtureTests \
  -only-testing:KontrolTests/LaunchRecoveryTests test
```
