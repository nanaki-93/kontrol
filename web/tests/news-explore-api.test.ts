import test from 'node:test';
import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { withAPI } from './helpers';
import { getDiscovery } from '../server/news/discovery';
import { exportData } from '../server/modules/settings';
import { ExploreServiceError, type ExploreService } from '../server/news/explore';
import type { AppOptions } from '../server/app';
import type { NewsInterest, DiscoveredArticle, NewsResponse } from '../shared/news';
import type { NewsState } from '../shared/schema';
import { briefingStories } from '../shared/briefing';
import {
  EXPLORE_SESSION_TTL_MS, exploreGenerateResponseSchema, exploreSearchResponseSchema, exploreStatusResponseSchema,
} from '../shared/news-explore';
import type { Store } from '../server/store';
import { getWorkspace } from '../server/modules/workspace';
import { canonicalURL } from '../shared/workspace';

// Composition/import fixtures use the service directly; endpoint fixtures below
// exercise the protected HTTP contracts with injected providers and retrieval.
const ideas = (sources: readonly NewsInterest[]) => JSON.stringify({ topics: [{
  sourceInterestID: sources[0].id, title: 'Community infrastructure',
  description: 'An adjacent topic direction, not a claim about current events.',
  connection: 'Connects the saved interest to community infrastructure.',
  query: 'Community infrastructure public research collaborative projects',
}] });
const retrieved = (interest: NewsInterest): DiscoveredArticle[] => [{
  id: 'adapter-identity', title: 'Retrieved fixture coverage', url: 'https://example.com/articles/community',
  source: 'Example', summary: 'Literal retrieved source excerpt.', contentKind: 'article',
  publishedAt: null, fetchedAt: new Date().toISOString(), feedIDs: [], topicIDs: [],
  matches: [{ interestID: interest.id, interestRevision: interest.revision, mode: 'search', score: 80, reason: 'Standard fixture' }],
}];
const fixtures: Omit<AppOptions, 'origin'> = {
  explore: { available: async () => true, ideate: async sources => ideas(sources) },
  news: { search: async interest => retrieved(interest) },
};
function deferred<T>() {
  let resolve!: (value: T) => void;
  const promise = new Promise<T>(yes => { resolve = yes; });
  return { promise, resolve };
}
function parent(store: Store): NewsInterest { return getDiscovery(store).preferences.interests.find(i => i.enabled)!; }
async function preview(explore: ExploreService) {
  const { session } = await explore.generate();
  const topic = session.topics[0];
  await explore.search(session.id, topic.id, { expectedSessionRevision: session.revision, search: topic.proposedSearch });
  assert.ok(explore.resolve('https://example.com/articles/community'));
  return session;
}
const obsolete = (error: unknown) => error instanceof ExploreServiceError && error.code === 'obsolete-source';

type Request = Parameters<Parameters<typeof withAPI>[0]>[0]['request'];
const previewURL = 'https://example.com/articles/community';
async function reading(request: Request, store: Store, body: Record<string, unknown>) {
  return request('/workspace/articles', 'PUT', { expectedRevision: getWorkspace(store).revision, ...body });
}

for (const command of [{ saved: true }, { read: true }, { notes: 'Authored preview note', expectedNotes: '' }]) {
  test('explore reading: trusted preview supports ' + Object.keys(command)[0] + ' without persistent discovery', async () => {
    await withAPI(async ({ request, store, explore }) => {
      await preview(explore);
      const news = store.get('news'), discovery = store.get('newsDiscovery');
      const trusted = explore.resolve(previewURL)!.article;
      assert.equal((await reading(request, store, { url: previewURL, ...command,
        article: { title: 'Forged headline', summaryKind: 'ai-snippet', summary: 'Untrusted client text' },
      })).status, 200);
      const record = getWorkspace(store).articles[0];
      assert.deepEqual(record.article, { title: trusted.title, url: trusted.url, source: trusted.source,
        summary: trusted.summary, publishedAt: trusted.publishedAt, fetchedAt: trusted.fetchedAt, summaryKind: 'source' });
      assert.equal(record.savedAt !== null, 'saved' in command || 'notes' in command);
      assert.equal(record.readAt !== null, 'read' in command);
      assert.equal(record.notes, 'notes' in command ? command.notes : '');
      assert.deepEqual(store.get('news'), news); assert.deepEqual(store.get('newsDiscovery'), discovery);
      explore.dispose();
      assert.equal((await reading(request, store, { url: previewURL, read: false })).status, 200);
      assert.deepEqual(getWorkspace(store).articles[0].article, record.article);
      assert.equal(getWorkspace(store).articles[0].notes, record.notes);
    }, fixtures);
  });
}

test('explore reading: arbitrary snapshots and unknown URLs cannot establish evidence', async () => {
  await withAPI(async ({ request, store, explore }) => {
    await preview(explore);
    const before = getWorkspace(store), article = explore.resolve(previewURL)!.article;
    await assertPublicError(await reading(request, store, { url: 'https://example.com/articles/not-retrieved', saved: true, article }), 404, /search|refresh/);
    await assertPublicError(await reading(request, store, { article, saved: true }), 400);
    await assertPublicError(await reading(request, store, { url: 'javascript:alert(1)', article, saved: true }), 400);
    assert.deepEqual(getWorkspace(store), before);
  }, fixtures);
});

