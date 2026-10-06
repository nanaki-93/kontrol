import test from 'node:test';
import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { createServer } from 'node:http';
import type { AddressInfo } from 'node:net';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { withAPI } from './helpers';
import { Store } from '../server/store';
import { createApp, type AppOptions } from '../server/app';
import { getWorkspace } from '../server/modules/workspace';
import { emptyWorkspace, type Workspace } from '../shared/workspace';
import { type NewsState, type Learning } from '../shared/schema';
import { type DiscoveryState } from '../shared/news';
import { emptyJobs } from '../shared/jobs';
import { cvText, profile, match } from './jobs-fixtures';

type Request = Parameters<Parameters<typeof withAPI>[0]>[0]['request'];
const at = '2026-10-03T01:00:00.000Z';
async function action(request: Request, path: string, body: Record<string, unknown>, method = 'POST') {
  const state: Workspace = await (await request('/workspace')).json();
  return request('/workspace' + path, method, { ...body, expectedRevision: state.revision });
}
const manual = { title: 'Go backend engineer', company: 'Fixture company', url: 'https://example.com/jobs/1', location: 'Tokyo', description: 'Go, SQL and Kubernetes. Design reliable APIs.' };
const note = { title: 'Interview preparation', body: 'Review cancellation', url: null, kind: 'note' };
function seedArticle(store: Store) {
  const state = store.get<NewsState>('news');
  const article = { id: 'fixture-story', title: 'Go concurrency update', url: 'https://example.com/story', source: 'Fixture publisher', summary: 'A retrieved excerpt.', publishedAt: at, fetchedAt: at, feedIDs: [], topicIDs: ['go'] };
  state.articles = [article]; store.set('news', state); return article;
}
test('saved reading and read state survive cache replacement, deduplicate links, and preserve notes', async () => {
  await withAPI(async ({ request, store }) => {
    const article = seedArticle(store);
    assert.equal((await action(request, '/articles', { url: article.url + '?utm_source=feed', saved: true }, 'PUT')).status, 200);
    assert.equal((await action(request, '/articles', { url: article.url, read: true, notes: 'My takeaway' }, 'PUT')).status, 200);
    const before = getWorkspace(store); assert.equal(before.articles.length, 1);
    store.set('news', { ...store.get<NewsState>('news'), articles: [] });
    store.set('newsDiscovery', { ...store.get<DiscoveryState>('newsDiscovery'), articles: [] });
    assert.equal((await action(request, '/articles', { url: article.url, read: false }, 'PUT')).status, 200);
    const after = getWorkspace(store).articles[0];
    assert.equal(after.notes, 'My takeaway'); assert.equal(after.savedAt, before.articles[0].savedAt); assert.equal(after.readAt, null);
    assert.deepEqual(after.article, before.articles[0].article);
    assert.equal((await action(request, '/articles', { url: 'https://example.com/not-retrieved', saved: true }, 'PUT')).status, 404);
    assert.equal((await action(request, '/articles', { url: article.url, notes: 'Overwrite', expectedNotes: '' }, 'PUT')).status, 409);
    assert.equal(getWorkspace(store).articles[0].notes, 'My takeaway');
  }, { clock: () => Date.parse(at) });
});
test('bookmarked AI summaries retain their provenance after the discovery cache is cleared', async () => {
  await withAPI(async ({ request, store }) => {
    const article = seedArticle(store), discovery = store.get<DiscoveryState>('newsDiscovery'), interest = discovery.preferences.interests[0];
    discovery.articles = [{ ...article, summary: 'AI interpretation of a retrieved snippet.', matches: [{ interestID: interest.id, interestRevision: interest.revision, score: 90, reason: 'Matches the chosen interest', mode: 'ai' }] }];
    store.set('newsDiscovery', discovery);
    assert.equal((await action(request, '/articles', { url: article.url, saved: true }, 'PUT')).status, 200);
    assert.equal(getWorkspace(store).articles[0].article.summaryKind, 'ai-snippet');
    store.set('newsDiscovery', { ...discovery, articles: [] });
    assert.match(getWorkspace(store).articles[0].article.summary, /AI interpretation/);
  });
});
test('article capacity evicts only disposable read markers and never reports an unsaved bookmark as saved', async () => {
  await withAPI(async ({ request, store }) => {
    const article = seedArticle(store), workspace = getWorkspace(store);
    workspace.articles = Array.from({ length: 1000 }, (_, i) => ({ id: randomUUID(), article: {
      title: 'Older story ' + i, url: 'https://example.com/old/' + i, summary: '', source: 'Fixture', publishedAt: at, fetchedAt: at, summaryKind: 'source' as const,
    }, savedAt: i === 0 ? at : null, readAt: at, notes: i === 1 ? 'Authored note' : '', updatedAt: at }));
    store.set('workspace', workspace);
    assert.equal((await action(request, '/articles', { url: article.url, saved: true }, 'PUT')).status, 200);
    const saved = getWorkspace(store);
    assert.equal(saved.articles.length, 1000);
    assert.ok(saved.articles.find(a => a.id === workspace.articles[0].id));
    assert.equal(saved.articles.find(a => a.id === workspace.articles[1].id)?.notes, 'Authored note');
    assert.ok(saved.articles.find(a => a.article.url === article.url)?.savedAt);
    saved.articles.forEach(a => { a.savedAt = at; }); store.set('workspace', saved);
    store.set('news', { ...store.get<NewsState>('news'), articles: [{ ...article, id: 'another-story', url: 'https://example.com/another' }] });
    assert.equal((await action(request, '/articles', { url: 'https://example.com/another', read: true }, 'PUT')).status, 400);
    assert.deepEqual(getWorkspace(store), saved);
  });
});
test('confirming a CV profile shares target roles without changing interests or saved opportunities', async () => {
  await withAPI(async ({ request, store }) => {
    await action(request, '/jobs', { manual });
    const workspace = getWorkspace(store);
    await action(request, '/profile', { profile: { ...workspace.profile, goal: 'Prepare for interviews', interests: ['Go'] } }, 'PUT');
    const jobs = emptyJobs(randomUUID());
    store.set('jobs', { ...jobs, cv: { name: 'cv.txt', bytes: cvText.length, text: cvText, uploadedAt: at }, profile });
    assert.equal((await request('/jobs/profile', 'PUT', { expectedRevision: jobs.revision, profile })).status, 200);
    const updated = getWorkspace(store);
    assert.deepEqual(updated.profile.targetRoles, profile.roles); assert.deepEqual(updated.profile.interests, ['Go']);
    assert.deepEqual(updated.jobs, workspace.jobs); assert.equal(updated.profile.goal, 'Prepare for interviews');
  });
});
test('manual opportunities need no CV and application snapshots survive search and CV changes', async () => {
  await withAPI(async ({ request, store }) => {
    assert.equal((await action(request, '/jobs', { manual })).status, 200);
    assert.equal((await action(request, '/jobs', { manual: { ...manual, url: manual.url + '?utm_source=other' } })).status, 200);
    let saved = getWorkspace(store).jobs[0]; assert.equal(getWorkspace(store).jobs.length, 1); assert.equal(saved.fit, null);
    assert.equal((await action(request, '/jobs/' + saved.id, { stage: 'applied', followUpOn: '2026-10-05', notes: 'Prepare answers', skills: [{ label: 'Go', decision: 'practice' }], expectedRecordRevision: saved.revision }, 'PATCH')).status, 200);
    saved = getWorkspace(store).jobs[0]; assert.deepEqual(saved.history.map(h => h.stage), ['saved', 'applied']);
    assert.equal((await action(request, '/jobs/' + saved.id, { stage: 'applied', expectedRecordRevision: saved.revision }, 'PATCH')).status, 200);
    assert.equal(getWorkspace(store).jobs[0].history.length, 2);
    const jobs = emptyJobs(randomUUID()); store.set('jobs', { ...jobs, cv: { name: 'cv.txt', bytes: cvText.length, text: cvText, uploadedAt: at }, profile, profileConfirmed: true, matches: [match] });
    assert.equal((await action(request, '/jobs', { matchID: match.id })).status, 200);
    const snapshots = getWorkspace(store).jobs;
    assert.equal((await request('/jobs/cv', 'DELETE', { expectedRevision: jobs.revision })).status, 200);
    assert.deepEqual(getWorkspace(store).jobs, snapshots);
    const newest = getWorkspace(store).jobs[0];
    assert.equal((await action(request, '/jobs/' + newest.id, { followUpOn: '2026-02-30', expectedRecordRevision: newest.revision }, 'PATCH')).status, 400);
    assert.deepEqual(getWorkspace(store).jobs, snapshots);
  }, { clock: () => Date.parse(at) });
});
test('stale workspace and per-record revisions reject conflicting notes even within one millisecond', async () => {
  await withAPI(async ({ request, store }) => {
    const initial = getWorkspace(store);
    assert.equal((await action(request, '/notes', note)).status, 200);
    assert.equal((await request('/workspace/notes', 'POST', { ...note, expectedRevision: initial.revision })).status, 409);
    const saved = getWorkspace(store).notes[0];
    assert.equal((await action(request, '/notes/' + saved.id, { ...note, body: 'Other tab edit', expectedRecordRevision: saved.revision }, 'PUT')).status, 200);
    assert.equal((await action(request, '/notes/' + saved.id, { ...note, body: 'Stale overwrite', expectedRecordRevision: saved.revision }, 'PUT')).status, 409);
    assert.equal((await action(request, '/notes/' + saved.id, { expectedRecordRevision: saved.revision }, 'DELETE')).status, 409);
    assert.equal(getWorkspace(store).notes[0].body, 'Other tab edit');
    assert.equal((await action(request, '/notes', { ...note, kind: 'link', url: 'javascript:alert(1)' })).status, 400);
  }, { clock: () => Date.parse(at) });
});
test('shared goals validate time zones and prevent a stale profile draft from overwriting newer goals', async () => {
  await withAPI(async ({ request, store }) => {
    const baseline = getWorkspace(store).profile;
    assert.equal((await action(request, '/profile', { profile: { ...baseline, weeklyTarget: 4, goal: 'Backend interviews', timeZones: [{ label: 'Tokyo', zone: 'Asia/Tokyo' }] }, expectedProfile: baseline }, 'PUT')).status, 200);
    const saved = getWorkspace(store);
    assert.equal((await action(request, '/profile', { profile: { ...baseline, goal: 'Stale draft' }, expectedProfile: baseline }, 'PUT')).status, 409);
    assert.equal((await action(request, '/profile', { profile: { ...saved.profile, timeZones: [{ label: 'Bad', zone: 'Invalid/Place' }] } }, 'PUT')).status, 400);
    assert.deepEqual(getWorkspace(store), saved);
  });
});
test('recall reviews require completed lessons, save separate answers and schedule the next review', async () => {
  let now = Date.parse(at);
  await withAPI(async ({ request, store }) => {
    const lessonID = store.get<Learning>('learning').definitions[0].id;
    assert.equal((await action(request, '/reviews/' + lessonID, { response: 'A recall answer', rating: 'okay' })).status, 409);
    const base = '/learning/' + lessonID;
    await request(base + '/open', 'POST'); await request(base + '/answer', 'PATCH', { answer: 'Original answer', revision: 0 });
    await request(base + '/reveal', 'POST'); await request(base + '/complete', 'POST', { acknowledged: true });
    const original = store.get<Learning>('learning');
    assert.equal((await action(request, '/lessons/' + lessonID, { saved: true }, 'PUT')).status, 200);
    assert.equal((await action(request, '/reviews/' + lessonID, { response: '', rating: 'okay' })).status, 400);
    assert.equal((await action(request, '/reviews/' + lessonID, { response: 'A recall answer', rating: 'okay' })).status, 200);
    assert.equal(getWorkspace(store).reviews[0].nextAt, new Date(now + 3 * 86_400_000).toISOString());
    assert.equal((await action(request, '/reviews/' + lessonID, { response: 'Double click', rating: 'confident' })).status, 409);
    now += 86_400_000;
    assert.equal((await action(request, '/reviews/' + lessonID, { response: 'Try again', rating: 'again' })).status, 200);
    assert.equal(getWorkspace(store).reviews[0].history.length, 2);
    assert.deepEqual(store.get('learning'), original);
  }, { clock: () => now });
});
test('version-5 backups round-trip saved work and reject malformed or destructive imports atomically', async () => {
  let backup: Record<string, unknown> = {}, workspace: Workspace = emptyWorkspace(randomUUID());
  await withAPI(async ({ request, store }) => {
    const article = seedArticle(store);
    await action(request, '/articles', { url: article.url, saved: true, notes: 'A note' }, 'PUT');
    await action(request, '/jobs', { manual }); await action(request, '/notes', note);
    workspace = getWorkspace(store);
    backup = await (await request('/settings/export')).json(); assert.equal(backup.schemaVersion, 5);
    assert.equal((await request('/settings/import', 'POST', backup)).status, 409);
  });
  await withAPI(async ({ request, store }) => {
    const malformed = { ...backup, workspace: { ...workspace, jobs: [{ ...workspace.jobs[0], followUpOn: '2026-02-30' }] } };
    const before = getWorkspace(store);
    assert.equal((await request('/settings/import', 'POST', malformed)).status, 400);
    assert.deepEqual(getWorkspace(store), before); assert.equal(store.has('imported'), false);
    assert.equal((await request('/settings/import', 'POST', backup)).status, 200);
    const restored = getWorkspace(store); assert.notEqual(restored.revision, workspace.revision);
    assert.deepEqual({ ...restored, revision: workspace.revision }, workspace);
    assert.equal((await request('/settings/import', 'POST', backup)).status, 409);
  });
  await withAPI(async ({ request }) => {
    await action(request, '/notes', note);
    const legacy: Record<string, unknown> = { ...backup, schemaVersion: 4 }; delete legacy.workspace;
    assert.equal((await request('/settings/import', 'POST', legacy)).status, 409);
  });
});
test('preview reading survives SQLite reopen with no temporary cache or automatic network work', async () => {
  const directory = await mkdtemp(join(tmpdir(), 'kontrol-explore-reading-'));
  const path = join(directory, 'fixture.sqlite');
  let saved: Workspace['articles'] = [], ideations = 0, searches = 0;
  // Each listener, app owner and database belongs to this fixture only. Close
  // them even on assertion failures before reopening/removing its directory.
  async function diskAPI(options: Omit<AppOptions, 'origin'>, run: (fixture: {
    app: ReturnType<typeof createApp>; store: Store; request: Request;
  }) => Promise<void>) {
    const store = new Store(path), server = createServer();
    let app: ReturnType<typeof createApp> | undefined;
    try {
      await new Promise<void>(resolve => server.listen(0, '127.0.0.1', resolve));
      const origin = 'http://127.0.0.1:' + (server.address() as AddressInfo).port;
      app = createApp(store, { origin, ...options }); server.on('request', app);
      await run({ app, store, request: (route, method = 'GET', body, headers = {}) => fetch(origin + '/api' + route, {
        method, headers: { 'X-Kontrol-Client': 'web', 'Content-Type': 'application/json', ...headers },
        ...(body !== undefined ? { body: JSON.stringify(body) } : {}),
      }) });
    } finally {
      app?.dispose(); server.closeAllConnections();
      try { if (server.listening) await new Promise<void>((resolve, reject) => server.close(error => error ? reject(error) : resolve())); }
      finally { store.close(); }
    }
  }
  try {
    await diskAPI({ clock: () => Date.parse(at), explore: { available: async () => true, ideate: async sources => {
      ideations++; return JSON.stringify({ topics: [{ sourceInterestID: sources[0].id, title: 'Public infrastructure research',
        description: 'An adjacent topic idea.', connection: 'Related to infrastructure.', query: 'Public infrastructure research community collaborative projects' }] });
    } }, news: { search: async interest => {
      searches++; return ['bookmark', 'notes', 'read', 'unsaved'].map(kind => ({
        id: kind, title: 'Retrieved ' + kind, url: 'https://example.com/articles/' + kind, source: 'Fixture', summary: 'Retrieved source excerpt.',
        publishedAt: null, fetchedAt: at, contentKind: 'article' as const, feedIDs: [], topicIDs: [],
        matches: [{ interestID: interest.id, interestRevision: interest.revision, mode: 'search' as const, score: 80, reason: 'Fixture' }],
      }));
    } } }, async ({ app, store, request }) => {
      const { session } = await app.explore.generate(), topic = session.topics[0];
      await app.explore.search(session.id, topic.id, { expectedSessionRevision: session.revision, search: topic.proposedSearch });
      for (const [kind, command] of [['bookmark', { saved: true }], ['notes', { notes: 'Persistent authored reading' }], ['read', { read: true }]] as const) {
        assert.equal((await action(request, '/articles', { url: 'https://example.com/articles/' + kind, ...command }, 'PUT')).status, 200);
      }
      saved = getWorkspace(store).articles;
      assert.equal(saved.length, 3); assert.equal(saved[2].savedAt, null, 'Read-only markers remain disposable, not bookmarks');
      assert.deepEqual([ideations, searches], [1, 1]);
    });
    await diskAPI({ explore: { available: async () => { throw new Error('Unexpected automatic availability'); },
      ideate: async () => { ideations++; throw new Error('Unexpected automatic PI'); } },
      news: { search: async () => { searches++; throw new Error('Unexpected automatic search'); } } }, async ({ app, store, request }) => {
      assert.equal(app.explore.snapshot().lifecycle.state, 'absent');
      assert.deepEqual(getWorkspace(store).articles, saved);
      assert.deepEqual((await (await request('/workspace')).json()).articles, saved);
      const before = getWorkspace(store);
      const missing = await action(request, '/articles', { url: 'https://example.com/articles/unsaved', saved: true }, 'PUT');
      assert.equal(missing.status, 404); assert.match((await missing.json()).error, /search|refresh/);
      assert.deepEqual(getWorkspace(store), before);
      assert.equal((await action(request, '/articles', { url: 'https://example.com/articles/notes', read: true }, 'PUT')).status, 200);
      assert.equal(getWorkspace(store).articles[1].notes, 'Persistent authored reading');
      assert.deepEqual([ideations, searches], [1, 1]);
    });
  } finally { await rm(directory, { recursive: true, force: true }); }
});

test('saved workspace survives reopening an isolated SQLite database and rejects unsupported document versions', async () => {
  const directory = await mkdtemp(join(tmpdir(), 'kontrol-workspace-'));
  try {
    const path = join(directory, 'fixture.sqlite'), state = emptyWorkspace(randomUUID());
    state.notes.push({ ...note, kind: 'note', id: randomUUID(), revision: randomUUID(), createdAt: at, updatedAt: at });
    const store = new Store(path); store.set('workspace', state); store.close();
    const reopened = new Store(path);
    try {
      createApp(reopened, { origin: 'http://127.0.0.1:4310' });
      assert.deepEqual(getWorkspace(reopened), state);
      reopened.set('workspace', { ...state, schemaVersion: 99 });
      assert.throws(() => getWorkspace(reopened)); assert.equal(reopened.get<Workspace>('workspace').schemaVersion, 99);
    } finally { reopened.close(); }
  } finally { await rm(directory, { recursive: true, force: true }); }
});
