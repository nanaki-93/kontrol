import test from 'node:test';
import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { interestPresets, type NewsInterest } from '../shared/news';
import { aiRequest, parseAIResponse, aiDiscovery, aiSources, webSearchURL, type AISource } from '../server/news/ai';

const now = Date.parse('2026-10-02T12:00:00Z');
const interest: NewsInterest = { ...interestPresets[1], id: randomUUID(), revision: randomUUID() };
const source = (overrides: Partial<AISource> = {}): AISource => ({ title: 'New AI model release', url: 'https://example.com/model',
  summary: 'A new language model with benchmark results.', publishedAt: '2026-10-01T10:00:00.000Z', ...overrides });
const item = (overrides = {}) => ({ url: 'https://example.com/model', summary: 'A new language model with benchmark results.',
  relevance: 95, reason: 'Announces a model release with benchmark results.', ...overrides });
const response = (articles = [item()]) => JSON.stringify({ articles });

test('PI prompt sends only the selected interest, filters and bounded retrieved source fields', () => {
  const payload = JSON.parse(aiRequest({ ...interest, privateData: 'must not be sent' } as NewsInterest, [source()], now));
  assert.deepEqual(Object.keys(payload).sort(), ['instructions', 'currentDate', 'since', 'interest', 'language', 'region', 'intent', 'requiredKeywordGroups', 'excludedPhrases', 'sources'].sort());
  assert.equal(payload.interest, interest.query);
  assert.deepEqual(payload.sources, [source()]);
  assert.equal(JSON.stringify(payload).includes('must not be sent'), false);
});
test('PI accepts only retrieved URLs, deduplicates and preserves source titles and unknown dates', () => {
  const rows = parseAIResponse(response([item({ url: 'https://example.com/model?utm_source=search#section',
    publishedAt: '2026-10-02', title: 'Invented title' }), item()]), [source({ publishedAt: null })], interest, now);
  assert.equal(rows.length, 1);
  assert.equal(rows[0].url, 'https://example.com/model');
  assert.equal(rows[0].title, source().title);
  assert.equal(rows[0].publishedAt, null);
  assert.equal(rows[0].source, 'example.com');
  assert.equal(rows[0].matches[0].mode, 'ai');
  assert.equal(rows[0].matches[0].reason, item().reason);
});
test('PI drops invented URLs, weak matches, private links, exclusions and out-of-window source dates', () => {
  const cases: [ReturnType<typeof item>, AISource[]][] = [
    [item({ url: 'https://invented.example/model' }), [source()]],
    [item({ relevance: 12 }), [source()]],
    [item({ url: 'http://127.0.0.1/secret' }), [source({ url: 'http://127.0.0.1/secret' })]],
    [item({ summary: 'stock price went up' }), [source()]],
    ...['2025-01-01T00:00:00Z', '2030-01-01T00:00:00Z', 'unknown'].map(date => [item(), [source({ publishedAt: date })]] as [ReturnType<typeof item>, AISource[]]),
    [item({ summary: 'A travel report.' }), [source({ title: 'Travel in Japan' })]],
  ];
  for (const [candidate, sources] of cases) {
    assert.throws(() => parseAIResponse(response([candidate]), sources, interest, now), /citation, date and interest checks/);
  }
  assert.equal(parseAIResponse(response(), [source()], interest, now)[0].publishedAt, source().publishedAt);
});
test('malformed PI responses do not become successful empty searches; fenced JSON is supported', () => {
  for (const invalid of ['Not JSON', '{"articles":null}', response([item({ relevance: 101 })])]) {
    assert.throws(() => parseAIResponse(invalid, [source()], interest, now), /unreadable/);
  }
  assert.deepEqual(parseAIResponse(response([]), [source()], interest, now), []);
  assert.equal(parseAIResponse('```json\n' + response() + '\n```', [source()], interest, now).length, 1);
});
const rss = (url = 'https://example.com/model') => '<rss><channel><item><title>New AI model release</title><link>' + url + '</link><description>A new language model with benchmark results.</description><pubDate>Thu, 01 Oct 2026 10:00:00 GMT</pubDate></item></channel></rss>';
test('AI retrieves news and wider-web evidence with public URL checks and shared cancellation', async () => {
  const signal = new AbortController().signal, urls: string[] = [];
  const sources = await aiSources(interest, now, signal, async (url, redirects, providedSignal) => {
    urls.push(url); assert.equal(redirects, 0); assert.equal(providedSignal, signal);
    return rss(url.includes('bing.com') ? 'https://example.org/job' : 'https://example.com/model');
  });
  assert.deepEqual(urls.map(url => new URL(url).hostname).sort(), ['news.google.com', 'www.bing.com']);
  assert.equal(sources.length, 2);
  assert.equal(sources[0].publishedAt, source().publishedAt);
  assert.equal(sources[1].publishedAt, null, 'General web search dates must not masquerade as publication dates');
  assert.equal(new URL(webSearchURL(interest)).searchParams.get('format'), 'rss');
  assert.equal(new URL(webSearchURL(interest)).searchParams.get('cc'), 'US');
  assert.equal(new URL(webSearchURL(interest)).searchParams.get('q')?.includes('-"stock price"'), true);
  assert.deepEqual(await aiSources(interest, now, signal, async () => rss('http://127.0.0.1/private')), []);
});
test('failed search sources cannot masquerade as empty success and partial usable evidence is retained', async () => {
  const signal = new AbortController().signal;
  await assert.rejects(aiSources(interest, now, signal, async () => { throw new Error('sensitive details'); }), /Live search sources/);
  await assert.rejects(aiSources(interest, now, signal, async url => {
    if (url.includes('bing.com')) throw new Error('offline');
    return '<rss><channel/></rss>';
  }), /Live search sources/);
  assert.equal((await aiSources(interest, now, signal, async url => {
    if (url.includes('bing.com')) throw new Error('offline');
    return rss();
  })).length, 1);
});
test('an undated web duplicate cannot revive a source with a known expired publication date', async () => {
  const sources = await aiSources(interest, now, new AbortController().signal, async () => rss().replace('01 Oct 2026', '01 Oct 2025'));
  assert.deepEqual(sources, []);
});
test('AI calls PI once, shares a deadline, sanitizes errors, and skips paid inference for empty search', async () => {
  let calls = 0;
  let searchSignal: AbortSignal | undefined;
  const adapter = aiDiscovery({ sources: async (_interest, _at, signal) => {
    searchSignal = signal; return [source({ publishedAt: null })];
  }, run: async (prompt, _options, signal) => {
    calls++; assert.equal(signal, searchSignal); assert.equal(JSON.parse(prompt).interest, interest.query); return response();
  } });
  assert.equal((await adapter(interest)).length, 1);
  assert.equal(calls, 1);
  const failed = aiDiscovery({ sources: async () => [source()], run: async () => { calls++; throw new Error('secret-from-provider'); } });
  await assert.rejects(failed(interest), error => error instanceof Error && !error.message.includes('secret-from-provider'));
  assert.equal(calls, 2, 'No automatic retries');
  const empty = aiDiscovery({ sources: async () => [], run: async () => { throw new Error('Must not run PI'); } });
  assert.deepEqual(await empty(interest), []);
});
