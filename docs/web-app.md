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

The Today page opens with a feature showing an actual next step:
the oldest due application follow-up, a due recall review, or the next lesson.
When those are unavailable it highlights a briefing story or an unsaved,
unexpired job match, then falls back to learning paths. **Overview** keeps
Learning, News and Jobs reachable with content previews, reading counts, lesson
time or due-work counts. Unavailable counts use a dash. The widgets below provide
more detail. It seeds no personal activity. **Customize** lets you show/hide,
move earlier/later, and select half/full width for each widget. Layout changes
save in SQLite. Hiding a widget leaves its full page and data available.

The primary navigation is **Today, Learning, News, Jobs**. Library, Focus
and Projects remain available as utilities; a compact Focus timer can be opened
from any page. New workspaces start with Learning, News and Jobs widgets.
Existing layouts are retained. **Customize → Balanced / Learning / Job search**
previews a preset; **Save layout** applies it and Cancel discards the preview.

**Settings → Goals & interests** stores a goal, preferred learning topics,
target roles, interests, a learning path, a weekly lesson target and up to three
world clocks. Interests and target roles prioritize the briefing. Target roles
can be copied into the CV review form before confirmation; confirming that form
also updates the shared target roles. Changing workspace goals alone does not
silently alter a reviewed CV profile or run a new search.

Today includes quick notes and links, configured world clocks and a weekly review. The
review uses the current browser time zone and a Monday week boundary, showing
completed lessons, recall reviews, saved stories and application stage changes.
Due application follow-ups are surfaced on Today; they do not schedule background
notifications or send messages. Weekly totals stay visible, with the activity
list under **Activity**. The Matrix theme uses a near-black canvas, electric
green actions and accents, monospace headings, square panels and a static grid.
Every section shares this palette, including navigation, widgets and weekly
totals. Other colors are reserved for meaningful information and status:
blue for informational badges and application progress, amber for warnings,
and red for errors or destructive actions. Success stays green. Text and symbols
identify each state as well. Fonts are local system fonts.

Pages use a title and relevant actions without slogans or app-usage paragraphs.
Page headers do not accept subtitles. Today displays a saved personal goal as
user content. Empty states use an icon, brief status and an action where needed.
Use short labels for primary actions and named icon buttons with tooltips for
repeated save, read, edit, remove and close actions. Filter summaries use chips;
match reasons, salary sources and project descriptions use expandable details.
Apply this pattern to new features as well. Setup walkthroughs,
search-method explanations and promotional panels are omitted from the interface;
configuration and source details remain in this guide. Field formats, content
provenance, errors, and concise notices about data transfer, provider billing and
destructive actions remain where they affect a decision. Lesson explanations,
exercises, source excerpts and personal notes are content and remain available.

| Module | Implemented web behavior |
| --- | --- |
| Focus | Custom duration and presets, one active session, pause/resume/end, bounded completion, history, restart reconciliation and backward-clock recovery. |
| Learning | Forty offline lessons, four persistent choices per topic, pinned answers, self-checks, goal-based paths, mini-project prompts, saved lessons and recall reviews. |
| Projects | Explicit absolute-path connection to local .kontrol folders, manifests, roadmap/context/rules, deterministic next-three feature selection, validated frontmatter completion and revision-checked Undo, reference-only disconnection. |
| News | A finite briefing, related coverage, read status, persistent bookmarks and notes, specific interests, cross-publisher search, optional AI selection and RSS/Atom subscriptions. |
| Jobs | CV analysis and matching plus saved applications, manual job links, stages, notes, follow-up dates, comparisons and optional learning suggestions. |
| Settings | Focus/text/motion defaults, data export, web backup restore and legacy macOS export import. |

### Learning paths and recall

Learning includes Go backend interviews, Java backend skills and System Design
paths assembled from existing catalog objectives. A followed path and preferred
topics inform the next-lesson suggestion; an already-started lesson takes priority.
Each path has a mini-project brief that can be saved as a practice project in the
library, with notes and an optional implementation link. No code is run or graded.

Completed lessons with their full original content pinned become due for recall
after one day. Reviews save separate responses and self-assessments: Again sets
one day, Okay three days, and Confident spaces reviews from seven up to thirty
days. Original answers and completion records are untouched. Historical records
without full pinned content remain viewable but are not replaced by current
catalog content to manufacture a review. Neither completion nor recall is a
mastery score. Lesson bookmarks are searchable in Saved library.