test('explore reading: canonical duplicates, workspace revisions and note baselines protect authored snapshots', async () => {
  await withAPI(async ({ request, store, explore }) => {
    await preview(explore);
    const initial = getWorkspace(store);
    assert.equal((await reading(request, store, { url: previewURL + '?utm_source=fixture#top', notes: 'First note', read: true })).status, 200);
    const saved = getWorkspace(store);
    await assertPublicError(await request('/workspace/articles', 'PUT', {
      url: previewURL, saved: true, notes: 'Stale overwrite', expectedRevision: initial.revision,
    }), 409, /workspace changed/);
    await assertPublicError(await reading(request, store, { url: previewURL, notes: 'Stale overwrite', saved: false, expectedNotes: '' }), 409, /notes changed/);
    assert.deepEqual(getWorkspace(store), saved);
    assert.equal((await reading(request, store, { url: previewURL, notes: 'Approved edit', expectedNotes: 'First note' })).status, 200);
    const after = getWorkspace(store);
    assert.equal(after.articles.length, 1); assert.deepEqual(after.articles[0].article, saved.articles[0].article);
    assert.equal(after.articles[0].notes, 'Approved edit'); assert.equal(after.articles[0].savedAt, saved.articles[0].savedAt);
    assert.equal(canonicalURL(after.articles[0].article.url), previewURL);
  }, fixtures);
});

test('explore reading: existing AI workspace, persisted discovery and feed snapshots precede temporary evidence', async () => {
  await withAPI(async ({ request, store, explore }) => {
    await preview(explore);
    const source = retrieved(parent(store))[0], discovery = getDiscovery(store), news = store.get<NewsState>('news');
    discovery.articles = [{ ...source, summary: 'Persisted AI excerpt.', matches: [{ ...source.matches[0], mode: 'ai' }] }];
    news.articles = [{ ...source, summary: 'Persisted feed excerpt.' }];
    store.set('newsDiscovery', discovery); store.set('news', news);
    assert.equal((await reading(request, store, { url: previewURL, notes: 'Keep authored text' })).status, 200);
    const saved = getWorkspace(store).articles[0];
    assert.equal(saved.article.summary, 'Persisted AI excerpt.'); assert.equal(saved.article.summaryKind, 'ai-snippet');
    store.set('newsDiscovery', { ...discovery, articles: [] });
    assert.equal((await reading(request, store, { url: previewURL, read: true })).status, 200);
    assert.deepEqual(getWorkspace(store).articles[0].article, saved.article);
    assert.equal(getWorkspace(store).articles[0].notes, 'Keep authored text');
    // Remove only the test record to exercise the next precedence tier.
    const workspace = getWorkspace(store); store.set('workspace', { ...workspace, articles: [] });
    assert.equal((await reading(request, store, { url: previewURL, saved: true })).status, 200);
    assert.equal(getWorkspace(store).articles[0].article.summary, 'Persisted feed excerpt.');
    assert.equal(getWorkspace(store).articles[0].article.summaryKind, 'source');
  }, fixtures);
});

test('explore reading: bookmark capacity failures roll back without evicting authored records', async () => {
  await withAPI(async ({ request, store, explore }) => {
    await preview(explore);
    const state = getWorkspace(store), at = new Date().toISOString();
    state.articles = Array.from({ length: 1000 }, (_, i) => ({ id: randomUUID(), article: {
      title: 'Saved fixture ' + i, url: 'https://example.com/articles/saved/' + i, source: 'Fixture', summary: '',
      publishedAt: null, fetchedAt: at, summaryKind: 'source' as const,
    }, savedAt: at, readAt: null, notes: i === 0 ? 'Authored note' : '', updatedAt: at }));
    store.set('workspace', state);
    await assertPublicError(await reading(request, store, { url: previewURL, saved: true }), 400);
    assert.deepEqual(getWorkspace(store), state);
    assert.ok(explore.resolve(previewURL), 'Rejected persistence does not destroy trusted preview');
    state.articles[1].savedAt = null; state.articles[1].readAt = at;
    state.articles[2].savedAt = null; state.articles[2].notes = 'Protected authored note';
    store.set('workspace', state);
    assert.equal((await reading(request, store, { url: previewURL, read: true })).status, 200);
    const after = getWorkspace(store);
    assert.equal(after.articles.length, 1000);
    assert.equal(after.articles.some(a => a.id === state.articles[1].id), false, 'Only disposable read marker is evicted');
    assert.equal(after.articles.find(a => a.id === state.articles[2].id)?.notes, 'Protected authored note');
    assert.equal(after.articles.find(a => a.article.url === previewURL)?.savedAt, null);
  }, fixtures);
});

test('explore reading: byte capacity failures are atomic even below the article count bound', async () => {
  await withAPI(async ({ request, store, explore }) => {
    await preview(explore);
    const state = getWorkspace(store), at = new Date().toISOString();
    state.articles = Array.from({ length: 170 }, (_, i) => ({ id: randomUUID(), article: {
      title: 'Saved fixture ' + i, url: 'https://example.com/articles/saved/' + i, source: 'Fixture', summary: '',
      publishedAt: null, fetchedAt: at, summaryKind: 'source' as const,
    }, savedAt: at, readAt: null, notes: '', updatedAt: at }));
    let remaining = 8 * 1024 * 1024 - 1024 - Buffer.byteLength(JSON.stringify(state));
    for (const record of state.articles) {
      const length = Math.min(50_000, remaining); record.article.summary = 'x'.repeat(length); remaining -= length;
    }
    assert.equal(remaining, 0); store.set('workspace', state);
    await assertPublicError(await reading(request, store, { url: previewURL, saved: true, notes: 'x'.repeat(2000) }), 400, /8 MB/);
    assert.deepEqual(getWorkspace(store), state);
  }, fixtures);
});

