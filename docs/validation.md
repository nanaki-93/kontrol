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

## UI hierarchy and concise copy — 2026-10-03

Source review identified oversized introductory copy, persistent setup details
above results, and equally emphasized secondary controls. The update reduces
header and card spacing, uses slate surfaces with teal actions, and keeps amber
attention states and red errors distinct. Today highlights due work and previews
three briefing stories; confirmed Jobs profiles put matches before setup, with
stable section keys retaining drafts. News interests, confirmed profile details,
offer details and weekly activity use disclosure controls.

Executed from `web/`:

```sh
node --import tsx --test tests/workspace-domain.test.ts tests/jobs-client.test.ts
npm run build
```

The explicitly selected non-GUI suites passed **12 tests, 0 failures, 0 skips**.
They cover existing recommendation/recall helpers, briefing grouping, layout
presets, draft refresh/revision handling, and request/cache completion. These
are domain and client-state checks, not rendered UI validation. TypeScript and
the Vite production build passed. `git diff --check` passed from the repository
root. No dependencies, persistence schemas or production data were changed.

UI validation was limited to source review and compilation under `AGENTS.md`.
No browser/app launch, interactive journey, screenshot, accessibility, native
keyboard/focus or presentation checks were run or required. Visual appearance
has not been verified in a running app.

## PI news search returning zero results — 2026-10-03

Read-only inspection of the discovery document showed a successful AI run with
zero matches for **Programming jobs in Japan**. Direct source retrieval reproduced
the cause: Google News returned 14 candidates, none satisfying the interest's
keyword groups; Bing RSS returned no candidates. Three simpler Bing queries
also returned no candidates. PI was ranking this limited input rather than
performing web search.

News AI now uses PI's existing hosted web-search integration for OpenAI Responses
and Codex models. Public provider-cited URLs are retrieved before acceptance;
titles and publication dates come from page metadata. Providers without hosted
search retain the RSS-ranking path. Search/evidence/page failures preserve
previous results and remain errors. No persistence schema changed.

Executed from `web/`:

```sh
node --import tsx --test tests/news-ai.test.ts tests/news-api.test.ts tests/news-discovery.test.ts tests/news-pi.test.ts
KONTROL_TEST_PI_COMMAND=/opt/homebrew/bin/pi node --import tsx --test tests/news-pi-cli.test.ts
node --import tsx --test tests/news-ai.test.ts tests/news-api.test.ts
npm run build
```

The first selection passed **40 tests**, and both installed-PI fixture tests
passed (**2 tests**). The final AI/API selection, after refining metadata
selection and adding unreadable-page cache-retention assertions, passed
**23 tests**. All selections had **0 failures and 0 skips**. The installed-PI
checks use temporary credentials/configuration and local provider fixtures.
The TypeScript check and Vite production build passed. `git diff --check` passed
from the repository root.

A separate live, non-interactive adapter check used the configured
`openai-codex/gpt-6-astra` model and the shipped Japan interest, with fresh fixture
IDs. The exact command, run from `web/`, was:

```sh
node --import tsx --input-type=module <<'JS'
import { randomUUID } from 'node:crypto';
import { interestPresets } from './shared/news.ts';
import { aiDiscovery } from './server/news/ai.ts';
import { runPIWebSearch } from './server/news/pi.ts';
import { fetchFeed } from './server/news/transport.ts';
import { parseSourcePage } from './server/news/pages.ts';
const interest = { ...interestPresets[0], id: randomUUID(), revision: randomUUID() };
const started = Date.now();
const rows = await aiDiscovery({
  webSearch: async (...args) => {
    const result = await runPIWebSearch(...args);
    console.log(JSON.stringify({ providerEvidenceURLs: result.urls.length, answer: JSON.parse(result.text) }));
    return result;
  },
  fetcher: async (...args) => {
    const html = await fetchFeed(...args);
    const source = parseSourcePage(html, args[0]);
    console.log(JSON.stringify({ fetchedHost: new URL(args[0]).hostname, title: source?.title, publishedAt: source?.publishedAt }));
    return html;
  },
})(interest);
console.log(JSON.stringify({ elapsedMs: Date.now() - started, accepted: rows.length, results: rows.map(({ title, url, publishedAt }) => ({ title, url, publishedAt })) }, null, 2));
JS
```

