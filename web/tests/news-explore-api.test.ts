import test from 'node:test';
import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { withAPI } from './helpers';
import { getDiscovery } from '../server/news/discovery';
import { exportData } from '../server/modules/settings';
import { ExploreServiceError, type ExploreService } from '../server/news/explore';
import type { AppOptions } from '../server/app';
import type { NewsInterest, DiscoveredArticle } from '../shared/news';
import type { Store } from '../server/store';

// Step 6 exercises composition and existing mutation/import routes directly.
// The Explore HTTP contracts are added separately; no fake endpoint is needed.
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
