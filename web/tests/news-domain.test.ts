import test from 'node:test';
import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { interestDraftSchema, interestSchema, interestPresets, interestWordCount, relevanceForInterest, articleInterestFits, newsSearchQuery, canBeNewsArticleURL,
  visibleDiscoveries, discoveryRunError, type NewsInterest, type NewsResponse, type DiscoveredArticle, type DiscoveryRun } from '../shared/news';
import { groupNewsByDate } from '../shared/news-dates';
import { briefingStories, editionEmptyReason, editionReadCount, publisherKey, EDITION_LIMIT, EDITION_PREVIEW_LIMIT, RELEVANCE_FLOOR,
  RECENCY_POINTS, RECENCY_HORIZON_DAYS, INTEREST_REPEAT_PENALTY, PUBLISHER_REPEAT_PENALTY } from '../shared/briefing';
import { canonicalURL, emptyWorkspace, type SavedArticle, type Workspace } from '../shared/workspace';
import type { Article } from '../shared/schema';

const now = Date.parse('2026-10-05T04:00:00Z');
const interest = (overrides: Partial<NewsInterest> = {}): NewsInterest => ({ ...interestPresets[0], query: 'Japan software developer visa sponsorship',
  requiredTerms: [], id: randomUUID(), revision: randomUUID(), ...overrides });
const article = (overrides: Partial<Article> = {}): Article => ({ id: randomUUID(), title: 'Japan software developer visa sponsorship',
  summary: '', source: 'Fixture', url: 'https://example.com/' + randomUUID(), publishedAt: '2026-10-05T01:00:00Z',
  fetchedAt: '2026-10-05T04:00:00Z', feedIDs: ['fixture-feed'], topicIDs: ['fixture-topic'], ...overrides });