### Briefing and saved reading

News opens on a briefing of up to five stories from the latest searches and
enabled feeds. Briefing, Discover, Saved and Feeds group articles by publication
day, newest first. Headings show **Today**, **Yesterday** and dated groups in
the browser's local time zone; unknown publication dates stay in **Undated** at
the end rather than taking the retrieval date. It does not fetch automatically.
Similar dated headlines are grouped conservatively as related coverage; grouping is heuristic, not a verified
event identity. Source dates remain visible, including unknown dates. AI text is
labeled as an interpretation of retrieved snippets, including after bookmarking.
Kontrol does not retrieve full articles for the briefing.

The Today widget previews the first three stories and links to the full briefing.
The lead story receives a larger headline and a labeled excerpt; numbered story
cards show read status. Article cards show a **0–100% match** estimate for their
closest enabled news interest, with the interest name on full cards. Selecting
one interest in Discover limits the percentage to that interest. Full article
cards show each interest's percentage, reason and estimate method under
**Interest matches**. Related coverage, reading notes and save/read actions
remain available.
In Discover, **Manage** expands the saved interest cards; search controls
and results remain visible when those cards are collapsed. Source excerpts and
AI snippet summaries keep distinct labels.

The bookmark, read/unread and notes buttons work on both discovery
and feed articles. Bookmarks copy the title, excerpt, source, original link and
dates into the workspace so cache refreshes or interest/feed deletion cannot
remove saved reading. Reading notes also bookmark a story. If it is later
unbookmarked, its authored notes are still searchable in Saved library. Links
to Learning suggest existing lessons and explicitly report missing coverage.

### Applications and preparation

Save retrieved offers or use **Jobs → Applications → Add job**,
which works without a CV or PI. Saved offers retain their source snapshot
even after another search, changed filters, or CV removal. Manually entered links
are saved without fetching or submitting anything. Check original listings for
current availability.

Applications move through Saved, Applied, Interviewing, Offer and Archived.
Their notes, stage history and calendar follow-up dates persist. The due filter
includes today and overdue dates, excluding Offer and Archived. Select two or
three opportunities to compare their source details side by side.

Preparation identifies supported topic names mentioned in a saved listing. Users
confirm experience or choose **I want to practice this** before seeing lesson
suggestions. Missing CV information is not treated as a skill deficiency. Topics
without suitable catalog content say so; completing a lesson never changes an
estimated fit score or claims professional proficiency.

### Saved library and persistence

Saved library searches articles and reading notes, lesson titles/content, saved
offers and application notes, quick notes, pinned links and practice projects.
Forms keep their current drafts after rejected saves, and conflicting edits
offer the currently saved content for review before another save.

Workspace records use their own validated SQLite document and are separate from
News and Jobs search caches. Capacity is bounded to 1,000 article records, 500
applications, 1,000 notes, 1,000 lesson bookmarks and 1,000 review records, with an
8 MB workspace limit. Each review and application history allows 1,000 entries.
Only unbookmarked article records without notes may be evicted when space is
needed; explicit bookmarks and authored content are never silently discarded.
Other capacity violations reject the entire write.

Responses autosave after a short delay and on module navigation. Pending drafts
are also retained in browser storage, namespaced by the database instance.
Revision conflicts preserve the local draft and offer review of the currently
saved response before choosing a version. Export includes server-saved answers,
not an unsaved browser draft; wait for **Saved** before exporting.

The Matrix theme uses a shared green accent, prominent headlines, and quieter
secondary controls. Lesson cards surface titles, difficulty and duration;
job cards pair estimated fit with expandable **Match details**. Shared text sizes keep nested badges and metadata
readable; **Text size → Large** scales those sizes along with body copy. Reading text
has a bounded line length, and the layout adapts to narrow windows. Controls retain
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

The importer accepts native export schema version 1 or a version-1 through version-5
kontrol-web backup envelope. New web exports use version 5 with the five-module
dashboard layout, Jobs, news interests and the saved workspace. Versions 1–4
remain accepted; version 5 additionally preserves goals, bookmarks, notes,
applications and reviews. Version 1 and native imports retain
current interests, and formats before version 3 retain the current empty Jobs state.
Existing layouts and older backups drop the retired Tasks and Planner widgets;
six-widget layouts also gain Jobs. The remaining widgets keep their order,
visibility and width. Saved Tasks and Planner records are retained for backup
compatibility, and historical Focus titles and links remain intact. These retired
sections have no pages, widgets or API routes. Every included record is validated before an
atomic SQLite transaction. Saved authored text, answers, content pins,
historical snapshots, generated lesson definitions and nonsecret configuration
are retained. Only an entirely empty curriculum gets the bundled definitions.
No current definition is substituted for missing historical lesson content.

