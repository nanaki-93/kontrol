import test from 'node:test';
import assert from 'node:assert/strict';
import { createHash, randomUUID } from 'node:crypto';
import { createServer, request, type RequestOptions } from 'node:http';
import type { AddressInfo } from 'node:net';
import { interestPresets, matchesInterest, visibleDiscoveries, type NewsInterest, type DiscoveredArticle } from '../shared/news';
import { pinnedLookup, fetchFeed, newsErrorMessage } from '../server/news/transport';
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
