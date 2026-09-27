# Frozen V1 disk store

`V1/Kontrol.store` is a **closed** SwiftData disk fixture created with `KontrolSchemaV1` (schema version 1.0.0) on macOS using the then-current production `ModelContainerFactory` and `KontrolMigrationPlan` (V1 only, no stages). `Kontrol.store-shm` and `Kontrol.store-wal` were present at process exit and are retained alongside the database. These files are test data, not an app resource or a user store. Do not edit or reopen the checked-in originals in place. Never claim a V0 → V1 migration: there is no V0 schema.

The single task has UUID `D07A6D98-65ED-4B59-92B2-DA3CED39F3E5`, title `V1 reopen fixture`, creation time `2023-11-14T22:13:20Z` (Unix 1700000000), no planned day or completion. This identity must remain stable as future schema versions are added. Generated SQLite bytes themselves need not be identical across runs; the persisted values and schema version are the contract.

## Reproduction (Mac with full Xcode selected)

Run from the repository root, using the *released V1* source definitions. The generator is deliberately **not** compiled into the app/test target. It requires a nonexistent directory under the system temporary root and refuses to overwrite an existing store:

```sh
xcrun swiftc -o /tmp/kontrol-v1-writer \
  Kontrol/Data/Persistence/KontrolSchemaV1.swift \
  Kontrol/Data/Persistence/KontrolMigrationPlan.swift \
  Kontrol/Data/Persistence/ModelContainerFactory.swift \
  Kontrol/Data/Persistence/StoreLocation.swift \
  KontrolTests/Fixtures/GenerateV1.swift
base=$(mktemp -d)
/tmp/kontrol-v1-writer "$base/V1"
# After the writer exits, copy the entire file set together; inspect before replacing any frozen fixture.
ls -la "$base/V1"
# For initial capture only: cp "$base/V1/"* KontrolTests/Fixtures/V1/
```

Do not silently regenerate this historical artifact when models or migration stages change. For a new schema, add a separate versioned fixture. To verify the frozen fixture, Xcode copies the entire `V1/` folder as a test resource; `V1FixtureTests` copies all its regular files to a unique temporary directory, opens that copy twice via `ModelContainerFactory`, checks the task fields/identity, and verifies the bundled source bytes are unchanged. Temporary copies are removed after the test. Run:

```sh
xcodebuild -project Kontrol.xcodeproj -scheme Kontrol -destination 'platform=macOS' \
  -derivedDataPath /tmp/kontrol-f00-derived CODE_SIGNING_ALLOWED=NO \
  -only-testing:KontrolTests/V1FixtureTests test
```
