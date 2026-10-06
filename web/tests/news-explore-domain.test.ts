import test from 'node:test';
import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { interestDraftSchema, interestSchema, type InterestDraft, type NewsInterest } from '../shared/news';
import {
  EXPLORE_MAX_SESSIONS, EXPLORE_SESSION_TTL_MS, EXPLORE_CLIENT_RETENTION_MS, EXPLORE_MAX_TOPICS,
  EXPLORE_MAX_ARTICLES_PER_TOPIC, EXPLORE_MAX_ARTICLES, EXPLORE_MAX_RETAINED_BYTES, EXPLORE_MAX_FOLLOW_SUBMISSIONS,
  EXPLORE_MAX_GENERATIONS, EXPLORE_MAX_CONCURRENT_SEARCHES, EXPLORE_MAX_SEARCHES_PER_TOPIC,
  EXPLORE_MAX_MODEL_BYTES, EXPLORE_MAX_MODEL_CANDIDATES, EXPLORE_AVAILABILITY_DEADLINE_MS, EXPLORE_IDEATION_DEADLINE_MS,
  EXPLORE_GENERATION_DEADLINE_MS, EXPLORE_GENERATION_CLIENT_DEADLINE_MS, EXPLORE_SEARCH_DEADLINE_MS,
  EXPLORE_SEARCH_CLIENT_DEADLINE_MS, EXPLORE_RECOVERY_DEADLINE_MS, EXPLORE_RECOVERY_CLIENT_DEADLINE_MS,
  EXPLORE_FOLLOW_DEADLINE_MS, EXPLORE_FOLLOW_CLIENT_DEADLINE_MS,
  EXPLORE_MAX_TITLE_CHARS, EXPLORE_MAX_DESCRIPTION_CHARS, EXPLORE_MAX_CONNECTION_CHARS, EXPLORE_MAX_QUERY_CHARS,
  exploreBytes, exploreExpired, exploreSourceCurrent, exploreSourcesSchema, exploreSearchSchema,
  proposedExploreSearch, exploreSearchDescriptor, exploreModelCandidateSchema, validateExploreIdeas,
  normalizeExploreTitle, normalizeExploreQuery, exploreArticleSchema, explorePreviewSchema, exploreSessionSchema,
  exploreGenerateRequestSchema, exploreSearchRequestSchema, exploreFollowRequestSchema, exploreTopicParamsSchema,
  exploreStatusResponseSchema, exploreGenerateResponseSchema, exploreSearchResponseSchema, exploreFollowResponseSchema,
  exploreErrorSchema, EXPLORE_ERROR_HTTP_STATUS, exploreFollowKey, equivalentExploreInterest,
  type ExploreArticle, type ExploreSearch, type ExploreSession,
} from '../shared/news-explore';