test('new interest descriptions require five search words without counting operators, exclusions or site filters', () => {
  for (const query of ['Japan', 'programming', 'Japan software developer jobs', 'Japan OR software OR jobs AND NOT', 'Japan site:example.com -"celebrity stock price"']) {
    const result = interestDraftSchema.safeParse(interest({ query }));
    assert.equal(result.success, false, query);
    if (!result.success) assert.match(result.error.issues[0].message, /at least 5 words/);
  }
  assert.equal(interestWordCount('Software developer jobs in Japan'), 5);
  assert.equal(interestDraftSchema.safeParse(interest({ query: 'Software developer jobs in Japan' })).success, true);
  for (const preset of interestPresets) assert.equal(interestDraftSchema.safeParse(preset).success, true);
});
test('word counting handles Japanese descriptions and stored legacy interests remain readable', () => {
  const japanese = interest({ query: '東京 ソフトウェア 開発 求人 ビザ', language: 'ja' });
  assert.equal(interestDraftSchema.safeParse(japanese).success, true);
  assert.ok(interestWordCount('東京でソフトウェア開発者の求人を探す', 'ja') >= 5);
  assert.equal(interestSchema.safeParse(interest({ query: 'Japan' })).success, true);
});
test('keyword percentages distinguish full, partial and unrelated coverage and ignore publication age', () => {
  const i = interest(), full = article(), partial = article({ title: 'Japan developer', summary: '' });
  assert.equal(relevanceForInterest(full, i), 100);
  assert.equal(relevanceForInterest(partial, i), 40);
  assert.equal(relevanceForInterest(article({ title: 'Space telescope observes distant nebula' }), i), 0);
  assert.equal(relevanceForInterest(article({ publishedAt: null }), i), 100);
  assert.equal(relevanceForInterest(article({ publishedAt: '2020-01-01T00:00:00Z' }), i), 100);
});
test('percentages support required alternatives, exclusions, short technical terms and whole-word boundaries', () => {
  const i = interest({ requiredTerms: ['Japan|Tokyo', 'software|engineer', 'developer|hiring', 'visa'] });
  assert.ok(relevanceForInterest(article({ title: 'Tokyo engineer hiring with visa' }), i) >= 70);
  assert.equal(relevanceForInterest(article(), { ...i, excludedTerms: ['sponsorship'] }), 0);
  const technical = interest({ query: 'AI Go model compiler benchmarks' });
  assert.equal(relevanceForInterest(article({ title: 'AI and Go', summary: 'Model compiler benchmarks' }), technical), 100);
  assert.equal(relevanceForInterest(article({ title: 'Said goodbye' }), technical), 0);
  assert.equal(relevanceForInterest(article(), interest({ query: 'Japan Japan software developer visa sponsorship' })), 100);
});
test('closest-interest percentages use current AI estimates and recalculate old standard ranks', () => {
  const i = interest(), other = interest({ name: 'Astronomy', query: 'Space telescope observes distant nebula' });
  const matched: DiscoveredArticle = { ...article(), matches: [{ interestID: i.id, interestRevision: i.revision, mode: 'ai', score: 93, reason: 'Specific location and sponsorship.' }] };
  let fits = articleInterestFits(matched, [other, i]);
  assert.equal(fits[0].interest.id, i.id); assert.equal(fits[0].score, 93); assert.equal(fits[0].method, 'ai');
  assert.equal(fits[0].reason, matched.matches[0].reason);
  fits = articleInterestFits({ ...matched, matches: [{ ...matched.matches[0], mode: 'search', score: 21 }] }, [i]);
  assert.equal(fits[0].score, 100); assert.equal(fits[0].method, 'keywords');
  fits = articleInterestFits(matched, [{ ...i, revision: randomUUID() }]);
  assert.equal(fits[0].score, 100); assert.equal(fits[0].method, 'keywords');
  for (const score of [NaN, Infinity, -1, 101]) assert.equal(articleInterestFits({ ...matched, matches: [{ ...matched.matches[0], score }] }, [i])[0].score, 100);
  assert.deepEqual(articleInterestFits(matched, [{ ...i, enabled: false }]), []);
});
test('news groups use local publication days, newest timestamps first and undated entries last without mutating inputs', () => {
  const rows = [article({ id: 'older', publishedAt: '2026-10-03T17:00:00Z' }), article({ id: 'undated', publishedAt: null }),
    article({ id: 'offset', publishedAt: '2026-10-05T00:30:00+08:00' }), article({ id: 'latest', publishedAt: '2026-10-05T01:00:00Z' }),
    article({ id: 'invalid', publishedAt: 'unknown' }), article({ id: 'year', publishedAt: '2025-10-05T01:00:00Z' })];
  const before = structuredClone(rows);
  const groups = groupNewsByDate(rows, row => row.publishedAt, now, 'Asia/Manila');
  assert.deepEqual(groups.map(group => group.key), ['2026-10-05', '2026-10-04', '2025-10-05', 'undated']);
  assert.deepEqual(groups[0].items.map(row => row.id), ['latest', 'offset']);
  assert.match(groups[0].label, /^Today · /); assert.match(groups[1].label, /^Yesterday · /); assert.match(groups[2].label, /2025/);
  assert.deepEqual(groups.at(-1)!.items.map(row => row.id), ['undated', 'invalid']);
  assert.deepEqual(rows, before);
  assert.deepEqual(groupNewsByDate([], (row: Article) => row.publishedAt, now, 'Asia/Manila'), []);
});
test('yesterday headings follow calendar days through daylight saving and a new year', () => {
  const groups = groupNewsByDate([article({ publishedAt: '2026-03-08T05:30:00Z' })], row => row.publishedAt,
    Date.parse('2026-03-09T04:15:00Z'), 'America/New_York');
  assert.equal(groups[0].key, '2026-03-08'); assert.match(groups[0].label, /^Yesterday · /);
  const newYear = groupNewsByDate([article({ publishedAt: '2025-12-31T10:00:00Z' })], row => row.publishedAt,
    Date.parse('2026-01-01T02:00:00Z'), 'Asia/Manila');
  assert.equal(newYear[0].key, '2025-12-31'); assert.match(newYear[0].label, /^Yesterday · /);
});