Import requires a database without archived tasks or blocks, Focus sessions,
started/terminal learning progress, attempts, a saved CV, or saved workspace content, and allows one import per
database. It fails rather than merging ambiguously or overwriting existing
work. Use a separate KONTROL_DATA_DIR to restore a backup alongside current
work. The web backup includes the saved workspace, dashboard layout, news interests, extracted CV text,
reviewed job profile, job preferences and cached matches; native exports do not. Web
exports exclude project references/paths, external files, browser drafts,
news article caches and credentials. They contain unencrypted personal content,
including the full extracted CV. Original PDF/DOCX/TXT file bytes are not retained.

JSON export and import share a 64 MB UTF-8 document limit, including download
formatting. Export checks the complete file before offering it for download.
For larger workspaces, stop Kontrol and copy the full data directory (including
any SQLite WAL/SHM sidecars) as a database backup; export explains this instead
of producing a file that cannot be restored. Other import limits are Gregorian/ISO planned dates, at most
four slots per topic, and a Focus preference of 1–1,440 minutes. Incompatible
exports fail as a whole; no records are silently dropped. Old records without
pinned lesson content remain readable as saved answers/history; they do not
become invented completed snapshots.

## Specific news interests

Open **News → Discover**. The initial interests are **Programming jobs in Japan**
and **AI models & releases**. Add or edit up to 12 interests with a search
description of **at least five words**, such as **Java and Kotlin backend hiring
trends in Japan**. The editor shows a word count; Boolean operators,
excluded phrases and search filters such as `site:` do not count toward the
minimum. Japanese descriptions use word segmentation, including text without
spaces. Short existing interests and backups stay readable; expand their
descriptions or pause those interests before running another search. Choose the
**News & announcements** or **Career & industry news** coverage, English or
Japanese, a search region, and a 1-, 7- or
30-day publication window. Advanced filters require every keyword group, accept
alternatives within a group separated by a vertical bar, and exclude phrases.
Change those keywords when changing the query or language.

Every News interest searches for individual articles, reporting, blog posts and
announcements. Career topics cover hiring trends, the developer job market,
skills and working conditions. Job offers, generic homepages, product pages and
directories are excluded. Existing interests saved with the old opportunities
type follow the same article rules. Descriptions requesting no job offers are
removed from the literal search keywords; adjacent Boolean groups get a space.

**Standard search** needs no key. It queries Google News RSS across publishers,
then applies keyword groups, exclusions and the publication window locally.
Match percentages measure keyword coverage in the title and excerpt, independently
of publication age. Required keyword groups contribute 70% when configured,
and query keyword coverage contributes 30%; without groups, query coverage supplies
the full score. Common filler words and repeated query words do not inflate it.
It is a news index, so a very specific job search may legitimately return
no matches. Zero matches are distinct from a failed fetch; neither is padded
with unrelated headlines. Links from this provider use Google News redirects to
the publisher. Search depends on the availability and coverage of that index.

**AI search** uses your local **PI** installation and its saved provider/model.
With OpenAI Responses or Codex models, PI searches the web directly, using focused
queries for news or career reporting, summarizes retrieved facts and explains each
match. Current AI matches use PI's estimated percentage of interest fit; the prompts
keep recency separate from that score. Feed articles, saved snapshots and older
standard results receive current keyword estimates, so editing or pausing an
interest updates their displayed fit. Percentages are estimates of relevance,
not probabilities or guarantees about an article's claims.
This does not depend on Google News or Bing RSS returning useful results.
Only public URLs present in completed provider search evidence are accepted.
Kontrol then retrieves those pages to verify article evidence and read their
titles, descriptions, bounded article text and publication metadata. Required
concepts are checked against that source evidence, so a concise AI summary can
omit a keyword without causing a false rejection, and invented summary keywords
cannot make an unrelated source pass. Regular English forms such as
release/releases/released are recognized. Unrelated structured metadata is
ignored. Job postings and generic pages, invented links, weak scores, excluded
phrases and known dates outside the selected window are rejected. Titles and
publication dates come from retrieved pages,
never the model's answer. Page modification dates do not count as publication.
Unknown dates remain labeled. If all proposed results are rejected, the error
reports how many failed citation, article-type, date, relevance or keyword checks;
previous results are retained. Obvious homepages and listings in an older
discovery cache are hidden without rewriting the stored cache or saved bookmarks.