const at = '2026-10-06T10:00:00.000Z';
const later = '2026-10-06T10:05:00.000Z';
const source = (overrides: Partial<NewsInterest> = {}): NewsInterest => ({
  id: randomUUID(), revision: randomUUID(), name: 'AI model releases', query: 'AI models releases benchmarks open weights',
  language: 'en', region: 'US', days: 7, intent: 'news', requiredTerms: ['model|models'], excludedTerms: ['stock'], enabled: true, ...overrides,
});
const search = (overrides: Partial<ExploreSearch> = {}): ExploreSearch => ({
  query: 'Data center power grid cooling infrastructure', language: 'en', region: 'US', days: 7, ...overrides,
});
const candidate = (parent: NewsInterest, overrides: Record<string, unknown> = {}) => ({
  sourceInterestID: parent.id, title: 'Computing infrastructure', description: 'Explore the systems supporting computing.',
  connection: 'An adjacent direction to model development.', query: search().query, ...overrides,
});
const article = (overrides: Partial<ExploreArticle> = {}): ExploreArticle => ({
  id: randomUUID(), title: 'Retrieved fixture', url: 'https://example.com/articles/' + randomUUID(), source: 'Fixture',
  summary: 'Source excerpt', publishedAt: null, fetchedAt: at, summaryKind: 'source', feedIDs: [], topicIDs: [], ...overrides,
});
const session = (): ExploreSession => {
  const parent = source();
  return { id: randomUUID(), revision: randomUUID(), generatedAt: at,
    expiresAt: new Date(Date.parse(at) + EXPLORE_SESSION_TTL_MS).toISOString(), sources: [{ id: parent.id, revision: parent.revision }],
    topics: [{ id: randomUUID(), sourceInterestID: parent.id, sourceInterestRevision: parent.revision,
      title: 'Computing infrastructure', description: 'Explore supporting systems.', connection: 'Adjacent to model development.',
      proposedSearch: search(), status: 'available', preview: { state: 'not-searched' } }],
  };
};
const draft = (overrides: Partial<InterestDraft> = {}): InterestDraft => ({
  name: 'Computing infrastructure', ...search(), intent: 'news', requiredTerms: [], excludedTerms: [], enabled: true, ...overrides,
});
const error = { code: 'search-failed', error: 'Search failed. Previous coverage is retained.' } as const;

test('named lifecycle bounds are finite, absolute, and align client deadlines with server deadlines', () => {
  assert.deepEqual([EXPLORE_MAX_SESSIONS, EXPLORE_MAX_TOPICS, EXPLORE_MAX_ARTICLES_PER_TOPIC, EXPLORE_MAX_ARTICLES,
    EXPLORE_MAX_FOLLOW_SUBMISSIONS, EXPLORE_MAX_GENERATIONS, EXPLORE_MAX_CONCURRENT_SEARCHES, EXPLORE_MAX_SEARCHES_PER_TOPIC],
  [1, 3, 40, 120, 64, 1, 2, 1]);
  assert.equal(EXPLORE_MAX_RETAINED_BYTES, 8 * 1024 * 1024);
  assert.equal(EXPLORE_SESSION_TTL_MS, 30 * 60_000);
  assert.equal(EXPLORE_CLIENT_RETENTION_MS, EXPLORE_SESSION_TTL_MS);
  assert.equal(EXPLORE_GENERATION_DEADLINE_MS, EXPLORE_AVAILABILITY_DEADLINE_MS + EXPLORE_IDEATION_DEADLINE_MS);
  for (const [server, client] of [[EXPLORE_GENERATION_DEADLINE_MS, EXPLORE_GENERATION_CLIENT_DEADLINE_MS],
    [EXPLORE_SEARCH_DEADLINE_MS, EXPLORE_SEARCH_CLIENT_DEADLINE_MS], [EXPLORE_RECOVERY_DEADLINE_MS, EXPLORE_RECOVERY_CLIENT_DEADLINE_MS],
    [EXPLORE_FOLLOW_DEADLINE_MS, EXPLORE_FOLLOW_CLIENT_DEADLINE_MS]]) {
    assert.ok(Number.isFinite(server) && server > 0 && client > server);
  }
  const value = session();
  assert.equal(exploreExpired(value.expiresAt, Date.parse(value.expiresAt) - 1), false);
  assert.equal(exploreExpired(value.expiresAt, Date.parse(value.expiresAt)), true);
  assert.equal(exploreExpired(value.expiresAt, Date.parse(value.expiresAt) + 1), true);
  assert.equal(exploreBytes('日本'), Buffer.byteLength(JSON.stringify('日本')));
});

