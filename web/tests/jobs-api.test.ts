import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { randomUUID } from 'node:crypto';
import { withAPI } from './helpers';
import { Store } from '../server/store';
import { jobsModule, getJobs } from '../server/modules/jobs';
import { jobAI } from '../server/jobs/ai';
import { NewsFetchError } from '../server/news/transport';
import { settingsModule } from '../server/modules/settings';
import { defaultLayout, type Layout } from '../shared/schema';
import { emptyJobs, type JobsResponse, type JobsState } from '../shared/jobs';
import { berlin, profile, cvText, cvUpload, job, match, jobNow, readyPI } from './jobs-fixtures';

type Request = Parameters<Parameters<typeof withAPI>[0]>[0]['request'];
async function state(request: Request): Promise<JobsResponse> { return (await request('/jobs')).json(); }
async function action(request: Request, path: string, method = 'POST', body: object = {}) {
  return request('/jobs' + path, method, { ...body, expectedRevision: (await state(request)).revision });
}
async function prepare(request: Request) {
  assert.equal((await action(request, '/cv', 'POST', cvUpload)).status, 200);
  assert.equal((await action(request, '/analyze')).status, 200);
  assert.equal((await action(request, '/profile', 'PUT', { profile })).status, 200);
}
const options = { clock: () => jobNow, aiStatus: readyPI, analyze: async () => profile,
  sources: async () => ({ sources: [job], warnings: [] }), rank: async () => [match] };
function deferred() {
  let resolve!: () => void;
  const promise = new Promise<void>(done => { resolve = done; });
  return { promise, resolve };
}