for (const loss of ['expiry', 'source-revocation', 'replacement', 'disposal'] as const) {
  test('explore reading: ' + loss + ' requires explicit refresh for unsaved sources but preserves bookmarks and notes', async () => {
    let now = Date.parse('2026-10-06T12:00:00Z');
    await withAPI(async ({ request, store, explore }) => {
      // A second retrieved fixture provides an independently unsaved URL.
      const { session } = await explore.generate();
      const topic = session.topics[0];
      await explore.search(session.id, topic.id, { expectedSessionRevision: session.revision, search: topic.proposedSearch });
      assert.equal((await reading(request, store, { url: previewURL, saved: true, notes: 'Durable note' })).status, 200);
      const before = getWorkspace(store), unsaved = previewURL + '-unsaved';
      assert.ok(explore.resolve(unsaved));
      if (loss === 'expiry') now += EXPLORE_SESSION_TTL_MS;
      else if (loss === 'source-revocation') {
        const source = parent(store);
        assert.equal((await request('/news/interests/' + source.id, 'PUT', { ...source, enabled: false, expectedRevision: source.revision })).status, 200);
      } else if (loss === 'replacement') await explore.generate();
      else explore.dispose();
      await assertPublicError(await reading(request, store, { url: unsaved, notes: 'Cannot save stale coverage' }), 404, /search|refresh/);
      assert.deepEqual(getWorkspace(store), before);
      assert.equal((await reading(request, store, { url: previewURL, read: true })).status, 200);
      const after = getWorkspace(store).articles[0];
      assert.deepEqual(after.article, before.articles[0].article); assert.equal(after.notes, 'Durable note');
    }, { ...fixtures, clock: () => now, news: { search: async interest => {
      const source = retrieved(interest)[0]; return [source, { ...source, id: 'unsaved', url: source.url + '-unsaved' }];
    } } });
  });
}

test('explore reading: version-5 backup/import retains saved reading but excludes temporary ideas and unsaved coverage', async () => {
  let backup: Record<string, unknown> = {}, saved: ReturnType<typeof getWorkspace>['articles'] = [];
  await withAPI(async ({ request, store, explore }) => {
    await preview(explore);
    assert.equal((await reading(request, store, { url: previewURL, notes: 'Backup reading note', read: true })).status, 200);
    saved = getWorkspace(store).articles;
    backup = await (await request('/settings/export')).json();
    assert.equal(backup.schemaVersion, 5);
    assert.deepEqual(Object.keys(backup).sort(), ['format', 'schemaVersion', 'data', 'layout', 'newsDiscovery', 'jobs', 'workspace'].sort());
    assert.doesNotMatch(JSON.stringify(backup), /Community infrastructure|sourceInterestID/);
    explore.dispose();
  }, fixtures);
  await withAPI(async ({ request, store, explore }) => {
    assert.equal((await request('/settings/import', 'POST', backup)).status, 200);
    assert.deepEqual(getWorkspace(store).articles, saved);
    assert.equal(explore.resolve(previewURL), undefined);
    assert.equal((await reading(request, store, { url: previewURL, read: false })).status, 200);
    assert.equal(getWorkspace(store).articles[0].notes, 'Backup reading note');
  }, fixtures);
});

test('explore composition: apps own isolated caches and local reads invoke no external work', async () => {
  let ideations = 0, searches = 0;
  await withAPI(async ({ request, explore: a, store: storeA }) => {
    assert.equal((await request('/news')).status, 200);
    assert.equal(a.snapshot().lifecycle.state, 'absent');
    assert.equal(ideations, 0); assert.equal(searches, 0);
    const beforeNews = storeA.get('news'), beforeDiscovery = storeA.get('newsDiscovery');
    await preview(a);
    await withAPI(async ({ explore: b }) => {
      assert.notEqual(a, b); assert.equal(b.snapshot().lifecycle.state, 'absent');
      assert.equal(b.resolve('https://example.com/articles/community'), undefined);
      b.invalidate();
      assert.equal(a.snapshot().lifecycle.state, 'available');
    }, fixtures);
    assert.equal(ideations, 1); assert.equal(searches, 1);
    assert.deepEqual(storeA.get('news'), beforeNews); assert.deepEqual(storeA.get('newsDiscovery'), beforeDiscovery);
    const backup = await (await request('/settings/export')).json();
    assert.deepEqual(Object.keys(backup).sort(), ['format', 'schemaVersion', 'data', 'layout', 'newsDiscovery', 'jobs', 'workspace'].sort());
    assert.doesNotMatch(JSON.stringify(backup), /Community infrastructure|Literal retrieved source excerpt/);
  }, { explore: { ...fixtures.explore, ideate: async sources => { ideations++; return ideas(sources); } },
    news: { search: async interest => { searches++; return retrieved(interest); } } });
});