test('preview queries always enforce existing English/Japanese word rules and supported defaults', () => {
  for (const query of ['AI model release benchmark', 'AI OR model OR release AND NOT', 'AI site:example.com -"extra excluded search words"',
    'AI model when:7d before:2026-10-06 after:2026-10-01 intitle:release inurl:benchmark']) {
    assert.equal(exploreSearchSchema.safeParse(search({ query })).success, false, query);
  }
  assert.equal(exploreSearchSchema.safeParse(search({ query: '東京 ソフトウェア 開発 求人 ビザ', language: 'ja' })).success, true);
  assert.equal(exploreSearchSchema.safeParse(search({ query: '東京でソフトウェア開発者の求人を探す', language: 'ja' })).success, true);
  assert.equal(exploreSearchSchema.safeParse(search({ query: 'AI model release benchmark -cooling', language: 'en' })).success, false);
  for (const extra of [{ enabled: false }, { intent: 'opportunities' }, { mode: 'ai' }, { requiredTerms: ['AI'] }, { excludedTerms: ['cooling'] }]) {
    assert.equal(exploreSearchSchema.safeParse({ ...search(), ...extra }).success, false);
  }
  for (const invalid of [{ days: 14 }, { language: 'fr' }, { region: 'DE' }]) assert.equal(exploreSearchSchema.safeParse({ ...search(), ...invalid }).success, false);
  const queryPrefix = 'power grid cooling energy ';
  const boundedQuery = queryPrefix + 'x'.repeat(EXPLORE_MAX_QUERY_CHARS - queryPrefix.length);
  assert.equal(boundedQuery.length, EXPLORE_MAX_QUERY_CHARS);
  assert.equal(exploreSearchSchema.safeParse(search({ query: boundedQuery })).success, true);
  assert.equal(exploreSearchSchema.safeParse(search({ query: boundedQuery + 'x' })).success, false);
  const parent = source({ language: 'ja', region: 'JP', days: 30, intent: 'opportunities' });
  const proposed = proposedExploreSearch('東京 ソフトウェア 開発 求人 ビザ', parent);
  const descriptor = exploreSearchDescriptor({ id: randomUUID(), revision: randomUUID() }, 'Adjacent direction', proposed);
  assert.deepEqual([descriptor.language, descriptor.region, descriptor.days, descriptor.intent, descriptor.enabled], ['ja', 'JP', 30, 'news', true]);
  assert.deepEqual(descriptor.requiredTerms, []); assert.deepEqual(descriptor.excludedTerms, []);
  assert.notEqual(descriptor.id, parent.id);
  assert.deepEqual(parent.requiredTerms, ['model|models']);
  // New contracts do not rewrite the shared legacy/backup boundary.
  assert.equal(interestSchema.safeParse(source({ query: 'AI' })).success, false); // existing minimum length is 3
  assert.equal(interestSchema.safeParse(source({ query: 'Japan' })).success, true);
  assert.equal(interestDraftSchema.safeParse(draft({ query: 'Japan', enabled: false })).success, true);
  assert.equal(exploreSearchSchema.safeParse(search({ query: 'Japan' })).success, false);
});

test('model candidates enforce text boundaries and reject evidence and model-issued identities', () => {
  const parent = source();
  for (const [field, limit] of [['title', EXPLORE_MAX_TITLE_CHARS], ['description', EXPLORE_MAX_DESCRIPTION_CHARS],
    ['connection', EXPLORE_MAX_CONNECTION_CHARS], ['query', EXPLORE_MAX_QUERY_CHARS]] as const) {
    assert.equal(exploreModelCandidateSchema.safeParse(candidate(parent, { [field]: 'x'.repeat(limit) })).success, true, field);
    assert.equal(exploreModelCandidateSchema.safeParse(candidate(parent, { [field]: 'x'.repeat(limit + 1) })).success, false, field);
    assert.equal(exploreModelCandidateSchema.safeParse(candidate(parent, { [field]: ' \n ' })).success, false, field);
    assert.equal(exploreModelCandidateSchema.safeParse(candidate(parent, { [field]: 'https://publisher.example/story' })).success, false, field);
  }
  for (const extra of [{ id: randomUUID() }, { revision: randomUUID() }, { sourceInterestRevision: parent.revision },
    { articles: [article()] }, { headline: 'Unverified news' }, { evidence: ['https://example.com/story'] }]) {
    assert.equal(exploreModelCandidateSchema.safeParse(candidate(parent, extra)).success, false);
  }
});