This completed in **34,365 ms**, with **29 provider-evidence URLs** and **5 accepted
sources**: Robert Walters, TokyoDev, WorkinGames, ranked.jp and Michael Page.
These were opportunity directories with unknown publication dates; they were
kept undated, and individual job availability was not verified. The check called
the adapter directly and did not persist results or operate the application.

All automated tests used isolated fixtures. Production application data was
read only and left untouched. No app/browser launch, GUI journey, screenshot,
Accessibility, keyboard/focus or presentation validation was run or required.
Historical validation results above remain unchanged.

## Editorial UI and content hierarchy — 2026-10-04

Today now opens with a light **Start here** feature using an actual due
follow-up, recall review, lesson, briefing story or job match. Its adjacent
**On your radar** section retains direct routes and uses dashes for unavailable
counts. The shared shell uses a charcoal canvas with separate Learning, News
and Jobs accents. Lesson cards surface objectives and duration, briefings give
the lead story a headline and labeled excerpt, and job cards show estimated fit
alongside a match-reason preview. Existing save/read, notes, application,
customization and disclosure controls remain in the source.

The final source review included responsive rules, long-text wrapping, pending
and unavailable data, link destinations, source/AI labels, module styling,
large text and reduced-motion preferences. The brand mark, favicon and HTML
browser theme color were aligned. Existing work in progress was retained;
this pass changed no dependencies, persistence schemas or production data.

Executed from `web/` with Node **25.8.2**:

```sh
node --import tsx --test tests/workspace-domain.test.ts tests/jobs-client.test.ts
npm run build
```

The explicitly selected non-GUI suites passed **12 tests, 0 failures, 0 skips**.
These check recommendation/recall helpers, briefing grouping, layout presets,
draft refresh/revision handling and request/cache completion. They are domain
and client-state checks, not rendered UI tests. TypeScript and the Vite
production build passed, including a final build after the refinements.

Executed from the repository root:

```sh
git diff --check
python3 - <<'PY'
from pathlib import Path
from xml.etree import ElementTree
ElementTree.parse('web/public/favicon.svg')
assert Path('web/src/main.tsx').is_file()
assert 'href="/favicon.svg"' in Path('web/index.html').read_text()
assert 'content="#131613"' in Path('web/index.html').read_text()
print('Static SVG and HTML asset checks passed.')
PY
```

Whitespace, SVG parsing and HTML asset checks passed. No app or browser was
launched or operated. No GUI, Accessibility, keyboard/focus, screenshot or
presentation validation was run or required. Appearance in a running app remains
unverified. Earlier validation evidence remains unchanged.

## UI copy and information cleanup — 2026-10-04

Removed page slogans, repeated labels, app-usage paragraphs, setup walkthroughs,
search-method explanations, promotional panels and instructional empty states
across Today, Learning, News, Jobs, Focus, Projects, Library and Settings.
Page descriptions are optional; Today retains a user-authored goal when set.
Empty clocks are omitted, headers are smaller, and unused copy-related styles
were removed. Actual lesson material, article excerpts, match reasons and user
notes remain. Field formats, source/AI provenance, error recovery, provider
usage, CV transfer and destructive-action notices retain concise wording.

Executed from `web/` with Node **25.8.2**:

```sh
npm run build
git diff --check
```

TypeScript and the Vite production build passed after the copy changes and again
after spacing refinements. Whitespace checks passed. No new unit tests were added
or run for this presentation-only change; earlier test results above are historical.

An initial ad hoc static source audit through `node --input-type=module` stopped
before checking files with `TypeError: ts.createPrinter is not a function`.
Inspection showed the installed TypeScript package exports version metadata but
not that legacy compiler API. This was an audit-tool limitation, not a successful
check. The audit was then completed with the parser already bundled by Rolldown:

