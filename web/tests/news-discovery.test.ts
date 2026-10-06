import test from 'node:test';
import assert from 'node:assert/strict';
import { createHash, randomUUID } from 'node:crypto';
import http, { createServer, request, type RequestOptions } from 'node:http';
import dns from 'node:dns/promises';
import { syncBuiltinESMExports } from 'node:module';
import type { AddressInfo } from 'node:net';
import { Readable, Transform } from 'node:stream';
import { createGunzip, gzipSync } from 'node:zlib';
import { interestPresets, matchesInterest, visibleDiscoveries, type NewsInterest, type DiscoveredArticle } from '../shared/news';
import { pinnedLookup, fetchFeed, newsErrorMessage, requestHeaders, pageRequestOptions, collectBody, redirectLimit, PAGE_USER_AGENT } from '../server/news/transport';
import { parseFeed } from '../server/news/feeds';
import { initialDiscovery, mergeDiscovery, searchDiscovery, searchURL, STANDARD_SEARCH_TIMEOUT_MS } from '../server/news/discovery';

const now = Date.parse('2026-10-02T12:00:00Z');
const interest = (overrides: Partial<NewsInterest> = {}): NewsInterest => ({ ...interestPresets[1], id: randomUUID(), revision: randomUUID(), ...overrides });
const result = (i: NewsInterest, overrides: Partial<DiscoveredArticle> = {}): DiscoveredArticle => ({
  id: createHash('sha256').update('https://example.com/release').digest('hex'), title: 'New AI model release', url: 'https://example.com/release',
  summary: 'A benchmark of the new language model.', source: 'Example', publishedAt: new Date(now - 3600_000).toISOString(),
  fetchedAt: new Date(now).toISOString(), feedIDs: [], topicIDs: [],
  matches: [{ interestID: i.id, interestRevision: i.revision, mode: 'search', score: 90, reason: 'Matches' }], ...overrides,
});

