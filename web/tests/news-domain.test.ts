import test from 'node:test';
import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { interestDraftSchema, interestSchema, interestPresets, interestWordCount, relevanceForInterest, articleInterestFits, newsSearchQuery, canBeNewsArticleURL,
  visibleDiscoveries, discoveryRunError, type NewsInterest, type NewsResponse, type DiscoveredArticle } from '../shared/news';
import { groupNewsByDate } from '../shared/news-dates';
import { briefingStories } from '../shared/briefing';
import { emptyWorkspace } from '../shared/workspace';
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
test('briefing and discoveries prioritize publication dates over stronger older matches and recent retrieval of undated stories', () => {
  const i = interest(), rows = [article({ id: 'older', publishedAt: '2026-10-03T04:00:00Z' }),
    article({ id: 'undated', title: 'Undated sponsorship listing for developers', publishedAt: null }),
    article({ id: 'newer', title: 'Space telescope observes distant nebula', publishedAt: '2026-10-05T01:00:00Z' })];
  const state = newsState(rows), workspace = emptyWorkspace(randomUUID()); workspace.profile.interests = [i.query];
  assert.deepEqual(briefingStories(state, workspace, now).map(group => group.lead.id), ['newer', 'older', 'undated']);
  state.discovery.preferences.interests = [i];
  state.discovery.articles = rows.map((row, index) => ({ ...row, matches: [{ interestID: i.id, interestRevision: i.revision, mode: 'search', score: index === 0 ? 99 : 1, reason: 'Fixture' }] }));
  assert.deepEqual(visibleDiscoveries(state.discovery, undefined, now).map(row => row.id), ['newer', 'older', 'undated']);
});
test('briefing recognizes detailed profile descriptions when breaking publication-time ties', () => {
  const match = article(), unrelated = article({ title: 'Space telescope observes distant nebula' });
  const state = newsState([unrelated, match]), workspace = emptyWorkspace(randomUUID());
  workspace.profile.interests = ['Software developer roles with Japan visa sponsorship'];
  assert.equal(briefingStories(state, workspace, now)[0].lead.url, match.url);
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
