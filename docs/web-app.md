# Kontrol Web

Kontrol is a local, modular web dashboard built with React, TypeScript,
Node/Express and SQLite. The web app is the repository's only application.
The retired macOS implementation's validation records are preserved in the
[native archive](archive/native/README.md).

## Run on your Mac

Install Node 22.13 or later, then run from the repository root:

    cd web
    npm ci
    npm run dev

Open http://127.0.0.1:4310. The API and frontend share that exact origin, so
there is one process and one port. The server prints the address but never
launches a browser. Keep the process running while using the dashboard.

For the production frontend:

    cd web
    npm run build
    npm start

The server reads its bundled learning catalog and default feeds from
[web/resources](../web/resources). Include that directory alongside `server/`,
`shared/` and the built `dist/` assets when copying the application. The frontend
requires no external fonts, images or CDN. Core modules work without internet
access while the local service is running. News refresh is an explicit network
operation; article links open the original website.

KONTROL_PORT changes the listening port. KONTROL_DATA_DIR sets an absolute
directory for an independent database:

    KONTROL_PORT=4311 KONTROL_DATA_DIR=/tmp/kontrol-web-scratch npm run dev

The default is web/.data/kontrol.sqlite, ignored by Git. Keep its WAL/SHM
sidecars together with the database. Do not remove .data to troubleshoot a
failed open. Unsupported future schema versions and corrupt included records
are not automatically reset. When keeping a database-file backup, stop the local
server first and copy the whole data directory.

## Dashboard and modules

The Overview page shows actual counts and independent widgets; it seeds no
personal tasks, sessions or project references. **Customize** lets you show/hide,
move earlier/later, and select half/full width for each widget. Layout changes
save in SQLite. Hiding a widget leaves its full page and data available.

| Module | Implemented web behavior |
| --- | --- |
| Tasks | Today/overdue, open, unplanned and completed filters; search; quick capture; notes, planned date and due time; edit, complete/reopen and confirmed deletion. |
| Planner | Date navigation, add/edit/remove time blocks, lesson links, explicit overlap approval, half-open interval comparison. |
| Focus | Custom duration and presets, optional task link, one active session, pause/resume/end, bounded completion, history, restart reconciliation and backward-clock recovery. Completion leaves the linked record unchanged. |
| Learning | The 40 existing offline lessons, four persistent choices per topic, all four content formats, pinned attempts, saved responses, solution reveal/self-check, completion, dismissal/restore, history and practiced-concept coverage. |
| Projects | Explicit absolute-path connection to local .kontrol folders, manifests, roadmap/context/rules, deterministic next-three feature selection, validated frontmatter completion and revision-checked Undo, reference-only disconnection. |
| News | Specific saved interests, cross-publisher search, optional AI web search with cited sources and match explanations, language/region/recency/keyword filters, bounded offline cache, and optional RSS/Atom subscriptions. |
| JOB | PDF/DOCX/TXT CV upload, PI profile analysis and editable review, independent work-arrangement/employment filters, offline worldwide city search, retrieved job offers ranked by fit with source links and gaps, persisted profile and matches. |
| Settings | Focus/text/motion defaults, data export, web backup restore and legacy macOS export import. |

Responses autosave after a short delay and on module navigation. Pending drafts
are also retained in browser storage, namespaced by the database instance.
Revision conflicts preserve the local draft and offer review of the currently
saved response before choosing a version. Export includes server-saved answers,
not an unsaved browser draft; wait for **Saved** before exporting.

The dark theme uses brighter coral accents, lighter graphite panels, and clearer
text and border colors. The layout adapts to narrow windows. Controls retain
visible focus styling, names, standard
keyboard semantics, large text and reduced-motion support; these features are
implemented without reinstating interactive validation gates.

## Move existing data

1. Use a previously saved version-1 JSON export from the former macOS app or a
   Kontrol web backup. Legacy SwiftData files cannot be imported directly.
2. Start the web app with a fresh data directory and open **Settings → Import
   JSON**. Choose the export, review its record counts, then import.
3. Connect project folders separately in Projects. Legacy sandbox bookmarks,
   credentials, paths and external project contents are absent from the macOS
   export and cannot be transferred through it.

The importer accepts native export schema version 1 or a version-1/version-2/version-3
kontrol-web backup envelope. New web exports use version 3 to include JOB
alongside news interests; version 1 and native imports retain current interests,
and older formats retain the current empty JOB state. Legacy six-widget layouts
gain JOB without changing existing widget order, visibility or width. Every
included module is validated before an
atomic SQLite transaction. Saved authored text, answers, content pins,
historical snapshots, generated lesson definitions and nonsecret configuration
are retained. Only an entirely empty curriculum gets the bundled definitions.
No current definition is substituted for missing historical lesson content.

