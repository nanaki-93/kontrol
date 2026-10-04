import test from 'node:test';
import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { interestPresets, newsSearchQuery, type NewsInterest } from '../shared/news';
import { aiRequest, webSearchRequest, parseAIResponse, aiDiscovery, aiSources, webSearchURL, pageFailureKind, pageFailureSummary, PageRetrievalError, type AISource } from '../server/news/ai';
import { parseSourcePage } from '../server/news/pages';
import { NewsFetchError, pageRequestOptions, type FetchOptions } from '../server/news/transport';

const now = Date.parse('2026-10-02T12:00:00Z');
const interest: NewsInterest = { ...interestPresets[1], id: randomUUID(), revision: randomUUID() };
const source = (overrides: Partial<AISource> = {}): AISource => ({ title: 'New AI model release', url: 'https://example.com/model',
  summary: 'A new language model with benchmark results.', publishedAt: '2026-10-01T10:00:00.000Z', kind: 'article', ...overrides });
const item = (overrides = {}) => ({ url: 'https://example.com/model', summary: 'A new language model with benchmark results.',
  relevance: 95, reason: 'Announces a model release with benchmark results.', ...overrides });
const response = (articles = [item()]) => JSON.stringify({ articles });
const unsupportedSearch = async () => { throw new NewsFetchError('pi-web-unavailable', 'Unsupported fixture provider.'); };
const page = '<html><head><title>New AI model release</title><meta property="og:type" content="article"><meta name="description" content="A new language model with benchmark results."></head></html>';

test('PI prompt sends only the selected interest, filters and bounded retrieved source fields', () => {
  const payload = JSON.parse(aiRequest({ ...interest, privateData: 'must not be sent' } as NewsInterest, [source()], now));
  assert.deepEqual(Object.keys(payload).sort(), ['instructions', 'currentDate', 'since', 'interest', 'language', 'region', 'intent', 'requiredKeywordGroups', 'excludedPhrases', 'sources'].sort());
  assert.equal(payload.interest, interest.query);
  assert.match(payload.instructions.join(' '), /Publication age.*must not increase the relevance score/);
  const { kind: _kind, ...fields } = source(); assert.deepEqual(payload.sources, [fields]);
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
    [item({ summary: 'A travel report.' }), [source({ title: 'Travel in Japan', summary: 'A travel report.' })]],
  ];
  for (const [candidate, sources] of cases) {
    assert.throws(() => parseAIResponse(response([candidate]), sources, interest, now), /no news articles passed validation/);
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
    urls.push(url); assert.equal(redirects, 0);
    if (!url.includes('google.com') && !url.includes('bing.com')) { assert.ok(providedSignal && !providedSignal.aborted); return page; }
    assert.equal(providedSignal, signal);
    return rss(url.includes('bing.com') ? 'https://example.org/model' : 'https://example.com/model');
  });
  assert.deepEqual(urls.map(url => new URL(url).hostname).sort(), ['example.org', 'news.google.com', 'www.bing.com']);
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
test('providers without hosted search retain one PI ranking call, shared cancellation and empty-source handling', async () => {
  let calls = 0;
  let searchSignal: AbortSignal | undefined;
  const adapter = aiDiscovery({ webSearch: unsupportedSearch, sources: async (_interest, _at, signal) => {
    searchSignal = signal; return [source({ publishedAt: null })];
  }, run: async (prompt, _options, signal) => {
    calls++; assert.equal(signal, searchSignal); assert.equal(JSON.parse(prompt).interest, interest.query); return response();
  } });
  assert.equal((await adapter(interest)).length, 1);
  assert.equal(calls, 1);
  const failed = aiDiscovery({ webSearch: unsupportedSearch, sources: async () => [source()], run: async () => { calls++; throw new Error('secret-from-provider'); } });
  await assert.rejects(failed(interest), error => error instanceof Error && !error.message.includes('secret-from-provider'));
  assert.equal(calls, 2, 'No automatic retries');
  const empty = aiDiscovery({ webSearch: unsupportedSearch, sources: async () => [], run: async () => { throw new Error('Must not run PI'); } });
  assert.deepEqual(await empty(interest), []);
});