```sh
node --input-type=module <<'JS'
import assert from 'node:assert/strict';
import { readdirSync, readFileSync } from 'node:fs';
import { join, relative } from 'node:path';
import { parseSync, Visitor } from 'rolldown/utils';
const baseline = '/var/folders/lz/20cqfx4x2k98r89q68w3q3ch0000gn/T/kontrol-copy-baseline-5eyy45ax/web/src';
const keys = new Set(['onClick', 'onSubmit', 'onChange', 'onKeyDown', 'disabled', 'required', 'min', 'max', 'minLength', 'maxLength', 'accept', 'type', 'value', 'checked']);
const positions = new Set(['start', 'end', 'range', 'loc', 'raw']);
function bindings(text) {
  const result = parseSync('source.tsx', text);
  assert.equal(result.errors.length, 0);
  const values = [];
  new Visitor({ JSXAttribute(node) {
    if (keys.has(node.name.name)) values.push(JSON.stringify(node, (key, value) => positions.has(key) ? undefined : value));
  } }).visit(result.program);
  return values.sort();
}
let files = 0, attributes = 0;
function check(directory) {
  for (const entry of readdirSync(directory, { withFileTypes: true })) {
    const path = join(directory, entry.name);
    if (entry.isDirectory()) check(path);
    else if (path.endsWith('.tsx')) {
      const previous = bindings(readFileSync(join(baseline, relative('src', path)), 'utf8'));
      const current = bindings(readFileSync(path, 'utf8'));
      assert.deepEqual(current, previous, path + ': event handlers or field constraints changed');
      files++; attributes += current.length;
    }
  }
}
check('src');
console.log(`Static source comparison passed: ${files} TSX files, ${attributes} unchanged event and field attributes.`);
JS
```

The source comparison passed across **27 TSX files and 408 event/field
attributes** against the snapshot taken before this copy cleanup. It verifies
source bindings and constraints, not rendered behavior. No dependencies,
server logic, persistence schemas or production data changed in this pass.
No app/browser was launched or operated, and no GUI, Accessibility,
keyboard/focus, screenshot or presentation checks were run or required.
Visual appearance remains unverified in a running app.

## Matrix visual direction — 2026-10-04

Applied the selected Matrix direction to the existing app: near-black surfaces,
electric green actions, bright text, square panel/control corners, monospace
headings and a static grid behind the Today feature. Module accent overrides and
pastel weekly totals are replaced by the shared palette. Navigation keeps its
labels with a simple divider; redundant group labels and the large decorative
feature arrow are removed. The heading underscore is decorative. Amber warning
and red error treatments remain distinct. The favicon and browser theme color
match the app. Fonts use local system stacks with no new assets or dependencies.

Executed from `web/`:

```sh
npm run build
node --input-type=module <<'JS'
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import postcss from 'postcss';
import { parseSync, Visitor } from 'rolldown/utils';
const baseline = '/var/folders/lz/20cqfx4x2k98r89q68w3q3ch0000gn/T/kontrol-matrix-baseline-rpj8chhg/web';
const css = postcss.parse(readFileSync('src/styles.css', 'utf8'));
const tokens = new Set();
const references = new Set();
css.walkDecls(decl => {
  if (decl.prop.startsWith('--')) tokens.add(decl.prop);
  for (const match of decl.value.matchAll(/var\((--[\w-]+)/g)) references.add(match[1]);
});
assert.deepEqual([...references].filter(name => !tokens.has(name)), []);
assert(!readFileSync('src/styles.css', 'utf8').includes('@import'));
const keys = new Set(['onClick', 'onSubmit', 'onChange', 'onKeyDown', 'disabled', 'required', 'min', 'max', 'minLength', 'maxLength', 'accept', 'type', 'value', 'checked', 'href']);
const positions = new Set(['start', 'end', 'range', 'loc', 'raw']);
function bindings(text) {
  const result = parseSync('source.tsx', text);
  assert.equal(result.errors.length, 0);
  const values = [];
  new Visitor({ JSXAttribute(node) {
    if (keys.has(node.name.name)) values.push(JSON.stringify(node, (key, value) => positions.has(key) ? undefined : value));
  } }).visit(result.program);
  return values.sort();
}
let attributes = 0;
const files = ['src/app/App.tsx', 'src/app/Dashboard.tsx', 'src/components/ui.tsx'];
for (const file of files) {
  const previous = bindings(readFileSync(baseline + '/' + file, 'utf8'));
  const current = bindings(readFileSync(file, 'utf8'));
  assert.deepEqual(current, previous, file + ': interaction bindings changed');
  attributes += current.length;
}
console.log('CSS parsed; ' + tokens.size + ' custom properties resolve. No font imports.');
console.log('Static source comparison: ' + files.length + ' TSX files, ' + attributes + ' unchanged event, field and link attributes.');
JS
```

