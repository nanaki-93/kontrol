# Web validation history

These dated checkpoints preserve the commands, failures, repairs and results as
originally recorded. They describe the implementation at each checkpoint, not
current requirements. Follow [AGENTS.md](../AGENTS.md) for validation policy and
the [web guide](web-app.md) for current behavior.

## Validation evidence — 2026-10-02

Executed from web/ with Node 25.8.2 and npm 11.14.1:

- **npm test** — **30 passing** Node domain, persistence and HTTP integration
  tests. They use in-memory SQLite or uniquely named temporary directories,
  copied project fixtures, and injected feed responses. The transient API
  listeners serve fixtures only; no browser or running native application is
  driven.
- **npm run build** — TypeScript check and Vite production build passed. Each
  module has a separate component chunk. Bundled curriculum validation occurs
  in the domain/API tests.
- **npm audit --omit=dev --audit-level=high --cache /tmp/kontrol-npm-cache** —
  zero reported runtime dependency vulnerabilities at this checkpoint.
- **git diff --check** — passed.

Initial test runs exposed a refined-schema composition error, empty YAML scalar
spacing, bodyless-delete content-type handling, and test harness Host/canonical
path assumptions. Those were corrected before the passing run. The first build
also reported an empty CSS import and eager imports preventing module chunks;
both were corrected.

No UI automation, accessibility/AX checks, hosted presentation tests, screenshots,
or live-app journeys were executed or required, following AGENTS.md. No native
build, native test suite, signing, packaging or distribution approval is claimed
by this web-only change.