test('bounded envelopes reject malformed output while valid siblings survive independently without filler', () => {
  const parent = source(), disabled = source({ enabled: false });
  for (const text of ['no JSON', 'null', '[]', '{}', JSON.stringify({ topics: [], explanation: 'extra' }),
    JSON.stringify({ topics: Array(EXPLORE_MAX_MODEL_CANDIDATES + 1).fill(candidate(parent)) }), ' '.repeat(EXPLORE_MAX_MODEL_BYTES + 1)]) {
    assert.deepEqual(validateExploreIdeas(text, [parent]), { state: 'invalid-envelope' });
  }
  const result = validateExploreIdeas(JSON.stringify({ topics: [null, candidate(parent, { sourceInterestID: randomUUID() }),
    candidate(disabled), candidate(parent, { query: 'AI model release' }), candidate(parent, { evidence: [] }), candidate(parent)] }), [parent, disabled]);
  assert.equal(result.state, 'accepted');
  if (result.state !== 'accepted') return;
  assert.equal(result.ideas.length, 1); assert.equal(result.partial, true); assert.equal(result.rejectedCount, 5);
  assert.deepEqual(result.ideas[0].proposedSearch, search());
  assert.equal(result.ideas[0].sourceInterestRevision, parent.revision);
  assert.equal('id' in result.ideas[0], false);
  assert.deepEqual(validateExploreIdeas('{"topics":[]}', [parent]), { state: 'no-valid-ideas', rejectedCount: 0 });
  assert.deepEqual(validateExploreIdeas('{"topics":[null]}', [parent]), { state: 'no-valid-ideas', rejectedCount: 1 });
  const text = JSON.stringify({ topics: [candidate(parent)] });
  assert.equal(validateExploreIdeas(text + ' '.repeat(EXPLORE_MAX_MODEL_BYTES - Buffer.byteLength(text)), [parent]).state, 'accepted');
});

test('obvious duplicate normalization is deterministic, source-aware and makes no semantic novelty claim', () => {
  const parent = source();
  assert.equal(normalizeExploreTitle(' ＡＩ—Model  Releases! '), normalizeExploreTitle(parent.name));
  assert.equal(normalizeExploreQuery(' ＡＩ  -jobs OR "model releases" '), 'AI -jobs OR "model releases"');
  assert.notEqual(normalizeExploreQuery('AI -jobs model'), normalizeExploreQuery('AI jobs model'));
  const topics = [candidate(parent, { title: 'ＡＩ—Model Releases!' }), candidate(parent, { query: '  ' + parent.query.replaceAll(' ', '  ') + '  ' }),
    candidate(parent), candidate(parent, { title: ' COMPUTING—Infrastructure! ', query: 'different valid search query with words' }),
    candidate(parent, { title: 'Another idea', query: search().query + '  ' }),
    candidate(parent, { title: 'Public archives', query: 'Public archives language preservation research tools' }),
    candidate(parent, { title: 'Urban cooling', query: 'Urban cooling district heating infrastructure research' })];
  const result = validateExploreIdeas(JSON.stringify({ topics }), [parent]);
  assert.equal(result.state, 'accepted');
  if (result.state !== 'accepted') return;
  assert.deepEqual(result.ideas.map(idea => idea.title), ['Computing infrastructure', 'Public archives', 'Urban cooling']);
  assert.equal(result.partial, false); assert.equal(result.rejectedCount, 4);
});