Import requires a database without personal tasks, blocks, Focus sessions,
started/terminal learning progress, attempts, or a saved CV, and allows one import per
database. It fails rather than merging ambiguously or overwriting existing
work. Use a separate KONTROL_DATA_DIR to restore a backup alongside current
work. The web backup includes dashboard layout, news interests, extracted CV text,
reviewed job profile, job preferences and cached matches; native exports do not. Web
exports exclude project references/paths, external files, browser drafts,
news article caches and credentials. They contain unencrypted personal content,
including the full extracted CV. Original PDF/DOCX/TXT file bytes are not retained.

Current import limits are a 16 MB document, Gregorian/ISO planned dates, at most
four slots per topic, and a Focus preference of 1–1,440 minutes. Incompatible
exports fail as a whole; no records are silently dropped. Old records without
pinned lesson content remain readable as saved answers/history; they do not
become invented completed snapshots.

## Specific news interests

Open **News → Discover**. The initial interests are **Programming jobs in Japan**
and **AI models & releases**. Add or edit up to 12 interests with a specific query,
news/opportunities intent, English or Japanese, a search region, and a 1-, 7- or
30-day publication window. Advanced filters require every keyword group, accept
alternatives within a group separated by a vertical bar, and exclude phrases.
Change those keywords when changing the query or language.

**Standard search** needs no key. It queries Google News RSS across publishers,
then applies keyword groups, exclusions, freshness and a relevance/recency rank
locally. It is a news index, so a very specific job search may legitimately return
no matches. Zero matches are distinct from a failed fetch; neither is padded
with unrelated headlines. Links from this provider use Google News redirects to
the publisher. Search depends on the availability and coverage of that index.

**AI search** uses your local **PI** installation and its saved provider/model.
Kontrol retrieves current search results from Google News RSS and Bing web-search
RSS, then asks PI to rank those sources, summarize their snippets and explain each
match. This supports general web results, including job pages, as well as news.
Coverage depends on those search indexes; a precise query can return no matches.
PI does not browse full articles. Returned URLs must occur in the retrieved source
list; invented links, weak scores, excluded phrases and dates outside the selected
window are rejected. Source titles and publication dates come from the search
results, never the model. General web-search timestamps are treated as unknown
publication dates. Unknown dates remain labeled, and job availability still needs
source review.

Install **PI 1.0 or later** and configure it in your terminal. In PI, use **/login**
to sign in to your provider and **/model** to choose a model; save it as the default
with **Ctrl+S**. News uses that default automatically. **News → PI connection**
shows the configured model and can refresh after configuration changes. “PI
available” confirms the executable and settings are accessible; login and model
access are checked on the first search. Kontrol does not read PI's credential
file, collect API keys or copy credentials into SQLite, the browser or exports.
PI continues to manage its own credentials, including OAuth refresh when needed.

Optional overrides can be placed in the ignored **web/.env** (copy
**web/.env.example**) or the server environment:

- **PI_NEWS_COMMAND** — PI executable path when `pi` is not on the server's PATH.
- **PI_CODING_AGENT_DIR** — PI configuration directory; defaults to ~/.pi/agent.
- **PI_NEWS_PROVIDER** and **PI_NEWS_MODEL** — explicit provider/model pair instead
  of PI's saved default. PI_NEWS_MODEL also accepts a provider/model identifier.

Changes to .env require a server restart. OPENAI_NEWS_MODEL and Kontrol's former
OpenAI-key connection are no longer used. Provider environment credentials can
still be used by PI itself. Do not prefix credentials with VITE_.

Searches run only on request, with at most one PI inference per selected, enabled
interest, two concurrent interests and a shared one-minute search/inference
deadline. No inference is made for an empty source list. Automatic provider and
agent retries are disabled for this invocation. Your configured PI provider's
usage limits and billing apply. Only the interest, filters, date window and
retrieved title/URL/snippet/date fields enter the request. PI runs in a temporary
working directory with tools, extensions, skills, context files and prompt
templates disabled, and no saved session. Its temporary settings are removed
when the process exits, including failure or cancellation. This integration uses
PI's built-in providers and models.json; extension-defined providers are not loaded.
The dashboard widget's **Standard search** action never invokes PI.

A successful search replaces that interest's previous matches, deduplicating
canonical URLs across interests; errors preserve saved results. Edited, paused,
deleted or imported interests invalidate in-flight replies through revision
checks. Search cache and run state use a separate newsDiscovery document, so
adding discovery leaves existing feeds/articles intact. The cache is capped at
500 results and 30 days, with the chosen interest window applied for display.
Unknown dates use first discovery time for retention, not an invented publication
date. **Saved feeds** retains the existing subscriptions and manual refresh.