test('JOB lifecycle requires upload, analysis and profile review before searching; filter edits invalidate matches', async () => {
  let analyzedText = '', rankCalls = 0;
  await withAPI(async ({ request }) => {
    assert.equal((await state(request)).cv, null);
    assert.equal((await action(request, '/search')).status, 409);
    assert.equal((await action(request, '/analyze')).status, 409);
    assert.equal((await action(request, '/cv', 'POST', cvUpload)).status, 200);
    assert.equal((await action(request, '/search')).status, 409);
    assert.equal((await action(request, '/analyze')).status, 200);
    assert.equal(analyzedText, cvText);
    assert.equal((await state(request)).profileConfirmed, false);
    assert.equal((await action(request, '/search')).status, 409);
    assert.equal((await action(request, '/profile', 'PUT', { profile: { ...profile, skills: [] } })).status, 400);
    assert.equal((await action(request, '/profile', 'PUT', { profile })).status, 200);
    assert.equal((await action(request, '/search')).status, 200);
    let saved = await state(request);
    assert.equal(saved.matches.length, 1); assert.equal(saved.lastSearch?.sourceCount, 1); assert.equal(rankCalls, 1);
    assert.equal(saved.lastSearch?.completedAt, new Date(jobNow).toISOString());
    assert.equal((await action(request, '/preferences', 'PUT', { preferences: { ...saved.preferences, cities: [berlin], employmentTypes: ['part_time'] } })).status, 200);
    saved = await state(request); assert.equal(saved.matches.length, 0); assert.equal(saved.lastSearch, null);
    assert.equal(saved.profileConfirmed, true); assert.equal(saved.preferences.employmentTypes[0], 'part_time');
    assert.equal((await action(request, '/preferences', 'PUT', { preferences: { ...saved.preferences, workModes: [] } })).status, 400);
    assert.equal((await state(request)).preferences.employmentTypes[0], 'part_time');
  }, { jobs: { ...options, analyze: async text => { analyzedText = text; return profile; }, rank: async reviewed => {
    rankCalls++; assert.deepEqual(reviewed, profile); assert.doesNotMatch(JSON.stringify(reviewed), /Fixture Candidate/); return [match];
  } } });
});
test('failed upload, analysis and search retain previous CV, profile and results; replacement clears dependent data', async () => {
  let failAnalysis = false, failSearch = false;
  await withAPI(async ({ request }) => {
    await prepare(request); await action(request, '/search');
    const saved = await state(request);
    assert.equal((await action(request, '/cv', 'POST', { name: 'bad.pdf', base64: cvUpload.base64 })).status, 400);
    assert.equal((await state(request)).revision, saved.revision);
    failAnalysis = true;
    assert.equal((await action(request, '/analyze')).status, 502);
    assert.deepEqual((await state(request)).matches, saved.matches); assert.deepEqual((await state(request)).profile, profile);
    failSearch = true;
    assert.equal((await action(request, '/search')).status, 502);
    const failed = await state(request);
    assert.deepEqual(failed.matches, saved.matches); assert.ok(failed.lastSearch?.error);
    assert.doesNotMatch(JSON.stringify(failed), /fixture-private-key/); assert.equal(failed.activity, null);
    assert.equal((await action(request, '/cv', 'POST', { ...cvUpload, name: 'updated.txt' })).status, 200);
    const replaced = await state(request);
    assert.equal(replaced.profile, null); assert.equal(replaced.profileConfirmed, false); assert.equal(replaced.matches.length, 0);
    assert.equal(replaced.cv?.name, 'updated.txt');
  }, { jobs: { ...options, analyze: async () => { if (failAnalysis) throw new Error('fixture-private-key'); return profile; },
    sources: async () => { if (failSearch) throw new Error('fixture-private-key'); return { sources: [job], warnings: [] }; } } });
});
test('a long AI skill list completes analysis and the saved profile still requires review', async () => {
  const skills = Array.from({ length: 40 }, (_, i) => 'Skill ' + i);
  const ai = jobAI({ run: async () => JSON.stringify({ ...profile, skills }) });
  await withAPI(async ({ request }) => {
    await action(request, '/cv', 'POST', cvUpload);
    const response = await action(request, '/analyze');
    assert.equal(response.status, 200);
    const analyzed = await response.json();
    assert.deepEqual(analyzed.profile.skills, skills.slice(0, 30)); assert.equal(analyzed.profileConfirmed, false);
    assert.deepEqual((await state(request)).profile, analyzed.profile); assert.equal((await state(request)).activity, null);
    assert.equal((await action(request, '/search')).status, 409);
    assert.equal((await action(request, '/profile', 'PUT', { profile: { ...profile, skills } })).status, 400);
  }, { jobs: { ...options, analyze: ai.analyze } });
});
test('PI timeout explains the failure, releases the analysis gate and allows a successful retry', async () => {
  let fail = true;
  await withAPI(async ({ request }) => {
    await action(request, '/cv', 'POST', cvUpload);
    const before = await state(request), response = await action(request, '/analyze');
    assert.equal(response.status, 502); assert.match((await response.json()).error, /took too long/);
    const after = await state(request);
    assert.equal(after.activity, null); assert.equal(after.revision, before.revision); assert.deepEqual(after.cv, before.cv);
    fail = false;
    assert.equal((await action(request, '/analyze')).status, 200); assert.deepEqual((await state(request)).profile, profile);
  }, { jobs: { ...options, analyze: async () => {
    if (fail) throw new NewsFetchError('pi-timeout', 'PI took too long to respond. Your saved data is kept. Try again.');
    return profile;
  } } });
});
test('empty discovery is a successful empty result without PI ranking; warnings remain visible', async () => {
  let calls = 0;
  await withAPI(async ({ request }) => {
    await prepare(request);
    assert.equal((await action(request, '/search')).status, 200);
    const saved = await state(request);
    assert.equal(calls, 0); assert.equal(saved.lastSearch?.error, null); assert.equal(saved.matches.length, 0);
    assert.deepEqual(saved.lastSearch?.warnings, ['Fixture source unavailable.']);
  }, { jobs: { ...options, sources: async () => ({ sources: [], warnings: ['Fixture source unavailable.'] }), rank: async () => { calls++; return []; } } });
});
test('stale revisions cannot overwrite current CVs, filters or profiles', async () => {
  await withAPI(async ({ request }) => {
    const original = await state(request);
    await prepare(request);
    for (const [path, method, body] of [
      ['/cv', 'DELETE', {}], ['/cv', 'POST', cvUpload], ['/preferences', 'PUT', { preferences: original.preferences }],
      ['/profile', 'PUT', { profile }], ['/analyze', 'POST', {}], ['/search', 'POST', {}],
    ] as const) assert.equal((await request('/jobs' + path, method, { ...body, expectedRevision: original.revision })).status, 409);
    assert.equal((await state(request)).profileConfirmed, true);
  }, { jobs: options });
});
test('concurrent analysis is rejected and deleting the CV cancels it without resurrecting personal data', async () => {
  const started = deferred(), release = deferred();
  await withAPI(async ({ request }) => {
    await action(request, '/cv', 'POST', cvUpload);
    const saved = await state(request);
    const pending = request('/jobs/analyze', 'POST', { expectedRevision: saved.revision });
    await started.promise;
    try {
      assert.equal((await state(request)).activity, 'analyzing');
      assert.equal((await request('/jobs/analyze', 'POST', { expectedRevision: saved.revision })).status, 409);
      assert.equal((await request('/jobs/preferences', 'PUT', { expectedRevision: saved.revision, preferences: saved.preferences })).status, 409);
      assert.equal((await request('/jobs/cv', 'DELETE', { expectedRevision: saved.revision })).status, 200);
    } finally { release.resolve(); }
    assert.notEqual((await pending).status, 200);
    const removed = await state(request);
    assert.equal(removed.cv, null); assert.equal(removed.profile, null); assert.equal(removed.matches.length, 0); assert.equal(removed.activity, null);
  }, { jobs: { ...options, analyze: async () => { started.resolve(); await release.promise; return profile; } } });
});
test('city lookup is validated independently of CV upload and returns selected city metadata', async () => {
  await withAPI(async ({ request }) => {
    assert.equal((await request('/jobs/cities?q=B')).status, 400);
    const response = await request('/jobs/cities?q=Berlin');
    assert.equal(response.status, 200); assert.deepEqual(await response.json(), [berlin]);
  }, { jobs: { ...options, cities: async query => { assert.equal(query, 'Berlin'); return [berlin]; } } });
});
test('version-3 backups round-trip JOB data and protect existing CVs from import', async () => {
  let backup: Record<string, unknown> = {}, saved: JobsState | null = null;
  await withAPI(async ({ request, store }) => {
    await prepare(request); await action(request, '/search'); saved = getJobs(store);
    backup = await (await request('/settings/export')).json();
    assert.equal(backup.schemaVersion, 3); assert.deepEqual(backup.jobs, saved);
    assert.equal((await request('/settings/import', 'POST', backup)).status, 409);
    assert.deepEqual(getJobs(store), saved);
  }, { jobs: options });
  await withAPI(async ({ request, store }) => {
    const preview = await (await request('/settings/import/preview', 'POST', backup)).json();
    assert.equal(preview.cvs, 1); assert.equal(preview.jobMatches, 1);
    assert.equal((await request('/settings/import', 'POST', backup)).status, 200);
    const restored = getJobs(store);
    assert.notEqual(restored.revision, saved!.revision);
    assert.deepEqual({ ...restored, revision: saved!.revision }, saved);
  });
});
test('legacy backups add JOB without losing hidden widgets, order or widths; malformed JOB import stays atomic', async () => {
  let backup: Record<string, unknown> = {};
  await withAPI(async ({ request }) => { backup = await (await request('/settings/export')).json(); });
  const legacyLayout = defaultLayout.filter(item => item.id !== 'jobs').reverse().map(item => ({ ...item, visible: false, width: 'normal' }));
  for (const schemaVersion of [1, 2]) await withAPI(async ({ request }) => {
    assert.equal((await request('/settings/import', 'POST', { ...backup, schemaVersion, layout: legacyLayout })).status, 200);
    const saved = await (await request('/settings')).json();
    assert.deepEqual(saved.layout.slice(0, 6), legacyLayout); assert.equal(saved.layout[6].id, 'jobs');
    assert.equal((await state(request)).cv, null);
  });
  await withAPI(async ({ request, store }) => {
    const before = getJobs(store);
    const bad = { ...emptyJobs(randomUUID()), profileConfirmed: true };
    assert.equal((await request('/settings/import', 'POST', { ...backup, jobs: bad })).status, 400);
    assert.equal(store.has('imported'), false); assert.deepEqual(getJobs(store), before);
  });
});
test('JOB and existing dashboard layout survive reopening an isolated database', async () => {
  const directory = await mkdtemp(join(tmpdir(), 'kontrol-jobs-persistence-')), path = join(directory, 'fixture.sqlite');
  try {
    const store = new Store(path), layout = defaultLayout.filter(item => item.id !== 'jobs').reverse();
    store.set('layout', layout); jobsModule(store, options); settingsModule(store);
    const saved = { ...getJobs(store), cv: { name: 'cv.txt', bytes: Buffer.byteLength(cvText), text: cvText, uploadedAt: new Date(jobNow).toISOString() }, profile, profileConfirmed: true, matches: [match] };
    store.set('jobs', saved); store.close();
    const reopened = new Store(path);
    try {
      jobsModule(reopened, options); settingsModule(reopened);
      assert.deepEqual(getJobs(reopened), saved);
      assert.deepEqual(reopened.get<Layout>('layout').slice(0, 6), layout);
      assert.equal(reopened.get<Layout>('layout').length, 7);
    } finally { reopened.close(); }
  } finally { await rm(directory, { recursive: true, force: true }); }
});
