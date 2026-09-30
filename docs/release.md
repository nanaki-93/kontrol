# Kontrol 1.0 release and installation runbook

Run from the repository root with Bash and Xcode command-line tools selected.
The application requires **macOS 14 or newer**, uses Swift 5 language mode, and
has bundle identifier `com.kontrol.app`, version **1.0**, build **1**. Signing
identities, team and notarization credentials are external inputs, never repository
values. Do not put passwords, tokens or private keys in commands or evidence.

This is a procedure, **not release approval**. See [QA evidence](qa.md) for actual
results and unresolved historical observations. Implementation/static verification
is separate from mandatory **A13** (hosted/native accessibility), **S13** (signed
sandbox/offline), **B13** (macOS 14/current runtime), and **D13** (distribution).
Missing reserved desktop/host Accessibility permission, isolated account/data,
macOS 14 access, Developer ID identity/team or notary profile blocks the affected
gate. Unsigned builds and **ad-hoc signatures do not approve distribution**.

## 1. Guardrails and evidence

Execute each command block in a Bash script/subshell with `set -euo pipefail`;
do not paste past an error in an interactive shell. Stop immediately on any
failure, including a rejected/pending notarization, signature, entitlement,
resource, stapling or Gatekeeper failure. Preserve failed logs; repair and rerun
against new artifacts. Do not disable Gatekeeper, remove quarantine, alter TCC,
reset a store, or bypass tests to obtain approval.

Use fresh evidence and artifact directories. Keep command stdout/stderr, exit
codes, source revision/diff and file hashes, Xcode/Swift/OS/hardware versions,
xcresults and audited executed identifiers. Record native observations separately
with captures, point/pixel sizes, backing scale, reference paths and differences.
Never record export contents, credentials or personal folder paths in public logs.
Retain store fixtures until their owning processes exit; follow only the guarded
cleanup procedure in [QA](qa.md). Do not validate with production user data.

```bash
set -euo pipefail
EVIDENCE="$(mktemp -d /tmp/kontrol-f13-release-evidence.XXXXXX)"
printf 'Evidence: %s\n' "$EVIDENCE"
git rev-parse HEAD > "$EVIDENCE/source-revision.txt"
git status --short > "$EVIDENCE/worktree.txt"
git diff --binary > "$EVIDENCE/source.patch"
xcode-select -p
xcodebuild -version
xcrun swift --version
xcodebuild -list -project Kontrol.xcodeproj
sw_vers
uname -m
```

## 2. Unsigned development and static verification

The [Makefile](../Makefile) deliberately builds with `CODE_SIGNING_ALLOWED=NO`.
Keep this path for development; it does not establish sandbox or Gatekeeper
acceptance. These commands build and inspect only; they do not launch the app or
open a production store. All hosted tests can be compiled without claiming native
observations. The full serial suite and deferred selectors remain A13 in QA.

```bash
set -euo pipefail
make build DERIVED_DATA=/tmp/kontrol-f13-derived
make build CONFIGURATION=Release DERIVED_DATA=/tmp/kontrol-f13-release-build
xcodebuild -project Kontrol.xcodeproj -scheme Kontrol \
  -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath /tmp/kontrol-f13-derived \
  CODE_SIGNING_ALLOWED=NO build-for-testing
xcodebuild -showBuildSettings -json -project Kontrol.xcodeproj \
  -scheme Kontrol -configuration Release > "$EVIDENCE/Release-settings.json"
plutil -lint Kontrol.xcodeproj/project.pbxproj Kontrol/Kontrol.entitlements
plutil -p /tmp/kontrol-f13-release-build/Build/Products/Release/Kontrol.app/Contents/Info.plist
for resource in starter-catalog generation-objectives default-feeds; do
  python3 -m json.tool "Kontrol/Resources/$resource.json" >/dev/null
done
python3 -m json.tool \
  Kontrol.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved >/dev/null
python3 - "$EVIDENCE/Release-settings.json" <<'PY'
import json, plistlib, sys
from pathlib import Path
settings = json.loads(Path(sys.argv[1]).read_text())
app = [row['buildSettings'] for row in settings if row['target'] == 'Kontrol']
assert len(app) == 1
s = app[0]
for key, value in {
    'MARKETING_VERSION': '1.0', 'CURRENT_PROJECT_VERSION': '1',
    'MACOSX_DEPLOYMENT_TARGET': '14.0', 'SWIFT_VERSION': '5.0',
    'ENABLE_HARDENED_RUNTIME': 'YES', 'CODE_SIGN_INJECT_BASE_ENTITLEMENTS': 'NO',
    'CODE_SIGN_ENTITLEMENTS': 'Kontrol/Kontrol.entitlements',
    'CODE_SIGNING_ALLOWED': 'NO',
}.items():
    assert s[key] == value, (key, s.get(key))
assert 'DEBUG' not in s.get('SWIFT_ACTIVE_COMPILATION_CONDITIONS', '').split()
expected = {key: True for key in (
    'com.apple.security.app-sandbox', 'com.apple.security.network.client',
    'com.apple.security.files.user-selected.read-write',
    'com.apple.security.files.bookmarks.app-scope')}
assert plistlib.loads(Path('Kontrol/Kontrol.entitlements').read_bytes()) == expected
pin = json.loads(Path(
    'Kontrol.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved'
).read_text())['pins']
assert len(pin) == 1 and pin[0]['identity'] == 'yams'
assert pin[0]['state'] == {
    'version': '5.4.0', 'revision': '3d6871d5b4a5cd519adf233fbb576e0a2af71c17'}
print('Release configuration, source permissions and dependency pin passed.')
PY
git diff --check
```