for (const action of ['edit', 'disable', 'delete'] as const) {
  test('explore composition: committed ' + action + ' revokes immediately and remains sticky', async () => {
    await withAPI(async ({ store, request, explore }) => {
      const original = getDiscovery(store), source = parent(store);
      const session = await preview(explore);
      // Rejected mutations cannot revoke a valid session.
      assert.equal((await request('/news/interests/' + source.id, 'PUT', {
        ...source, expectedRevision: randomUUID(),
      })).status, 409);
      assert.equal((await request('/news/interests/' + source.id, 'PUT', {
        ...source, query: '', expectedRevision: source.revision,
      })).status, 400);
      assert.equal((await request('/news/interests/' + source.id, 'DELETE', { expectedRevision: randomUUID() })).status, 409);
      assert.equal(explore.snapshot().lifecycle.state, 'available');
      assert.ok(explore.resolve('https://example.com/articles/community'));
      // A failed database write must not invoke the post-commit revocation hook.
      const beforeRollback = explore.snapshot();
      const set = store.set.bind(store);
      store.set = (key, value) => { if (key === 'newsDiscovery') throw new Error('Injected mutation failure'); set(key, value); };
      try {
        assert.equal((await request('/news/interests/' + source.id, 'PUT', {
          ...source, name: 'Rejected storage edit', expectedRevision: source.revision,
        })).status, 500);
      } finally { store.set = set; }
      assert.deepEqual(explore.snapshot(), beforeRollback);
      assert.ok(explore.resolve('https://example.com/articles/community'));
      const result = action === 'delete' ? await request('/news/interests/' + source.id, 'DELETE', { expectedRevision: source.revision }) :
        await request('/news/interests/' + source.id, 'PUT', { ...source, expectedRevision: source.revision,
          ...(action === 'disable' ? { enabled: false } : { name: 'Edited source' }) });
      assert.equal(result.status, action === 'delete' ? 204 : 200);
      // Restore before any exposure: proves the route hook revoked it at COMMIT,
      // not merely the service's defensive current-source check on the next read.
      store.set('newsDiscovery', original);
      const status = explore.snapshot();
      assert.equal(status.lifecycle.state, 'available');
      if (status.lifecycle.state !== 'available') assert.fail('Expected retained obsolete gallery');
      assert.equal(status.lifecycle.session.topics[0].status, 'obsolete');
      assert.notEqual(status.lifecycle.session.revision, session.revision);
      assert.equal(explore.resolve('https://example.com/articles/community'), undefined);
    }, fixtures);
  });
}

test('explore composition: direct store changes are rechecked at exposure and resolution', async () => {
  await withAPI(async ({ store, explore }) => {
    await preview(explore);
    const original = getDiscovery(store), changed = structuredClone(original);
    changed.preferences.interests[0].enabled = false;
    store.set('newsDiscovery', changed);
    assert.equal(explore.resolve('https://example.com/articles/community'), undefined);
    store.set('newsDiscovery', original);
    const status = explore.snapshot();
    if (status.lifecycle.state !== 'available') assert.fail('Expected retained gallery');
    assert.equal(status.lifecycle.session.topics[0].status, 'obsolete');
  }, fixtures);
});

for (const format of ['legacy', 'current'] as const) {
  test('explore import: successful ' + format + ' commit revokes even retained interest revisions', async () => {
    await withAPI(async ({ store, request, explore }) => {
      const session = await preview(explore), original = getDiscovery(store).preferences;
      const backup = format === 'legacy' ? exportData(store) : await (await request('/settings/export')).json();
      assert.equal((await request('/settings/import/preview', 'POST', backup)).status, 200);
      assert.equal(explore.snapshot().lifecycle.state, 'available');
      assert.equal((await request('/settings/import', 'POST', backup)).status, 200);
      assert.equal(explore.snapshot().lifecycle.state, 'obsolete');
      assert.equal(explore.resolve('https://example.com/articles/community'), undefined);
      if (format === 'legacy') assert.deepEqual(getDiscovery(store).preferences, original);
      else assert.notEqual(parent(store).revision, original.interests[0].revision);
      await assert.rejects(explore.search(session.id, session.topics[0].id, {
        expectedSessionRevision: session.revision, search: session.topics[0].proposedSearch,
      }), obsolete);
    }, fixtures);
  });
}

test('explore import: invalid input, rejected import and transaction rollback preserve valid evidence', async () => {
  await withAPI(async ({ store, request, explore }) => {
    await preview(explore);
    const before = explore.snapshot(), discovery = getDiscovery(store);
    const backup = exportData(store);
    assert.equal((await request('/settings/import', 'POST', {})).status, 400);
    store.set('imported', { at: new Date().toISOString() });
    assert.equal((await request('/settings/import', 'POST', backup)).status, 409);
    store.db.prepare('DELETE FROM documents WHERE key = ?').run('imported');
    const set = store.set.bind(store);
    store.set = (key, value) => { if (key === 'preferences') throw new Error('Injected storage failure'); set(key, value); };
    try { assert.equal((await request('/settings/import', 'POST', backup)).status, 500); }
    finally { store.set = set; }
    assert.equal(store.has('imported'), false);
    assert.deepEqual(getDiscovery(store), discovery);
    assert.deepEqual(explore.snapshot(), before);
    assert.ok(explore.resolve('https://example.com/articles/community'));
  }, fixtures);
});