function newsState(articles: Article[]): NewsResponse {
  return { articles, preferences: { feeds: [{ id: 'fixture-feed', name: 'Fixture', endpoint: 'https://example.com/feed', topicIDs: ['fixture-topic'], isEnabled: true }],
    selectedTopicIDs: ['fixture-topic'] }, errors: {}, lastRefreshAt: null,
    discovery: { preferences: { schemaVersion: 1, interests: [] }, articles: [], runs: {} },
    ai: { configured: false, provider: 'pi', model: 'Fixture', message: '' }, activity: { discovering: false, refreshingFeeds: false } };
}
const hoursAgo = (hours: number) => new Date(now - hours * 3_600_000).toISOString();
// Single-word headlines never form related groups; distinct sources avoid publisher penalties unless a test sets one.
const story = (id: string, overrides: Partial<Article> = {}) => article({ id, title: 'Headline ' + id, source: 'Publisher ' + id,
  url: 'https://example.com/story-' + id, ...overrides });
// Current-revision AI matches set an exact relevance.
const matched = (i: NewsInterest, score: number, id: string, overrides: Partial<Article> = {}): DiscoveredArticle =>
  ({ ...story(id, overrides), matches: [{ interestID: i.id, interestRevision: i.revision, mode: 'ai', score, reason: 'Fixture' }] });
function discoveryState(interests: NewsInterest[], discovered: DiscoveredArticle[], feed: Article[] = []): NewsResponse {
  const state = newsState(feed);
  state.discovery.preferences.interests = interests; state.discovery.articles = discovered;
  return state;
}
const leadIDs = (state: NewsResponse, workspace?: Workspace) => briefingStories(state, workspace, now).map(group => group.lead.id);
const record = (source: Article, changes: Partial<SavedArticle> = {}): SavedArticle => ({ id: randomUUID(),
  article: { title: source.title, url: source.url, source: source.source, summary: source.summary, publishedAt: source.publishedAt,
    fetchedAt: source.fetchedAt, summaryKind: 'source' }, savedAt: null, readAt: null, notes: '', updatedAt: new Date(now).toISOString(), ...changes });