### Bundle inspection helper (unsigned and signed artifacts)

Define this function in the same Bash process as the subsequent commands. It
checks actual Info.plist, packaged curriculum/objectives/feed resources and notices
against the source being released. See [notice provenance](third-party-notices.md)
for the pinned-source license audit; a byte comparison does not replace that audit.
It also checks Release binaries for the existing Debug recovery injection markers.
The source `#if DEBUG` and Release compilation conditions must remain intact.

```bash
inspect_bundle() {
  python3 - "$1" "$2" <<'PY'
import hashlib, json, plistlib, sys
from pathlib import Path
app, configuration = Path(sys.argv[1]), sys.argv[2]
info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
for key, value in {
    'CFBundleIdentifier': 'com.kontrol.app', 'CFBundleShortVersionString': '1.0',
    'CFBundleVersion': '1', 'LSMinimumSystemVersion': '14.0',
}.items():
    assert info[key] == value, (key, info.get(key))
for name in ('starter-catalog.json', 'generation-objectives.json',
             'default-feeds.json', 'ThirdPartyNotices.txt'):
    source = Path('Kontrol/Resources') / name
    bundled = app / 'Contents/Resources' / name
    data = bundled.read_bytes()
    assert data == source.read_bytes(), name
    if name.endswith('.json'):
        json.loads(data)
    print(bundled, len(data), hashlib.sha256(data).hexdigest())
executable = app / 'Contents/MacOS' / info['CFBundleExecutable']
data = executable.read_bytes()
if configuration == 'Release':
    for marker in (b'KONTROL_F00_RECOVERY_TEST', b'KontrolF00Recovery-'):
        assert marker not in data, 'Debug recovery injection in Release'
else:
    assert configuration == 'Debug'
print(executable, hashlib.sha256(data).hexdigest())
print('Bundle metadata/resources/notices passed:', app)
PY
}
inspect_bundle /tmp/kontrol-f13-derived/Build/Products/Debug/Kontrol.app Debug
inspect_bundle /tmp/kontrol-f13-release-build/Build/Products/Release/Kontrol.app Release
```

### Unsigned packaging smoke check (not distribution approval)

A fresh ZIP/extraction smoke check can run without signing credentials. It tests
packaging/checksum/resource preservation only; do not publish this unsigned ZIP.

```bash
set -euo pipefail
SMOKE_DIR="$(mktemp -d /tmp/kontrol-f13-unsigned-package.XXXXXX)"
APP=/tmp/kontrol-f13-release-build/Build/Products/Release/Kontrol.app
ditto -c -k --keepParent "$APP" "$SMOKE_DIR/Kontrol-unsigned.zip"
shasum -a 256 "$SMOKE_DIR/Kontrol-unsigned.zip" > "$SMOKE_DIR/Kontrol-unsigned.zip.sha256"
shasum -a 256 -c "$SMOKE_DIR/Kontrol-unsigned.zip.sha256"
ditto -x -k "$SMOKE_DIR/Kontrol-unsigned.zip" "$SMOKE_DIR/extracted"
inspect_bundle "$SMOKE_DIR/extracted/Kontrol.app" Release
diff -qr "$APP" "$SMOKE_DIR/extracted/Kontrol.app"
printf 'Unsigned packaging evidence: %s\n' "$SMOKE_DIR"
```