TypeScript and the Vite production build passed: 2,070 modules, 46.67 kB CSS.
The stylesheet parsed successfully with 35 defined custom properties and no
unresolved variable references. All 45 event, field and link attributes in the
three edited TSX files match the snapshot taken before this theme change.
This is a source comparison, not evidence of rendered behavior.

Executed from the repository root:

```sh
git diff --check
python3 - <<'PY'
from pathlib import Path
from xml.etree import ElementTree
icon = ElementTree.parse('web/public/favicon.svg')
html = Path('web/index.html').read_text()
assert Path('web/src/main.tsx').is_file()
assert 'href="/favicon.svg"' in html
assert 'content="#030805"' in html
print('Whitespace, SVG and HTML asset checks passed.')
PY
```

Whitespace, SVG parsing and HTML resource checks passed. No new unit tests were
added or run for this presentation change. No server logic, persistence schemas
or production data changed in this pass. No app or browser was launched or
operated; no GUI, Accessibility, keyboard/focus, screenshot or presentation
validation was run or required. Appearance in a running app remains unverified.
Earlier validation evidence remains unchanged.

## RAL filters and salary provenance — 2026-10-04

Jobs now accepts optional annual gross EUR bounds, extracts explicitly annual
declared pay, researches missing company/role pay against retrieved source
evidence, and converts supported foreign currencies with dated ECB rates.
Research runs before RAL filtering; unknown amounts remain visible only when
the salary filter is unrestricted. Preview cards, saved applications and
comparisons distinguish declared salaries from researched estimates.

Executed from `web/` during implementation:

```sh
npm run typecheck
./node_modules/.bin/tsx --test tests/jobs-salaries.test.ts tests/jobs-domain.test.ts tests/jobs-api.test.ts tests/jobs-client.test.ts
./node_modules/.bin/tsx --test tests/jobs-salaries.test.ts tests/jobs-api.test.ts tests/workspace-domain.test.ts tests/workspace-api.test.ts
```

TypeScript and the first 62 selected tests passed. The first expanded API/
workspace run passed 44 tests and failed one new integration test: its direct
`POST /workspace/jobs` fixture omitted the required `expectedRevision`, so the
API correctly returned 400 rather than the asserted 200. The fixture now reads
the current workspace revision and supplies it, as the actual client already
does. No production revision guard was weakened.

Final validation executed from `web/`:

```sh
npm run build
./node_modules/.bin/tsx --test tests/jobs-domain.test.ts tests/jobs-api.test.ts tests/jobs-client.test.ts tests/jobs-salaries.test.ts tests/workspace-domain.test.ts tests/workspace-api.test.ts
```

The TypeScript check and Vite production build passed (2,072 modules). All **80
selected non-GUI tests passed**, with zero failures, skips or cancellations.
Coverage includes optional/invalid/reversed bounds; inclusive salary overlap;
legacy persisted defaults; annual salary parsing across all adapters; rejection
of monthly/hourly, net, bonus, ambiguous and mixed-currency pay; missing-salary
discovery retention; evidence URL/quote/company/role/location checks; original
currency and ECB conversion provenance; research failures and cancellation;
filtering before ranking; and salary/source preservation in applications and
backup import/export. PI, salary pages and exchange-rate requests use isolated
fixtures in these tests; actual PI salary-search quality was not measured.

