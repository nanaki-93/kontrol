import test from 'node:test';
import assert from 'node:assert/strict';
import { createHash, randomUUID } from 'node:crypto';
import { createServer, request, type RequestOptions } from 'node:http';
import type { AddressInfo } from 'node:net';
import { Readable, Transform } from 'node:stream';
import { createGunzip, gzipSync } from 'node:zlib';
import { interestPresets, matchesInterest, visibleDiscoveries, type NewsInterest, type DiscoveredArticle } from '../shared/news';
import { pinnedLookup, fetchFeed, newsErrorMessage, requestHeaders, pageRequestOptions, collectBody, redirectLimit, PAGE_USER_AGENT } from '../server/news/transport';
import { parseFeed } from '../server/news/feeds';
import { initialDiscovery, mergeDiscovery, searchDiscovery, searchURL } from '../server/news/discovery';

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
