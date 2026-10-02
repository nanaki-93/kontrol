import test from 'node:test';
import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { request as httpRequest } from 'node:http';
import { withAPI } from './helpers';
import { exportData, importData } from '../server/modules/settings';
import { nativeExportSchema, type Learning, type Task, type NewsState } from '../shared/schema';

test('API rejects other origins, DNS rebinding hosts and missing client headers', async () => {
  await withAPI(async ({ request, origin }) => {
    assert.equal((await request('/tasks', 'POST', {}, { Origin: 'https://elsewhere.example' })).status, 403);
    const reboundStatus = await new Promise<number | undefined>((resolve, reject) => {
      const req = httpRequest(origin + '/api/tasks', { headers: { Host: 'hostile.example', 'X-Kontrol-Client': 'web' } }, res => { res.resume(); resolve(res.statusCode); });
      req.on('error', reject); req.end();
    });
    assert.equal(reboundStatus, 403);
    assert.equal((await fetch(origin + '/api/tasks')).status, 403);
    assert.equal((await request('/tasks', 'POST', {}, { 'Content-Type': 'text/plain' })).status, 415);
    assert.equal((await request('/missing')).status, 404);
  });
});
test('tasks support create, edit, complete, reopen and delete; invalid changes preserve saved data', async () => {
  await withAPI(async ({ request, store }) => {
    const result = await request('/tasks', 'POST', { title: 'Write plan', notes: ' keep whitespace\n', plannedDay: null, dueAt: null });
    assert.equal(result.status, 201);
    const task = await result.json() as Task;
    assert.equal((await request('/tasks/' + task.id, 'PATCH', { title: ' ' })).status, 400);
    assert.equal(store.get<Task[]>('tasks')[0].title, 'Write plan');
    assert.equal((await request('/tasks/' + task.id, 'PATCH', { title: 'Review plan', completedAt: new Date().toISOString() })).status, 200);
    assert.ok(store.get<Task[]>('tasks')[0].completedAt);
    assert.equal((await request('/tasks/' + task.id, 'PATCH', { completedAt: null })).status, 200);
    assert.equal(store.get<Task[]>('tasks')[0].completedAt, null);
    assert.equal(store.get<Task[]>('tasks')[0].notes, ' keep whitespace\n');
    assert.equal((await request('/tasks/' + task.id, 'DELETE')).status, 204);
    assert.equal(store.get<Task[]>('tasks').length, 0);
  });
});
test('schedule validates bounds and requires explicit overlapping-block approval', async () => {
  await withAPI(async ({ request }) => {
    const block = { title: 'Deep work', startAt: '2026-10-02T08:00:00.000Z', endAt: '2026-10-02T09:00:00.000Z', note: null, lessonID: null, linkedTitleSnapshot: null };
    assert.equal((await request('/schedule', 'POST', block)).status, 201);
    assert.equal((await request('/schedule', 'POST', block)).status, 409);
    assert.equal((await request('/schedule', 'POST', { ...block, allowOverlap: true })).status, 201);
    assert.equal((await request('/schedule', 'POST', { ...block, endAt: block.startAt })).status, 400);
    assert.equal((await request('/schedule', 'POST', { ...block, startAt: block.endAt, endAt: '2026-10-02T10:00:00.000Z' })).status, 201);
  });
});
test('Focus maintains one active session and never completes a linked task', async () => {
  let clock = Date.parse('2026-10-02T08:00:00.000Z');
  await withAPI(async ({ request, store }) => {
    const task = await (await request('/tasks', 'POST', { title: 'Stay open', notes: null, dueAt: null, plannedDay: null })).json();
    const first = await request('/focus', 'POST', { minutes: 1, taskID: task.id });
    assert.equal(first.status, 201);
    const session = await first.json();
    assert.equal((await request('/focus', 'POST', { minutes: 1, taskID: null })).status, 409);
    clock += 90_000;
    const current = await (await request('/focus')).json();
    assert.equal(current.sessions[0].state, 'completed');
    assert.equal(current.sessions[0].accumulatedActiveSeconds, 60);
    assert.equal((await request('/focus/' + session.id + '/end', 'POST')).status, 200);
    assert.equal(store.get<Task[]>('tasks')[0].completedAt, null);
    assert.equal((await (await request('/focus')).json()).sessions.length, 1);
  }, { clock: () => clock });
});
test('learning saves exact answers, rejects stale writes, requires self-check, completes once and rotates one slot', async () => {
  await withAPI(async ({ request, store }) => {
    const before = store.get<Learning>('learning'), slot = before.slots[0], path = '/learning/' + slot.lessonID;
    const attempt = await (await request(path + '/open', 'POST')).json();
    const answer = '  Personal draft\n<no html execution>\né\u0301\n';
    assert.equal((await request(path + '/answer', 'PATCH', { answer, revision: attempt.revision })).status, 200);
    assert.equal((await request(path + '/answer', 'PATCH', { answer: 'other tab', revision: attempt.revision })).status, 409);
    assert.equal((await request(path + '/complete', 'POST', { acknowledged: true })).status, 409);
    assert.equal((await request(path + '/reveal', 'POST')).status, 200);
    assert.equal((await request(path + '/complete', 'POST', { acknowledged: false })).status, 400);
    assert.equal((await request(path + '/complete', 'POST', { acknowledged: true })).status, 200);
    assert.equal((await request(path + '/complete', 'POST', { acknowledged: true })).status, 200);
    const after = store.get<Learning>('learning');
    assert.equal(after.attempts.length, 1);
    assert.equal(after.attempts[0].answerDraft, answer);
    assert.ok(after.attempts[0].completedContentSnapshot);
    assert.deepEqual(after.slots.filter(s => s.key !== slot.key), before.slots.filter(s => s.key !== slot.key));
    assert.equal(after.slots.some(s => s.lessonID === slot.lessonID), false);
  });
});
test('dismissal is separate from completion and can be explicitly restored', async () => {
  await withAPI(async ({ request, store }) => {
    const state = store.get<Learning>('learning'), lesson = state.slots[0].lessonID;
    assert.equal((await request('/learning/' + lesson + '/dismiss', 'POST')).status, 200);
    assert.equal(store.get<Learning>('learning').progress[0].completedAt, null);
    assert.equal((await request('/learning/' + lesson + '/restore', 'POST')).status, 200);
    assert.equal(store.get<Learning>('learning').progress[0].dismissedAt, null);
  });
});
test('native import validates before writing, preserves historical data and cannot overwrite work', async () => {
  await withAPI(async ({ store, request }) => {
    const data = exportData(store);
    data.tasks.push({ id: randomUUID(), title: ' Migrated task ', notes: 'literal secret-looking text \n',
      plannedDay: null, dueAt: null, completedAt: null, createdAt: '2026-10-02T00:00:00.000Z' });
    const invalid = structuredClone(data);
    invalid.tasks.push({ ...invalid.tasks[0] });
    assert.equal((await request('/settings/import', 'POST', invalid)).status, 400);
    assert.equal(store.get<Task[]>('tasks').length, 0);
    assert.equal((await request('/settings/import/preview', 'POST', data)).status, 200);
    assert.equal((await request('/settings/import', 'POST', data)).status, 200);
    const backup = await (await request('/settings/export')).json();
    assert.deepEqual(backup.data.tasks, data.tasks);
    assert.equal(nativeExportSchema.safeParse(backup.data).success, true);
    assert.equal((await request('/settings/import', 'POST', data)).status, 409);
    const serialized = JSON.stringify(backup);
    assert.equal(serialized.includes('bookmarkData'), false);
    assert.equal(serialized.includes('credentialReference'), false);
    assert.equal('projects' in backup, false);
  });
});
test('multi-module import rolls back on storage failure', async () => {
  await withAPI(async ({ store }) => {
    const data = exportData(store);
    data.tasks.push({ id: randomUUID(), title: 'Rollback', notes: null, plannedDay: null, dueAt: null, completedAt: null, createdAt: new Date().toISOString() });
    const before = store.get('tasks'), original = store.set.bind(store);
    store.set = (key, value) => { if (key === 'focus') throw new Error('Injected disk failure'); original(key, value); };
    assert.throws(() => importData(store, data), /Injected disk failure/);
    assert.deepEqual(store.get('tasks'), before);
    assert.equal(store.has('imported'), false);
    store.set = original;
  });
});
test('native learning import preserves the studied version and exact historical answer independently of current catalog text', async () => {
  await withAPI(async ({ store, request }) => {
    const data = exportData(store);
    data.appVersion = '1.0';
    const studied = structuredClone(data.learning.definitions[0]);
    const at = '2026-10-01T10:00:00.000Z';
    data.learning.definitions[0].title = 'Current catalog title';
    data.learning.definitions[0].contentVersion++;
    data.learning.progress.push({ lessonID: studied.id, status: 'completed',
      firstShownAt: at, startedAt: at, completedAt: at, dismissedAt: null, lastOpenedAt: at });
    data.learning.attempts.push({
      id: randomUUID(), lessonID: studied.id, contentVersion: studied.contentVersion,
      answerDraft: '  Answer with exact whitespace\nand 日本語.\n', revision: 7, solutionRevealedAt: at,
      selfCheckAcknowledgedAt: at, completedAt: at,
      pinnedContent: { envelopeVersion: 1, definition: studied }, completedContentSnapshot: null,
    });
    data.learning.slots = data.learning.slots.filter(s => s.lessonID !== studied.id);
    const mismatch = structuredClone(data);
    mismatch.learning.attempts[0].pinnedContent!.definition.id = 'wrong-identity';
    assert.equal((await request('/settings/import', 'POST', mismatch)).status, 400);
    assert.equal(store.get<Learning>('learning').attempts.length, 0);
    assert.equal((await request('/settings/import', 'POST', data)).status, 200);
    const saved = store.get<Learning>('learning');
    assert.deepEqual(saved.attempts, data.learning.attempts);
    assert.deepEqual(saved.progress, data.learning.progress);
    assert.equal(saved.attempts[0].pinnedContent!.definition.title, studied.title);
    assert.equal(saved.definitions[0].title, 'Current catalog title');
    assert.deepEqual(exportData(store).learning.attempts, data.learning.attempts);
  });
});
test('legacy missing lesson pins cannot manufacture a completion or lose the saved response', async () => {
  await withAPI(async ({ request, store }) => {
    const data = exportData(store), lesson = data.learning.slots[0].lessonID, at = new Date().toISOString();
    data.learning.progress.push({ lessonID: lesson, status: 'started',
      firstShownAt: at, startedAt: at, completedAt: null, dismissedAt: null, lastOpenedAt: at });
    data.learning.attempts.push({ id: randomUUID(), lessonID: lesson, contentVersion: 1,
      answerDraft: 'Retain this legacy answer', revision: 0, solutionRevealedAt: at,
      selfCheckAcknowledgedAt: null, completedAt: null, pinnedContent: null, completedContentSnapshot: null });
    assert.equal((await request('/settings/import', 'POST', data)).status, 200);
    assert.equal((await request('/learning/' + lesson + '/complete', 'POST', { acknowledged: true })).status, 409);
    assert.equal(store.get<Learning>('learning').attempts[0].answerDraft, 'Retain this legacy answer');
    assert.equal(store.get<Learning>('learning').progress[0].status, 'started');
  });
});
test('web backup restores layout and personal records into a fresh isolated database', async () => {
  let backup: unknown;
  await withAPI(async ({ request }) => {
    await request('/tasks', 'POST', { title: 'Keep me', notes: null, dueAt: null, plannedDay: null });
    const settings = await (await request('/settings')).json();
    settings.layout.reverse(); settings.layout[0].visible = false;
    assert.equal((await request('/settings/layout', 'PUT', settings.layout)).status, 200);
    backup = await (await request('/settings/export')).json();
  });
  await withAPI(async ({ request }) => {
    assert.equal((await request('/settings/import', 'POST', backup)).status, 200);
    assert.equal((await (await request('/tasks')).json())[0].title, 'Keep me');
    assert.equal((await (await request('/settings')).json()).layout[0].visible, false);
  });
});
test('feed refresh keeps cached content on individual failures and does not duplicate articles', async () => {
  await withAPI(async ({ request, store }) => {
    const state = store.get<NewsState>('news');
    state.preferences.feeds = state.preferences.feeds.slice(0, 2);
    store.set('news', state);
    const first = await (await request('/news/refresh', 'POST')).json();
    assert.equal(first.articles.length, 1);
    assert.equal(Object.keys(first.errors).length, 1);
    const second = await (await request('/news/refresh', 'POST')).json();
    assert.equal(second.articles.length, 1);
    assert.equal(second.articles[0].publishedAt, null);
  }, { feedFetcher: async url => {
    if (url.includes('inside.java')) throw new Error('Fixture failure');
    return '<rss><channel><item><title>Fixture news</title><link>https://go.dev/example</link></item></channel></rss>';
  } });
});