The ECB XML endpoint was also read once with `curl --fail --silent --show-error
--max-time 15 https://www.ecb.europa.eu/stats/eurofxref/eurofxref-daily.xml` to
confirm its documented structure and base-currency convention. No user data was
sent. `git diff --check` passed from the repository root.

No production database was changed and no app/browser was launched or operated.
GUI, Accessibility, keyboard/focus, screenshots and presentation checks were
neither run nor required. Historical evidence above remains unchanged.

## Concise controls and section colors — 2026-10-04

Removed shared page-subtitle and empty-state-description slots, unused module
slogans, lesson-card objectives, path introductions and repeated action copy.
Today, Learning, News, Jobs, Focus, Projects, Library and Settings use shorter
labels, icons and compact badges. Each module has a consistent accent across
navigation, widgets and weekly totals. Repeated icon controls retain names,
tooltips and state feedback. Match reasons, project descriptions, salary sources
and city-data attribution remain available in disclosures. Lesson material,
article excerpts, personal content and concise decision notices remain available.

Executed from `web/` with Node **25.8.2**:

```sh
npm run build
node /var/folders/lz/20cqfx4x2k98r89q68w3q3ch0000gn/T/kontrol-concise-ui-utliaa04/audit.mjs
```

TypeScript and the Vite production build passed (**2,073 modules**). The scratch
source audit compares the current TSX syntax trees against a snapshot taken
before this pass. It passed across **29 TSX files**, with **532 unchanged event,
state, link and field attributes**; the added filter-summary component contains
no interaction bindings. The same audit parsed the stylesheet and resolved all
**41 custom properties**. The audit script and starting snapshot are local
scratch evidence, not repository dependencies. An earlier inline audit also
passed its narrower selection of 447 attributes before the final refinements.

Executed from the repository root:

```sh
git diff --check
node --version
```

Whitespace checks passed. No new unit tests were added or run for this
presentation change. Existing work in progress was retained. No dependencies,
server logic, persistence schemas or production data changed in this pass.
Validation was limited to source review, static checks and compilation; no
app/browser, interactive journey, GUI, Accessibility, native keyboard/focus,
screenshot or presentation checks were run or required. Running-app appearance
remains unverified. Historical results above are unchanged.

## Restore Matrix theme with status accents — 2026-10-04

Restored the shared near-black/electric-green Matrix palette across every
section by removing module-level accent overrides. Blue is limited to
informational/progress badges, amber to warnings and red to errors/destructive
actions; success remains green. The concise copy, icons, disclosures and
controls from the preceding pass remain. The only TSX change is the AI
provenance badge's color tone.

Executed from `web/`:

```sh
npm run build
node --input-type=module <<'JS'
import assert from 'node:assert/strict';
import { readdirSync, readFileSync } from 'node:fs';
import postcss from 'postcss';
const css = postcss.parse(readFileSync('src/styles.css', 'utf8'));
const tokens = new Set(), references = new Set();
css.walkDecls(decl => {
  if (decl.prop.startsWith('--')) tokens.add(decl.prop);
  if (decl.prop.startsWith('--accent') || decl.prop === '--on-accent') assert.equal(decl.parent.selector, ':root');
  for (const match of decl.value.matchAll(/var\((--[\w-]+)/g)) references.add(match[1]);
});
assert.deepEqual([...references].filter(name => !tokens.has(name)), []);
assert(readFileSync('src/styles.css', 'utf8').includes('--accent: #63ff98;'));
const baseline = '/var/folders/lz/20cqfx4x2k98r89q68w3q3ch0000gn/T/kontrol-matrix-restore-rg5z73v2/src/';
const files = readdirSync('src', { recursive: true }).filter(file => /\.tsx?$/.test(file));
for (const file of files) {
  const previous = readFileSync(baseline + file, 'utf8');
  const expected = file === 'modules/news/articles.tsx' ? previous.replace('tone="violet"', 'tone="info"') : previous;
  assert.equal(readFileSync('src/' + file, 'utf8'), expected, file);
}
console.log(`Matrix accents are root-only; ${tokens.size} CSS properties resolve.`);
console.log(`${files.length} source files unchanged except the AI badge tone.`);
JS
```