The news implementation is split into server/news/transport.ts (bounded public
HTTP fetch), feeds.ts (RSS/Atom parsing), discovery.ts (standard search and merge),
ai.ts (live source retrieval and citation acceptance), pi.ts (isolated PI runner
and connection status), and server/modules/news.ts
(HTTP routes and persistence). UI components for interests, connection, discovery,
articles, feeds and the dashboard widget live under src/modules/news/.

## JOB: CV to matching offers

1. Open **JOB** and upload a **PDF, DOCX or UTF-8 TXT** CV (up to 5 MB,
   PDF up to 25 pages, extracted text up to 60,000 characters). Extraction uses
   local PDF.js/Mammoth parsers; scanned PDFs need OCR before upload. Invalid,
   unreadable and oversized files leave the previous CV intact.
2. Select **Remote / Hybrid / Office**, then optional **Full-time / Part-time /
   Contract / Freelance / Internship** filters. Employment type is independent
   of where the work happens. Pick up to five cities and a 7/30/90-day window;
   choose **Save preferences**. No cities means any location, and no employment
   types means any type. A work arrangement must be selected.
3. Choose **Analyze CV** to send extracted text to the provider configured in
   PI. Review the headline, summary, suggested roles, skills, experience and
   languages. Analysis can take up to two minutes. The profile selects up to
   five target roles and 30 primary skills; edit errors and **Confirm profile**
   before searching.
4. Choose **Find matching jobs**. Each result shows a source title, company,
   location and employment metadata, estimated fit, specific match reasons,
   gaps/uncertainties, and a link to the original offer. No applications are sent.

Use **Minimize / Expand** on **Your CV** and **Search filters** to make more room
for offers. Each panel remembers its own choice in this browser. Without a saved
choice, panels start open during setup and minimized on later visits once the
profile is confirmed. Minimized panels show the CV name/profile status or current
filters; filter drafts stay intact and unsaved changes remain flagged. Upload,
analysis and preference-save errors stay visible even when their panel is closed.

City lookup runs entirely on the server against the bundled `cities.json`
GeoNames catalog, including towns above 1,000 population and administrative
seats. It supports accent-insensitive search and optional country/state
qualifiers, such as `Tokyo, Japan`, `Berlin, DE`, or `Paris, Texas`. Only matching
city records reach the browser; the catalog is not part of the frontend bundle.
Attribution is shown in the city picker. City and profile review work offline.

Search uses up to two reviewed role titles per selected city (at most ten Bing
queries), bounded direct page retrieval, the latest 100 Remotive remote postings,
and up to 500 Arbeitnow postings. Only single structured `JobPosting` records
are accepted from web pages; general search snippets and news articles cannot
become offers. Direct job-board records provide an additional source, with
Arbeitnow focused mainly on Germany. Source URLs and metadata come from retrieved
records, never from the model. Provider and page failures are reported separately
from an empty successful search, and no inference runs for an empty candidate list.

Office/hybrid city matching requires both city and country evidence. Ambiguous
Arbeitnow locations get a bounded attempt to read their structured posting;
missing countries are not guessed. Remote listings must explicitly cover a
selected country or worldwide work when cities are selected. This checks source
geography, not visa or work authorization. With a specific employment or work
arrangement filter, unstated values are excluded; selecting all arrangements
also permits listings marked unknown. Known expired, future-dated and old listings
are excluded; unknown posting dates remain clearly labeled.

The server passes at most 30 filtered candidates, a bounded description excerpt,
the reviewed profile and preferences to PI. It accepts only exact retrieved
source IDs and scores of at least 60, rechecks filters, deduplicates links and
retains at most 20 matches. Scores estimate fit, not hiring probability.
Coverage is limited by the sources, their geographic coverage, page availability
and structured metadata. Check current availability and eligibility on the source.
Remotive's API is delayed by 24 hours; its response is cached for six hours,
Arbeitnow's for ten minutes, within the running server process.

JOB reuses News's PI executable/model/login configuration and `PI_NEWS_*`
overrides. It uses a dedicated job-analysis system prompt with the same isolated,
tool-free, session-free runner. Upload and city search make no AI request. Only
**Analyze CV** sends CV text; **Find matching jobs** sends the reviewed profile
and source descriptions to PI and role/location/filter queries to Bing. Inference
uses the configured provider's usage limits or billing. No CV is sent to a job
board, recruiter or employer. Do not put contact details into reviewed profile
fields if you do not want those fields included in matching requests.

One JOB upload/analysis/search can run at a time. Analysis has a 120-second limit;
search has a 110-second shared limit, including bounded source retrieval and at
most one PI ranking invocation. Mutations compare revisions. A changed CV,
profile or preference set clears stale matches. Failed requests retain previous
data, and deletion cancels an in-flight request and prevents late results from
restoring removed data. Saved matches can be read without a network. Remove CV
deletes the module's saved CV text, profile and matches, retaining preferences;
the original file and prior exported backups are unchanged.