test('query identity preserves case-sensitive Boolean syntax for duplicate ideas and follow equivalence', () => {
  for (const operator of ['OR', 'AND', 'NOT']) {
    const first = draft({ query: `power grid cooling ${operator} energy infrastructure research` });
    const literal = draft({ ...first, query: first.query.replace(operator, operator.toLowerCase()) });
    assert.notEqual(normalizeExploreQuery(first.query), normalizeExploreQuery(literal.query), operator);
    assert.notEqual(exploreFollowKey(first), exploreFollowKey(literal), operator);
    assert.equal(equivalentExploreInterest(first, source(literal)), false, operator);
    assert.equal(equivalentExploreInterest(literal, source(first)), false, operator);
    assert.equal(equivalentExploreInterest(first, source({ ...first, query: '  ' + first.query.replaceAll(' ', '  ') + '  ' })), true);
    const parent = source(first);
    const result = validateExploreIdeas(JSON.stringify({ topics: [candidate(parent, {
      title: 'Distinct search direction', query: literal.query,
    })] }), [parent]);
    assert.equal(result.state, 'accepted', operator);
  }
});

test('request contracts require server-issued UUID references and reject arbitrary article evidence', () => {
  const revision = randomUUID();
  assert.equal(exploreGenerateRequestSchema.safeParse({}).success, true);
  for (const body of [{ interests: [source()] }, { articles: [article()] }, { prompt: 'private context' }]) {
    assert.equal(exploreGenerateRequestSchema.safeParse(body).success, false);
  }
  assert.equal(exploreTopicParamsSchema.safeParse({ sessionID: randomUUID(), topicID: randomUUID() }).success, true);
  assert.equal(exploreTopicParamsSchema.safeParse({ sessionID: 'model-id', topicID: randomUUID() }).success, false);
  const body = { expectedSessionRevision: revision, search: search() };
  assert.equal(exploreSearchRequestSchema.safeParse(body).success, true);
  for (const extra of [{ article: article() }, { mode: 'ai' }, { topics: [] }]) assert.equal(exploreSearchRequestSchema.safeParse({ ...body, ...extra }).success, false);
  const follow = { expectedSessionRevision: revision, submissionID: randomUUID(), draft: draft() };
  assert.equal(exploreFollowRequestSchema.safeParse(follow).success, true);
  assert.equal(exploreFollowRequestSchema.safeParse({ ...follow, draft: { ...draft(), id: randomUUID() } }).success, false);
  assert.equal(exploreFollowRequestSchema.safeParse({ ...follow, draft: draft({ query: 'short query' }) }).success, false);
  assert.equal(exploreFollowRequestSchema.safeParse({ ...follow, submissionID: 'model-issued' }).success, false);
  assert.equal(exploreFollowRequestSchema.safeParse({ ...follow, article: article() }).success, false);
});

test('runtime preview evidence uses snapshot URL/date/size validation and source provenance only', () => {
  assert.equal(exploreArticleSchema.safeParse(article()).success, true);
  for (const invalid of [{ url: 'javascript:alert(1)' }, { url: 'https://user:secret@example.com/story' },
    { publishedAt: 'unknown' }, { fetchedAt: 'yesterday' }, { summary: 'x'.repeat(50_001) }, { title: '' },
    { summaryKind: 'ai-snippet' }, { matches: [{ interestID: randomUUID() }] }, { feedIDs: [randomUUID()] }, { topicIDs: [randomUUID()] }]) {
    assert.equal(exploreArticleSchema.safeParse({ ...article(), ...invalid }).success, false);
  }
});

