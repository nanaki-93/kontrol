# Kontrol 1.0 release and installation runbook

Run from the repository root with Bash and Xcode command-line tools selected.
The application requires **macOS 14 or newer**, uses Swift 5 language mode, and
has bundle identifier `com.kontrol.app`, version **1.0**, build **1**. Signing
identities, team and notarization credentials are external inputs, never repository
values. Do not put passwords, tokens or private keys in commands or evidence.

This is a procedure, **not release approval**. See [QA evidence](qa.md) for actual
results and unresolved historical observations. Implementation/static verification
follows root [AGENTS.md](../AGENTS.md): only non-interactive checks are required.
Accessibility, native keyboard, hosted UI and live-app journeys are removed, not
deferred. No desktop/Accessibility authorization or manual runtime matrix is a
gate. Developer ID identity/team and notary profile remain distribution inputs.
Unsigned builds and **ad-hoc signatures do not approve distribution**.

## 1. Guardrails and evidence

Execute each command block in a Bash script/subshell with `set -euo pipefail`;
do not paste past an error in an interactive shell. Stop immediately on any
failure, including a rejected/pending notarization, signature, entitlement,
resource, stapling or Gatekeeper failure. Preserve failed logs; repair and rerun
against new artifacts. Do not disable Gatekeeper, remove quarantine, alter TCC,
reset a store, or bypass tests to obtain approval.

Use fresh evidence and artifact directories. Keep command stdout/stderr, exit
codes, source revision/diff and file hashes, Xcode/Swift/OS/hardware versions,
xcresults and audited executed non-GUI identifiers. No native observations or
captures are required.
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
observations. Execute only inspected non-GUI selectors; no full UI suite or deferred A13 gate is required.

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

## 3. Static locally signed sandbox inspection

Build and inspect only; do not launch the app. No desktop or separate GUI account
is needed. A derived-data path does not isolate production persistence, so tests
must use isolated fixtures. `KONTROL_F00_RECOVERY_TEST` remains Debug-only.

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

Inspect actual signed permissions as above. No broad filesystem, inbound
networking, Keychain or debugging entitlement is permitted. This is static
signature/entitlement evidence, not proof of runtime sandbox behavior.

## 4. Non-GUI integration

Use isolated repository/store/service tests for task/block/Focus persistence,
Learning answers/history, project completion/Undo/conflicts, offline transport
failures and export cancellation/atomicity. Inject picker/grant/network outcomes;
do not open dialogs, disconnect the network, or drive the application.
Record the actual OS/toolchain used without claiming untested runtime behavior.
Accessibility, keyboard, screenshots and live runtime journeys are not gates.

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
extraction. Link this evidence to the exact source/diff and non-GUI validation results.
If source/resources/configuration change, rebuild and repeat affected gates; an
old accepted upload is not evidence for a changed artifact.

## 6. Installation, update and local storage guidance

These are user installation instructions, not validation tasks. No app launch,
click-through or fresh-account journey is required. Use the final verified
extracted app; do not remove quarantine or bypass Gatekeeper.

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
   )
   ```

3. Inspect the installed bundle's metadata/resources with `inspect_bundle`.
   No launch, picker, export or feature-completion journey is required.

### Non-destructive update

1. Before a user-initiated update, close the application normally and ensure no
   process owns its store. Do not create test data in a running production app.
2. Make a separate closed-store safety copy including `Kontrol.store`, its
   `-wal`/`-shm` sidecars when present, and any adjacent store support files.
   Preserve originals and hashes. Never copy just a live SQLite main file or use
   unlink/reset recovery. A changed migrated store hash is not data loss; compare
   row identities, fields and exact answers before/after and after repeated reopen.
3. Replace **only the application bundle** using the final extracted D13 app in
   Finder after the old app exits. Leave its container, Application Support,
   Keychain and external folders untouched; do not delete user data to uninstall
   the old binary. Repeat signature/staple/Gatekeeper inspection at the installed
   path without launching the app as a validation step.
4. Validate migration and repeated reopen using isolated repository fixtures, not
   interactive update journeys. Preserve the old artifact/safety copy; do not
   launch an older schema binary against an already migrated store.

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

Publish F13/V1 completion only after required non-GUI validation and applicable
static distribution checks have traceable evidence. Removed interactive checks
are not pending gates and must not be reported as passes. Documentation edits
alone do not approve a distribution artifact.