For PI providers without hosted web search, Kontrol retains Google News RSS and
Bing web-search RSS retrieval followed by PI snippet ranking. Coverage in that
fallback depends on those indexes; a precise query can return no matches.
General web-search timestamps are treated as unknown publication dates; their
target pages must supply article evidence and publication metadata. Failed
hosted searches are reported as errors and retain saved results rather than
silently falling back to an empty successful search.

Source pages are read with a browser-compatible page request profile (a
browser-style user agent and language header). The profile applies only to News AI
page reads, not to Feeds, Jobs or other requests. Up to five redirects are followed,
and a page larger than 2 MB is truncated rather than rejected. When PI's cited
pages all fail, the error names the categorized reasons, such as pages that blocked
automated access, rate-limited the request, timed out, returned an HTTP error, a
verification or unreadable page, or could not be reached.

**News-index fallback.** When hosted search cites sources but every page read fails,
Kontrol ranks Google News RSS snippets for the interest in one further PI inference.
Those snippets carry their own titles and dates and need no page reads. Other
failures do not trigger it. If the fallback finds no usable articles, or itself
fails or hits the deadline, the search still ends in an error that includes the
original retrieval reasons, and saved results are retained; an empty fallback is
never a successful search.

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

Searches run only on request, with at most two PI inferences per selected, enabled
interest (the second only for the news-index fallback), two concurrent interests and
a shared 90-second search/retrieval deadline. Hosted search runs even when RSS would
be empty. In the snippet-ranking
fallback, no inference is made for an empty source list. Automatic provider and
agent retries are disabled for this invocation. Your configured PI provider's
usage limits and billing apply. Only the interest, filters and date window enter
hosted search; the fallback also sends retrieved title/URL/snippet/date fields.
PI runs in a temporary working directory, with no local tools, user extensions,
skills, context files, prompt templates or saved session. Hosted search enables
one explicit extension that adds the provider's web tool and records source URLs.
Source-page retrieval is bounded to four concurrent requests, eight seconds per
page, five redirects and 2 MB per response, within the shared deadline. A larger
page is truncated to its first 2 MB rather than rejected. Temporary settings are
removed when the process exits, including failure or cancellation. This integration uses
PI's built-in providers and models.json; extension-defined providers are not loaded.
The **Standard search** option in Discover never invokes PI.

A successful search replaces that interest's previous matches, deduplicating
canonical URLs across interests; errors preserve saved results. Edited, paused,
deleted or imported interests invalidate in-flight replies through revision
checks. Search cache and run state use a separate newsDiscovery document, so
adding discovery leaves existing feeds/articles intact. The cache is capped at
500 results and 30 days, with the chosen interest window applied for display.
Unknown dates use first discovery time for retention, not an invented publication
date. **Feeds** retains the existing subscriptions and manual refresh.

The news implementation is split into server/news/transport.ts (bounded public
HTTP fetch), feeds.ts (RSS/Atom parsing), discovery.ts (standard search and merge),
ai.ts (live source retrieval and citation acceptance), pages.ts (source-page
titles and publication metadata), pi.ts (isolated PI runner
and connection status), and server/modules/news.ts
(HTTP routes and persistence). UI components for interests, connection, discovery,
articles, feeds and the dashboard widget live under src/modules/news/.

## Jobs: CV to matching offers

1. Open **Jobs** and upload a **PDF, DOCX or UTF-8 TXT** CV (up to 5 MB,
   PDF up to 25 pages, extracted text up to 60,000 characters). Extraction uses
   local PDF.js/Mammoth parsers; scanned PDFs need OCR before upload. Invalid,
   unreadable and oversized files leave the previous CV intact.
2. Select **Remote / Hybrid / Office**, then optional **Full-time / Part-time /
   Contract / Freelance / Internship** filters. Employment type is independent
   of where the work happens. Pick up to five cities and a 7/30/90-day window;
   choose **Save filters**. No cities means any location, and no employment
   types means any type. A work arrangement must be selected.