test('preview lifecycle separates producing coverage from attempted searches and successful emptiness', () => {
  const previous = { search: search(), succeededAt: at, articles: [article()] };
  const attempt = { requestID: randomUUID(), search: search({ query: 'New grid energy demand research policy' }), startedAt: later };
  const retained = explorePreviewSchema.parse({ state: 'failed-retained', attempt, error, previous });
  assert.deepEqual(retained, { state: 'failed-retained', attempt, error, previous });
  assert.notEqual(previous.search.query, attempt.search.query);
  assert.equal(explorePreviewSchema.safeParse({ state: 'failed-retained', attempt, error }).success, false);
  assert.equal(explorePreviewSchema.safeParse({ state: 'failed', attempt, error, previous }).success, false);
  assert.equal(explorePreviewSchema.safeParse({ state: 'failed-retained', attempt: { ...attempt, startedAt: at }, error,
    previous: { ...previous, succeededAt: later } }).success, false);
  assert.equal(explorePreviewSchema.safeParse({ state: 'successful-empty', result: { ...previous, articles: [] } }).success, true);
  assert.equal(explorePreviewSchema.safeParse({ state: 'successful-empty', result: previous }).success, false);
  assert.equal(explorePreviewSchema.safeParse({ state: 'successful', result: { ...previous, articles: [] } }).success, false);
  assert.equal(explorePreviewSchema.safeParse({ state: 'successful', result: { ...previous, articles: Array.from({ length: 40 }, () => article()) } }).success, true);
  assert.equal(explorePreviewSchema.safeParse({ state: 'successful', result: { ...previous, articles: Array.from({ length: 41 }, () => article()) } }).success, false);
  const duplicate = previous.articles[0];
  assert.equal(explorePreviewSchema.safeParse({ state: 'successful', result: { ...previous, articles: [duplicate,
    { ...duplicate, id: randomUUID(), url: duplicate.url + '?utm_source=fixture#comments' }] } }).success, false);
  for (const state of ['not-searched', 'obsolete', 'expired']) {
    assert.equal(explorePreviewSchema.safeParse({ state }).success, true);
    assert.equal(explorePreviewSchema.safeParse({ state, result: previous }).success, false);
  }
  for (const state of ['pending', 'uncertain']) assert.equal(explorePreviewSchema.safeParse({ state, attempt, previous }).success, true);
});

test('session contracts bound lifetime, source revisions, topic counts, duplicates and retained bytes', () => {
  const value = session();
  assert.equal(exploreSessionSchema.safeParse(value).success, true);
  assert.equal(exploreSessionSchema.safeParse({ ...value, expiresAt: at }).success, false);
  assert.equal(exploreSessionSchema.safeParse({ ...value, expiresAt: new Date(Date.parse(value.expiresAt) + 1).toISOString() }).success, false);
  assert.equal(exploreSessionSchema.safeParse({ ...value, topics: [] }).success, false);
  assert.equal(exploreSessionSchema.safeParse({ ...value, topics: Array(4).fill(value.topics[0]) }).success, false);
  assert.equal(exploreSessionSchema.safeParse({ ...value, topics: [value.topics[0], { ...value.topics[0], id: randomUUID() }] }).success, false);
  const full = { ...value, topics: [0, 1, 2].map(index => ({ ...value.topics[0], id: randomUUID(), title: 'Direction ' + index,
    proposedSearch: search({ query: search().query + ' ' + index }), preview: { state: 'successful', result: {
      search: search({ query: search().query + ' ' + index }), succeededAt: at, articles: Array.from({ length: 40 }, () => article()),
    } } })) };
  assert.equal(exploreSessionSchema.safeParse(full).success, true);
  assert.equal(exploreSessionSchema.safeParse({ ...full, topics: [full.topics[0], { ...full.topics[1], id: full.topics[0].id }] }).success, false);
  assert.equal(exploreSessionSchema.safeParse({ ...value, sources: [{ ...value.sources[0], revision: randomUUID() }] }).success, false);
  assert.equal(exploreSourcesSchema.safeParse([value.sources[0], value.sources[0]]).success, false);
  const obsolete = { ...value.topics[0], status: 'obsolete' };
  assert.equal(exploreSessionSchema.safeParse({ ...value, topics: [obsolete] }).success, false);
  assert.equal(exploreSessionSchema.safeParse({ ...value, topics: [{ ...obsolete, preview: { state: 'obsolete' } }] }).success, true);
  const huge = { ...value, topics: [{ ...value.topics[0], preview: { state: 'successful', result: {
    search: search(), succeededAt: at, articles: Array.from({ length: 40 }, () => article({ summary: '\u0000'.repeat(50_000) })),
  } } }] };
  assert.ok(exploreBytes(huge) > EXPLORE_MAX_RETAINED_BYTES);
  assert.equal(exploreSessionSchema.safeParse(huge).success, false);
  const parent = source(), snapshot = { id: parent.id, revision: parent.revision };
  assert.equal(exploreSourceCurrent(snapshot, [parent]), true);
  for (const interests of [[], [{ ...parent, revision: randomUUID() }], [{ ...parent, enabled: false }]]) {
    assert.equal(exploreSourceCurrent(snapshot, interests), false);
  }
});