test('legacy career interests and job-related descriptions search for individual articles independently of RSS', async () => {
  const jobs = { ...interestPresets[0], id: randomUUID(), revision: randomUUID(),
    query: 'Japan (developer OR "software engineer" OR programming) (jobs OR hiring OR recruitment)(Java OR Kotlin OR Backend)\nDON\'T get me any job offers.' };
  const url = 'https://board.example/blog/software-hiring-trends-japan';
  let calls = 0, fetched = 0;
  const discovery = aiDiscovery({
    webSearch: async (prompt, options, signal) => {
      calls++;
      const payload = JSON.parse(prompt);
      assert.equal(payload.interest, newsSearchQuery(jobs.query)); assert.doesNotMatch(payload.interest, /DON'T/);
      assert.deepEqual(payload.requiredKeywordGroups, jobs.requiredTerms);
      assert.equal(payload.intent, 'news');
      assert.match(payload.instructions.join(' '), /Exclude homepages.*job offers and job listings/);
      assert.ok(signal && !signal.aborted);
      assert.match(options?.systemPrompt ?? '', /web search/);
      return { text: response([item({ url, title: 'Invented title', publishedAt: '2030-01-01',
        summary: 'An article about Java and Kotlin backend hiring trends for software developers in Japan.' })]), urls: [url] };
    },
    fetcher: async (endpoint, redirects, signal, options) => {
      fetched++;
      assert.equal(endpoint, url); assert.equal(redirects, 0);
      assert.ok(signal && !signal.aborted); assert.match(options?.accept ?? '', /text\/html/);
      return '<html><title>Software developer hiring trends in Japan</title><meta property="og:type" content="article"><meta property="og:description" content="Programming jobs in Tokyo and Osaka: Java and Kotlin hiring trends"></html>';
    },
    sources: async () => { throw new Error('RSS must not gate hosted search'); },
    run: async () => { throw new Error('No second PI ranking invocation'); },
  });
  const rows = await discovery(jobs);
  assert.equal(calls, 1); assert.equal(fetched, 1); assert.equal(rows.length, 1);
  assert.equal(rows[0].url, url);
  assert.equal(rows[0].title, 'Software developer hiring trends in Japan');
  assert.equal(rows[0].publishedAt, null, 'A model date must not become a publication date');
  assert.equal(rows[0].matches[0].mode, 'ai');
});

test('hosted news prompt contains only selected interest fields and requires current retrieved evidence', () => {
  const payload = JSON.parse(webSearchRequest({ ...interest, privateData: 'PRIVATE-DATA' } as NewsInterest, now));
  assert.deepEqual(Object.keys(payload).sort(), ['instructions', 'currentDate', 'since', 'interest', 'language', 'region', 'intent', 'requiredKeywordGroups', 'excludedPhrases'].sort());
  assert.equal(payload.since, '2026-09-25T12:00:00.000Z');
  assert.doesNotMatch(JSON.stringify(payload), /PRIVATE-DATA/);
  assert.match(payload.instructions.join(' '), /simpler queries/);
  assert.match(payload.instructions.join(' '), /exact public URLs/);
  assert.match(payload.instructions.join(' '), /Publication age.*must not increase the relevance score/);
});

test('hosted discovery fetches only deduplicated, public, provider-cited URLs', async () => {
  const url = source().url, calls: string[] = [];
  const privateURL = 'http://127.0.0.1/private', invented = 'https://invented.example/model';
  const rows = await aiDiscovery({
    webSearch: async () => ({ text: response([item(), item({ url: url + '?utm_source=pi#section' }), item({ url: privateURL }), item({ url: invented })]), urls: [url, privateURL] }),
    fetcher: async endpoint => { calls.push(endpoint); return page; },
  })(interest);
  assert.deepEqual(calls, [url]); assert.equal(rows.length, 1);
  await assert.rejects(aiDiscovery({
    webSearch: async () => ({ text: response(), urls: [] }),
    fetcher: async () => { throw new Error('An uncited URL must never be fetched'); },
  })(interest), /no matching citation/);
});

test('source pages supply titles and publication dates without mistaking updates or directories for fresh news', () => {
  const structured = (value: unknown) => '<script type="application/ld+json">' + JSON.stringify(value) + '</script>';
  const url = source().url;
  const article = parseSourcePage('<title>Fallback</title><meta content="AI model &amp; release" property="og:title">' + structured({
    '@graph': [{ '@type': 'WebPage', url, dateModified: '2026-10-02T10:00:00Z' },
      { '@type': 'NewsArticle', url, datePublished: '2026-10-01T10:00:00Z', dateModified: '2026-10-02T10:00:00Z', description: 'Model benchmark' }],
  }), url)!;
  assert.equal(article.title, 'AI model & release');
  assert.equal(article.summary, 'Model benchmark');
  assert.equal(article.publishedAt, source().publishedAt);
  assert.equal(parseSourcePage(page + '<meta content="2026-10-01T10:00:00Z" property="article:published_time">', url)?.publishedAt, source().publishedAt);
  assert.equal(parseSourcePage(page + structured({ '@type': 'JobPosting', datePosted: '2026-10-01T10:00:00' }), url)?.publishedAt, source().publishedAt);
  assert.equal(parseSourcePage(page + structured({ '@type': 'WebPage', dateModified: '2026-10-01T10:00:00Z' }), url)?.publishedAt, null);
  assert.equal(parseSourcePage(page + structured([{ '@type': 'JobPosting', datePosted: '2026-10-01' }, { '@type': 'JobPosting', datePosted: '2025-01-01' }]), url)?.publishedAt, null);
  assert.equal(parseSourcePage('<title>Just a moment...</title>', url), null);
  assert.equal(parseSourcePage('<html>Missing page title</html>', url), null);
});

test('hosted discovery preserves partial retrieval and rejects known stale publications', async () => {
  const blocked = 'https://blocked.example/model';
  const webSearch = async () => ({ text: response([item(), item({ url: blocked })]), urls: [source().url, blocked] });
  assert.equal((await aiDiscovery({ webSearch, fetcher: async url => {
    if (url === blocked) throw new Error('fixture network failure');
    return page;
  } })(interest)).length, 1);
  await assert.rejects(aiDiscovery({ webSearch, fetcher: async () => page + '<meta property="article:published_time" content="2020-01-01T00:00:00Z">' })(interest), /outside the 7-day publication window/);
});

test('hosted search failures and page failures without news-index evidence stay errors, never successful empty RSS results', async () => {
  for (const failure of [new Error('private-provider-error'), new NewsFetchError('pi-web-evidence', 'Missing completed search evidence.')]) {
    let calls = 0;
    await assert.rejects(aiDiscovery({
      webSearch: async () => { calls++; throw failure; },
      sources: async () => { throw new Error('RSS must not mask hosted-search failures'); },
    })(interest), error => error instanceof Error && !error.message.includes('private-provider-error'));
    assert.equal(calls, 1);
  }
  for (const fetcher of [async () => { throw new Error('private-fetch-error'); }, async () => '<title>Access denied</title>']) {
    await assert.rejects(aiDiscovery({ webSearch: async () => ({ text: response(), urls: [source().url] }), fetcher })(interest), /pages could not be retrieved/);
  }
  assert.deepEqual(await aiDiscovery({
    webSearch: async () => ({ text: response([]), urls: [] }),
    fetcher: async () => { throw new Error('A genuine empty search has no pages to retrieve'); },
  })(interest), []);
});

test('retrieved descriptions and article bodies satisfy interest checks when the AI summary omits required words', async () => {
  const html = '<html><head><title>Acme releases Helios</title><meta property="og:type" content="article"><meta name="description" content="An announcement from Acme."></head>' +
    '<body><nav><p>stock price</p></nav><main><p>Acme has released a new AI model with benchmark results. The new language model is available to developers today.</p></main><footer><p>stock price</p></footer></body></html>';
  const parsed = parseSourcePage(html, source().url)!;
  assert.equal(parsed.kind, 'article'); assert.doesNotMatch(parsed.evidenceText!, /stock price/);
  const brief = item({ summary: 'Helios is available to developers today.' });
  assert.equal(parseAIResponse(response([brief]), [parsed], interest, now).length, 1);
  assert.equal((await aiDiscovery({ webSearch: async () => ({ text: response([brief]), urls: [source().url] }), fetcher: async () => html })(interest)).length, 1);
});
test('PI summaries cannot supply missing concepts or bypass exclusions in the retrieved source', () => {
  for (const retrieved of [source({ title: 'Travel in Japan', summary: 'A travel report.' }), source({ summary: 'The stock price increased after an AI model release.' })]) {
    assert.throws(() => parseAIResponse(response(), [retrieved], interest, now), /keyword filters in the retrieved article/);
  }
  assert.equal(parseAIResponse(response(), [source({ title: 'Acme released AI models', summary: '' })], interest, now).length, 1);
});
test('page classification distinguishes articles, product pages, job listings, directories and unrelated structured metadata', () => {
  const structured = (record: unknown) => '<script type="application/ld+json">' + JSON.stringify(record) + '</script>';
  const description = '<meta name="description" content="Software developer jobs in Japan">';
  const article = '<title>Japanese software hiring trends</title>' + description + structured({ '@type': 'BlogPosting', headline: 'Developer hiring trends in Japan', datePublished: '2026-10-01' });
  assert.equal(parseSourcePage(article, 'https://japan-dev.com/blog/developer-hiring-trends')?.kind, 'article');
  for (const url of ['https://japan-dev.com/', 'https://japan-dev.com/jobs', 'https://japan-dev.com/en', 'https://japan-dev.com/blog', 'https://japan-dev.com/companies']) {
    assert.equal(parseSourcePage(article, url)?.kind, 'generic', url);
  }
  assert.equal(parseSourcePage('<title>Backend developer</title>' + structured({ '@type': 'JobPosting', datePosted: '2026-10-01' }), 'https://company.example/openings/backend')?.kind, 'job');
  assert.equal(parseSourcePage('<title>Helios platform</title><meta property="og:type" content="website">', 'https://company.example/products/helios')?.kind, 'generic');
  const unrelated = '<title>Products</title>' + structured({ '@type': 'NewsArticle', url: 'https://company.example/news/other', headline: 'AI model release', datePublished: '2026-10-01' });
  const parsed = parseSourcePage(unrelated, 'https://company.example/products/helios')!;
  assert.equal(parsed.kind, 'generic'); assert.equal(parsed.title, 'Products'); assert.equal(parsed.publishedAt, null);
});
test('job offers without structured metadata are rejected even when their social metadata says article', () => {
  const html = '<title>Java backend developer in Japan</title><meta property="og:type" content="article"><article>' +
    '<p>Job description: build APIs in Tokyo. Responsibilities: maintain backend services. Qualifications: Java and Kotlin. Benefits: visa sponsorship. Apply now.</p></article>';
  assert.equal(parseSourcePage(html, 'https://company.example/recruiting/java-backend')?.kind, 'job');
  const report = '<title>Japan developer hiring trends</title><meta property="og:type" content="article"><article><p>' +
    'A report on software hiring in Japan. Researchers reviewed listings that say apply now and compared qualifications across Java and Kotlin teams.' + '</p></article>';
  assert.equal(parseSourcePage(report, 'https://publisher.example/news/hiring-trends')?.kind, 'article');
});
test('hosted career search rejects a Japan Dev homepage and a vacancy while accepting a specific article', async () => {
  const career = { ...interestPresets[0], id: randomUUID(), revision: randomUUID() };
  const home = 'https://japan-dev.com/', vacancy = 'https://company.example/jobs/java-backend', article = 'https://japan-dev.com/blog/java-kotlin-hiring-trends';
  const candidates = [home, vacancy, article].map(url => item({ url, summary: 'Software developer jobs and hiring trends in Japan with Java and Kotlin.' }));
  const rows = await aiDiscovery({
    webSearch: async () => ({ text: response(candidates), urls: [home, vacancy, article] }),
    fetcher: async url => '<title>Software developer hiring trends in Japan</title><meta property="og:type" content="article">' +
      '<meta name="description" content="Java and Kotlin software developer hiring and jobs in Japan">' +
      (url === vacancy ? '<script type="application/ld+json">{"@type":"JobPosting","datePosted":"2026-10-01"}</script>' : ''),
  })(career);
  assert.deepEqual(rows.map(row => row.url), [article]); assert.equal(rows[0].contentKind, 'article');
});
test('all rejected PI proposals report actionable citation, source, date, relevance and keyword reasons', () => {
  const candidates = [item({ url: 'https://uncited.example/article' }), item({ url: 'https://japan-dev.com/' }),
    item({ url: 'https://example.com/old' }), item({ url: 'https://example.com/weak', relevance: 1 }), item({ url: 'https://example.com/travel' })];
  const sources = [source({ url: candidates[1].url, kind: 'generic' }), source({ url: candidates[2].url, publishedAt: '2020-01-01' }),
    source({ url: candidates[3].url }), source({ url: candidates[4].url, title: 'Travel in Japan', summary: 'A travel report.' })];
  assert.throws(() => parseAIResponse(response(candidates), sources, interest, now), error => {
    assert.ok(error instanceof NewsFetchError); assert.equal(error.code, 'ai-evidence');
    for (const reason of ['1 had no matching citation', '1 was a generic page or job listing', 'outside the 7-day publication window', 'weak relevance', 'keyword filters in the retrieved article']) assert.ok(error.message.includes(reason), error.message);
    return true;
  });
});
test('citation matching accepts query parameter reordering while retaining meaningful parameter differences', () => {
  const candidates = response([item({ url: 'https://example.com/model?version=2&locale=en' })]);
  assert.equal(parseAIResponse(candidates, [source({ url: 'https://example.com/model?locale=en&version=2' })], interest, now).length, 1);
  assert.throws(() => parseAIResponse(candidates, [source({ url: 'https://example.com/model?locale=en&version=3' })], interest, now), /no matching citation/);
});
test('wider-web fallback verifies article pages and never uses RSS dates as proof for generic sites or stale pages', async () => {
  for (const html of ['<title>AI model platform</title><meta property="og:type" content="website">', page + '<meta property="article:published_time" content="2020-01-01T00:00:00Z">']) {
    const sources = await aiSources(interest, now, new AbortController().signal, async url => url.includes('google.com') ? '<rss><channel><title>Empty fixture</title></channel></rss>' : url.includes('bing.com') ? rss() : html);
    assert.deepEqual(sources, []);
  }
});

// News AI page retrieval profile, failure reasons and the news-index fallback.
const indexURL = 'https://example.net/ai-model-release';
const recent = () => new Date(Date.now() - 3_600_000);
const indexSource = () => source({ url: indexURL, publishedAt: recent().toISOString() });
const indexRSS = (url = indexURL) => rss(url).replace('Thu, 01 Oct 2026 10:00:00 GMT', recent().toUTCString());
const citedSearch = (urls = [source().url]) => async () => ({ text: response(urls.map(url => item({ url }))), urls });
const isGeneric = (error: unknown) => error instanceof Error && /PI search could not finish/.test(error.message);

test('News AI page reads use the browser-compatible page profile while feed requests keep transport defaults', async () => {
  const pageOptions: (FetchOptions | undefined)[] = [];
  assert.equal((await aiDiscovery({ webSearch: citedSearch(), fetcher: async (_url, redirects, _signal, options) => {
    assert.equal(redirects, 0); pageOptions.push(options); return page;
  } })(interest)).length, 1);
  const japanese: NewsInterest = { ...interest, language: 'ja' };
  const feedOptions: (FetchOptions | undefined)[] = [];
  assert.equal((await aiSources(japanese, now, new AbortController().signal, async (url, redirects, _signal, options) => {
    assert.equal(redirects, 0);
    if (url.includes('google.com') || url.includes('bing.com')) { feedOptions.push(options); return rss(url.includes('bing.com') ? 'https://example.org/model' : source().url); }
    pageOptions.push(options); return page;
  })).length, 2);
  assert.deepEqual(feedOptions, [undefined, undefined], 'RSS endpoints keep the default feed request');
  assert.equal(pageOptions.length, 2);
  for (const [options, language] of [[pageOptions[0], 'en-US,en;q=0.9'], [pageOptions[1], 'ja-JP,ja;q=0.9,en;q=0.8']] as const) {
    assert.match(options?.userAgent ?? '', /^Mozilla\/5\.0 /);
    assert.match(options?.accept ?? '', /text\/html/);
    assert.equal(options?.acceptLanguage, language);
    assert.equal(options?.maxRedirects, 5);
    assert.equal(options?.truncate, true);
  }
  assert.deepEqual(pageOptions[1], pageRequestOptions('ja'));
});

test('page failures are summarized by fixed category order without raw error text', async () => {
  assert.equal(pageFailureKind(null), 'unreadable');
  assert.equal(pageFailureKind(new NewsFetchError('http-451', 'x')), 'blocked');
  assert.equal(pageFailureKind(new NewsFetchError('http-429', 'x')), 'rate-limited');
  assert.equal(pageFailureKind(new NewsFetchError('timeout', 'x')), 'timeout');
  assert.equal(pageFailureKind(new DOMException('x', 'AbortError')), 'timeout');
  assert.equal(pageFailureKind(new NewsFetchError('http-502', 'x')), 'http');
  for (const code of ['private-address', 'redirect', 'encoding', 'size']) assert.equal(pageFailureKind(new NewsFetchError(code, 'x')), 'unreachable');
  assert.equal(pageFailureSummary(['timeout', 'blocked', 'timeout', 'blocked']), '2 blocked automated access; 2 timed out');
  assert.equal(new PageRetrievalError(3, '2 blocked automated access; 1 timed out').message,
    'PI found 3 sources, but their pages could not be retrieved (2 blocked automated access; 1 timed out). Saved results are retained; try again.');
  assert.equal(new PageRetrievalError(1, '1 timed out').retrieval, 'PI found 1 source, but their pages could not be retrieved (1 timed out).');

  const failures: Record<string, () => Promise<string>> = {
    'https://a-secret-host.example/news/one': async () => { throw new NewsFetchError('http-403', 'secret-403-detail'); },
    'https://b-secret-host.example/news/two': async () => { throw new NewsFetchError('http-401', 'secret-401-detail'); },
    'https://c-secret-host.example/news/three': async () => { throw new NewsFetchError('http-429', 'secret-429-detail'); },
    'https://d-secret-host.example/news/four': async () => { throw new DOMException('secret-timeout-detail', 'TimeoutError'); },
    'https://e-secret-host.example/news/five': async () => { throw new NewsFetchError('http-500', 'secret-500-detail'); },
    'https://f-secret-host.example/news/six': async () => '<title>Just a moment...</title>',
    'https://g-secret-host.example/news/seven': async () => { throw new Error('private-fetch-error'); },
  };
  const urls = Object.keys(failures);
  await assert.rejects(aiDiscovery({ webSearch: citedSearch(urls), fetcher: url => failures[url](),
    sources: async () => [], run: async () => { throw new Error('Must not run PI'); } })(interest), error => {
    assert.ok(error instanceof NewsFetchError); assert.equal(error.code, 'ai-pages');
    assert.ok(error.message.startsWith('PI found 7 sources, but their pages could not be retrieved (2 blocked automated access; 1 rate-limited the request; ' +
      '1 timed out; 1 returned an HTTP error; 1 returned a verification or unreadable page; 1 could not be reached).'), error.message);
    assert.doesNotMatch(error.message, /secret|private-fetch-error|Just a moment/);
    return true;
  });
  await assert.rejects(aiSources(interest, now, new AbortController().signal, async url => {
    if (url.includes('google.com')) return '<rss><channel><title>Empty fixture</title></channel></rss>';
    if (url.includes('bing.com')) return rss('https://example.org/model');
    throw new NewsFetchError('http-403', 'secret-403-detail');
  }), error => {
    assert.ok(error instanceof NewsFetchError); assert.equal(error.code, 'ai-search');
    assert.equal(error.message, 'Search found links, but their article pages could not be retrieved (1 blocked automated access). Saved results are retained; try again.');
    return true;
  });
});

test('when every cited page fails, one news-index ranking call can return validated AI results', async () => {
  let sourceCalls = 0, runCalls = 0, sharedSignal: AbortSignal | undefined;
  const fetched: string[] = [];
  const rows = await aiDiscovery({
    webSearch: citedSearch(),
    fetcher: async url => { fetched.push(url); throw new NewsFetchError('http-403', 'secret-403-detail'); },
    sources: async (selected, _at, signal, fetcher, options) => {
      sourceCalls++; sharedSignal = signal;
      assert.equal(selected, interest); assert.equal(typeof fetcher, 'function'); assert.deepEqual(options, { webPages: false });
      return [indexSource()];
    },
    run: async (prompt, _options, signal) => {
      runCalls++; assert.equal(signal, sharedSignal);
      assert.deepEqual(JSON.parse(prompt).sources.map((entry: AISource) => entry.url), [indexURL]);
      return response([item({ url: indexURL })]);
    },
  })(interest);
  assert.equal(sourceCalls, 1); assert.equal(runCalls, 1); assert.deepEqual(fetched, [source().url]);
  assert.equal(rows.length, 1); assert.equal(rows[0].url, indexURL); assert.equal(rows[0].matches[0].mode, 'ai');
  assert.equal(rows[0].title, source().title, 'Titles come from news-index evidence, not the model');

  // Without an injected source list the fallback reads only the news index: no wider-web search and no page reads.
  const defaultFetches: string[] = [];
  const indexed = await aiDiscovery({
    webSearch: citedSearch(),
    fetcher: async url => {
      defaultFetches.push(url);
      if (url.includes('news.google.com')) return indexRSS();
      throw new DOMException('secret-timeout-detail', 'TimeoutError');
    },
    run: async () => response([item({ url: indexURL })]),
  })(interest);
  assert.deepEqual(defaultFetches.map(url => new URL(url).hostname), ['example.com', 'news.google.com']);
  assert.equal(indexed.length, 1); assert.equal(indexed[0].matches[0].mode, 'ai');
});

test('an empty, failing or timed-out news-index fallback reports the retrieval failure and retains saved results', async () => {
  const fallbackError = (error: unknown) => {
    assert.ok(error instanceof NewsFetchError); assert.equal(error.code, 'ai-pages');
    assert.match(error.message, /pages could not be retrieved \(1 blocked automated access\)\./);
    assert.match(error.message, /news-index fallback found no usable articles/);
    assert.match(error.message, /Saved results are retained; try again\.$/);
    assert.doesNotMatch(error.message, /secret/);
    return true;
  };
  const blocked = async () => { throw new NewsFetchError('http-403', 'secret-403-detail'); };
  let runCalls = 0;
  await assert.rejects(aiDiscovery({ webSearch: citedSearch(), fetcher: blocked, sources: async () => [],
    run: async () => { runCalls++; return response(); } })(interest), fallbackError);
  assert.equal(runCalls, 0, 'No news-index sources means no ranking call');
  const failing: NonNullable<Parameters<typeof aiDiscovery>[0]>[] = [
    { sources: async () => { throw new Error('secret-index-failure'); } },
    { sources: async () => [indexSource()], run: async () => { throw new Error('secret-run-failure'); } },
    { sources: async () => [indexSource()], run: async () => response([]) },
    { sources: async () => [indexSource()], run: async () => 'secret unreadable answer' },
    { sources: async () => [indexSource()], run: async () => response([item({ url: indexURL, relevance: 1 })]) },
  ];
  for (const options of failing) await assert.rejects(aiDiscovery({ webSearch: citedSearch(), fetcher: blocked, ...options })(interest), fallbackError);
  let started = false;
  await assert.rejects(aiDiscovery({ deadlineMs: 150, webSearch: citedSearch(), fetcher: blocked, sources: async () => [indexSource()],
    run: (_prompt, _options, signal) => new Promise<string>((_resolve, reject) => {
      started = true;
      signal!.addEventListener('abort', () => reject(signal!.reason), { once: true });
    }) })(interest), error => !isGeneric(error) && fallbackError(error));
  assert.equal(started, true);
});

test('provider failures, missing evidence, unreadable answers, validation rejections and partial retrieval never use the fallback', async () => {
  let fallbackCalls = 0;
  const fallback = {
    sources: async () => { fallbackCalls++; return [indexSource()]; },
    run: async () => { fallbackCalls++; return response([item({ url: indexURL })]); },
  };
  await assert.rejects(aiDiscovery({ ...fallback, webSearch: async () => { throw new Error('private-provider-error'); } })(interest), isGeneric);
  await assert.rejects(aiDiscovery({ ...fallback, webSearch: async () => { throw new NewsFetchError('pi-web-evidence', 'Missing completed search evidence.'); } })(interest), /Missing completed search evidence/);
  await assert.rejects(aiDiscovery({ ...fallback, webSearch: async () => ({ text: 'Not JSON', urls: [source().url] }), fetcher: async () => page })(interest), /unreadable/);
  await assert.rejects(aiDiscovery({ ...fallback, webSearch: citedSearch(), fetcher: async () => page + '<meta property="article:published_time" content="2020-01-01T00:00:00Z">' })(interest),
    error => error instanceof NewsFetchError && error.code === 'ai-evidence');
  const blocked = 'https://blocked.example/model';
  assert.equal((await aiDiscovery({ ...fallback, webSearch: citedSearch([source().url, blocked]), fetcher: async url => {
    if (url === blocked) throw new NewsFetchError('http-403', 'secret-403-detail');
    return page;
  } })(interest)).length, 1);
  assert.deepEqual(await aiDiscovery({ ...fallback, webSearch: async () => ({ text: response([]), urls: [] }) })(interest), []);
  await assert.rejects(aiDiscovery({ ...fallback, deadlineMs: 50, webSearch: (_prompt, _options, signal) => new Promise((_resolve, reject) => {
    signal!.addEventListener('abort', () => reject(signal!.reason), { once: true });
  }) })(interest), isGeneric);
  assert.equal(fallbackCalls, 0);
});

test('news-index-only sources fetch just the Google News endpoint and no pages', async () => {
  const fetched: string[] = [];
  const sources = await aiSources(interest, now, new AbortController().signal, async url => { fetched.push(url); return rss(); }, { webPages: false });
  assert.deepEqual(fetched.map(url => new URL(url).hostname), ['news.google.com']);
  assert.equal(sources.length, 1); assert.equal(sources[0].publishedAt, source().publishedAt);
  await assert.rejects(aiSources(interest, now, new AbortController().signal, async () => { throw new Error('secret-index-failure'); }, { webPages: false }), /Live search sources/);
});
