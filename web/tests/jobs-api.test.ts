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
import { createJobDiscovery } from '../server/jobs/sources';
import { piJobSearch } from '../server/jobs/search';
import { NewsFetchError } from '../server/news/transport';
import { settingsModule } from '../server/modules/settings';
import { type Layout } from '../shared/schema';
import { emptyJobs, type JobsResponse, type JobsState } from '../shared/jobs';
import { berlin, tokyo, profile, cvText, cvUpload, job, match, jobNow, readyPI } from './jobs-fixtures';

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
for (const provider of ['PI', 'DuckDuckGo', 'Direct boards']) test(`search ranks and saves verified ${provider} listings from discovery through the JOB API`, async () => {
  const offer = provider === 'Direct boards' ? 'https://www.tokyodev.com/companies/fixture/jobs/backend' : 'https://board.example/jobs/backend';
  const calls: string[] = [];
  const sources = createJobDiscovery(async url => {
    calls.push(url);
    if (url.includes('remotive.com/api')) return '{"jobs":[]}';
    if (url.includes('arbeitnow.com/api')) return '{"data":[]}';
    if (provider === 'Direct boards' && url === 'https://www.tokyodev.com/jobs/backend') return '<a href="/companies/fixture/jobs/backend">Backend engineer</a>';
    if (url.includes('bing.com/search')) return '<rss><channel><item><title>Backend tutorials</title><link>https://example.com/tutorials</link></item></channel></rss>';
    if (url.includes('duckduckgo.com/html')) return '<a class="result__a" href="https://board.example/jobs">Backend jobs</a>';
    if (url === 'https://board.example/jobs') return '<a href="/jobs/backend">Backend Engineer</a>';
    if (url === offer) return '<script type="application/ld+json">' + JSON.stringify({ '@type': 'JobPosting', title: job.title,
      hiringOrganization: { name: job.company }, description: job.description, datePosted: '2026-10-01', employmentType: 'FULL_TIME',
      jobLocation: { address: { addressLocality: 'Minato-ku', addressRegion: 'Tokyo', addressCountry: 'JP' } },
    }) + '</script>';
    return '<p>Backend tutorial</p>';
  }, provider !== 'DuckDuckGo' ? piJobSearch({ run: async prompt => {
    assert.deepEqual(JSON.parse(prompt).roles, profile.roles);
    assert.doesNotMatch(prompt, /Fixture Candidate/);
    if (provider === 'Direct boards') return { text: '{"links":[]}', urls: [] };
    return { text: JSON.stringify({ links: [
      { url: offer, title: 'Model title must not replace the retrieved job title' },
      { url: 'https://invented.example/jobs/fake', title: 'Invented listing' },
    ] }), urls: [offer] };
  } }) : undefined);
  const ai = jobAI({ run: async prompt => {
    const evidence = JSON.parse(prompt).sources;
    assert.equal(evidence.length, 1); assert.equal(evidence[0].url, offer); assert.equal(evidence[0].title, job.title);
    return JSON.stringify({ matches: [{ id: evidence[0].id, score: 88, reason: 'Go and PostgreSQL match.', gaps: ['Confirm job requirements.'] }] });
  } });
  await withAPI(async ({ request }) => {
    await prepare(request);
    const preferences = { ...(await state(request)).preferences, cities: [tokyo], employmentTypes: ['full_time'] };
    assert.equal((await action(request, '/preferences', 'PUT', { preferences })).status, 200);
    assert.equal((await action(request, '/search')).status, 200);
    const saved = await state(request);
    assert.equal(saved.lastSearch?.sourceCount, 1); assert.equal(saved.lastSearch?.error, null);
    assert.equal(saved.matches.length, 1); assert.equal(saved.matches[0].url, offer);
    assert.deepEqual(saved.matches[0].cities, [{ name: 'Minato-ku', region: 'Tokyo', country: 'JP' }]);
    assert.equal(calls.filter(url => url === offer).length, 1);
    assert.equal(calls.some(url => url.includes('invented.example')), false);
    assert.equal(calls.some(url => /bing\.com|duckduckgo\.com/.test(url)), provider === 'DuckDuckGo');
  }, { jobs: { ...options, sources, rank: ai.rank } });
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
test('version-3 through version-5 backups round-trip JOB data and protect existing CVs from import', async () => {
  let backup: Record<string, unknown> = {}, saved: JobsState | null = null;
  await withAPI(async ({ request, store }) => {
    await prepare(request); await action(request, '/search'); saved = getJobs(store);
    backup = await (await request('/settings/export')).json();
    assert.equal(backup.schemaVersion, 5); assert.deepEqual(backup.jobs, saved);
    assert.equal((await request('/settings/import', 'POST', backup)).status, 409);
    assert.deepEqual(getJobs(store), saved);
  }, { jobs: options });
  for (const schemaVersion of [3, 4, 5]) await withAPI(async ({ request, store }) => {
    const layout = backup.layout as Layout;
    const source = { ...backup, schemaVersion, layout: schemaVersion === 3 ? [
      { id: 'tasks', visible: true, width: 'normal' }, ...layout,
      { id: 'schedule', visible: false, width: 'wide' },
    ] : layout };
    const preview = await (await request('/settings/import/preview', 'POST', source)).json();
    assert.equal(preview.cvs, 1); assert.equal(preview.jobMatches, 1);
    assert.equal((await request('/settings/import', 'POST', source)).status, 200);
    assert.deepEqual((await (await request('/settings')).json()).layout, layout);
    const restored = getJobs(store);
    assert.notEqual(restored.revision, saved!.revision);
    assert.deepEqual({ ...restored, revision: saved!.revision }, saved);
  });
});
test('legacy backups retire sections and add JOB without losing customization; malformed JOB import stays atomic', async () => {
  let backup: Record<string, unknown> = {};
  await withAPI(async ({ request }) => { backup = await (await request('/settings/export')).json(); });
  const legacyLayout = ['tasks', 'focus', 'schedule', 'projects', 'learning', 'news'].reverse().map(id => ({ id, visible: false, width: 'normal' }));
  const remaining = legacyLayout.filter(item => item.id !== 'tasks' && item.id !== 'schedule');
  for (const schemaVersion of [1, 2]) await withAPI(async ({ request }) => {
    assert.equal((await request('/settings/import', 'POST', { ...backup, schemaVersion, layout: legacyLayout })).status, 200);
    const saved = await (await request('/settings')).json();
    assert.deepEqual(saved.layout, [...remaining, { id: 'jobs', visible: true, width: 'wide' }]);
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
    const store = new Store(path), layout = ['tasks', 'focus', 'schedule', 'projects', 'learning', 'news', 'jobs'].reverse()
      .map((id, index) => ({ id, visible: index % 2 === 0, width: index % 2 === 0 ? 'normal' : 'wide' }));
    const remaining = layout.filter(item => item.id !== 'tasks' && item.id !== 'schedule');
    store.set('layout', layout); jobsModule(store, options); settingsModule(store);
    const saved = { ...getJobs(store), cv: { name: 'cv.txt', bytes: Buffer.byteLength(cvText), text: cvText, uploadedAt: new Date(jobNow).toISOString() }, profile, profileConfirmed: true, matches: [match] };
    store.set('jobs', saved); store.close();
    const reopened = new Store(path);
    try {
      jobsModule(reopened, options); settingsModule(reopened);
      assert.deepEqual(getJobs(reopened), saved);
      assert.deepEqual(reopened.get<Layout>('layout'), remaining);
    } finally { reopened.close(); }
  } finally { await rm(directory, { recursive: true, force: true }); }
});