for (const format of ['legacy', 'current'] as const) for (const operation of ['generation', 'search'] as const) {
  test('explore import race: committed ' + format + ' import aborts ' + operation + ' and rejects late publication', async () => {
    const started = deferred<void>(), release = deferred<void>();
    let ownedSignal: AbortSignal | undefined;
    await withAPI(async ({ store, request, explore }) => {
      const original = getDiscovery(store).preferences;
      let pending: Promise<unknown>;
      if (operation === 'generation') pending = explore.generate();
      else {
        const { session } = await explore.generate();
        pending = explore.search(session.id, session.topics[0].id, {
          expectedSessionRevision: session.revision, search: session.topics[0].proposedSearch,
        });
      }
      const rejected = assert.rejects(pending, obsolete); // attach before cancellation
      try {
        await started.promise;
        const backup = format === 'legacy' ? exportData(store) : await (await request('/settings/export')).json();
        assert.equal((await request('/settings/import', 'POST', backup)).status, 200);
        assert.equal(ownedSignal?.aborted, true);
        await rejected;
        if (format === 'legacy') assert.deepEqual(getDiscovery(store).preferences, original);
        assert.equal(explore.snapshot().lifecycle.state, 'obsolete');
      } finally { release.resolve(); }
      // Adapter deliberately ignores cancellation; its old response still cannot
      // resurrect state. A fresh explicit generation establishes a new owner.
      const replacement = await explore.generate();
      assert.deepEqual(explore.snapshot().lifecycle, { state: 'available', session: replacement.session });
    }, {
      explore: { available: async () => true, ideate: async (sources, signal) => {
        if (operation === 'generation' && !ownedSignal) { ownedSignal = signal; started.resolve(); await release.promise; }
        return ideas(sources);
      } },
      news: { search: async (interest, signal) => {
        ownedSignal = signal; started.resolve(); await release.promise; return retrieved(interest);
      } },
    });
  });
}

test('explore lifecycle: fixture teardown disposes timers and resolver before closing the store', async () => {
  const timers = new Set<() => void>(); let owner: ExploreService | undefined;
  await withAPI(async ({ explore }) => { owner = explore; await preview(explore); assert.equal(timers.size, 1); }, {
    ...fixtures, explore: { ...fixtures.explore, schedule: callback => { timers.add(callback); return () => { timers.delete(callback); }; } },
  });
  assert.equal(timers.size, 0);
  assert.equal(owner?.resolve('https://example.com/articles/community'), undefined);
  await assert.rejects(owner!.generate(), error => error instanceof ExploreServiceError && error.code === 'session-gone');
});

const topicSearchPath = (sessionID: string, topicID: string) => '/news/explore/' + sessionID + '/topics/' + topicID + '/search';
const threeIdeas = (sources: readonly NewsInterest[]) => JSON.stringify({ topics: [
  JSON.parse(ideas(sources)).topics[0],
  { sourceInterestID: sources[0].id, title: 'Public archives', description: 'Another adjacent direction.',
    connection: 'Connects research and public archives.', query: 'Public archives language preservation research tools' },
  { sourceInterestID: sources[0].id, title: 'Urban cooling', description: 'A third adjacent direction.',
    connection: 'Connects infrastructure and urban cooling.', query: 'Urban cooling district heating infrastructure research' },
] });
async function assertPublicError(response: Response, status: number, message?: RegExp) {
  assert.equal(response.status, status);
  const body = await response.json();
  assert.deepEqual(Object.keys(body), ['error']);
  assert.equal(typeof body.error, 'string');
  assert.doesNotMatch(body.error, /private-provider-secret|private-transport-secret/);
  if (message) assert.match(body.error, message);
}

test('explore HTTP: local recovery is zero-work; explicit actions preserve persistent News and fixed-clock briefing', async () => {
  const at = Date.parse('2026-10-06T12:00:00Z');
  let ideations = 0, searches = 0, availability = 0;
  await withAPI(async ({ request, store }) => {
    const news = store.get<NewsState>('news');
    const feed = news.preferences.feeds.find(f => f.isEnabled && f.topicIDs.some(id => news.preferences.selectedTopicIDs.includes(id)))!;
    assert.ok(feed);
    news.articles = [{ ...retrieved(parent(store))[0], id: 'existing-feed-article', title: 'Existing feed story',
      url: 'https://example.com/articles/existing', publishedAt: new Date(at).toISOString(),
      fetchedAt: new Date(at).toISOString(), feedIDs: [feed.id], topicIDs: feed.topicIDs }];
    store.set('news', news);
    const initial: NewsResponse = await (await request('/news')).json();
    const documents = store.db.prepare('SELECT * FROM documents ORDER BY key').all();
    const edition = briefingStories(initial, undefined, at);
    assert.ok(edition.length > 0, 'Non-empty briefing makes the equality check meaningful');
    for (let i = 0; i < 2; i++) {
      const response = await request('/news/explore');
      assert.equal(response.status, 200);
      assert.equal(response.headers.get('cache-control'), 'no-store');
      assert.deepEqual(exploreStatusResponseSchema.parse(await response.json()), { lifecycle: { state: 'absent' }, generation: { state: 'idle' } });
    }
    assert.deepEqual([ideations, searches, availability], [0, 0, 0]);
    const generated = await request('/news/explore/generate', 'POST', {});
    assert.equal(generated.status, 200);
    const { session, partial } = exploreGenerateResponseSchema.parse(await generated.json());
    assert.equal(partial, false); assert.equal(session.topics.length, 3);
    assert.deepEqual([ideations, searches, availability], [1, 0, 1]);
    const topic = session.topics[0];
    const found = await request(topicSearchPath(session.id, topic.id), 'POST', {
      expectedSessionRevision: session.revision, search: topic.proposedSearch,
    });
    assert.equal(found.status, 200);
    const result = exploreSearchResponseSchema.parse(await found.json());
    assert.equal(result.topicID, topic.id); assert.equal(result.preview.state, 'successful');
    if (result.preview.state !== 'successful') assert.fail('Expected retrieved coverage');
    assert.equal(result.preview.result.articles[0].summary, 'Literal retrieved source excerpt.');
    assert.equal(result.preview.result.articles[0].summaryKind, 'source');
    assert.equal('matches' in result.preview.result.articles[0], false);
    const status = exploreStatusResponseSchema.parse(await (await request('/news/explore')).json());
    if (status.lifecycle.state !== 'available') assert.fail('Expected current session');
    assert.deepEqual(status.lifecycle.session.topics[0].preview, result.preview);
    assert.equal(status.lifecycle.session.topics[1].preview.state, 'not-searched');
    assert.deepEqual([ideations, searches, availability], [1, 1, 1]);
    assert.deepEqual(store.db.prepare('SELECT * FROM documents ORDER BY key').all(), documents);
    const after: NewsResponse = await (await request('/news')).json();
    assert.deepEqual(after, initial);
    assert.deepEqual(briefingStories(after, undefined, at), edition);
    // Temporary search does not weaken or repurpose saved-interest discovery.
    await assertPublicError(await request('/news/discover', 'POST', { mode: 'search', interestID: topic.id }), 400);
    assert.deepEqual(store.db.prepare('SELECT * FROM documents ORDER BY key').all(), documents);
    assert.equal(searches, 1);
  }, { clock: () => at, explore: { available: async () => { availability++; return true; },
    ideate: async sources => { ideations++; return threeIdeas(sources); } },
    news: { search: async interest => { searches++; return retrieved(interest); } } });
});