### Actual signed permissions and identity helper

Define this alongside `inspect_bundle` before S13/D13. Unlike source-plist
inspection, this reads the **actual signature**. Xcode signing metadata may add
application/team identifiers; no additional capability or debugging entitlement
is allowed. Ad-hoc mode expects no team; Developer ID mode requires the externally
supplied authority and team. Keep the output as evidence for each artifact.

```bash
inspect_signed_bundle() {
  local app="$1" output="$2" team="$3" identity="$4"
  mkdir -p "$output"
  inspect_bundle "$app" Release
  codesign --display --verbose=4 "$app" 2> "$output/signature.txt"
  codesign --display --entitlements - "$app" \
    > "$output/entitlements.plist" 2> "$output/entitlements.stderr"
  python3 - "$output" "$team" "$identity" <<'PY'
import plistlib, re, sys
from pathlib import Path
output, team, identity = Path(sys.argv[1]), sys.argv[2], sys.argv[3]
actual = plistlib.loads((output / 'entitlements.plist').read_bytes())
required = plistlib.loads(Path('Kontrol/Kontrol.entitlements').read_bytes())
for key, value in required.items():
    assert actual.get(key) is value, (key, actual.get(key))
metadata = {'com.apple.application-identifier',
            'com.apple.developer.team-identifier'}
assert set(actual) <= set(required) | metadata, actual.keys()
assert 'com.apple.security.get-task-allow' not in actual
assert 'get-task-allow' not in actual
signature = (output / 'signature.txt').read_text()
assert re.search(r'^CodeDirectory .*flags=.*\bruntime\b', signature, re.M), 'Hardened runtime missing'
assert 'Identifier=com.kontrol.app\n' in signature
if identity == '-':
    assert 'Signature=adhoc' in signature and 'TeamIdentifier=not set' in signature
    assert not (set(actual) & metadata)
else:
    assert 'Authority=' + identity + '\n' in signature
    assert 'TeamIdentifier=' + team + '\n' in signature
    if 'com.apple.developer.team-identifier' in actual:
        assert actual['com.apple.developer.team-identifier'] == team
    if 'com.apple.application-identifier' in actual:
        assert actual['com.apple.application-identifier'] == team + '.com.kontrol.app'
print('Actual signed permissions, identity and hardened runtime passed.')
PY
}
```

## 3. S13 — isolated locally signed sandbox verification

Prerequisite: an authorized **separate macOS test account** with no production
Kontrol data, an active reserved desktop and copied disposable project trees.
A fresh derived-data path does **not** isolate the app's persistent container.
Do not launch this build under the developer's production account. Do not use
`KONTROL_F00_RECOVERY_TEST` as a Release isolation mechanism; it is Debug-only.

Define both inspection helpers above. Build the specification's ad-hoc Release
artifact (no Developer ID credentials required):

```bash
set -euo pipefail
xcodebuild -project Kontrol.xcodeproj -scheme Kontrol \
  -configuration Release -destination 'platform=macOS' \
  -derivedDataPath /tmp/kontrol-f13-sandbox \
  CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- \
  CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= build

APP=/tmp/kontrol-f13-sandbox/Build/Products/Release/Kontrol.app
codesign --verify --deep --strict --verbose=2 "$APP"
codesign --display --entitlements - "$APP"
inspect_signed_bundle "$APP" "$EVIDENCE/sandbox-signature" '' '-'
```

Only after account/data isolation is confirmed, launch with `open "$APP"` in
that account. Confirm the running path and quit/relaunch the same signed artifact,
not a previously running Debug copy. Inspect actual sandbox permissions as above.
No broad filesystem, inbound networking, Keychain or debugging entitlement is
permitted. Ad-hoc verification is **local sandbox evidence only**, not D13.

Record each journey and failure with the artifact/source identity:

- **Offline Today:** disconnect network; create task, schedule block and linked
  Focus session; pause/end as applicable; quit/relaunch and verify persisted links,
  timings and state. Preference changes must not rewrite existing sessions.
- **Offline Learning:** exact saved answer, reveal, complete, one-slot replacement,
  history, quit/relaunch and exact answer/historical-content preservation.
- **Projects:** use the real picker to Add a copied folder, quit/relaunch to reopen
  its real bookmark, complete a feature with the minimal authorized frontmatter
  change, verify dependent eligibility and Undo/conflict. Exercise revoked access,
  Reconnect and disconnect. Keep before/after byte inventories including `.kontrol`,
  source and Git files: disconnect/export must leave external bytes unchanged.
- **News/AI:** establish authorized cached News, then verify offline cached use;
  optional provider/feed failures must preserve core state. Do not initiate paid
  generation without separate authorization. Opening Settings must not generate
  lessons or refresh feeds.
- **Native export:** exercise Cancel/Escape, replacement approval and cancellation,
  failed save and explicit retry, success and pre/post-commit cancellation. Compare
  existing destination hashes before/after every pre-commit failure/cancel. Parse
  successful JSON with `python3 -m json.tool "$EXPORT_FILE" >/dev/null` using an
  explicitly selected isolated destination. Verify version-1 required collections,
  exact saved answers, field exclusions and owned staging cleanup without logging
  personal content. See [export contract](export-format.md). No import/restore or
  encrypted-backup claim is made.

## 4. A13 / B13 — desktop accessibility and runtime matrix

A human must reserve the desktop and authorize Accessibility for the **actual
rebuilt host**, then confirm activation/AX window registration. Shell trust and
compilation do not satisfy A13. Execute the full serial suite, original seven-suite
gate and every exact deferred selector in [QA](qa.md); retain fresh xcresults,
audit executed identifiers/counts and fix failures, never skip them for approval.
Compare actual captures against all applicable [mockup references](mockups/INDEX.md)
and supplemental states. Observe keyboard-only journeys, visible/restored focus,
Escape/Cancel, spoken VoiceOver, non-color status and reduced motion at 520×340
Settings and 1000×700/1440×940 desktop sizes, standard/130%/larger accessibility
text. Verify targets ≥32 points, text contrast ≥4.5:1 and essential focus/boundaries
≥3:1. Record dimensions/backing scale and differences, not just fixture rendering.

B13 requires actual execution on **macOS 14** and the **current supported macOS
runtime**. Record OS build, Xcode/SDK/Swift, architecture/hardware and artifact
identity for each. Run applicable core/Settings/export regressions plus the A13
and S13 journeys on both; note API/symbol/layout/persistence differences. The
14.0 deployment setting or a newer-host build is not macOS 14 evidence. Unavailable
baseline hardware/VM or native observations explicitly block B13, not an inferred
pass. See QA for integration commands and still-outstanding gates.

## 5. D13 — Developer ID archive through final extracted artifact

Prerequisites: authorized Developer Program team; a matching **Developer ID
Application** certificate/private key in the signing Keychain; and an existing
`notarytool` Keychain profile for that team. Supply `DEVELOPMENT_TEAM`,
`DEVELOPER_ID_APPLICATION` (full certificate identity) and `NOTARY_PROFILE`
externally. Never embed credentials or use an ad-hoc signature as a substitute.
Do not create/store credentials in this runbook or automatically change accounts.

Run the following **complete guarded sequence** in a Bash script that defines
both inspection helpers first. It preserves the required specification sequence;
additional checks inspect the archive and final extracted bundle. The subshell
makes `set -e` failures terminate the sequence rather than continuing in a pasted
interactive shell. Do not invoke the block in an `if`, `&&` or `||` context that
suppresses Bash errexit. Logs must retain every exit code/output. Print and retain
the fresh `RELEASE_DIR`; it is never reused for retries. Do not alter the app after
signing/stapling or publish the upload ZIP instead of the final ZIP.