test('response and error contracts are strict and expose explicit lifecycle/activity/partial states', () => {
  const value = session();
  for (const state of ['absent', 'obsolete', 'expired']) assert.equal(exploreStatusResponseSchema.safeParse({ lifecycle: { state }, generation: { state: 'idle' } }).success, true);
  assert.equal(exploreStatusResponseSchema.safeParse({ lifecycle: { state: 'available', session: value },
    generation: { state: 'pending', requestID: randomUUID(), startedAt: at } }).success, true);
  assert.equal(exploreStatusResponseSchema.safeParse({ lifecycle: { state: 'expired', session: value }, generation: { state: 'idle' } }).success, false);
  assert.equal(exploreGenerateResponseSchema.safeParse({ session: value, partial: true }).success, true);
  assert.equal(exploreGenerateResponseSchema.safeParse({ session: value, partial: false }).success, false);
  assert.equal(exploreGenerateResponseSchema.safeParse({ session: value, partial: true, evidence: [] }).success, false);
  assert.equal(exploreSearchResponseSchema.safeParse({ sessionID: value.id, sessionRevision: value.revision, topicID: value.topics[0].id, preview: { state: 'not-searched' } }).success, true);
  assert.equal(exploreFollowResponseSchema.safeParse({ interest: source(), created: false }).success, true);
  assert.equal(exploreErrorSchema.safeParse(error).success, true);
  assert.equal(exploreErrorSchema.safeParse({ ...error, prompt: 'private' }).success, false);
  assert.equal(EXPLORE_ERROR_HTTP_STATUS['session-gone'], 410);
  assert.equal(EXPLORE_ERROR_HTTP_STATUS['obsolete-source'], 409);
  assert.equal(EXPLORE_ERROR_HTTP_STATUS['follow-capacity'], 400);
});

test('follow equivalence ignores cosmetic names but preserves search semantics, locale, enabled state and filters', () => {
  const first = draft({ requiredTerms: ['grid|power', 'cooling'], excludedTerms: ['stock price', 'jobs'] });
  const existing = source({ ...first, name: 'Different cosmetic title', query: ' Ｄata  center power grid cooling infrastructure ',
    requiredTerms: ['COOLING', 'grid|power'], excludedTerms: ['JOBS', 'stock price'] });
  assert.equal(equivalentExploreInterest(first, existing), true);
  for (const change of [{ query: first.query + ' -jobs' }, { query: '"Data center" power grid cooling infrastructure' },
    { language: 'ja' as const }, { region: 'JP' as const }, { days: 30 as const }, { intent: 'opportunities' as const },
    { enabled: false }, { requiredTerms: ['grid', 'power', 'cooling'] }, { excludedTerms: ['jobs'] }]) {
    assert.equal(equivalentExploreInterest(first, { ...existing, ...change }), false, JSON.stringify(change));
  }
  assert.notEqual(exploreFollowKey(first), exploreFollowKey({ ...first, requiredTerms: ['power|grid', 'cooling'] }));
  assert.equal(equivalentExploreInterest(first, source({ query: 'Japan' })), false);
  assert.throws(() => exploreFollowKey(draft({ query: 'too short' })));
  assert.throws(() => exploreFollowKey({ ...first, url: 'https://example.com/' } as InterestDraft));
});