test('explore HTTP: every endpoint inherits client, host, origin, fetch-site and JSON protections', async () => {
  let ideations = 0, searches = 0;
  await withAPI(async ({ request, store, origin }) => {
    const generated = exploreGenerateResponseSchema.parse(await (await request('/news/explore/generate', 'POST', {})).json());
    const topic = generated.session.topics[0];
    const before = store.db.prepare('SELECT * FROM documents ORDER BY key').all();
    const routes = [
      { path: '/news/explore', method: 'GET', body: undefined },
      { path: '/news/explore/generate', method: 'POST', body: {} },
      { path: topicSearchPath(generated.session.id, topic.id), method: 'POST',
        body: { expectedSessionRevision: generated.session.revision, search: topic.proposedSearch } },
    ];
    const rejectedHeaders: Record<string, string>[] = [{ 'X-Kontrol-Client': '' }, { Origin: 'https://other.example' },
      { Host: 'other.example' }, { 'Sec-Fetch-Site': 'cross-site' }];
    for (const route of routes) {
      for (const headers of rejectedHeaders) {
        await assertPublicError(await request(route.path, route.method, route.body, headers), 403);
      }
      if (route.method === 'POST') {
        await assertPublicError(await request(route.path, route.method, route.body, { 'Content-Type': 'text/plain' }), 415);
        await assertPublicError(await fetch(origin + '/api' + route.path, { method: 'POST', headers: {
          'X-Kontrol-Client': 'web', 'Content-Type': 'application/json',
        }, body: '{broken-json' }), 400, /Invalid JSON/);
      }
    }
    assert.deepEqual([ideations, searches], [1, 0]);
    assert.deepEqual(store.db.prepare('SELECT * FROM documents ORDER BY key').all(), before);
  }, { ...fixtures, explore: { ...fixtures.explore, ideate: async sources => { ideations++; return ideas(sources); } },
    news: { search: async interest => { searches++; return retrieved(interest); } } });
});

test('explore HTTP: strict bodies, UUID parameters and query rules reject client context, evidence and AI modes before admission', async () => {
  let ideations = 0, searches = 0;
  await withAPI(async ({ request, store }) => {
    for (const body of [undefined, null, [], { interests: [parent(store)] }, { prompt: 'private context' },
      { articles: retrieved(parent(store)) }, { mode: 'ai' }]) {
      await assertPublicError(await request('/news/explore/generate', 'POST', body), 400);
    }
    assert.equal(ideations, 0);
    const { session } = exploreGenerateResponseSchema.parse(await (await request('/news/explore/generate', 'POST', {})).json());
    const topic = session.topics[0], path = topicSearchPath(session.id, topic.id);
    const valid = { expectedSessionRevision: session.revision, search: topic.proposedSearch };
    const before = store.db.prepare('SELECT * FROM documents ORDER BY key').all();
    for (const body of [undefined, null, [], {}, { ...valid, expectedSessionRevision: 'bad-revision' },
      { ...valid, mode: 'ai' }, { ...valid, article: retrieved(parent(store))[0] },
      { ...valid, search: { ...valid.search, query: 'short query' } },
      { ...valid, search: { ...valid.search, language: 'fr' } }, { ...valid, search: { ...valid.search, region: 'DE' } },
      { ...valid, search: { ...valid.search, days: 14 } }, { ...valid, search: { ...valid.search, enabled: false } },
      { ...valid, search: { ...valid.search, mode: 'ai' } }, { ...valid, search: { ...valid.search, intent: 'opportunities' } },
      { ...valid, search: { ...valid.search, requiredTerms: ['inherited'] } }]) {
      await assertPublicError(await request(path, 'POST', body), 400);
    }
    for (const [sessionID, topicID] of [['model-session', topic.id], [session.id, 'model-topic']]) {
      await assertPublicError(await request(topicSearchPath(sessionID, topicID), 'POST', valid), 400);
    }
    assert.deepEqual([ideations, searches], [1, 0]);
    const status = exploreStatusResponseSchema.parse(await (await request('/news/explore')).json());
    assert.deepEqual(status, { lifecycle: { state: 'available', session }, generation: { state: 'idle' } });
    assert.deepEqual(store.db.prepare('SELECT * FROM documents ORDER BY key').all(), before);
  }, { ...fixtures, explore: { ...fixtures.explore, ideate: async sources => { ideations++; return ideas(sources); } },
    news: { search: async interest => { searches++; return retrieved(interest); } } });
});

