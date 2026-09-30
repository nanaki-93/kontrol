# Third-party notices

Kontrol packages [ThirdPartyNotices.txt](../Kontrol/Resources/ThirdPartyNotices.txt)
unchanged at `Kontrol.app/Contents/Resources/ThirdPartyNotices.txt` in Debug and
Release. The application's Resources build phase explicitly includes it. This
resource contains both complete MIT licenses and the unique Yams source-header
copyright notices; it is not a replacement for the upstream source licenses.

## Resolved dependency provenance

The authoritative [Package.resolved](../Kontrol.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved)
contains one dependency:

- **Yams 5.4.0**, repository `https://github.com/jpsim/Yams`.
- Exact revision: **`3d6871d5b4a5cd519adf233fbb576e0a2af71c17`**.
- [LICENSE at that revision](https://github.com/jpsim/Yams/blob/3d6871d5b4a5cd519adf233fbb576e0a2af71c17/LICENSE):
  complete text reproduced byte-for-byte, including JP Simard's copyright.
  SHA-256: `0354b0ea403d2e78059c5ae0510a2cfae9f8eb306fcef094ac9fff5b47e20bed`.
- The tracked `Sources/Yams` headers contain three distinct copyright lines
  (2016, 2017, 2024 Yams), all preserved with only comment syntax removed.
  Examples: [Parser.swift](https://github.com/jpsim/Yams/blob/3d6871d5b4a5cd519adf233fbb576e0a2af71c17/Sources/Yams/Parser.swift),
  [Encoder.swift](https://github.com/jpsim/Yams/blob/3d6871d5b4a5cd519adf233fbb576e0a2af71c17/Sources/Yams/Encoder.swift),
  [Anchor.swift](https://github.com/jpsim/Yams/blob/3d6871d5b4a5cd519adf233fbb576e0a2af71c17/Sources/Yams/Anchor.swift).

The verified local source was the clean SwiftPM checkout at
`/tmp/kontrol-f13-derived/SourcePackages/checkouts/Yams`; the Release checkout
at `/tmp/kontrol-f13-release-build/SourcePackages/checkouts/Yams` had the same
revision. Neither checkout nor the dependency pin was edited.

## Embedded libyaml / CYaml

Yams' pinned [Package.swift](https://github.com/jpsim/Yams/blob/3d6871d5b4a5cd519adf233fbb576e0a2af71c17/Package.swift)
has no external package dependencies, but its Yams target depends on **CYaml**,
the vendored libyaml C implementation. The pinned
[README license section](https://github.com/jpsim/Yams/blob/3d6871d5b4a5cd519adf233fbb576e0a2af71c17/README.md#license)
identifies both Yams and libyaml as MIT licensed. The Yams tree does **not**
include libyaml's separate `License` file. Its text was therefore obtained from
the immutable upstream revision identified by the pinned tree's vendor history,
not inferred from a generic MIT template:

1. Yams [vendor update `409e565756cfdf50642a59c8f4290a6961fe7f1d`](https://github.com/jpsim/Yams/commit/409e565756cfdf50642a59c8f4290a6961fe7f1d)
   identifies libyaml `acd6f6f`, resolved upstream to
   **`acd6f6f014c25e46363e718381e0b35205df2d83`**.
2. The latest CYaml source update in the pinned Yams ancestry,
   [`c7a3398466895c46c875966fc9da6ad11619bce6`](https://github.com/jpsim/Yams/commit/c7a3398466895c46c875966fc9da6ad11619bce6),
   identifies additional libyaml commits:
   `51843fe48257c6b7b6e70cdec1db634f64a40818`,
   `588eabff23ba2292f537872bbea5b64bce1e1a21`, and
   `840b65c40675e2d06bf40405ad3f12dec7f35923`.
3. Upstream [License at the base revision](https://github.com/yaml/libyaml/blob/acd6f6f014c25e46363e718381e0b35205df2d83/License)
   and at all three additional commits is byte-identical (SHA-256
   **`c40112449f254b9753045925248313e9270efa36d226b22d82d4cc6c43c57f29`**).
   That complete text, including **Ingy döt Net** and **Kirill Simonov**
   copyrights, is reproduced unchanged. The base hash is license provenance,
   not a claim that all CYaml files correspond to an unmodified libyaml release.

Tracked-tree and source notice searches found no further license/notice files
or distinct copyright notices in the shipped Yams/CYaml targets. Test fixtures,
build tooling and Git sample hooks are not shipped by these SwiftPM targets.

## Reproduce the notice audit

Use the resolved checkout from your build; do not change the lockfile or use
latest upstream license text. If source evidence is unavailable, stop rather
than guessing. Run from the repository root:

```sh
python3 -m json.tool \
  Kontrol.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved >/dev/null
YAMS=/tmp/kontrol-f13-derived/SourcePackages/checkouts/Yams
AUDIT="$(mktemp -d /tmp/kontrol-notices.XXXXXX)"
git clone https://github.com/yaml/libyaml.git "$AUDIT/libyaml"
python3 - "$YAMS" "$AUDIT/libyaml" <<'PY'
import hashlib, json, pathlib, re, subprocess, sys

def git(root, *args):
    return subprocess.check_output(['git', '-C', str(root), *args])

yams, libyaml = map(pathlib.Path, sys.argv[1:])
pin = json.loads(pathlib.Path(
    'Kontrol.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved'
).read_text())['pins'][0]
revision = '3d6871d5b4a5cd519adf233fbb576e0a2af71c17'
assert pin['identity'] == 'yams' and pin['location'] == 'https://github.com/jpsim/Yams'
assert pin['state'] == {'revision': revision, 'version': '5.4.0'}
assert git(yams, 'rev-parse', 'HEAD').decode().strip() == revision
assert not git(yams, 'status', '--porcelain', '--untracked-files=no')
notice = pathlib.Path('Kontrol/Resources/ThirdPartyNotices.txt').read_bytes()
yams_license = git(yams, 'show', revision + ':LICENSE')
assert notice.count(yams_license) == 1
assert hashlib.sha256(yams_license).hexdigest() == (
    '0354b0ea403d2e78059c5ae0510a2cfae9f8eb306fcef094ac9fff5b47e20bed')
headers = set()
for name in git(yams, 'ls-files', 'Sources').decode().splitlines():
    for line in (yams / name).read_text().splitlines():
        if re.search(r'copyright', line, re.I):
            headers.add(re.sub(r'^\s*//\s*', '', line))
assert len(headers) == 3
for line in headers:
    assert notice.count(line.encode()) == 1
for ref in ('acd6f6f014c25e46363e718381e0b35205df2d83',
            '51843fe48257c6b7b6e70cdec1db634f64a40818',
            '588eabff23ba2292f537872bbea5b64bce1e1a21',
            '840b65c40675e2d06bf40405ad3f12dec7f35923'):
    license_text = git(libyaml, 'show', ref + ':License')
    assert hashlib.sha256(license_text).hexdigest() == (
        'c40112449f254b9753045925248313e9270efa36d226b22d82d4cc6c43c57f29')
    assert notice.count(license_text) == 1
print('Pinned source licenses and all shipped source-header notices match.')
PY
make build DERIVED_DATA=/tmp/kontrol-f13-derived
make build CONFIGURATION=Release DERIVED_DATA=/tmp/kontrol-f13-release-build
cmp Kontrol/Resources/ThirdPartyNotices.txt \
  /tmp/kontrol-f13-derived/Build/Products/Debug/Kontrol.app/Contents/Resources/ThirdPartyNotices.txt
cmp Kontrol/Resources/ThirdPartyNotices.txt \
  /tmp/kontrol-f13-release-build/Build/Products/Release/Kontrol.app/Contents/Resources/ThirdPartyNotices.txt
git diff --check
```

For a dependency update, re-inventory vendored sources, trace their immutable
upstream license evidence, regenerate the notices and repeat both bundle
comparisons. Packaging verification is not signed-distribution acceptance.
See [QA evidence](qa.md) for executed commands and artifact paths.
