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
        if (action === 'edit') assert.equal((await request('/news/interests/' + i.id, 'PUT', { ...i, query: 'A changed interest', expectedRevision: i.revision })).status, 200);
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
  let fail = false;
  const ai = aiDiscovery({ sources: async () => [{ title: 'AI model release', summary: 'A new language model and benchmark.', url: 'https://example.com/new-model', publishedAt: null }],
    run: async () => {
      if (fail) throw new Error('private-provider-error');
      return JSON.stringify({ articles: [{ summary: 'A new language model and benchmark.', url: 'https://example.com/new-model', relevance: 90, reason: 'A model release with benchmark evidence.' }] });
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
test('web backups restore interests with fresh revisions and old web backups remain accepted', async () => {
  let backup: Record<string, unknown> = {};
  let saved: NewsInterest[] = [];
  await withAPI(async ({ request }) => {
    await request('/news/interests', 'POST', { ...interestPresets[0], name: 'Specific role', excludedTerms: ['senior'] });
    const state: NewsResponse = await (await request('/news')).json(); saved = state.discovery.preferences.interests;
    backup = await (await request('/settings/export')).json(); assert.equal(backup.schemaVersion, 3);
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