test('explore HTTP: pending generation gates duplicates before availability and exposes local activity and partial success', async () => {
  const started = deferred<void>(), release = deferred<void>();
  let availability = 0, ideations = 0;
  await withAPI(async ({ request }) => {
    const pending = request('/news/explore/generate', 'POST', {});
    try {
      await started.promise;
      const status = exploreStatusResponseSchema.parse(await (await request('/news/explore')).json());
      assert.equal(status.generation.state, 'pending'); assert.equal(status.lifecycle.state, 'absent');
      await assertPublicError(await request('/news/explore/generate', 'POST', {}), 409, /already running/);
      assert.deepEqual([availability, ideations], [1, 0]);
    } finally { release.resolve(); await pending; }
    const response = await pending; assert.equal(response.status, 200);
    const generated = exploreGenerateResponseSchema.parse(await response.json());
    assert.equal(generated.partial, true); assert.equal(generated.session.topics.length, 1);
    assert.deepEqual([availability, ideations], [1, 1]);
    const recovered = exploreStatusResponseSchema.parse(await (await request('/news/explore')).json());
    assert.equal(recovered.generation.state, 'idle');
    assert.deepEqual(recovered.lifecycle, { state: 'available', session: generated.session });
  }, { explore: { available: async () => { availability++; started.resolve(); await release.promise; return true; },
    ideate: async sources => { ideations++; return ideas(sources); } } });
});

test('explore HTTP: preview activity gates same-topic duplicates and global concurrency without queuing', async () => {
  const release = deferred<void>(), firstStarted = deferred<void>(), secondStarted = deferred<void>();
  let searches = 0;
  await withAPI(async ({ request }) => {
    const { session } = exploreGenerateResponseSchema.parse(await (await request('/news/explore/generate', 'POST', {})).json());
    const search = (index: number) => request(topicSearchPath(session.id, session.topics[index].id), 'POST', {
      expectedSessionRevision: session.revision, search: session.topics[index].proposedSearch,
    });
    const first = search(0); let second: Promise<Response> | undefined;
    try {
      await firstStarted.promise;
      await assertPublicError(await search(0), 409);
      second = search(1); await secondStarted.promise;
      await assertPublicError(await search(2), 409);
      const status = exploreStatusResponseSchema.parse(await (await request('/news/explore')).json());
      if (status.lifecycle.state !== 'available') assert.fail('Expected current session');
      assert.deepEqual(status.lifecycle.session.topics.map(t => t.preview.state), ['pending', 'pending', 'not-searched']);
      assert.equal(searches, 2);
    } finally { release.resolve(); await Promise.all([first, second]); }
    assert.equal((await first).status, 200); assert.equal((await second!).status, 200);
    assert.equal((await search(2)).status, 200); assert.equal(searches, 3);
  }, { explore: { available: async () => true, ideate: async sources => threeIdeas(sources) },
    news: { search: async interest => {
      searches++; if (searches === 1) firstStarted.resolve(); if (searches === 2) secondStarted.resolve();
      await release.promise; return retrieved(interest);
    } } });
});

test('explore HTTP: missing, restarted and expired identities give recovery errors without external work', async () => {
  let now = Date.parse('2026-10-06T12:00:00Z'), searches = 0, ideations = 0;
  let oldSessionID = '', oldTopicID = '', oldRevision = '';
  await withAPI(async ({ request }) => {
    const search = { query: 'Community infrastructure public research collaborative projects', language: 'en', region: 'US', days: 7 };
    await assertPublicError(await request(topicSearchPath(randomUUID(), randomUUID()), 'POST', {
      expectedSessionRevision: randomUUID(), search,
    }), 410, /expired|unavailable/);
    const { session } = exploreGenerateResponseSchema.parse(await (await request('/news/explore/generate', 'POST', {})).json());
    const topic = session.topics[0];
    oldSessionID = session.id; oldTopicID = topic.id; oldRevision = session.revision;
    const body = { expectedSessionRevision: session.revision, search: topic.proposedSearch };
    await assertPublicError(await request(topicSearchPath(randomUUID(), topic.id), 'POST', body), 410);
    await assertPublicError(await request(topicSearchPath(session.id, randomUUID()), 'POST', body), 410);
    await assertPublicError(await request(topicSearchPath(session.id, topic.id), 'POST', { ...body, expectedSessionRevision: randomUUID() }), 409);
    now += EXPLORE_SESSION_TTL_MS;
    const status = exploreStatusResponseSchema.parse(await (await request('/news/explore')).json());
    assert.equal(status.lifecycle.state, 'expired');
    await assertPublicError(await request(topicSearchPath(session.id, topic.id), 'POST', body), 410);
    assert.deepEqual([ideations, searches], [1, 0]);
  }, { clock: () => now, explore: { available: async () => true, ideate: async sources => { ideations++; return ideas(sources); } },
    news: { search: async () => { searches++; return []; } } });
  await withAPI(async ({ request }) => {
    await assertPublicError(await request(topicSearchPath(oldSessionID, oldTopicID), 'POST', {
      expectedSessionRevision: oldRevision,
      search: { query: 'Community infrastructure public research collaborative projects', language: 'en', region: 'US', days: 7 },
    }), 410);
    assert.equal(exploreStatusResponseSchema.parse(await (await request('/news/explore')).json()).lifecycle.state, 'absent');
  }, fixtures);
});