test('discoveries prioritize publication dates over stronger older matches and recent retrieval of undated stories', () => {
  const i = interest(), rows = [article({ id: 'older', publishedAt: '2026-10-03T04:00:00Z' }),
    article({ id: 'undated', title: 'Undated sponsorship listing for developers', publishedAt: null }),
    article({ id: 'newer', title: 'Space telescope observes distant nebula', publishedAt: '2026-10-05T01:00:00Z' })];
  const state = newsState([]);
  state.discovery.preferences.interests = [i];
  state.discovery.articles = rows.map((row, index) => ({ ...row, matches: [{ interestID: i.id, interestRevision: i.revision, mode: 'search', score: index === 0 ? 99 : 1, reason: 'Fixture' }] }));
  assert.deepEqual(visibleDiscoveries(state.discovery, undefined, now).map(row => row.id), ['newer', 'older', 'undated']);
});
test('briefing lets an older relevant story outrank a newer weak one while Discover stays newest-first (Example A)', () => {
  const i = interest();
  const state = discoveryState([i], [matched(i, 40, 'Y', { publishedAt: hoursAgo(1) }), matched(i, 100, 'X', { publishedAt: hoursAgo(72) })]);
  const edition = briefingStories(state, undefined, now);
  assert.deepEqual(edition.map(group => group.lead.id), ['X', 'Y']);
  assert.deepEqual(edition.map(group => group.relevance), [100, 40]);
  assert.deepEqual(visibleDiscoveries(state.discovery, undefined, now).map(row => row.id), ['Y', 'X']);
});
test('briefing recognizes detailed profile descriptions when breaking publication-time ties', () => {
  const match = article(), unrelated = article({ title: 'Space telescope observes distant nebula' });
  const state = newsState([unrelated, match]), workspace = emptyWorkspace(randomUUID());
  workspace.profile.interests = ['Software developer roles with Japan visa sponsorship'];
  assert.equal(briefingStories(state, workspace, now)[0].lead.url, match.url);
});
function interestVarietyState() {
  const a = interest({ name: 'Interest A' }), b = interest({ name: 'Interest B' });
  const rows = [1, 2, 3, 4, 5, 6].map(hours => matched(a, 100, 'a' + hours, { publishedAt: hoursAgo(hours) }));
  rows.push(matched(b, 80, 'b1', { publishedAt: hoursAgo(24) }));
  return { a, b, state: discoveryState([a, b], rows) };
}
test('edition constants and the Today preview slice follow the documented policy', () => {
  assert.deepEqual([EDITION_LIMIT, EDITION_PREVIEW_LIMIT, RELEVANCE_FLOOR, RECENCY_POINTS, RECENCY_HORIZON_DAYS, INTEREST_REPEAT_PENALTY, PUBLISHER_REPEAT_PENALTY],
    [5, 3, 50, 20, 7, 25, 15]);
  const edition = briefingStories(interestVarietyState().state, undefined, now);
  assert.equal(edition.length, EDITION_LIMIT);
  assert.deepEqual(edition.slice(0, EDITION_PREVIEW_LIMIT).map(group => group.lead.id), ['a1', 'b1', 'a2']);
});
test('a second relevant interest earns a place that newest-first ordering would exclude (Example B)', () => {
  const { a, b, state } = interestVarietyState();
  const edition = briefingStories(state, undefined, now);
  assert.deepEqual(edition.map(group => group.lead.id), ['a1', 'b1', 'a2', 'a3', 'a4']);
  assert.deepEqual(edition[0].context, { kind: 'interest', interestID: a.id, label: 'Interest A' });
  assert.deepEqual(edition[1].context, { kind: 'interest', interestID: b.id, label: 'Interest B' });
  assert.deepEqual(visibleDiscoveries(state.discovery, undefined, now).slice(0, EDITION_LIMIT).map(row => row.id), ['a1', 'a2', 'a3', 'a4', 'a5']);
});
test('a second publisher is preferred over repeats from one publisher within an interest (Example C)', () => {
  const i = interest();
  const state = discoveryState([i], [matched(i, 100, 'x', { source: 'Wire One', publishedAt: hoursAgo(1) }),
    matched(i, 100, 'y', { source: 'Wire One', publishedAt: hoursAgo(2) }), matched(i, 100, 'z', { source: 'Wire One', publishedAt: hoursAgo(3) }),
    matched(i, 100, 'q', { source: 'Daily Two', publishedAt: hoursAgo(5) })]);
  assert.deepEqual(leadIDs(state), ['x', 'q', 'y', 'z']);
});
test('without interests or profile matches the edition is recent coverage with publisher variety (Example D)', () => {
  const state = newsState([story('f1', { source: 'Feed One', publishedAt: hoursAgo(1) }), story('f2', { source: 'Feed One', publishedAt: hoursAgo(2) }),
    story('f3', { source: 'Feed One', publishedAt: hoursAgo(3) }), story('g1', { source: 'Feed Two', publishedAt: hoursAgo(30) })]);
  const edition = briefingStories(state, emptyWorkspace(randomUUID()), now);
  assert.deepEqual(edition.map(group => group.lead.id), ['f1', 'g1', 'f2', 'f3']);
  assert.ok(edition.every(group => group.relevance === 0 && group.context.kind === 'recent'));
});
test('search placeholders and Google News redirect hosts never count as one publisher', () => {
  const google = (id: string, hours: number) => story(id, { source: 'News search', url: 'https://news.google.com/rss/articles/' + id, publishedAt: hoursAgo(hours) });
  const state = newsState([google('n1', 1), google('n2', 2), google('n3', 3), story('g1', { source: 'Feed Two', publishedAt: hoursAgo(30) })]);
  assert.deepEqual(leadIDs(state), ['n1', 'n2', 'n3', 'g1']);
  assert.equal(publisherKey({ source: 'Reuters', url: 'https://news.google.com/rss/articles/one' }), 'reuters');
  assert.notEqual(publisherKey({ source: 'Reuters', url: 'https://news.google.com/rss/articles/one' }),
    publisherKey({ source: 'BBC News', url: 'https://news.google.com/rss/articles/two' }));
  assert.equal(publisherKey({ source: '  Daily\u00a0  TWO ', url: 'https://example.com/a' }), 'daily two');
  assert.equal(publisherKey({ source: 'WWW.Example.com', url: 'https://other.example/a' }), 'example.com');
  assert.equal(publisherKey({ source: 'News search', url: 'https://news.google.com/rss/articles/three' }), null);
  assert.equal(publisherKey({ source: 'news.google.com', url: 'https://news.google.com/rss/articles/four' }), null);
  assert.equal(publisherKey({ source: '', url: 'https://news.google.com/rss/articles/five' }), null);
  assert.equal(publisherKey({ source: 'News search', url: 'https://www.example.org/story' }), 'example.org');
  assert.equal(publisherKey({ source: ' ', url: 'not a url' }), null);
});
test('undated stories get no recency bonus but a clearly more relevant undated story can still lead (Example E)', () => {
  const i = interest();
  let state = discoveryState([i], [matched(i, 100, 'undated', { publishedAt: null }), matched(i, 100, 'dated', { publishedAt: hoursAgo(144) })]);
  let edition = briefingStories(state, undefined, now);
  assert.deepEqual(edition.map(group => group.lead.id), ['dated', 'undated']);
  assert.equal(edition[1].lead.publishedAt, null);
  state = discoveryState([i], [matched(i, 60, 'recent', { publishedAt: hoursAgo(1) }), matched(i, 100, 'undated', { publishedAt: null })]);
  edition = briefingStories(state, undefined, now);
  assert.deepEqual(edition.map(group => group.lead.id), ['undated', 'recent']);
  assert.equal(edition[0].lead.publishedAt, null);
});
test('unparsable publication dates rank as undated, after comparable dated stories, and keep their stored value', () => {
  const rows = [story('a-undated', { url: 'https://example.com/a-undated', publishedAt: null }),
    story('b-invalid', { url: 'https://example.com/b-invalid', publishedAt: 'unknown' }),
    story('z-old', { url: 'https://example.com/z-old', publishedAt: hoursAgo(24 * 10) })];
  const edition = briefingStories(newsState(rows), undefined, now);
  assert.deepEqual(edition.map(group => group.lead.id), ['z-old', 'a-undated', 'b-invalid']);
  assert.equal(edition[1].lead.publishedAt, null);
  assert.equal(edition[2].lead.publishedAt, 'unknown');
});
test('unrelated recent content is never forced ahead of relevant groups (Example F)', () => {
  const i = interest();
  const rows = [1, 2, 3, 4, 5, 6].map(hours => matched(i, 100, 's' + hours, { publishedAt: hoursAgo(hours) }));
  const state = discoveryState([i], rows, [story('feed', { publishedAt: new Date(now).toISOString() })]);
  assert.deepEqual(leadIDs(state), ['s1', 's2', 's3', 's4', 's5']);
});
test('a single useful interest and publisher still fills five groups in relevance-plus-recency order', () => {
  const i = interest();
  const rows = ([['g1', 90, 1], ['g2', 100, 144], ['g3', 95, 24], ['g4', 70, 1], ['g5', 85, 48], ['g6', 60, 0], ['g7', 80, 72]] as const)
    .map(([id, score, hours]) => matched(i, score, id, { source: 'Same Publisher', publishedAt: hoursAgo(hours) }));
  const edition = briefingStories(discoveryState([i], rows), undefined, now);
  assert.deepEqual(edition.map(group => group.lead.id), ['g3', 'g1', 'g2', 'g5', 'g7']);
  assert.deepEqual(edition.map(group => group.relevance), [95, 90, 100, 85, 80]);
});
test('the edition has at most five unique leads and shows fewer groups without filler', () => {
  const many = briefingStories(newsState([1, 2, 3, 4, 5, 6, 7, 8].map(hours => story('m' + hours, { publishedAt: hoursAgo(hours) }))), undefined, now);
  assert.equal(many.length, EDITION_LIMIT);
  assert.equal(new Set(many.map(group => canonicalURL(group.lead.url))).size, EDITION_LIMIT);
  assert.deepEqual(leadIDs(newsState([story('two', { publishedAt: hoursAgo(4) }), story('one', { publishedAt: hoursAgo(1) })])), ['one', 'two']);
  assert.deepEqual(briefingStories(newsState([]), undefined, now), []);
  const workspace = emptyWorkspace(randomUUID()); workspace.profile.interests = ['Software developer roles with Japan visa sponsorship'];
  assert.deepEqual(briefingStories(newsState([]), workspace, now), []);
});
test('related coverage ranked after the selected groups is kept and URL duplicates collapse', () => {
  const i = interest();
  const lead = matched(i, 100, 'lead', { title: 'Harbor authority approves new crane terminal expansion', publishedAt: hoursAgo(1) });
  const others = [2, 3, 4, 5, 6, 7].map(hours => matched(i, 100, 'other' + hours, { publishedAt: hoursAgo(hours) }));
  const related = story('related', { title: 'Harbor authority approves crane terminal expansion plan', publishedAt: hoursAgo(30) });
  const feed = [related, story('duplicate', { url: lead.url + '?utm_source=feed&utm_medium=rss', title: lead.title, publishedAt: lead.publishedAt }),
    story('related-copy', { url: related.url + '#comments', title: related.title, publishedAt: related.publishedAt })];
  const edition = briefingStories(discoveryState([i], [lead, ...others], feed), undefined, now);
  assert.equal(edition.length, EDITION_LIMIT);
  assert.equal(edition[0].lead.id, 'lead');
  assert.deepEqual(edition[0].related.map(row => row.id), ['related']);
  const ids = edition.flatMap(group => [group.lead, ...group.related].map(row => row.id));
  assert.equal(ids.includes('duplicate'), false); assert.equal(ids.includes('related-copy'), false);
  assert.equal(new Set(edition.map(group => canonicalURL(group.lead.url))).size, edition.length);
});
test('disabled interests, stale revisions, expired matches, excluded kinds and URLs, disabled feeds and unselected topics cannot enter', () => {
  const active = interest({ name: 'Active' }), paused = interest({ name: 'Paused', enabled: false });
  const discovered = [matched(active, 100, 'visible'), matched(paused, 100, 'disabled-interest'),
    { ...story('stale-revision'), matches: [{ interestID: active.id, interestRevision: randomUUID(), mode: 'ai' as const, score: 100, reason: 'Fixture' }] },
    matched(active, 100, 'expired', { publishedAt: hoursAgo(24 * 40) }), { ...matched(active, 100, 'job'), contentKind: 'job' as const },
    { ...matched(active, 100, 'generic'), contentKind: 'generic' as const }, matched(active, 100, 'homepage', { url: 'https://example.com/' })];
  const feed = [story('feed-visible'), story('disabled-feed', { feedIDs: ['paused-feed'] }), story('unselected-topic', { topicIDs: ['other-topic'] }),
    story('bad-url', { url: 'not a url' })];
  const state = discoveryState([active, paused], discovered, feed);
  state.preferences.feeds.push({ id: 'paused-feed', name: 'Paused', endpoint: 'https://example.com/paused', topicIDs: ['fixture-topic'], isEnabled: false });
  const edition = briefingStories(state, undefined, now);
  assert.deepEqual(edition.flatMap(group => [group.lead, ...group.related].map(row => row.id)).sort(), ['feed-visible', 'visible']);
});
test('fixed inputs give deeply equal editions across repeated calls and permuted candidate arrays, ending ties by canonical URL', () => {
  const { state } = interestVarietyState();
  state.articles = [story('feed-one', { publishedAt: hoursAgo(2) }), story('a1-copy', { url: 'https://example.com/story-a1?utm_campaign=x', title: 'Headline a1' })];
  const expected = briefingStories(state, undefined, now);
  assert.deepEqual(briefingStories(state, undefined, now), expected);
  for (const permute of [<T,>(rows: T[]) => [...rows].reverse(), <T,>(rows: T[]) => [...rows.slice(3), ...rows.slice(0, 3)]]) {
    const permuted = structuredClone(state);
    permuted.discovery.articles = permute(permuted.discovery.articles); permuted.articles = permute(permuted.articles);
    assert.deepEqual(briefingStories(permuted, undefined, now), expected);
  }
  const at = hoursAgo(5), ties = [story('tie-b', { url: 'https://example.com/tie-b', publishedAt: at }), story('tie-a', { url: 'https://example.com/tie-a', publishedAt: at })];
  assert.deepEqual(leadIDs(newsState(ties)), ['tie-a', 'tie-b']);
  assert.deepEqual(leadIDs(newsState([...ties].reverse())), ['tie-a', 'tie-b']);
  const dated = [story('z-dated', { url: 'https://example.com/z-dated', publishedAt: hoursAgo(24 * 10) }), story('a-undated', { url: 'https://example.com/a-undated', publishedAt: null })];
  assert.deepEqual(leadIDs(newsState(dated)), ['z-dated', 'a-undated']);
});
test('read, save and notes changes never reorder the edition and inputs are not mutated', () => {
  const { state } = interestVarietyState();
  state.articles = [story('feed-one', { publishedAt: hoursAgo(2) })];
  const workspace = emptyWorkspace(randomUUID()); workspace.profile.targetRoles = ['Harbor crane terminal operator'];
  const newsBefore = structuredClone(state), workspaceBefore = structuredClone(workspace);
  const expected = briefingStories(state, workspace, now);
  assert.deepEqual(state, newsBefore); assert.deepEqual(workspace, workspaceBefore);
  const at = new Date(now).toISOString();
  workspace.articles = expected.map((group, index) => record(group.lead, index % 2 ? { readAt: at } : { savedAt: at, readAt: at, notes: 'Follow up' }));
  workspace.articles.push(record(story('elsewhere'), { savedAt: at }));
  const withRecords = structuredClone(workspace);
  assert.deepEqual(briefingStories(state, workspace, now), expected);
  assert.deepEqual(workspace, withRecords); assert.deepEqual(state, newsBefore);
});
test('selection context comes from the matched interest or profile text, and recent coverage below the floor', () => {
  const i = interest({ name: 'Harbor logistics', query: 'harbor crane terminal expansion shipping' });
  const workspace = emptyWorkspace(randomUUID());
  workspace.profile.interests = ['Volcano monitoring sensor network research', 'Harbor crane terminal expansion shipping'];
  workspace.profile.targetRoles = ['Glacier field researcher role', 'Volcano monitoring sensor network research'];
  const rows = [story('by-interest', { title: 'Harbor crane terminal expansion shipping', publishedAt: hoursAgo(1) }),
    story('by-profile', { title: 'Volcano monitoring sensor network research update', publishedAt: hoursAgo(2) }),
    story('by-role', { title: 'Glacier field researcher role opening', publishedAt: hoursAgo(3) }),
    story('weak', { title: 'Harbor weather', publishedAt: hoursAgo(4) })];
  const state = newsState(rows); state.discovery.preferences.interests = [i];
  const byID = new Map(briefingStories(state, workspace, now).map(group => [group.lead.id, group]));
  assert.deepEqual(byID.get('by-interest')?.context, { kind: 'interest', interestID: i.id, label: 'Harbor logistics' });
  assert.deepEqual(byID.get('by-profile')?.context, { kind: 'profile-interest', label: 'Volcano monitoring sensor network research' });
  assert.deepEqual(byID.get('by-role')?.context, { kind: 'target-role', label: 'Glacier field researcher role' });
  assert.deepEqual(byID.get('weak')?.context, { kind: 'recent' });
  assert.equal(byID.get('by-interest')?.relevance, 100);
  assert.ok((byID.get('weak')?.relevance ?? 100) < RELEVANCE_FLOOR);
});
test('edition read counts use workspace read records for selected leads only', () => {
  const rows = [story('one'), story('two', { publishedAt: hoursAgo(2) }), story('three', { publishedAt: hoursAgo(3) })];
  const groups = briefingStories(newsState(rows), undefined, now), at = new Date(now).toISOString();
  const workspace = emptyWorkspace(randomUUID());
  const readOne = record(rows[0], { readAt: at, savedAt: at });
  readOne.article.url += '?utm_source=newsletter';
  workspace.articles = [readOne, record(rows[1], { savedAt: at, notes: 'Saved, unread' }), record(story('elsewhere'), { readAt: at })];
  assert.equal(editionReadCount(groups, workspace), 1);
  assert.equal(editionReadCount(groups), 0);
  assert.equal(editionReadCount([], workspace), 0);
});
test('empty editions are classified from existing interests and runs', () => {
  const i = interest(), state = newsState([]), at = new Date(now).toISOString();
  const run = (changes: Partial<DiscoveryRun> = {}): DiscoveryRun => ({ interestRevision: i.revision, attemptedAt: at, succeededAt: null, mode: 'search',
    count: 0, error: 'The source could not be reached.', ...changes });
  assert.equal(editionEmptyReason(state), 'no-interests');
  state.discovery.preferences.interests = [{ ...i, enabled: false }];
  state.discovery.runs = { [i.id]: run({ error: null, succeededAt: at }) };
  assert.equal(editionEmptyReason(state), 'no-interests');
  state.discovery.preferences.interests = [i]; state.discovery.runs = {};
  assert.equal(editionEmptyReason(state), 'not-searched');
  state.discovery.runs = { [i.id]: run() };
  assert.equal(editionEmptyReason(state), 'not-searched');
  state.discovery.runs = { [i.id]: run({ error: null, succeededAt: at, interestRevision: randomUUID() }) };
  assert.equal(editionEmptyReason(state), 'not-searched');
  state.discovery.runs = { [i.id]: run({ error: null, succeededAt: at }) };
  assert.equal(editionEmptyReason(state), 'no-matches');
});
test('news queries retain career topic words while removing a request to exclude job offers from the search terms', () => {
  const query = 'Japan (developer OR "software engineer" OR programming) (jobs OR hiring OR recruitment)(Java OR Kotlin OR Backend)\nDON\'T get me any job offers.';
  const cleaned = newsSearchQuery(query);
  assert.match(cleaned, /recruitment\) \(Java/); assert.doesNotMatch(cleaned, /DON'T|offers/);
  assert.equal(interestWordCount(query), interestWordCount(cleaned));
});
test('cached discovery homepages, job listings and generic source kinds are hidden without modifying the stored cache', () => {
  const i = interest(), state = newsState([]);
  state.discovery.preferences.interests = [i];
  const match = { interestID: i.id, interestRevision: i.revision, mode: 'ai' as const, score: 95, reason: 'Fixture' };
  state.discovery.articles = ['https://japan-dev.com/', 'https://japan-dev.com/jobs', 'https://japan-dev.com/en', 'https://japan-dev.com/blog/hiring-trends'].map(url => ({ ...article({ url }), matches: [match] }));
  state.discovery.articles.push({ ...article({ url: 'https://company.example/opening' }), matches: [match], contentKind: 'job' });
  const before = structuredClone(state.discovery);
  assert.deepEqual(visibleDiscoveries(state.discovery, undefined, now).map(item => item.url), ['https://japan-dev.com/blog/hiring-trends']);
  assert.deepEqual(state.discovery, before);
  assert.equal(canBeNewsArticleURL('javascript:alert(1)'), false);
});

test('discovery run errors state the retained-results guarantee exactly once', () => {
  assert.equal(discoveryRunError('AI', 'PI found sources, but their pages could not be retrieved. Saved results are retained; try again.'),
    'AI: PI found sources, but their pages could not be retrieved. Saved results are retained; try again.');
  assert.equal(discoveryRunError('AI', 'The source could not be reached.'), 'AI: The source could not be reached. Saved results are retained.');
  assert.equal(discoveryRunError('AI', 'PI timed out. Your saved data is kept.'), 'AI: PI timed out. Your saved data is kept.');
});