test('pinned DNS lookup works with real Node auto-family selection and single-family requests', async () => {
  const server = createServer((_req, res) => res.end('fixture RSS'));
  await new Promise<void>(resolve => server.listen(0, '127.0.0.1', resolve));
  try {
    for (const autoSelectFamily of [true, false]) {
      const response = await new Promise<string>((resolve, reject) => {
        const options: RequestOptions & { autoSelectFamily: boolean } = { hostname: 'isolated-fixture.test', port: (server.address() as AddressInfo).port,
          autoSelectFamily, lookup: pinnedLookup([{ address: '127.0.0.1', family: 4 }]), agent: false };
        const req = request(options, res => {
          let body = ''; res.setEncoding('utf8'); res.on('data', chunk => body += chunk); res.on('end', () => resolve(body));
        });
        req.on('error', reject); req.end();
      });
      assert.equal(response, 'fixture RSS');
    }
  } finally { await new Promise<void>((resolve, reject) => server.close(error => error ? reject(error) : resolve())); }
});
test('real transport rejects local addresses before opening any socket', async () => {
  for (const url of ['http://127.0.0.1/feed', 'http://[::1]/feed', 'http://169.254.169.254/']) {
    await assert.rejects(fetchFeed(url), /public internet addresses/);
  }
  assert.match(newsErrorMessage({ code: 'ENOTFOUND' }), /resolved/);
  assert.doesNotMatch(newsErrorMessage(new Error('secret API key')), /secret/);
});
test('feed requests keep the Kontrol agent while the News AI page profile looks like a browser', () => {
  const feed = requestHeaders();
  assert.equal(feed['User-Agent'], 'Kontrol-Web/0.2');
  assert.equal(feed.Accept, 'application/rss+xml, application/atom+xml, application/xml, text/xml');
  assert.equal(feed['Accept-Encoding'], 'gzip, deflate, br');
  assert.equal('Accept-Language' in feed, false);
  const jobs = requestHeaders({ accept: 'application/json, text/html, application/rss+xml, application/xml', maxBytes: 8_000_000 });
  assert.equal(jobs['User-Agent'], 'Kontrol-Web/0.2');
  assert.equal('Accept-Language' in jobs, false);
  assert.match(PAGE_USER_AGENT, /^Mozilla\/5\.0 \(/);
  for (const [language, acceptLanguage] of [['en', 'en-US,en;q=0.9'], ['ja', 'ja-JP,ja;q=0.9,en;q=0.8']] as const) {
    const options = pageRequestOptions(language);
    assert.deepEqual({ maxRedirects: options.maxRedirects, truncate: options.truncate, maxBytes: options.maxBytes }, { maxRedirects: 5, truncate: true, maxBytes: 2_000_000 });
    const page = requestHeaders(options);
    assert.match(page['User-Agent'], /^Mozilla\/5\.0/);
    assert.equal(page.Accept, 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8');
    assert.match(page.Accept, /text\/html/);
    assert.equal(page['Accept-Language'], acceptLanguage);
    assert.equal(page['Accept-Encoding'], 'gzip, deflate, br');
  }
  assert.equal(redirectLimit(undefined), 3);
  assert.equal(redirectLimit(5), 5);
  assert.equal(redirectLimit(50), 10);
  assert.equal(redirectLimit(-1), 0);
  assert.equal(redirectLimit(Number.NaN), 3);
});
test('body collector keeps under-limit bodies and truncates or rejects oversized plain and gzip bodies', async () => {
  const plain = (...parts: string[]) => Readable.from(parts.map(part => Buffer.from(part)), { objectMode: false });
  const gzip = (text: string) => {
    const bytes = gzipSync(Buffer.from(text));
    return Readable.from([bytes.subarray(0, 10), bytes.subarray(10)], { objectMode: false });
  };
  assert.equal(await collectBody(plain('<html>', '<title>Hi</title>'), null, 100, false), '<html><title>Hi</title>');
  assert.equal(await collectBody(plain('<html>', '<title>Hi</title>'), null, 100, true), '<html><title>Hi</title>');
  assert.equal(await collectBody(gzip('<title>Compressed</title>'), createGunzip(), 100, false), '<title>Compressed</title>');

  let destroyed = 0;
  const response = plain('a'.repeat(1000), 'b'.repeat(1000), 'c'.repeat(1000));
  const truncated = await collectBody(response, null, 1500, true, { destroy: () => destroyed++ });
  assert.equal(truncated, 'a'.repeat(1000) + 'b'.repeat(500));
  assert.equal(truncated.length, 1500);
  assert.equal(destroyed, 1);
  assert.equal(response.destroyed, true);
  await assert.rejects(collectBody(plain('a'.repeat(1000), 'b'.repeat(1000)), null, 1500, false),
    (error: Error & { code?: string }) => error.code === 'size' && /exceeds the 1 MB limit/.test(error.message));

  const large = 'x'.repeat(3_000_000);
  const decoder = createGunzip(), compressed = gzip(large);
  const prefix = await collectBody(compressed, decoder, 2_000_000, true);
  assert.equal(prefix.length, 2_000_000);
  assert.equal(prefix, large.slice(0, 2_000_000));
  assert.equal(compressed.destroyed, true);
  assert.equal(decoder.destroyed, true);
  await assert.rejects(collectBody(gzip(large), createGunzip(), 2_000_000, false), /exceeds the 2 MB limit/);
  await assert.rejects(collectBody(plain('y'.repeat(2_000_001)), null, 2_000_000, false), /exceeds the 2 MB limit/);

  // A truncated multi-byte character must decode without throwing.
  const japanese = await collectBody(plain('あ'.repeat(10)), null, 10, true);
  assert.ok(japanese.startsWith('あああ'));
  assert.equal(japanese.length, 4);
});
test('body collector enforces the wire limit even when decoding shrinks the body', async () => {
  // Emits half of every compressed chunk, so the wire limit is reached first.
  const halve = () => new Transform({ transform(chunk: Buffer, _encoding, done) { done(null, chunk.subarray(0, chunk.length / 2)); } });
  const wire = () => Readable.from(['a', 'b', 'c'].map(letter => Buffer.from(letter.repeat(600))), { objectMode: false });
  const truncated = await collectBody(wire(), halve(), 1000, true);
  assert.ok(truncated.length <= 1000);
  assert.ok(('a'.repeat(300) + 'b'.repeat(300) + 'c'.repeat(300)).startsWith(truncated));
  await assert.rejects(collectBody(wire(), halve(), 1000, false), (error: Error & { code?: string }) => error.code === 'size');
  const failing = new Transform({ transform(_chunk, _encoding, done) { done(new Error('incorrect header check')); } });
  await assert.rejects(collectBody(wire(), failing, 10_000, true), /incorrect header check/);
});
test('search carries specific query, locale, exclusions and freshness without fixing a publisher', () => {
  const i = interest({ query: '東京 ソフトウェア 求人', region: 'JP', language: 'ja', days: 30, excludedTerms: ['株価'] });
  const url = new URL(searchURL(i));
  assert.equal(url.searchParams.get('q'), '東京 ソフトウェア 求人 -"株価" when:30d');
  assert.equal(url.searchParams.get('ceid'), 'JP:ja');
  assert.equal(url.searchParams.get('hl'), 'ja');
  assert.equal(url.searchParams.get('gl'), 'JP');
  assert.equal(url.search.includes('site%3A'), false);
});
test('matching requires every concept, supports alternatives and Japanese, and excludes noise', () => {
  const japan = interest({ ...interestPresets[0] });
  assert.ok(matchesInterest({ title: 'Tokyo software developer jobs', summary: '' }, japan));
  assert.equal(matchesInterest({ title: 'Tokyo welcomes visitors', summary: 'Jobs at restaurants' }, japan), false);
  assert.ok(matchesInterest({ title: 'AI model release', summary: '' }, interest()));
  assert.equal(matchesInterest({ title: 'He said model launch', summary: '' }, interest()), false);
  assert.equal(matchesInterest({ title: 'AI model release', summary: 'stock price increased' }, interest()), false);
  assert.ok(matchesInterest({ title: '東京でエンジニア募集中', summary: '日本語で開発' }, interest({ requiredTerms: ['東京|大阪', 'エンジニア|開発'], excludedTerms: [] })));
});
test('Google RSS extracts publisher names, plain text and canonical links', () => {
  const xml = '<rss><channel><item><title>AI model launch - Example News</title><source url="https://example.com/">Example News</source><link>https://example.com/release?utm_source=news</link><description><![CDATA[<a href="https://example.com/">AI model launch</a>]]></description></item></channel></rss>';
  const rows = parseFeed(xml, { id: randomUUID(), name: 'Search', endpoint: 'https://news.google.com/rss/search', topicIDs: [], isEnabled: true }, new Date(now).toISOString());
  assert.equal(rows[0].title, 'AI model launch');
  assert.equal(rows[0].source, 'Example News');
  assert.equal(rows[0].url, 'https://example.com/release');
  assert.equal(rows[0].summary, 'AI model launch');
  assert.equal(rows[0].publishedAt, null);
  const escaped = '<rss><channel><item><title>Model news</title><link>https://example.com/a</link><description>&lt;a href=&quot;https://example.com/AI-model-launch&quot;&gt;Unrelated story&lt;/a&gt;&amp;nbsp;Report &#8212; &#x6771;&#x4eac;</description></item></channel></rss>';
  const decoded = parseFeed(escaped, { id: randomUUID(), name: 'Search', endpoint: 'https://news.google.com/rss/search', topicIDs: [], isEnabled: true }, new Date(now).toISOString())[0];
  assert.equal(decoded.summary, 'Unrelated story Report — 東京');
  assert.equal(matchesInterest(decoded, interest()), false, 'HTML attributes cannot satisfy interest filters');
});
test('standard discovery removes irrelevant and expired articles and ranks fresh matches', async () => {
  const i = interest();
  const xml = '<rss><channel>' + [
    ['AI model release with benchmark', new Date().toUTCString(), 'good'],
    ['Tokyo travel recommendations', new Date().toUTCString(), 'unrelated'],
    ['AI model launch', 'Tue, 01 Jan 2019 00:00:00 GMT', 'stale'],
  ].map(([title, date, id]) => '<item><title>' + title + '</title><pubDate>' + date + '</pubDate><link>https://example.com/' + id + '</link></item>').join('') + '</channel></rss>';
  let endpoint = '';
  const rows = await searchDiscovery(async url => { endpoint = url; return xml; })(i);
  assert.match(endpoint, /news.google.com/);
  assert.equal(rows.length, 1);
  assert.equal(rows[0].url, 'https://example.com/good');
  assert.equal(rows[0].feedIDs.length, 0);
  assert.equal(rows[0].matches[0].interestRevision, i.revision);
});
test('merge deduplicates URLs across interests, replaces successful results and keeps other evidence', () => {
  const first = interest(), second = interest();
  const original = mergeDiscovery([], [result(first)], first, 'search', now);
  const merged = mergeDiscovery(original, [result(second, { url: 'https://example.com/release?utm_campaign=x#section' })], second, 'search', now + 10);
  assert.equal(merged.length, 1);
  assert.equal(merged[0].matches.length, 2);
  assert.equal(merged[0].fetchedAt, original[0].fetchedAt);
  const removed = mergeDiscovery(merged, [], first, 'search', now);
  assert.deepEqual(removed[0].matches.map(m => m.interestID), [second.id]);
  assert.equal(mergeDiscovery(removed, [], second, 'search', now).length, 0);
});
test('discovery rejects stale revisions, future and expired dates; visibility follows current interests', () => {
  const i = interest();
  assert.equal(mergeDiscovery([], [result(i, { publishedAt: new Date(now + 3 * 86_400_000).toISOString() })], i, 'search', now).length, 0);
  assert.equal(mergeDiscovery([], [result(i, { publishedAt: new Date(now - 8 * 86_400_000).toISOString() })], i, 'search', now).length, 0);
  assert.equal(mergeDiscovery([], [result({ ...i, revision: randomUUID() })], i, 'search', now).length, 0);
  const state = initialDiscovery(); state.preferences.interests = [i]; state.articles = [result(i)];
  assert.equal(visibleDiscoveries(state, undefined, now).length, 1);
  state.preferences.interests[0].enabled = false;
  assert.equal(visibleDiscoveries(state, undefined, now).length, 0);
  state.preferences.interests[0] = { ...i, enabled: true, revision: randomUUID() };
  assert.equal(visibleDiscoveries(state, undefined, now).length, 0);
});
test('standard news search and result merging exclude obvious homepages and job offers', async () => {
  const i = interest({ ...interestPresets[0] });
  const urls = ['https://japan-dev.com/', 'https://japan-dev.com/jobs/java-engineer', 'https://japan-dev.com/blog/software-hiring-trends'];
  const xml = '<rss><channel>' + urls.map(url => '<item><title>Software developer jobs and hiring trends in Japan</title><link>' + url + '</link><pubDate>' + new Date().toUTCString() + '</pubDate></item>').join('') + '</channel></rss>';
  const results = await searchDiscovery(async () => xml)(i);
  assert.deepEqual(results.map(item => item.url), [urls[2]]);
  assert.equal(results[0].contentKind, 'article');
  const merged = mergeDiscovery([], urls.map(url => result(i, { url })), i, 'search', now);
  assert.deepEqual(merged.map(item => item.url), [urls[2]]);
});

test('standard discovery keeps unknown dates, rejects future dates and unsafe URLs, and preserves ranking and caps', async () => {
  const i = interest();
  const current = Date.now();
  const item = (url: string, title: string, date?: string) => '<item><title>' + title + '</title><link>' + url + '</link>' +
    (date ? '<pubDate>' + date + '</pubDate>' : '') + '</item>';
  const xml = '<rss><channel>' + [
    item('https://example.com/unknown?utm_source=rss#section', 'AI model release with benchmark and open weights'),
    item('https://example.com/malformed-date', 'AI model release', 'not a date'),
    item('https://example.com/future', 'AI model release', new Date(current + 3 * 86_400_000).toUTCString()),
    item('https://example.com/expired', 'AI model release', new Date(current - 8 * 86_400_000).toUTCString()),
    ...['https://example.com/', 'https://example.com/news', 'https://example.com/jobs/engineer',
      'https://example.com/category/models', 'ftp://example.com/article', 'https://user:secret@example.com/article',
      'https://example.com:1234/article'].map(url => item(url, 'AI model release')),
    ...Array.from({ length: 45 }, (_, index) => item('https://example.com/story-' + index, 'AI model release', new Date(current).toUTCString())),
  ].join('') + '</channel></rss>';
  const rows = await searchDiscovery(async () => xml)(i);
  assert.equal(rows.length, 40);
  assert.equal(rows[0].url, 'https://example.com/unknown');
  assert.equal(rows[0].publishedAt, null);
  // RSS parsing already treats malformed dates as unknown, not as invented dates.
  assert.equal(rows.find(row => row.url.endsWith('/malformed-date'))?.publishedAt, null);
  assert.ok(rows.every(row => row.contentKind === 'article' && row.feedIDs.length === 0));
  assert.ok(rows.every((row, index) => !index || rows[index - 1].matches[0].score >= row.matches[0].score));
  assert.ok(rows.every(row => /\/(?:unknown|malformed-date|story-\d+)$/.test(row.url)));
});

test('discovery rejects ineligible incoming URL and content types without replacing other-interest evidence', () => {
  const first = interest(), second = interest();
  const original = mergeDiscovery([], [result(first)], first, 'search', now);
  for (const mode of ['search', 'ai'] as const) {
    for (const candidate of [
      ...['not a URL', 'ftp://example.com/release', 'https://example.com/', 'https://example.com/blog',
        'https://example.com/jobs/engineer', 'https://example.com:1234/release', 'https://user:secret@example.com/release']
        .map(url => result(second, { url })),
      result(second, { contentKind: 'job' }), result(second, { contentKind: 'generic' }),
      result(second, { publishedAt: 'not a date' }),
    ]) {
      candidate.matches[0].mode = mode;
      assert.deepEqual(mergeDiscovery(original, [candidate], second, mode, now), original);
    }
  }
  const both = mergeDiscovery(original, [result(second)], second, 'search', now);
  const invalidReplacement = mergeDiscovery(both, [result(first, { contentKind: 'job' })], first, 'search', now);
  assert.deepEqual(invalidReplacement[0].matches.map(match => match.interestID), [second.id]);
});

test('discovery rejects dates outside boundaries but retains unknown dates and the merge cap', () => {
  const i = interest();
  const rows = mergeDiscovery([], [
    result(i, { url: 'https://example.com/lower', publishedAt: new Date(now - i.days * 86_400_000).toISOString() }),
    result(i, { url: 'https://example.com/upper', publishedAt: new Date(now + 86_400_000).toISOString() }),
    result(i, { url: 'https://example.com/unknown', publishedAt: null }),
  ], i, 'search', now);
  assert.equal(rows.length, 3);
  assert.equal(rows.find(row => row.url.endsWith('/unknown'))?.publishedAt, null);
  const capped = mergeDiscovery([], Array.from({ length: 501 }, (_, index) => result(i, { url: 'https://example.com/item-' + index })), i, 'search', now);
  assert.equal(capped.length, 500);
});

test('standard cancellation forwards an abortable signal and rejects stalled injected retrieval', async () => {
  const controller = new AbortController();
  let received: AbortSignal | undefined;
  let complete!: (xml: string) => void;
  let started!: () => void;
  const admitted = new Promise<void>(resolve => started = resolve);
  const pending = searchDiscovery(async (_url, redirects, signal) => {
    assert.equal(redirects, 0);
    received = signal;
    started();
    return new Promise<string>(resolve => complete = resolve);
  })(interest(), controller.signal);
  const rejected = assert.rejects(pending, /took too long/);
  try {
    await admitted;
    assert.equal(received?.aborted, false);
    controller.abort();
    await rejected;
    assert.equal(received?.aborted, true);
    // Late success cannot trigger parsing or publication after cancellation.
    complete('not valid RSS');
    await Promise.resolve();
  } finally { controller.abort(); }
});

test('standard cancellation rejects already-aborted calls without invoking the fetcher', async () => {
  let calls = 0;
  await assert.rejects(searchDiscovery(async () => { calls++; return ''; })(interest(), AbortSignal.abort()), /took too long/);
  assert.equal(calls, 0);
});

test('standard cancellation keeps the default deadline even with a longer caller lifetime', async t => {
  t.mock.timers.enable({ apis: ['setTimeout'] });
  const controller = new AbortController();
  let received: AbortSignal | undefined;
  const pending = searchDiscovery(async (_url, _redirects, signal) => {
    received = signal;
    return new Promise<string>(() => {});
  })(interest(), controller.signal);
  const rejected = assert.rejects(pending, /took too long/);
  try {
    await Promise.resolve();
    t.mock.timers.tick(STANDARD_SEARCH_TIMEOUT_MS - 1);
    assert.equal(received?.aborted, false);
    t.mock.timers.tick(1);
    await rejected;
    assert.equal(received?.aborted, true);
    assert.equal(controller.signal.aborted, false);
  } finally { controller.abort(); t.mock.timers.reset(); }
});

// Real socket/transport integration is intentionally selected only at the final gate.
test('transport integration: Standard cancellation reaches production fetchFeed during stalled headers and bodies', async t => {
  const realRequest = http.request;
  // Only this fixture's built-in adapters are redirected to loopback. Production
  // URL, DNS policy, request signal and body collection still run in fetchFeed;
  // no real public-network request is made and no production policy is changed.
  for (const phase of ['headers', 'body']) {
    let opened!: () => void;
    const receiving = new Promise<void>(resolve => opened = resolve);
    const server = createServer((_req, res) => {
      if (phase === 'body') { res.writeHead(200); res.write('<rss>'); }
      opened();
    });
    await new Promise<void>(resolve => server.listen(0, '127.0.0.1', resolve));
    const controller = new AbortController();
    let closed: Promise<void> | undefined;
    try {
      t.mock.method(dns, 'lookup', async () => [{ address: '8.8.8.8', family: 4 }]);
      t.mock.method(http, 'request', (_url: string | URL, options: RequestOptions, callback: Parameters<typeof http.request>[2]) => {
        const req = realRequest('http://127.0.0.1:' + (server.address() as AddressInfo).port + '/feed', {
          ...options, lookup: pinnedLookup([{ address: '127.0.0.1', family: 4 }]), agent: false,
        }, callback);
        closed = new Promise<void>(resolve => req.once('close', resolve));
        return req;
      });
      syncBuiltinESMExports();
      const pending = searchDiscovery((_url, redirects, signal) => fetchFeed('http://isolated-fixture.test/feed', redirects, signal))(
        interest(), controller.signal);
      // Retrieval failure (including its bounded timeout) must also reach finally
      // if the fixture never receives a request.
      await Promise.race([receiving, pending.then(() => { throw new Error('The stalled fixture unexpectedly completed.'); })]);
      controller.abort();
      await assert.rejects(pending, /took too long/);
      assert.ok(closed);
      await closed;
    } finally {
      controller.abort();
      t.mock.restoreAll(); syncBuiltinESMExports();
      server.closeAllConnections();
      await new Promise<void>((resolve, reject) => server.close(error => error ? reject(error) : resolve()));
    }
  }
});

test('transport integration: Standard forwarding retains production public-network restrictions', async () => {
  await assert.rejects(searchDiscovery((_url, redirects, signal) => fetchFeed('http://127.0.0.1/feed', redirects, signal))(interest()),
    /public internet addresses/);
  await assert.rejects(searchDiscovery((_url, redirects, signal) => fetchFeed('http://127.0.0.1/feed', redirects, signal))(
    interest(), AbortSignal.abort()), /took too long/);
});