TypeScript and the Vite production build passed (**2,073 modules**). The static
check passed: all **38 CSS properties** resolve, the shared accent has no
section overrides, and **39 TS/TSX files** match the starting snapshot except
for the intended badge tone. `git diff --check` passed from the repository root.
No unit tests were added or run for this styling correction. No production data,
server logic or schemas changed. No app/browser or interactive validation was
run; running-app appearance remains unverified. Historical evidence is retained.

## News dates, detailed interests and match percentages — 2026-10-05

Briefing, Discover, Saved and Feeds now group articles by publication day, newest
first, with local Today/Yesterday headings and unknown dates at the end. Article
cards show the closest enabled interest's estimated percentage and disclose
per-interest reasons. Standard scores measure title/excerpt keyword coverage
without a recency bonus; current AI matches use PI's estimate, with prompts
keeping publication age separate. Saved articles are compared with current
interests. Detailed profile interests can break publication-time ties in the
briefing without requiring an exact phrase in the headline.

New and edited search descriptions require at least five words, with a word
count and example in the editor. Boolean operators, exclusions and search
filters do not satisfy the word minimum. Japanese word segmentation supports
unspaced descriptions. Stored short interests and old backups remain readable
and exportable/importable; they can be paused, but need more detail before a
new search. No production database or credentials were accessed or modified.

Executed from `web/` with Node **25.8.2**:

```sh
npm run typecheck
node --import tsx --test tests/news-domain.test.ts tests/news-discovery.test.ts tests/news-ai.test.ts tests/news-api.test.ts tests/workspace-domain.test.ts tests/workspace-api.test.ts
npm run build
```

The first typecheck passed before the new tests were added. The first selected
test run passed **38** tests and failed **19** because the sandbox rejected
temporary loopback fixture listeners with `listen EPERM`. The same selected
non-GUI tests were then run with permission to bind those isolated listeners:
**57 passed**, no failures or skips. They passed again after adding the legacy
backup-import assertion and finishing the source changes. Network and PI
responses are injected fixtures; no live provider or running application was
driven.

The first build after adding tests found three TypeScript errors in test
fixtures (excess properties in two narrowed arguments and a nonexistent feed
preferences field). Those fixtures were corrected. The final TypeScript check
and Vite production build passed (**2,075 modules**). The new domain tests cover
publication dates across UTC offsets, daylight saving and year boundaries;
undated/invalid dates; chronology over old ranks; detailed interest validation;
full/partial/unrelated keyword coverage; required alternatives and exclusions;
and stale, paused or invalid AI estimates. HTTP tests cover short-query rejection,
pausing legacy interests, editing them into valid queries and backup compatibility.

`git diff --check` passed. Validation uses source review, compilation and selected
non-GUI domain, persistence and HTTP integration tests. No app/browser, GUI,
Accessibility, keyboard/focus, screenshot or presentation validation was run or
required. Running-app appearance remains unverified. Prior work in progress and
historical validation evidence were preserved.

## News search rejects valid articles and returns directories — 2026-10-05

Source review found two contributing paths: the legacy opportunities coverage
explicitly requested job-board directories, and AI acceptance checked required
concepts in the generated summary while ignoring retrieved descriptions and
article text. News now searches for individual reporting, articles, blog posts
and announcements for every coverage type. Career interests cover hiring and
industry reporting. Homepages, directories, product pages and job postings are
excluded using URL rules and retrieved page evidence. Existing career interests
need no data rewrite. Obvious old discovery homepages are hidden without changing
stored results or saved bookmarks.

