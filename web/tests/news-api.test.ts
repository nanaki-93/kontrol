import test from 'node:test';
import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { withAPI } from './helpers';
import { Store } from '../server/store';
import { newsModule } from '../server/modules/news';
import { getDiscovery } from '../server/news/discovery';
import { initialNews } from '../server/news/feeds';
import { interestPresets, visibleDiscoveries, type NewsInterest, type DiscoveredArticle, type NewsResponse } from '../shared/news';
import { type NewsState } from '../shared/schema';
import { aiDiscovery } from '../server/news/ai';

function found(i: NewsInterest): DiscoveredArticle[] {
  return [{ id: 'assigned-on-merge', title: 'Fresh result for ' + i.name, url: 'https://example.com/' + i.id,
    summary: 'Fixture response', source: 'Example', publishedAt: null, fetchedAt: new Date().toISOString(), feedIDs: [], topicIDs: [],
    matches: [{ interestID: i.id, interestRevision: i.revision, mode: 'search', score: 80, reason: 'Matches this interest' }] }];
}
function gate() {
  let resolve!: () => void;
  const promise = new Promise<void>(r => { resolve = r; });
  return { promise, resolve };
}

test('news upgrade preserves old feeds and cached articles; interests persist across database reopen', () => {
  const directory = mkdtempSync(join(tmpdir(), 'kontrol-news-migration-'));
  const path = join(directory, 'fixture.sqlite'); let store = new Store(path);
  try {
    const legacy = initialNews(); legacy.preferences.selectedTopicIDs = ['personal-topic'];
    legacy.articles = found({ ...interestPresets[0], id: randomUUID(), revision: randomUUID() });
    store.set('news', legacy); store.set('unrelated', { keep: 'exact value' });
    newsModule(store);
    assert.deepEqual(store.get('news'), legacy);
    const discovery = getDiscovery(store); discovery.preferences.interests[0].query = 'Tokyo backend developer with visa sponsorship';
    store.set('newsDiscovery', discovery);
    store.close(); store = new Store(path); newsModule(store);
    assert.deepEqual(store.get('news'), legacy);
    assert.deepEqual(store.get('newsDiscovery'), discovery);
    assert.deepEqual(store.get('unrelated'), { keep: 'exact value' });
  } finally { store.close(); rmSync(directory, { recursive: true, force: true }); }
});
test('interest CRUD validates input, rejects stale edits, and immediately invalidates old matches', async () => {
  await withAPI(async ({ request }) => {
    const invalid = await request('/news/interests', 'POST', { ...interestPresets[0], query: '' });
    assert.equal(invalid.status, 400);
    const created = await request('/news/interests', 'POST', { ...interestPresets[0], name: 'Visa sponsorship' });
    assert.equal(created.status, 201);
    const interest: NewsInterest = await created.json();
    let state: NewsResponse = await (await request('/news/discover', 'POST', { mode: 'search', interestID: interest.id })).json();
    assert.equal(visibleDiscoveries(state.discovery).length, 1);
    const edit = { ...interest, query: 'Japan software jobs with visa sponsorship', expectedRevision: interest.revision };
    const edited = await request('/news/interests/' + interest.id, 'PUT', edit);
    assert.equal(edited.status, 200);
    const next: NewsInterest = await edited.json();
    assert.notEqual(next.revision, interest.revision);
    assert.equal((await request('/news/interests/' + interest.id, 'PUT', edit)).status, 409);
    state = await (await request('/news')).json();
    assert.equal(visibleDiscoveries(state.discovery).length, 0);
    assert.equal((await request('/news/interests/' + interest.id, 'DELETE', { expectedRevision: interest.revision })).status, 409);
    assert.equal((await request('/news/interests/' + interest.id, 'DELETE', { expectedRevision: next.revision })).status, 204);
    assert.equal((await request('/news/discover', 'POST', { mode: 'search', interestID: interest.id })).status, 400);
  }, { news: { search: async i => found(i) } });
});
test('search is explicit, isolates per-interest failures, retains cache and replaces successful empty results', async () => {
  let calls = 0, fail = false, empty = false;
  await withAPI(async ({ request, store }) => {
    const before: NewsResponse = await (await request('/news')).json();
    assert.equal(calls, 0);
    const first: NewsResponse = await (await request('/news/discover', 'POST', { mode: 'search' })).json();
    assert.equal(calls, 2); assert.equal(first.discovery.articles.length, 2);
    const japan = before.discovery.preferences.interests[0];
    fail = true;
    const second: NewsResponse = await (await request('/news/discover', 'POST', { mode: 'search' })).json();
    assert.equal(second.discovery.articles.length, 2);
    assert.ok(second.discovery.runs[japan.id].error);
    assert.equal(second.discovery.runs[japan.id].succeededAt, first.discovery.runs[japan.id].succeededAt);
    assert.doesNotMatch(JSON.stringify(second), /raw-secret-from-provider/);
    assert.deepEqual(store.get<NewsState>('news'), { preferences: before.preferences, articles: before.articles, errors: before.errors, lastRefreshAt: before.lastRefreshAt });
    fail = false; empty = true;
    const third: NewsResponse = await (await request('/news/discover', 'POST', { mode: 'search' })).json();
    assert.equal(third.discovery.articles.length, 0);
    assert.equal(third.discovery.runs[japan.id].error, null);
  }, { news: { search: async i => { calls++; if (fail && i.intent === 'opportunities') throw new Error('raw-secret-from-provider'); return empty ? [] : found(i); } } });
});
test('in-flight search rejects duplicates and cannot resurrect edited or deleted interests', async () => {
  for (const action of ['edit', 'delete']) {
    const started = gate(), release = gate();
    await withAPI(async ({ request }) => {
      const initial: NewsResponse = await (await request('/news')).json();
      const i = initial.discovery.preferences.interests[0];
      const pending = request('/news/discover', 'POST', { mode: 'search', interestID: i.id });
      try {
        await started.promise;
        assert.equal((await (await request('/news')).json()).activity.discovering, true);
        assert.equal((await request('/news/discover', 'POST', { mode: 'search' })).status, 409);
        if (action === 'edit') assert.equal((await request('/news/interests/' + i.id, 'PUT', { ...i, query: 'Japan backend developer roles with sponsorship', expectedRevision: i.revision })).status, 200);
        else assert.equal((await request('/news/interests/' + i.id, 'DELETE', { expectedRevision: i.revision })).status, 204);
      } finally { release.resolve(); }
      assert.equal((await pending).status, 200);
      const state: NewsResponse = await (await request('/news')).json();
      assert.equal(state.activity.discovering, false);
      assert.equal(state.discovery.articles.length, 0);
      assert.equal(state.discovery.runs[i.id], undefined);
    }, { news: { search: async i => { started.resolve(); await release.promise; return found(i); } } });
  }
});
test('five-word queries are enforced by create, edit and search while old preferences and backups remain readable', async () => {
  let calls = 0;
  let legacyBackup: unknown;
  await withAPI(async ({ request, store }) => {
    const initial: NewsResponse = await (await request('/news')).json();
    for (const query of ['Japan', 'Programming jobs in Japan', 'Japan OR jobs AND NOT']) {
      const rejected = await request('/news/interests', 'POST', { ...interestPresets[0], query });
      assert.equal(rejected.status, 400); assert.match((await rejected.json()).error, /at least 5 words/);
    }
    const i = initial.discovery.preferences.interests[0];
    assert.equal((await request('/news/interests/' + i.id, 'PUT', { ...i, query: 'Japan', expectedRevision: i.revision })).status, 400);
    assert.deepEqual(getDiscovery(store).preferences, initial.discovery.preferences);
    const legacy = { ...i, query: 'Japan' }, stored = getDiscovery(store);
    stored.preferences.interests = [legacy]; store.set('newsDiscovery', stored);
    assert.equal((await request('/news')).status, 200);
    const rejectedSearch = await request('/news/discover', 'POST', { mode: 'search' });
    assert.equal(rejectedSearch.status, 400); assert.match((await rejectedSearch.json()).error, /at least 5 search words/); assert.equal(calls, 0);
    const backup = await request('/settings/export'); assert.equal(backup.status, 200);
    const exported = await backup.json(); legacyBackup = exported;
    assert.equal(exported.newsDiscovery.interests[0].query, 'Japan');
    const paused = await request('/news/interests/' + i.id, 'PUT', { ...legacy, enabled: false, expectedRevision: legacy.revision });
    assert.equal(paused.status, 200); const next: NewsInterest = await paused.json();
    const detailed = await request('/news/interests/' + i.id, 'PUT', { ...next, query: 'Software developer jobs in Japan', enabled: true, expectedRevision: next.revision });
    assert.equal(detailed.status, 200);
    assert.equal((await request('/news/discover', 'POST', { mode: 'search' })).status, 200); assert.equal(calls, 1);
  }, { news: { search: async i => { calls++; return found(i); } } });
  await withAPI(async ({ request }) => {
    assert.equal((await request('/settings/import', 'POST', legacyBackup)).status, 200);
    const state: NewsResponse = await (await request('/news')).json();
    assert.equal(state.discovery.preferences.interests[0].query, 'Japan');
    assert.equal((await request('/news/discover', 'POST', { mode: 'search' })).status, 400);
    assert.equal(calls, 1);
  }, { news: { search: async i => { calls++; return found(i); } } });
});
const readyPI = async (): Promise<NewsResponse['ai']> => ({ configured: true, provider: 'pi', model: 'fixture/model', message: 'PI fixture available.' });