```bash
(
set -euo pipefail
: "${DEVELOPMENT_TEAM:?Authorized team required}"
: "${DEVELOPER_ID_APPLICATION:?Developer ID identity required}"
: "${NOTARY_PROFILE:?Existing notary Keychain profile required}"

RELEASE_DIR="$(mktemp -d /tmp/kontrol-f13-distribution.XXXXXX)"
printf 'Distribution artifacts: %s\n' "$RELEASE_DIR"
git rev-parse HEAD > "$RELEASE_DIR/source-revision.txt"
git diff --binary > "$RELEASE_DIR/source.patch"

xcodebuild -project Kontrol.xcodeproj -scheme Kontrol \
  -configuration Release -destination 'generic/platform=macOS' \
  -archivePath "$RELEASE_DIR/Kontrol.xcarchive" \
  CODE_SIGNING_ALLOWED=YES CODE_SIGN_STYLE=Manual \
  DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM" \
  CODE_SIGN_IDENTITY="$DEVELOPER_ID_APPLICATION" \
  ENABLE_HARDENED_RUNTIME=YES archive

APP="$RELEASE_DIR/Kontrol.xcarchive/Products/Applications/Kontrol.app"
codesign --verify --deep --strict --verbose=2 "$APP"
codesign --display --entitlements - "$APP"
inspect_signed_bundle "$APP" "$RELEASE_DIR/archive-inspection" \
  "$DEVELOPMENT_TEAM" "$DEVELOPER_ID_APPLICATION"

ditto -c -k --keepParent "$APP" "$RELEASE_DIR/notary-upload.zip"
xcrun notarytool submit "$RELEASE_DIR/notary-upload.zip" \
  --keychain-profile "$NOTARY_PROFILE" --wait --output-format json \
  > "$RELEASE_DIR/notary-result.json"

python3 - "$RELEASE_DIR/notary-result.json" <<'PY'
import json, sys
with open(sys.argv[1]) as source:
    result = json.load(source)
if result.get("status") != "Accepted":
    raise SystemExit("Notarization not Accepted; stop release.")
PY

xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
spctl --assess --type execute --verbose=4 "$APP"

ditto -c -k --keepParent "$APP" "$RELEASE_DIR/Kontrol-1.0.zip"
shasum -a 256 "$RELEASE_DIR/Kontrol-1.0.zip"
shasum -a 256 "$RELEASE_DIR/Kontrol-1.0.zip" > "$RELEASE_DIR/Kontrol-1.0.zip.sha256"
shasum -a 256 -c "$RELEASE_DIR/Kontrol-1.0.zip.sha256"
ditto -x -k "$RELEASE_DIR/Kontrol-1.0.zip" "$RELEASE_DIR/extracted"
codesign --verify --deep --strict --verbose=2 \
  "$RELEASE_DIR/extracted/Kontrol.app"
xcrun stapler validate "$RELEASE_DIR/extracted/Kontrol.app"
spctl --assess --type execute --verbose=4 \
  "$RELEASE_DIR/extracted/Kontrol.app"
inspect_signed_bundle "$RELEASE_DIR/extracted/Kontrol.app" \
  "$RELEASE_DIR/extracted-inspection" "$DEVELOPMENT_TEAM" "$DEVELOPER_ID_APPLICATION"
)
```

Notary submission exit success alone is insufficient: JSON status must be exactly
**`Accepted`** before any staple/package/install step. On rejection, stop; retain
submission ID/result and retrieve the notary log for diagnosis using the existing
profile, without resuming this sequence or publishing artifacts. After repair use
a new artifact directory and repeat all checks. Gatekeeper must approve both the
stapled archive app and **final extracted distributable**. No `codesign --force`
re-signing, quarantine removal or recursive permission workaround is allowed.

Record certificate authority/team, actual entitlements, notary JSON/ID, staple and
Gatekeeper outputs, final ZIP SHA-256 and extracted resource/notices hashes. Preserve
the final checksum with the release; verify a downloaded ZIP's checksum before
extraction. Link this evidence to the exact source/diff and A13/S13/B13 results.
If source/resources/configuration change, rebuild and repeat affected gates; an
old accepted upload is not evidence for a changed artifact.

## 6. Fresh installation, update and local storage

Perform both journeys using **the final D13 extracted app**, not an unsigned
build or only the archive. Use an authorized isolated test account and disposable
project folders. A local `ditto` extraction need not carry download quarantine;
also test a normally downloaded final ZIP on a clean account so the real
Gatekeeper launch path is observed. Do not remove quarantine to make it open.

### Fresh install