Acceptance now checks required concepts and exclusions against source titles,
descriptions and up to 10,000 characters of article text, omitting navigation,
sidebars and footers. A short AI summary can omit a source keyword; its invented
keywords cannot make an unrelated source pass. Regular English word forms are
recognized. Structured article metadata referring to another URL is ignored.
Citation matching normalizes query parameter order while preserving meaningful
parameter values. All-rejected answers identify citation, page type, publication
window, score or keyword failures and still retain prior results. Fallback web
RSS links require fetched article evidence instead of relying on index timestamps.
Descriptions such as the supplied Java/Kotlin/Backend query remove the literal
request to exclude job offers and separate adjacent Boolean groups.

Executed from `web/` with Node **25.8.2**:

```sh
npm run typecheck
node --import tsx --test tests/news-ai.test.ts tests/news-domain.test.ts
node --import tsx --test tests/news-domain.test.ts tests/news-discovery.test.ts tests/news-ai.test.ts tests/news-api.test.ts tests/news-pi.test.ts tests/workspace-domain.test.ts tests/workspace-api.test.ts
npm run build
git diff --check
```

The first typecheck identified a fixture missing the new required source-kind
field; the fixture was corrected and subsequent TypeScript checks passed. Two
focused runs had **22/23** and **31/32** passes: one fixture used `/job` for a
supposed article, and another represented a successful empty index using an
invalid empty RSS channel. Those fixtures were corrected while preserving the
transport and date assertions. The corrected focused run passed **32/32**.

The first expanded selection passed **75/77**. Two existing regressions exposed
an overly broad URL rule classifying the individual `/release` permalink as a
directory. The rule was narrowed while retaining the existing tests; a further
regression was added for vacancy content disguised as article metadata. The
final expanded selection passed **78/78**, with no failures or skips. Loopback
HTTP tests ran with permission for temporary isolated fixture listeners. PI
process tests use temporary configuration and fixture executables; network and
search results are injected. No live PI/provider search, personal credentials
or production database was accessed.

Regression coverage includes the supplied Japan programming/career interest,
Japan Dev homepage rejection with specific blog-article acceptance, vacancy
rejection, short-summary omissions, source-grounded keyword checks, article
metadata isolation, fallback freshness, citation parameter order, actionable
error reasons, old-cache visibility and HTTP retention of valid prior articles.
The final TypeScript check and Vite production build passed (**2,075 modules**),
and whitespace checks passed. Validation remained non-interactive: no app/browser
launch, GUI journey, screenshot, Accessibility, keyboard/focus or presentation
checks were run or required. Running-app and live-search behavior remain
unverified; earlier results and work in progress were preserved.

## News search page retrieval and fallback — 2026-10-05

A News AI search for **AI models & releases** returned zero results with
“PI found sources, but their pages could not be retrieved. Saved results are
retained; try again. Saved results are retained.” Source review found three
causes. First, cited article pages were fetched with the RSS transport profile:
a non-browser `Kontrol-Web/0.2` agent, no language header, three redirects, and
rejection of bodies over 2 MB. Second, when every cited page failed, the run
ended with an error even when the news index had matching dated stories. Third,
the Discover page appended the retained-results notice a second time, and the
message did not explain why retrieval failed.

Behavior changes:
- **Page requests:** News AI page reads (hosted-search citations and Bing
  wider-web results) use a browser-compatible `Mozilla/5.0` agent, an HTML
  `Accept` header and an `Accept-Language` matching the interest. They follow up
  to five redirects and truncate pages over 2 MB instead of rejecting them.
  Feeds, Standard search and Jobs keep `Kontrol-Web/0.2`, three redirects and
  reject-on-oversize. Public-IP pinning and URL, port, timeout and concurrency
  limits are unchanged.
- **Failure reasons:** Each failed page is counted in a fixed category (blocked
  automated access, rate-limited, timed out, HTTP error, verification or
  unreadable page, could not be reached). Messages never include raw error text.