3. Choose **Analyze** to send extracted text to the provider configured in
   PI. Review the headline, summary, suggested roles, skills, experience and
   languages. Analysis can take up to two minutes. The profile selects up to
   five target roles and 30 primary skills; edit errors and **Confirm profile**
   before searching.
4. Choose **Find matches**. Each result shows a source title, company,
   location and employment metadata, estimated fit, specific match reasons,
   gaps/uncertainties, and a link to the original offer. No applications are sent.

The **CV** and **Filters** headings expand or collapse their panels.
Each panel remembers its own choice in this browser. Without a saved
choice, panels start open during setup and minimized on later visits once the
profile is confirmed. Minimized panels show the CV name/profile status or current
filters; filter drafts stay intact and unsaved changes remain flagged. Upload,
analysis and preference-save errors stay visible even when their panel is closed.

Once the profile is confirmed, **Matches** appears before **Profile & filters**.
The search area shows saved filter chips and links to the setup section;
**↑ Matches** returns to the search action. Setup drafts stay mounted when confirmation
changes the section order. Confirmed profile details, offer descriptions and
items needing confirmation are expandable. Salary and estimated fit stay visible
on the offer card; a fit score is not a hiring probability.

Background refreshes preserve unsaved filter and profile edits. If another tab
changes the same saved fields, the form shows the current saved version and
requires **Use saved** or **Keep my edits** before saving. Unrelated
updates advance the revision without replacing the draft. Source coverage and
retrieval details are documented here; results retain source names, dates,
match reasons and current search warnings.

City lookup runs entirely on the server against the bundled `cities.json`
GeoNames catalog, including towns above 1,000 population and administrative
seats. It supports accent-insensitive search and optional country/state
qualifiers, such as `Tokyo, Japan`, `Berlin, DE`, or `Paris, Texas`. Only matching
city records reach the browser; the catalog is not part of the frontend bundle.
Attribution is shown in the city picker. City and profile review work offline.

Search asks PI to find current listings using its model provider's hosted
web search. This supports PI's OpenAI Responses and Codex providers and uses the
existing PI login; no separate search API key is needed. It does not select or
guarantee Google as the underlying search index. Only public URLs present in
completed provider search evidence are accepted, and Kontrol then retrieves each
page before accepting a listing. PI receives roles, skills, selected cities and
filters, including the posting-date cutoff, for discovery.

For software profiles selecting cities in Japan or Milan, discovery also reads
TokyoDev and Reteinformaticalavoro indexes directly, concurrently with PI search.
These indexes are fetched afresh and their linked offers must pass the same
structured-data and filter checks. This does not depend on a search engine
returning the board in its results. Italian `/lavoro/` links are supported.
Direct board retrieval has a 30-second cap and follows at most ten offers per
site, twenty total, within one level of each index.

If PI search and direct boards yield no readable, relevant postings passing the
filters, Bing and then DuckDuckGo provide fallbacks using up to two reviewed role
titles per selected city (at most ten queries per provider). Each provider can
retrieve up to 20 result pages and one level of up to 20 relevant offer links
from those pages, capped at ten linked offers per site. Source discovery shares
a 110-second limit: PI inference has a 60-second limit, its search/retrieval phase
has an 80-second cap, and Bing has a 15-second cap. The latest 100 Remotive remote
postings and up to 500 Arbeitnow postings provide additional candidates.
Only single structured `JobPosting` records are accepted from web pages; job
directories, general search snippets and news articles cannot become offers.
Direct job-board records provide an additional source, with
Arbeitnow focused mainly on Germany. Source URLs and metadata come from retrieved
records, never from the model's prose. Provider and page failures are reported
separately from an empty successful search, and ranking is skipped for an empty
candidate list.

Office/hybrid city matching requires both city and country evidence. Ambiguous
Arbeitnow locations get a bounded attempt to read their structured posting;
missing countries are not guessed. Tokyo also includes ward addresses such as
Minato-ku when the source explicitly identifies Tokyo as the region and Japan
as the country. Italian listings using Milano match the catalog's Milan entry;
a repeated matching country in the city field, such as `Milano, Italy`, is also
accepted. The separate country must still match; conflicting country qualifiers
are rejected. Other same-named states or prefectures are not
treated as cities.
Remote listings must explicitly cover a
selected country or worldwide work when cities are selected. This checks source
geography, not visa or work authorization. With a specific employment or work
arrangement filter, unstated values are excluded; selecting all arrangements
also permits listings marked unknown. Known expired, future-dated and old listings
are excluded; unknown posting dates remain clearly labeled.
Hybrid work is inferred from work-arrangement language; technical requirements
such as hybrid cloud do not override an explicitly remote role.