1. Verify final ZIP checksum, signature, staple, Gatekeeper, metadata and packaged
   resources as above. Confirm no Kontrol is running and the test account has no
   existing Kontrol data. Retain the artifact identity and OS environment.
2. Copy `extracted/Kontrol.app` to `/Applications/Kontrol.app` (or the account's
   `~/Applications/Kontrol.app`) in Finder. Do not overwrite a running app. A
   guarded account-local alternative, after setting `RELEASE_DIR` to the exact
   recorded directory, is:

   ```bash
   (
   set -euo pipefail
   : "${RELEASE_DIR:?Set the recorded successful D13 artifact directory}"
   INSTALL_ROOT="$HOME/Applications"
   mkdir -p "$INSTALL_ROOT"
   test ! -e "$INSTALL_ROOT/Kontrol.app"
   ditto "$RELEASE_DIR/extracted/Kontrol.app" "$INSTALL_ROOT/Kontrol.app"
   codesign --verify --deep --strict --verbose=2 "$INSTALL_ROOT/Kontrol.app"
   xcrun stapler validate "$INSTALL_ROOT/Kontrol.app"
   spctl --assess --type execute --verbose=4 "$INSTALL_ROOT/Kontrol.app"
   open "$INSTALL_ROOT/Kontrol.app"
   )
   ```

3. Confirm the installed/running path and version 1.0/build 1. Complete offline
   Today/Learning persistence loops, open both Settings entry points and export.
   Add a copied folder with the native picker; quit/relaunch, reopen its bookmark
   and complete a feature with only the intended minimal write. Record external
   inventories and actual outcomes. Successful shell assessment alone does not
   establish these native acceptance observations.

### Non-destructive update

1. In the isolated account, populate a previously accepted version with tasks,
   blocks, Focus sessions, exact Learning answers/history, settings and a real
   bookmarked copied project. Record semantic inventories and artifact version.
   Quit normally; if answer saving fails, Retry Save or Cancel Quit—do not force
   quit and call lost answers an update result. Confirm all owners have exited.
2. Make a separate closed-store safety copy including `Kontrol.store`, its
   `-wal`/`-shm` sidecars when present, and any adjacent store support files.
   Preserve originals and hashes. Never copy just a live SQLite main file or use
   unlink/reset recovery. A changed migrated store hash is not data loss; compare
   row identities, fields and exact answers before/after and after repeated reopen.
3. Replace **only the application bundle** using the final extracted D13 app in
   Finder after the old app exits. Leave its container, Application Support,
   Keychain and external folders untouched; do not delete user data to uninstall
   the old binary. Repeat signature/staple/Gatekeeper inspection at the installed
   path, then launch that path (not the old copy).
4. Verify version/build, migration and repeated reopen preserve every recorded
   value, exact answer/history and preference; reopen the selected folder through
   its existing bookmark and complete a feature. Compare external bytes, allowing
   only the expressly authorized completion patch. Verify export JSON and all S13
   offline loops again. Preserve old artifact/safety copy; do not launch an older
   schema binary against an already migrated store as a rollback test.

### Storage and recovery boundaries

[StoreLocation](../Kontrol/Data/Persistence/StoreLocation.swift) resolves the user
Application Support directory, then `Kontrol/Kontrol.store`. With the signed
sandbox identifier `com.kontrol.app`, its normal location is
`~/Library/Containers/com.kontrol.app/Data/Library/Application Support/Kontrol/Kontrol.store`.
SQLite may have WAL/SHM and adjacent support files; treat them as a store set,
not disposable live files. Inspect only isolated test data in this runbook.
AI credentials remain in the macOS Keychain; local configuration and project
bookmark references remain in the app's store. External project contents stay
in user-selected folders. An update must preserve the same identity/container.

Launch failure uses the existing non-destructive recovery screen and explicit
Retry. It is not authorization to reset, delete, overwrite or regenerate a store.
Preserve the closed failed store set/evidence, investigate migration/reopen in
copies, and leave the original untouched. Do not claim the JSON export is a full
backup, encrypted archive or restore mechanism; it excludes credentials,
bookmarks/project paths, article cache and unrelated unsaved drafts. See the
[format and limitations](export-format.md).

Publish F13/V1 completion only after implementation verification **and all four
mandatory gates** have satisfactory traceable evidence. This documentation task
itself does not execute or approve native, baseline-runtime or distribution gates.