- **News-index fallback:** This runs only when every cited page fails. Kontrol
  ranks Google News RSS snippets in one further PI inference, validated by the
  existing evidence rules. If it yields articles, the run succeeds with
  `mode: 'ai'`. If it finds nothing, fails or times out, the run fails with the
  retrieval reasons and “The news-index fallback found no usable articles”, and
  saved results are kept. Other failures never use the fallback.
- **Deadlines:** The shared AI discovery deadline is now 90 s (was 60 s). The
  client `/news/discover` timeout is 570,000 ms (was 390,000 ms).
- **Error text:** Discover shows the retained-results notice only once.

Executed from `web/` with Node **25.8.2**:

```sh
npm run typecheck
node --import tsx --test tests/domain.test.ts tests/api.test.ts tests/projects-persistence.test.ts tests/news-discovery.test.ts tests/news-domain.test.ts tests/news-ai.test.ts tests/news-api.test.ts tests/news-pi.test.ts tests/news-pi-cli.test.ts tests/jobs-domain.test.ts tests/jobs-api.test.ts tests/jobs-client.test.ts tests/jobs-salaries.test.ts tests/workspace-domain.test.ts tests/workspace-api.test.ts
KONTROL_TEST_PI_COMMAND=/opt/homebrew/bin/pi node --import tsx --test tests/news-pi-cli.test.ts
npm run build
```

From the repository root: `git diff --check`.

- **Typecheck:** passed.
- **Full selected suite** (the explicit non-GUI list in `package.json`):
  **186 tests, 184 passed, 0 failed, 2 skipped**. The two skipped tests are the
  installed-PI fixture tests, which need `KONTROL_TEST_PI_COMMAND`. No
  `listen EPERM` occurred, so no second run was needed for loopback permission.
- **Installed-PI fixture tests**, run separately with the variable set:
  **2 passed, 0 failed, 0 skipped**. They use temporary PI configuration and
  loopback provider fixtures.
- **Production build:** the TypeScript check and Vite build passed
  (**2,075 modules**).
- **`git diff --check`:** passed for the working tree and for the feature
  commits against their baseline.

New and updated tests cover:
- request headers for the page profile and the transport defaults;
- the body collector on plain and gzip streams (under the limit, truncated,
  rejected, wire limit, cut-off multi-byte character);
- page options received by the hosted and Bing fetchers;
- ordered failure summaries without raw text;
- fallback success, empty, throwing and deadline cases;
- no fallback for provider, evidence, format or validation failures, or for
  partial retrieval;
- news-index-only sources;
- HTTP retention and fallback replacement;
- the 570,000 ms client deadline;
- the single retained-results notice.

Optional live adapter diagnostics were run non-interactively from `web/`. They
used the configured PI default model and the network, and called `aiDiscovery`
directly with fresh fixture interest IDs. Nothing was persisted, and the app was
not launched.
- **Unmodified preset run:** this used real hosted search and real page reads.
  It finished in **25,692 ms** with **36 provider-evidence URLs** and **4
  proposed** results. Three page reads were still blocked with HTTP 403 (two
  apnews.com, one axios.com). One TechRadar page (1.88 MB) was retrieved. Partial
  retrieval succeeded without the fallback, accepting **1 article** dated
  2026-09-29.
- **Forced fallback run:** hosted search was replaced by one synthetic citation
  whose page read was forced to fail with HTTP 403. The real Google News RSS
  index supplied **30 sources**, and one real PI ranking call accepted **3
  articles** with `mode: 'ai'` (dated 2026-09-28 to 2026-09-30). It finished in
  **39,250 ms**, with one fallback call and one PI call.

These are single live samples. Publisher blocking and index coverage vary, so a
search can still end in the documented retrieval error. The 2 MB truncation path
was covered by unit tests only, not by a live page.

No test runner, watcher, dev server or loopback fixture was left running. The
tests and diagnostics ran in the foreground, and PI child processes ended with
their commands. No GUI, app/browser launch, Accessibility, keyboard/focus,
screenshot or presentation checks were run or required. No production database,
application data or stored credentials were read or modified. Kontrol never
reads PI credentials; the live diagnostics used PI's own login. Earlier
validation entries remain unchanged.