for (const failure of ['no-interests', 'pi-unavailable', 'availability-error', 'provider-error', 'invalid-output'] as const) {
  test('explore HTTP: ' + failure + ' is sanitized, finite and recoverable', async () => {
    let availableCalls = 0, ideations = 0;
    await withAPI(async ({ request, store }) => {
      if (failure === 'no-interests') {
        const discovery = getDiscovery(store);
        discovery.preferences.interests.forEach(i => { i.enabled = false; }); store.set('newsDiscovery', discovery);
      }
      const before = store.db.prepare('SELECT * FROM documents ORDER BY key').all();
      await assertPublicError(await request('/news/explore/generate', 'POST', {}),
        ['no-interests', 'pi-unavailable'].includes(failure) ? 400 : 502);
      const status = exploreStatusResponseSchema.parse(await (await request('/news/explore')).json());
      assert.equal(status.generation.state, 'failed'); assert.equal(status.lifecycle.state, 'absent');
      assert.equal(availableCalls, failure === 'no-interests' ? 0 : 1);
      assert.equal(ideations, ['provider-error', 'invalid-output'].includes(failure) ? 1 : 0);
      assert.doesNotMatch(JSON.stringify(status), /private-provider-secret/);
      assert.deepEqual(store.db.prepare('SELECT * FROM documents ORDER BY key').all(), before);
    }, { explore: { available: async () => {
      availableCalls++; if (failure === 'availability-error') throw new Error('private-provider-secret');
      return failure !== 'pi-unavailable';
    }, ideate: async () => {
      ideations++; if (failure === 'provider-error') throw new Error('private-provider-secret');
      return '{"topics":[]}';
    } } });
  });
}

test('explore HTTP: failed generation and changed-query refresh retain owned results; successful empty is distinct', async () => {
  let failGeneration = false, failSearch = false, empty = false;
  await withAPI(async ({ request }) => {
    const { session } = exploreGenerateResponseSchema.parse(await (await request('/news/explore/generate', 'POST', {})).json());
    const topic = session.topics[0], path = topicSearchPath(session.id, topic.id);
    const searchBody = { expectedSessionRevision: session.revision, search: topic.proposedSearch };
    const first = exploreSearchResponseSchema.parse(await (await request(path, 'POST', searchBody)).json());
    failGeneration = true;
    await assertPublicError(await request('/news/explore/generate', 'POST', {}), 502);
    failSearch = true;
    const changedSearch = { ...topic.proposedSearch, query: 'Public archives preservation research collaboration projects' };
    await assertPublicError(await request(path, 'POST', { ...searchBody, search: changedSearch }), 502);
    let status = exploreStatusResponseSchema.parse(await (await request('/news/explore')).json());
    if (status.lifecycle.state !== 'available') assert.fail('Expected retained session');
    assert.equal(status.lifecycle.session.id, session.id); assert.equal(status.generation.state, 'failed');
    const retained = status.lifecycle.session.topics[0].preview;
    if (retained.state !== 'failed-retained' || first.preview.state !== 'successful') assert.fail('Expected retained coverage');
    assert.deepEqual(retained.previous, first.preview.result);
    assert.deepEqual(retained.attempt.search, changedSearch);
    failSearch = false; empty = true;
    const replacement = await request(path, 'POST', { ...searchBody, search: changedSearch });
    assert.equal(replacement.status, 200);
    const result = exploreSearchResponseSchema.parse(await replacement.json());
    assert.equal(result.preview.state, 'successful-empty');
    status = exploreStatusResponseSchema.parse(await (await request('/news/explore')).json());
    if (status.lifecycle.state !== 'available') assert.fail('Expected session');
    assert.deepEqual(status.lifecycle.session.topics[0].preview, result.preview);
    assert.doesNotMatch(JSON.stringify(status), /private-provider-secret|private-transport-secret/);
    const source = status.lifecycle.session.sources[0];
    const initial: NewsResponse = await (await request('/news')).json();
    const interest = initial.discovery.preferences.interests.find(i => i.id === source.id)!;
    assert.equal((await request('/news/interests/' + interest.id, 'PUT', { ...interest, name: 'Edited source', expectedRevision: interest.revision })).status, 200);
    await assertPublicError(await request(path, 'POST', searchBody), 409, /interests changed/);
  }, { explore: { available: async () => true, ideate: async sources => {
    if (failGeneration) throw new Error('private-provider-secret'); return ideas(sources);
  } }, news: { search: async interest => {
    if (failSearch) throw new Error('private-transport-secret'); return empty ? [] : retrieved(interest);
  } } });
});