The analysis prompt includes the profile's exact JSON schema and field limits.
If PI still returns extra roles, skills or languages, the adapter retains the
first distinct entries in the requested relevance order within the editor's
limits. Other malformed fields fail with an answer-format error; they no longer
incorrectly imply that the CV lacks experience or skills. Stored profiles and
manual edits retain the same strict validation.

The connection label means PI is locally available; model access is checked by
an analysis/search request. Browser status and city requests have 15-second
deadlines. Analysis/search requests allow five seconds beyond the server's
deadline for the response. Completed commands update the profile and release
their busy state immediately, without waiting for a background status refresh.

Source references: [Remotive API](https://github.com/remotive-com/remote-jobs-api),
[Arbeitnow API terms](https://www.arbeitnow.com/terms),
[JobPosting vocabulary](https://schema.org/JobPosting),
[cities.json / GeoNames](https://github.com/lutangar/cities.json),
[PDF.js Node extraction](https://github.com/mozilla/pdf.js/blob/master/examples/node/getinfo.mjs),
and [Mammoth raw text extraction](https://github.com/mwilliamson/mammoth.js#extractrawtext).

## Architecture and extension

    web/
      src/app/                  shell, dashboard, module manifest
      src/modules/<feature>/    page/widget components and module query hook
      src/components/           small shared display and control components
      src/lib/                  same-origin API client and query invalidation
      shared/                   schemas, DTOs, date/interval helpers
      server/modules/           independently registered feature APIs
      server/store.ts           SQLite document adapter and transaction boundary
      server/app.ts             API composition and loopback/origin boundary
      server/index.ts           local server, Vite development or production assets
      resources/                bundled learning catalog and default feed catalog
      tests/                    isolated non-GUI domain/persistence/API tests

src/app/modules.ts is the frontend registration point. A module supplies its
ID, navigation label/icon, page and widget. Page and widget share the same query
cache and API; the dashboard has no second copy of feature state. Module
components are loaded in separate frontend chunks and have error boundaries.
Shared query hooks are separate from component entry points to avoid pulling
entire module UIs into the shell.

To add a module:

1. Define its validated DTOs and widget ID/default layout in shared/schema.ts.
2. Implement a router under server/modules and register it in server/app.ts.
   Use a module-owned SQLite document and synchronous transactions for mutations.
3. Add its query hook, page and widget under src/modules, then register them
   in src/app/modules.ts.
4. Add a layout migration when changing the set of required widget IDs. Existing
   layouts must retain the user's order, visibility and width.
5. Add focused non-GUI tests for new persistence/IO/domain behavior, then build.

The server binds to 127.0.0.1, checks the exact Host and Origin, and requires a
custom same-origin API header. It has no remote authentication and must not be
exposed through a public tunnel. Feed fetching validates public DNS addresses
and pins the checked address, rejects XML DTDs/entities, caps response sizes and
concurrency, and preserves cached content after per-feed failures.

Project access is limited to explicitly connected canonical roots. Nested
symlinks and traversal are rejected. Feature writes preserve unrelated YAML,
comments, Markdown and line endings. They compare digests immediately before
an atomic sibling-file replacement and verify afterwards; Undo requires the
exact post-write revision. These checks do not lock arbitrary external editors
through the final filesystem rename. Disconnect only deletes the saved local
reference.

See the [project format](project-format.md) and [example project](examples/.kontrol/project.yaml)
for the supported `.kontrol` files.

## Scope and limits

- Creating new AI lessons is not supported. Imported generated lessons and
  nonsecret AI settings are retained. News and JOB AI use PI as described above.
- The web app runs locally, with no cloud sync, accounts or remote access.
- Project connection uses an absolute-path field; symbolic links inside
  `.kontrol` are conservatively rejected.
- News refresh is manual. HTTP validator caching, retry-after scheduling and
  automatic background refresh are not implemented.
- There are no background notifications, PWA/service worker or macOS package.

## Validation

The root `make build` command checks TypeScript and builds the frontend.
`web/package.json` explicitly lists the non-GUI domain, persistence, transport
and HTTP test files used by `make test`. Inspect that selection before running
it; tests use isolated fixtures, not the production database. The installed PI
CLI test is opt-in through `KONTROL_TEST_PI_COMMAND` and uses a local fixture
provider with temporary configuration.

See [AGENTS.md](../AGENTS.md) for the governing non-interactive policy and
[validation history](validation.md) for exact commands, results and known
limitations. No browser or native application needs to be opened for validation.