test('PI is explicit, requires availability, accepts no API keys and leaves credentials out of storage', async () => {
  let aiCalls = 0, available = false;
  await withAPI(async ({ request, store }) => {
    const initial: NewsResponse = await (await request('/news')).json();
    assert.equal(initial.ai.provider, 'pi'); assert.equal(initial.ai.configured, false);
    assert.equal(aiCalls, 0);
    assert.equal((await request('/news/discover', 'POST', { mode: 'ai' })).status, 400);
    assert.equal(aiCalls, 0);
    const secret = 'test-only-sensitive-key-value';
    assert.equal((await request('/news/ai/key', 'POST', { apiKey: secret })).status, 404);
    available = true;
    const current: NewsResponse = await (await request('/news')).json();
    assert.equal(current.ai.configured, true); assert.equal(current.ai.model, 'fixture/model');
    assert.equal((await request('/news/discover', 'POST', { mode: 'search' })).status, 200);
    assert.equal(aiCalls, 0, 'Standard search never calls PI');
    assert.equal((await request('/news/discover', 'POST', { mode: 'ai', interestID: current.discovery.preferences.interests[0].id })).status, 200);
    assert.equal(aiCalls, 1);
    assert.equal((await (await request('/settings/export')).text()).includes(secret), false);
    assert.equal(JSON.stringify(store.db.prepare('SELECT * FROM documents').all()).includes(secret), false);
    available = false;
    assert.equal((await request('/news/discover', 'POST', { mode: 'ai' })).status, 400);
    assert.equal(aiCalls, 1);
  }, { news: { aiStatus: async () => ({ ...await readyPI(), configured: available }), search: async () => [], aiSearch: async () => { aiCalls++; return []; } } });
});
test('mocked PI response flows through HTTP discovery into cited cached results; failures preserve them', async () => {
  let fail = false, failPage = false;
  const ai = aiDiscovery({ fetcher: async () => {
    if (failPage) throw new Error('private-fetch-error');
    return '<html><title>AI model release</title><meta property="og:type" content="article"><meta name="description" content="A new language model and benchmark."></html>';
  },
    webSearch: async () => {
      if (fail) throw new Error('private-provider-error');
      return { text: JSON.stringify({ articles: [{ summary: 'A new language model and benchmark.', url: 'https://example.com/new-model', relevance: 90, reason: 'A model release with benchmark evidence.' }] }), urls: ['https://example.com/new-model'] };
    } });
  await withAPI(async ({ request }) => {
    const initial: NewsResponse = await (await request('/news')).json();
    const interest = initial.discovery.preferences.interests.find(i => i.intent === 'news')!;
    const result = await request('/news/discover', 'POST', { mode: 'ai', interestID: interest.id });
    assert.equal(result.status, 200);
    const state: NewsResponse = await result.json();
    assert.equal(state.activity.discovering, false);
    assert.equal(state.discovery.runs[interest.id].count, 1);
    assert.equal(state.discovery.articles[0].url, 'https://example.com/new-model');
    assert.equal(state.discovery.articles[0].matches[0].mode, 'ai');
    assert.equal((await (await request('/news')).json()).discovery.articles.length, 1);
    fail = true;
    const failed: NewsResponse = await (await request('/news/discover', 'POST', { mode: 'ai', interestID: interest.id })).json();
    assert.deepEqual(failed.discovery.articles, state.discovery.articles);
    assert.equal(failed.discovery.runs[interest.id].succeededAt, state.discovery.runs[interest.id].succeededAt);
    assert.ok(failed.discovery.runs[interest.id].error);
    assert.doesNotMatch(JSON.stringify(failed), /private-provider-error/);
    assert.equal(failed.activity.discovering, false);
    fail = false; failPage = true;
    const unreadable: NewsResponse = await (await request('/news/discover', 'POST', { mode: 'ai', interestID: interest.id })).json();
    assert.deepEqual(unreadable.discovery.articles, state.discovery.articles);
    assert.equal(unreadable.discovery.runs[interest.id].succeededAt, state.discovery.runs[interest.id].succeededAt);
    assert.match(unreadable.discovery.runs[interest.id].error ?? '', /pages could not be retrieved/);
    assert.doesNotMatch(JSON.stringify(unreadable), /private-fetch-error/);
    assert.equal(unreadable.activity.discovering, false);
  }, { news: { aiStatus: readyPI, aiSearch: ai } });
});
test('AI news-index fallback succeeds over HTTP when every cited page fails and replaces saved results', async () => {
  let pagesFail = false, runCalls = 0;
  const cited = 'https://example.com/new-model', indexed = 'https://example.net/ai-model-index-story';
  const summary = 'A new language model and benchmark.';
  const ai = aiDiscovery({
    webSearch: async () => ({ text: JSON.stringify({ articles: [{ summary, url: cited, relevance: 90, reason: 'A model release with benchmark evidence.' }] }), urls: [cited] }),
    fetcher: async url => {
      if (url.includes('news.google.com')) {
        return '<rss><channel><item><title>AI model release</title><link>' + indexed + '</link><description>' + summary + '</description><pubDate>' +
          new Date(Date.now() - 3_600_000).toUTCString() + '</pubDate></item></channel></rss>';
      }
      if (pagesFail) throw new Error('private-fetch-error');
      return '<html><title>AI model release</title><meta property="og:type" content="article"><meta name="description" content="' + summary + '"></html>';
    },
    run: async prompt => {
      runCalls++;
      assert.deepEqual(JSON.parse(prompt).sources.map((source: { url: string }) => source.url), [indexed]);
      return JSON.stringify({ articles: [{ summary, url: indexed, relevance: 88, reason: 'News-index report of a model release.' }] });
    },
  });
  await withAPI(async ({ request }) => {
    const initial: NewsResponse = await (await request('/news')).json();
    const interest = initial.discovery.preferences.interests.find(i => i.intent === 'news')!;
    const forInterest = (state: NewsResponse) => state.discovery.articles.filter(article => article.matches.some(match => match.interestID === interest.id));
    const first: NewsResponse = await (await request('/news/discover', 'POST', { mode: 'ai', interestID: interest.id })).json();
    assert.deepEqual(forInterest(first).map(article => article.url), [cited]);
    assert.equal(runCalls, 0, 'Readable pages never trigger the fallback');
    pagesFail = true;
    const result = await request('/news/discover', 'POST', { mode: 'ai', interestID: interest.id });
    assert.equal(result.status, 200);
    const fallback: NewsResponse = await result.json();
    assert.equal(runCalls, 1);
    assert.equal(fallback.discovery.runs[interest.id].error, null);
    assert.ok(fallback.discovery.runs[interest.id].count >= 1);
    assert.deepEqual(forInterest(fallback).map(article => article.url), [indexed]);
    assert.equal(forInterest(fallback)[0].matches[0].mode, 'ai');
    assert.doesNotMatch(JSON.stringify(fallback), /private-fetch-error/);
    assert.equal(fallback.activity.discovering, false);
  }, { news: { aiStatus: readyPI, aiSearch: ai } });
});
test('AI availability checks cannot admit overlapping PI searches', async () => {
  const started = gate(), release = gate();
  let calls = 0;
  await withAPI(async ({ request }) => {
    const initial: NewsResponse = await (await request('/news')).json();
    const interest = initial.discovery.preferences.interests[0];
    const pending = request('/news/discover', 'POST', { mode: 'ai', interestID: interest.id });
    try {
      await started.promise;
      assert.equal((await request('/news/discover', 'POST', { mode: 'ai', interestID: interest.id })).status, 409);
      assert.equal(calls, 1);
    } finally { release.resolve(); }
    assert.equal((await pending).status, 200);
  }, { news: { aiStatus: readyPI, aiSearch: async () => { calls++; started.resolve(); await release.promise; return []; } } });
});
test('AI news reports article-filter rejection reasons and preserves previous valid articles', async () => {
  let directoriesOnly = false;
  const url = 'https://example.com/ai-model-release', home = 'https://japan-dev.com/';
  const ai = aiDiscovery({
    webSearch: async () => ({ text: JSON.stringify({ articles: [{ url: directoriesOnly ? home : url,
      summary: 'An announcement about a new AI model with benchmark results.', relevance: 90, reason: 'Covers a model release.' }] }), urls: [directoriesOnly ? home : url] }),
    fetcher: async () => '<title>AI model release</title><meta property="og:type" content="article"><meta name="description" content="A new language model with benchmark results.">',
  });
  await withAPI(async ({ request }) => {
    const initial: NewsResponse = await (await request('/news')).json();
    const interest = initial.discovery.preferences.interests.find(i => i.intent === 'news')!;
    const first: NewsResponse = await (await request('/news/discover', 'POST', { mode: 'ai', interestID: interest.id })).json();
    assert.equal(first.discovery.articles.length, 1); assert.equal(first.discovery.articles[0].url, url);
    directoriesOnly = true;
    const second: NewsResponse = await (await request('/news/discover', 'POST', { mode: 'ai', interestID: interest.id })).json();
    assert.deepEqual(second.discovery.articles, first.discovery.articles);
    assert.match(second.discovery.runs[interest.id].error!, /generic page or job listing/);
    assert.equal(second.discovery.runs[interest.id].succeededAt, first.discovery.runs[interest.id].succeededAt);
  }, { news: { aiStatus: readyPI, aiSearch: ai } });
});
test('web backups restore interests with fresh revisions and old web backups remain accepted', async () => {
  let backup: Record<string, unknown> = {};
  let saved: NewsInterest[] = [];
  await withAPI(async ({ request }) => {
    await request('/news/interests', 'POST', { ...interestPresets[0], name: 'Specific role', excludedTerms: ['senior'] });
    const state: NewsResponse = await (await request('/news')).json(); saved = state.discovery.preferences.interests;
    backup = await (await request('/settings/export')).json(); assert.equal(backup.schemaVersion, 5);
  });
  await withAPI(async ({ request }) => {
    assert.equal((await request('/settings/import', 'POST', backup)).status, 200);
    const state: NewsResponse = await (await request('/news')).json();
    assert.deepEqual(state.discovery.preferences.interests.map(({ revision: _r, ...i }) => i), saved.map(({ revision: _r, ...i }) => i));
    assert.notEqual(state.discovery.preferences.interests[0].revision, saved[0].revision);
    assert.equal(state.discovery.articles.length, 0);
    assert.deepEqual(state.discovery.runs, {});
  });
  await withAPI(async ({ request }) => {
    const { newsDiscovery: _discovery, ...old } = backup;
    assert.equal((await request('/settings/import', 'POST', { ...old, schemaVersion: 1 })).status, 200);
    assert.equal((await (await request('/news')).json()).discovery.preferences.interests.length, 2);
  });
});
test('adding a custom feed selects its topics so refreshed items are visible', async () => {
  await withAPI(async ({ request }) => {
    assert.equal((await request('/news/feeds', 'POST', { name: 'New topic feed', endpoint: 'https://example.com/feed', isEnabled: true, topicIDs: ['unique-topic'] })).status, 201);
    const news: NewsResponse = await (await request('/news')).json();
    assert.ok(news.preferences.selectedTopicIDs.includes('unique-topic'));
  });
});