RAL filters accept optional minimum and maximum **annual gross salary in euros**.
Ranges overlap inclusively: a declared €50,000–€70,000 range meets a €60,000
minimum, without promising that the employer will offer the upper amount.
One-sided salaries use the stated bound; unknown bounds are not invented.
Leave both filters empty to keep offers with unavailable RAL. Setting either
bound excludes offers whose annual gross euro salary cannot be verified.
Saving a changed RAL filter clears the previous matches, like other filters.

Before filtering and ranking, salary enrichment reads `JobPosting.baseSalary`
and explicitly annual salary text from the offer. Unknown currency or period,
monthly/hourly pay, net pay and total compensation are not guessed into RAL.
Foreign currencies are converted using the [ECB reference rates](https://www.ecb.europa.eu/stats/policy_and_exchange_rates/euro_reference_exchange_rates/html/index.en.html).
The original annual amount, currency and rate date remain visible. Rates are
cached for six hours and must be no more than seven days old; if a rate is
unavailable, the offer's original pay remains visible without a euro RAL.

For offers without usable declared annual salary, PI searches for the average,
median or typical gross base salary for the same company, position, seniority
and location. Identical company/role/location queries are grouped. At most 30
candidates are researched in batches of six, with two concurrent batches,
45 seconds per PI invocation and a 100-second shared research deadline.
Estimates must cite provider-retrieved public URLs. The server fetches the cited
page and verifies a verbatim salary passage, company, role and location evidence;
generic market averages, fabricated links/amounts, and unreadable evidence are
discarded. The research step receives only job IDs, company, role and location,
never the CV or reviewed profile. Research failure leaves other offers usable
and produces a warning; it does not manufacture an estimate.

Job previews, dashboard cards and saved applications display RAL with green
**Declared** or amber **Estimate** badges; comparisons spell out the provenance.
Researched figures and currency conversions use an approximation marker.
**Salary sources** expands the source links, check date and any currency
conversion; **Listed pay** retains an unverified original amount. Unverified amounts read **RAL
unavailable**. Run **Find matches** to populate salary evidence for existing
search results. Saved application snapshots and backups retain the salary and
its sources. Older records and backups default to unrestricted RAL filters and
unavailable salary evidence, without discarding their other data.

The server passes at most 30 filtered candidates, a bounded description excerpt,
the reviewed profile and preferences to PI. It accepts only exact retrieved
source IDs and scores of at least 60, rechecks filters, deduplicates links and
retains at most 20 matches. Scores estimate fit, not hiring probability.
Coverage is limited by the sources, their geographic coverage, page availability
and structured metadata. Check current availability and eligibility on the source.
Remotive's API is delayed by 24 hours; its response is cached for six hours,
Arbeitnow's for ten minutes, within the running server process.

Jobs reuses News's PI executable/model/login configuration and `PI_NEWS_*`
overrides. Analysis and ranking use dedicated system prompts and the isolated,
tool-free, session-free runner. Discovery enables one bundled extension that
adds only hosted web search and records provider source URLs in the temporary
directory; local tools, user extensions, repository context and saved sessions
remain disabled. Upload and city search make no AI request. Only **Analyze**
sends CV text; **Find matches** sends roles/skills/filters to PI for search,
then the reviewed profile and retrieved descriptions for ranking. Role/location/
filter queries also go to Bing and DuckDuckGo when fallback is needed. Inference
uses the configured provider's usage limits or billing. No CV is sent to a job
board, recruiter or employer. Do not put contact details into reviewed profile
fields if you do not want those fields included in matching requests.

One Jobs upload/analysis/search can run at a time. Analysis has a 120-second limit;
search has a 300-second shared limit, including bounded source retrieval, salary
research, at most one PI discovery invocation and at most one PI ranking invocation. Mutations
compare revisions. A changed CV,
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
[OpenAI hosted web search](https://developers.openai.com/api/docs/guides/tools-web-search),
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
The shared workspace API owns durable bookmarks, applications, notes, goals and
reviews. The library and Today use the same query cache as feature pages.
Schemas and deterministic recommendation/grouping helpers live in
shared/workspace.ts; routes live in server/modules/workspace.ts.

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
  nonsecret AI settings are retained. News and Jobs AI use PI as described above.
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