Implementation references: [Vite guide](https://vite.dev/guide/),
[Node SQLite API](https://nodejs.org/api/sqlite.html), and
[Express 5 API](https://expressjs.com/en/5x/api.html).

## News repair and discovery validation — 2026-10-02

The original fetcher failed before HTTP with ERR_INVALID_IP_ADDRESS because its
custom DNS callback returned one address when modern Node requested an array
for automatic family selection. The repaired callback respects both modes while
pinning only prevalidated public addresses. The regression test performs real
HTTP requests to an isolated fixture with automatic family selection both on
and off. Additional parser repair decodes XML-escaped HTML before removing tags,
so source URLs/attributes cannot appear as summaries or satisfy keyword groups.

Executed from web/ using the same Node/npm versions as the initial checkpoint:

- **npm run typecheck** — passed. Initial new-test compilation exposed two test
  typing issues (HTTP option overload and inferred counter type); both were fixed.
- **./node_modules/.bin/tsx --test tests/news-discovery.test.ts tests/news-ai.test.ts**
  — 14 passing isolated transport/domain/provider tests.
- **./node_modules/.bin/tsx --test tests/news-api.test.ts** — 8 passing HTTP and
  persistence tests, including restart preservation, conflicts, in-flight edits
  and deletion, per-interest failure retention, credential omission, a mocked
  Responses-to-cache flow, and version-1/version-2 backup compatibility.
- **npm test** — 52 passing non-GUI tests (the earlier 30 plus 22 news tests).
- **npm run build** — TypeScript and Vite production build passed.
- **git diff --check** — passed.

Read-only source probes used ./node_modules/.bin/tsx -e to call fetchFeed,
parseFeed and searchDiscovery directly; no app was launched and no persistent
user data was read or changed. The Go Atom feed returned 10 articles. Standard
search for the shipped AI-model interest parsed 100 candidates and retained 40
matches from 37 publishers; final summaries contained no HTML tags. The strict
Japan-jobs query parsed 17 candidates and retained 0 matches, documenting the
news index's limited coverage rather than reporting a loading failure.

No OpenAI key was configured, so no paid live AI request was made. Provider
validation uses injected Responses fixtures and does not establish live model
access, billing eligibility or answer quality. No GUI validation or native
distribution check was run or required for this web change.

Provider references: [Responses web search](https://developers.openai.com/api/docs/guides/tools-web-search),
[structured outputs](https://developers.openai.com/api/docs/guides/structured-outputs),
and [Node DNS lookup callback contract](https://nodejs.org/api/dns.html#dnslookuphostname-options-callback).

## PI news provider validation — 2026-10-02

News AI now invokes PI 1.0 in print/JSON mode, reusing its saved model and login.
The earlier OpenAI Responses checkpoint above is historical. The current UI has
PI connection status and refresh instead of an API-key form; the former key
endpoint is absent. Source retrieval and strict result acceptance are owned by
Kontrol, while model inference and authentication are owned by PI.

Executed from web/ with Node 25.8.2 and the installed PI 1.0.0:

```sh
npm run typecheck
KONTROL_TEST_PI_COMMAND=/opt/homebrew/bin/pi node --import tsx --test \
  tests/domain.test.ts tests/api.test.ts tests/projects-persistence.test.ts \
  tests/news-discovery.test.ts tests/news-ai.test.ts tests/news-api.test.ts \
  tests/news-pi.test.ts tests/news-pi-cli.test.ts
npm run build
```

TypeScript and the Vite production build passed. The explicit test selection
executed **61 passed, 0 failed, 0 skipped**. The opt-in CLI test uses a temporary
PI configuration and a loopback fixture provider, including a successful streamed
answer and HTTP 503 failure. It verifies no credential/context leakage, no tools,
no saved session, unchanged global fixture settings, and exactly one provider
request for each invocation even when global PI retries are enabled. Set
KONTROL_TEST_PI_COMMAND to another installed PI executable to run that test on a
different machine; without it, only that CLI integration test is skipped.

The initial focused run had **26 passed, 3 failed**: two expectations omitted
ISO timestamp milliseconds, and cancellation returned before the child was
reaped. The expectations were normalized and the runner now waits for process
close before releasing its temporary directory/search gate. The corrected
focused selection passed **29/29**; the later full selection includes the added
date-duplicate regression and real CLI integration fixture. An initial
`npm run typecheck` from the repository root failed because package.json lives
under web/; the command succeeded from web/.

Read-only function probes (Node with `--import tsx --input-type=module`) called
piStatus and aiSources for the bundled interests, without launching Kontrol or
reading its database. PI's executable/default model were detected. The Japan
query yielded 17 dated news candidates and zero Bing candidates; the model-news
query yielded 40 bounded candidates, including 10 undated web candidates. These
counts are search-index observations, not model acceptance or relevance scores.
They demonstrate that search coverage can still be sparse for specific queries.
No paid inference or personal PI credential access was used in validation.

`git diff --check` passed for tracked changes. A separate trailing-whitespace
check covered the edited/new web files and documentation because the existing
web tree is currently untracked. No GUI validation was run or required.

Integration references: [PI CLI integration](https://pi.dev/docs/latest/cli-integration),
[JSON event stream](https://pi.dev/docs/latest/json), and
[PI model configuration](https://pi.dev/docs/latest/models).

## JOB validation — 2026-10-02

Executed from `web/` with Node 25.8.2 and npm 11.14.1:

```sh
KONTROL_TEST_PI_COMMAND=/opt/homebrew/bin/pi node --import tsx --test \
  tests/domain.test.ts tests/api.test.ts tests/projects-persistence.test.ts \
  tests/news-discovery.test.ts tests/news-ai.test.ts tests/news-api.test.ts \
  tests/news-pi.test.ts tests/news-pi-cli.test.ts \
  tests/jobs-domain.test.ts tests/jobs-api.test.ts
npm run build
```

The explicit selection passed **81 tests, 0 failures, 0 skips**, including 20
JOB domain/API/persistence tests. The production build includes TypeScript
checking and passed. Logs are `/tmp/kontrol-jobs-tests-20261002.log` and
`/tmp/kontrol-jobs-build-20261002.log`. The tests use synthetic PDF/DOCX/TXT
documents, isolated SQLite stores, injected job/AI responses, and the existing
PI CLI test with a temporary configuration and a local fixture provider.
They cover real text extraction, invalid/oversized uploads, independent filters,
offline city lookup, profile/search gates, source-ID validation, expiration
across duplicate sources, failure retention, revision conflicts, in-flight
deletion, persistence reopening, and version-1/2/3 backup compatibility.

Read-only resource probes invoked the source functions directly with synthetic
profiles, without launching the app or opening its database. The remote source
probe retrieved **16 Remotive candidates**; a later Berlin office/hybrid probe
retrieved **5 Arbeitnow candidates** with both work arrangements represented.
Some Bing-linked pages were unavailable and produced the expected partial-source
warning. These counts are source-coverage observations, not AI fit scores or a
guarantee of current availability. No personal CV, real PI credentials, or paid
model request was used for validation; live provider answer quality is unverified.

Intermediate findings were resolved rather than recorded as passing: the default
npm cache rejected installation with EACCES, so dependencies were installed with
`--cache /tmp/kontrol-npm-cache`; initial type checks found a removed PDF.js
option and an ES2024-only test helper, both corrected. A provisional online
geocoder timed out at 10 seconds (a separate probe eventually took 17.9 seconds),
so city lookup now uses the local catalog. Arbeitnow's approximately 2.94 MB feed
exceeded the original 2 MB transport cap; only that fixed API endpoint now gets
an 8 MB bound, while listing pages and other sources retain the 2 MB default.

`git diff --check` passed. A separate text check found no trailing whitespace in
the web source and edited documentation, including the currently untracked web
tree. No GUI, screenshot, Accessibility, or live-app validation was run. Existing
production data and the native app were untouched by validation.

## CV analysis correction — 2026-10-02

A non-interactive reproduction with the supplied PDF extracted 5,283 characters
in 354 ms. PI returned an answer after 27,209 ms, but the profile validator
rejected its skill list for exceeding 30 entries. The prompt had not specified
that limit, and the error incorrectly suggested incomplete CV contents.

The prompt now supplies the complete schema; the AI adapter deduplicates and
caps list entries in relevance order. Analysis receives a 120-second deadline
in both the server route and PI child process, while News/ranking keep their
60-second PI default. Browser request deadlines and command-cache settlement
also prevent a stalled status refresh from keeping completed commands pending.

Executed from `web/`:

```sh
npm run typecheck
node --import tsx --test tests/jobs-domain.test.ts tests/jobs-api.test.ts \
  tests/jobs-client.test.ts tests/news-pi.test.ts
KONTROL_TEST_PI_COMMAND=/opt/homebrew/bin/pi node --import tsx --test \
  tests/domain.test.ts tests/api.test.ts tests/projects-persistence.test.ts \
  tests/news-discovery.test.ts tests/news-ai.test.ts tests/news-api.test.ts \
  tests/news-pi.test.ts tests/news-pi-cli.test.ts \
  tests/jobs-domain.test.ts tests/jobs-api.test.ts tests/jobs-client.test.ts
npm run build
```

TypeScript passed. The focused selection passed **33 tests**; the full explicit
non-GUI selection passed **89 tests, 0 failures, 0 skips**. The production build
passed. Logs are `/tmp/kontrol-cv-fix-focused-20261002.log`,
`/tmp/kontrol-cv-fix-tests-20261002.log`, and
`/tmp/kontrol-cv-fix-build-20261002.log`. Added regressions cover overlong AI lists,
strict manual edits, retry after a PI timeout, actual child-process deadline and
cleanup, stalled HTTP headers/bodies, query cancellation, and success/failure
settlement while status fetching is stalled. Client tests operate directly on
transport and query-cache functions; they use no browser or DOM.

A second `node --import tsx --input-type=module` invocation called `extractCV`
and `jobAI().analyze` directly with the supplied PDF and the existing PI model.
This live provider check succeeded in **25,523 ms**, including 373 ms extraction,
and returned a schema-valid profile with 3 roles, 27 skills and 3 languages.
Only timing, validity and field counts were printed; no CV or generated profile
text was added to source, fixtures or logs. These two diagnostic calls used the
configured PI provider; they did not launch the app or open its production
database. The automated suite continues to use synthetic CVs and isolated data.

## JOB collapsible setup panels — 2026-10-02

The CV and search-filter panels now have independent Minimize/Expand controls,
with browser-local preferences, compact summaries and a visible unsaved-filter
indicator. Panel contents remain mounted while hidden, and upload, analysis and
preference-save errors remain outside the hidden area.

Executed from `web/`:

```sh
npm run build
node --import tsx --test tests/jobs-client.test.ts
```

TypeScript and the Vite production build passed. All **4 selected non-GUI
transport/query-cache tests passed**, with 0 failures and 0 skips. Source review
covered independent panel state, retained drafts, storage fallback and error
placement. No browser, GUI or live-app validation was run.

## Native app removal — 2026-10-02

Removed the Swift application, Xcode project, native tests and fixtures, AppleScript
launcher, native mockups and obsolete specifications. The learning catalog and
default feeds moved unchanged to `web/resources/`; their two server loaders now
read from that directory. Root commands build and run the web application, and
the npm test script explicitly names its non-GUI test files. Settings describes
legacy macOS imports without directing users to the retired application.

Historical native results, failures, skips and release evidence remain in the
[native archive](archive/native/README.md). All earlier web checkpoints above
are preserved verbatim from the previous web guide.

Executed from the repository root with Node **25.8.2** and npm **11.14.1**:

```sh
make build
git diff --check
make -n dev run start web-dev web-start test web-test clean
```

Executed from `web/`:

```sh
KONTROL_TEST_PI_COMMAND=/opt/homebrew/bin/pi node --import tsx --test \
  tests/domain.test.ts tests/api.test.ts tests/projects-persistence.test.ts \
  tests/news-discovery.test.ts tests/news-ai.test.ts tests/news-api.test.ts \
  tests/news-pi.test.ts tests/news-pi-cli.test.ts \
  tests/jobs-domain.test.ts tests/jobs-api.test.ts tests/jobs-client.test.ts
```

The TypeScript check and Vite production build passed. The explicit test selection
passed **89 tests, 0 failures, 0 skips**, including forty-lesson catalog loading,
default-feed initialization, legacy import/backup compatibility, isolated SQLite
and project-file persistence, and the installed PI CLI with a temporary local
provider fixture. Build and test logs are `build.log` and `tests.log` under
`/var/folders/lz/20cqfx4x2k98r89q68w3q3ch0000gn/T/kontrol-native-removal-2k_8439v/`.

An inline `python3` resource/document audit confirmed:

- Both moved JSON resources match their original SHA-256 hashes and parse correctly.
- Archived evidence bodies and earlier web validation entries are unchanged.
- Existing web files are unchanged except `package.json`, the two resource loaders
  and Settings copy; the two resource files are the only additions to the web tree.
- Native source/build trees are absent, and all 11 existing Node test files are
  explicitly selected by the npm script.
- Local links and heading anchors in the active Markdown documentation and
  archive index resolve. Original links inside historical snapshots are preserved
  as historical paths, as explained in the archive index.

`git diff --check` passed. The Makefile dry run confirmed that development/start
commands use npm and `clean` targets only `web/dist` and `web/coverage`.
No app or browser was launched, no GUI checks were run, and validation did not
open or change production data. No signing, packaging or distribution check is
claimed for the removed application.

## JOB discovery coverage repair — 2026-10-02

A read-only query of the saved JOB search metadata showed three assessed sources,
zero matches and no error for full-time roles in Tokyo/Kyoto within 30 days.
An isolated source probe reproduced the cause: Bing returned tutorials and
unrelated pages, Arbeitnow supplied no listings passing these filters, and
Remotive supplied only office-assistant, sales-contractor and service-desk roles.
The probe used a synthetic backend profile and did not send CV text or invoke PI.

Discovery now falls back to DuckDuckGo when Bing produces no relevant readable
postings, follows bounded same-origin links from directories to individual
structured offers, and retains explicit region evidence for Tokyo ward matching.
Empty-source coverage and zero strong profile matches have distinct messages.

Executed from `web/` with Node **25.8.2**:

```sh
npm run typecheck
node --import tsx --test tests/jobs-domain.test.ts tests/jobs-api.test.ts tests/jobs-client.test.ts
npm run build
```

TypeScript and the Vite production build passed. The final explicit non-GUI test
selection passed **34 tests, 0 failures, 0 skips**. Regression fixtures cover
irrelevant/unavailable primary search, directory-to-offer retrieval, private and
advertising links, traversal depth, strict city filters, Tokyo ward metadata, and
fallback discovery through ranking and persistence in an in-memory database.
The ranking response in the integration test is injected, not a live PI call.

Read-only source probes used `node --import tsx --input-type=module` to call
`createJobDiscovery` directly. With the same cities, employment filter and date
window, the repaired discovery returned **11 candidates**, including eight
software/backend listings, in about nine seconds. Some source pages and searches
were unavailable and produced coverage warnings. These counts are retrieved
candidates, not live AI match results or guarantees of current job availability.
No app, browser or native UI was launched. Production data was inspected through
read-only SQLite for diagnosis and was not modified.

## Tasks and Planner removal — 2026-10-02

Removed both modules' pages, navigation entries, dashboard widgets, task counter,
Focus task picker, Learning planner action, API routes and unused styles/helpers.
Existing six/seven-widget layouts migrate to the five remaining modules while
preserving their order, widths and visibility. Version-4 backups use the new
layout; native version-1 and web version-1 through version-3 imports remain
supported. Retired records and existing Focus links/titles remain in backups.

Executed from `web/` with Node **25.8.2**:

```sh
npm run build
node --import tsx --test tests/domain.test.ts tests/api.test.ts tests/projects-persistence.test.ts tests/news-api.test.ts tests/jobs-api.test.ts
```

TypeScript and the Vite production build passed. The explicitly selected
non-GUI suites passed **50 tests, 0 failures, 0 skips**. Coverage includes retired
routes rejecting reads/writes, standalone Focus creation, preserved historical
Focus records, legacy/current backup restore, layout migration and customization,
reopening an isolated SQLite database, import rollback and remaining module APIs.

Source review found no remaining frontend references to the removed sections or
imports of their deleted modules/helpers. `git diff --check` passed. Validation
used only in-memory databases, temporary files and injected network/PI fixtures.
No app/browser was launched, no GUI checks were run and production data was not
opened or modified. Earlier validation evidence is preserved unchanged.

## PI web search for JOB — 2026-10-03

The installed PI was verified to support hosted web search through the existing
OpenAI Codex login. JOB now uses that capability for discovery, then fetches the
returned pages and ranks only retrieved structured listings. A bundled extension
enables only hosted search and records completed provider source evidence; URLs
invented in assistant text cannot become candidates. User extensions, local
tools, context files and saved sessions stay disabled. Unsupported or failed PI
search falls back to the existing public sources. Normal News inference keeps
its original tool-free behavior.

The first live discovery probe found 14 URLs but still returned only the same
three unrelated remote records after filtering. Inspection identified a valid
Milan posting rejected because its source used the Italian name Milano. Matching
now accepts that alias only within Italy. An older Tokyo listing was correctly
excluded by the 30-day window; the search prompt now includes an explicit posting
cutoff and prioritizes HTML detail pages over application forms and PDFs.

Executed from `web/` with Node **25.8.2**:

```sh
npm run typecheck
KONTROL_TEST_PI_COMMAND=/opt/homebrew/bin/pi node --import tsx --test \
  tests/news-pi.test.ts tests/news-pi-cli.test.ts \
  tests/jobs-domain.test.ts tests/jobs-api.test.ts tests/jobs-client.test.ts
npm run build
```

The selected non-GUI suites passed **50 tests, 0 failures, 0 skips**. TypeScript
and the Vite production build passed. `git diff --check` passed from the repository
root. Tests cover source-evidence enforcement, unsupported providers, process
isolation/cleanup/cancellation, city aliases and PI discovery through retrieval,
ranking and persistence in an in-memory database. The installed-CLI tests use a
temporary local HTTP provider with fixture credentials and streamed Responses
events, including a valid-looking answer without actual search evidence.

Read-only live probes used `node --import tsx --input-type=module`, a synthetic
Java/Kotlin backend profile, and the selected Tokyo/Kyoto/Milan, full-time and
30-day filters. After the changes, PI returned 12 search links; retrieval produced
**7 candidates, including 4 software/backend listings**, in approximately 55
seconds without invoking Bing or DuckDuckGo. Some pages remained unavailable and
produced a coverage warning. A separate fetch of the Milano Java backend posting
confirmed that it now passes the saved filters. These are discovery results,
not live profile-fit scores or guarantees of vacancy availability. No live
ranking request used personal CV data, no production records were modified, and
no app/browser or GUI validation was run. Earlier evidence remains unchanged.

## JOB discovery reliability and complete ranking — 2026-10-03

The next user search still saved only three unrelated remote records and zero
matches. Read-only inspection confirmed that the updated server was running;
the failure remained in source discovery. A further live probe showed variable
PI results, including stale URLs, blocked pages and Italian directories whose
`/lavoro/` offer links the reader did not recognize. Some structured listings
also supplied `Milano, Italy` as the locality, which failed exact city matching.

Software searches for selected Japanese cities and Milan now retrieve TokyoDev
and Reteinformaticalavoro indexes independently of PI search. Retrieval remains
bounded, shares URL deduplication, and requires a fetched structured offer for
every candidate. Italian offer paths and locality fields containing a repeated,
matching country are accepted. Date, employment, work-mode and country filters
remain enforced. The UI and active guide describe the additional sources.

Executed from `web/` with Node **25.8.2**:

```sh
npm run typecheck
node --import tsx --test tests/jobs-domain.test.ts tests/jobs-api.test.ts tests/jobs-client.test.ts
npm run build
```

The selected non-GUI suites passed **45 tests, 0 failures, 0 skips**. TypeScript
and the Vite production build passed. `git diff --check` passed from the repository
root. New regressions cover empty/unavailable/blocked/unstructured PI discovery,
direct-board retrieval through ranking and persistence, Italian directory links,
country-qualified city names, expired offers and conflicting geography.

Two isolated live probes used `node --import tsx --input-type=module` and a
synthetic seven-year Java/Kotlin backend profile with representative skills and
languages, plus Tokyo/Kyoto/Milan, full-time and 30-day preferences:

- The complete live PI search → retrieval → live PI ranking path returned
  **15 candidates and 6 ranked matches** in approximately 84 seconds. Matches
  included Java/Kotlin backend work in Tokyo and Java backend work in Milan.
  Some source pages were unavailable and generated a coverage warning.
- With PI discovery deliberately returning no links, fresh direct-board
  retrieval still returned **10 software listings** (13 total candidates) in
  approximately 3.4 seconds, with no Bing/DuckDuckGo queries or warnings.

Synthetic inputs and public retrieved evidence from the complete run are in
`discovery.json` and `matches.json` under
`/var/folders/lz/20cqfx4x2k98r89q68w3q3ch0000gn/T/kontrol-job-live-check-FCXBss/`.
These checks did not save matches into the user's database. Production state was
read only for diagnosis; no CV text was transmitted. No app/browser was launched
or operated, and no GUI checks were run. Historical evidence above is unchanged.

## Today, saved workspace and connected learning — 2026-10-03

This change adds Today actions and layout presets, goal preferences, a saved
library, notes/links/clocks, weekly summaries, finite news briefings and bookmarks,
application tracking/comparison/follow-ups, learning paths and recall reviews.
Saved articles and offers use durable snapshots independent of discovery caches.
Web backup version 5 includes the workspace; versions 1–4 remain accepted.

Validation was non-interactive and used in-memory SQLite or uniquely named
scratch databases. No production database, personal CV or provider credentials
were accessed. No application/browser was launched or operated. No GUI,
Accessibility, screenshot, presentation or live-app checks were run or required.

The first new domain/API selection passed **12 tests**. The broader explicit
selection below then passed **120 tests, 0 failures, 2 skips**:

```sh
# From web/
./node_modules/.bin/tsx --test \
  tests/domain.test.ts tests/api.test.ts tests/projects-persistence.test.ts \
  tests/news-discovery.test.ts tests/news-ai.test.ts tests/news-api.test.ts \
  tests/news-pi.test.ts tests/news-pi-cli.test.ts \
  tests/jobs-domain.test.ts tests/jobs-api.test.ts tests/jobs-client.test.ts \
  tests/workspace-domain.test.ts tests/workspace-api.test.ts
```

The skipped tests are the opt-in installed-PI CLI fixture checks because
`KONTROL_TEST_PI_COMMAND` was not set. They are not reported as passing. The
remaining PI tests use isolated executable/provider fixtures.

Source review then tightened historical lesson handling, AI-summary provenance,
conflict recovery, shared target roles, and bounded read-marker retention.
Additional regressions cover these changes. The final affected selection passed
**54 tests, 0 failures, 0 skips**, including **15 workspace tests**:

```sh
# From web/
npm run build
./node_modules/.bin/tsx --test \
  tests/workspace-domain.test.ts tests/workspace-api.test.ts \
  tests/jobs-api.test.ts tests/jobs-client.test.ts tests/news-api.test.ts \
  tests/api.test.ts
```

The final production build passed both TypeScript and Vite compilation. During
implementation, one typecheck caught an insufficiently narrowed discovery source;
an intermediate build caught a missing Record annotation in a backup test.
Both were corrected, and the final command above passed. An earlier affected
selection passed 53 tests before the additional capacity regression was added.

Coverage includes canonical-link deduplication, saved content surviving cache/CV
replacement, manual jobs without AI, stage history, invalid follow-up dates,
revision conflicts (including edits at identical timestamps), goal validation,
full saved lesson content for reviews, separate recall answers, due scheduling,
backup round-trips and atomic import rejection, SQLite reopening, preservation
of AI provenance, and eviction of disposable read markers without loss of
bookmarks or authored notes. No test evaluates live recommendation quality.

`git diff --check` passed. A separate Python whitespace scan covered new and
edited frontend, shared, module and workspace-test sources, including untracked
files, and passed. Existing work in progress and historical validation entries
were retained.

## Bug fixes, performance and UI clarity — 2026-10-03

The pre-existing working tree was committed first as `57b7800`. Each subsequent
fix or improvement was committed separately. This pass addresses:

- PDF uploads at the advertised 5 MB limit without recursive base64 matching.
- Work-arrangement parsing that distinguishes hybrid work from hybrid cloud.
- Profile and filter drafts surviving background refreshes, with explicit
  conflict recovery when another tab changes the same saved fields.
- A shared 64 MB formatted JSON export/import limit. Oversized exports reject
  with a database-directory backup alternative instead of offering an
  unrestorable file. Other API request bodies retain their 16 MB limit.
- Cached headline tokens, dates and canonical URLs, bounded five-story grouping,
  and memoized briefing derivation. Related coverage appearing late in the
  source list is retained.
- Bounded API waits, query cancellation, slower idle polling, and a compact
  Focus status endpoint so ordinary pages do not repeatedly download history.
  Route content is isolated from shell timer updates; idle timers stop ticking.
- Shared typography sizes that avoid compounded nested text shrinkage, compact
  Today actions, and expandable Jobs source explanations with billing information
  still visible beside the search action.

Final validation ran from `web/` with Node **25.8.2**:

```sh
node --import tsx --test \
  tests/domain.test.ts tests/api.test.ts tests/projects-persistence.test.ts \
  tests/news-discovery.test.ts tests/news-ai.test.ts tests/news-api.test.ts \
  tests/news-pi.test.ts tests/news-pi-cli.test.ts \
  tests/jobs-domain.test.ts tests/jobs-api.test.ts tests/jobs-client.test.ts \
  tests/workspace-domain.test.ts tests/workspace-api.test.ts
npm run build
```

Results: **132 tests, 130 passed, 0 failed, 2 skipped**. The two skipped tests
are opt-in installed-PI CLI checks; `KONTROL_TEST_PI_COMMAND` was not set. They
are not reported as passing. The other PI tests use isolated fixtures.
TypeScript and Vite production compilation passed. `git diff --check` passed
from the repository root. Regression coverage includes a valid PDF at the exact
upload limit, malformed base64, remote/hybrid parsing, draft revision conflicts,
a formatted Unicode backup larger than 16 MB restoring every answer into a
fresh database, late related news coverage, API deadlines, and Focus completion
reconciliation while history is retained separately.

A final non-GUI microbenchmark used 1,000 distinct, equally dated synthetic
headlines, one warm-up and three measured iterations. It compared the checkpoint
implementation against the current helper in the same Node process (V8
**14.1.146.11-node.24**):

| Grouping operation | Three elapsed times (ms) |
| --- | --- |
| Checkpoint: group all, then take five | 590.22 / 589.22 / 594.76 |
| Current: group all | 29.77 / 28.80 / 28.67 |
| Current: retain five leading groups | 0.81 / 0.79 / 0.78 |

These are helper timings, not browser frame-time or end-to-end measurements.
The exact benchmark command, run from `web/`, was:

```sh
node --import tsx --input-type=module <<'NODE'
import { execFileSync } from 'node:child_process';
import { stripTypeScriptTypes } from 'node:module';
import { canonicalURL, groupStories } from './shared/workspace.ts';
const original = execFileSync('git', ['show', '57b7800:web/shared/workspace.ts'], { encoding: 'utf8' });
const source = original.slice(original.indexOf('export function groupStories')).replace('export function', 'function');
const before = new Function('canonicalURL', stripTypeScriptTypes(source) + '; return groupStories;')(canonicalURL);
const articles = Array.from({ length: 1000 }, (_, i) => ({
  title: 'Language' + i + ' compiler' + i + ' release' + i + ' benchmark' + i,
  url: 'https://example.com/story/' + i,
  publishedAt: '2026-10-03T00:00:00.000Z',
}));
const measure = fn => {
  fn();
  return Array.from({ length: 3 }, () => {
    const start = performance.now();
    const result = fn();
    return { ms: Number((performance.now() - start).toFixed(2)), groups: result.length };
  });
};
console.log(JSON.stringify({ node: process.version, v8: process.versions.v8,
  baseline: measure(() => before(articles).slice(0, 5)),
  cachedAll: measure(() => groupStories(articles)),
  boundedBriefing: measure(() => groupStories(articles, 5)),
}, null, 2));
NODE
```

Node emitted its experimental `stripTypeScriptTypes` warning; the benchmark
completed successfully. Tests used isolated in-memory or scratch persistence,
and no production data was changed. UI changes were checked through source
review and compilation. No app/browser was launched or operated, and no GUI,
Accessibility, native keyboard/focus, screenshot or presentation checks were run
or required. Earlier validation evidence remains unchanged.
