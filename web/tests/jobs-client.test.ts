import test from 'node:test';
import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { MutationObserver, QueryClient, QueryObserver } from '@tanstack/react-query';
import { api } from '../src/lib/api';
import { jobCommandOptions, jobsQueryOptions } from '../src/modules/jobs/api';
import { emptyJobs, type JobsResponse } from '../shared/jobs';
import { cvText, profile, readyPI } from './jobs-fixtures';

// Transport/cache tests only: no DOM, browser, app launch or UI interaction.
function untilAborted(signal: AbortSignal): Promise<never> {
  return new Promise((_, reject) => {
    const guard = setTimeout(() => { signal.removeEventListener('abort', abort); reject(new Error('Fixture request was not aborted')); }, 2000);
    function abort() { clearTimeout(guard); reject(signal.reason); }
    signal.addEventListener('abort', abort, { once: true });
    if (signal.aborted) abort();
  });
}
test('API deadlines cover waiting for headers and stalled response bodies', async context => {
  for (const stage of ['headers', 'body']) {
    let signal: AbortSignal | undefined;
    context.mock.method(globalThis, 'fetch', async (_input: unknown, init: RequestInit) => {
      signal = init.signal as AbortSignal;
      if (stage === 'headers') return untilAborted(signal);
      const response = new Response();
      response.json = () => untilAborted(signal!);
      return response;
    });
    await assert.rejects(api('/jobs/analyze', 'POST', {}, { timeoutMs: 20 }), /took too long.*Refresh/);
    assert.equal(signal?.aborted, true);
    context.mock.restoreAll();
  }
});
test('API preserves actionable server errors and supports query cancellation', async context => {
  context.mock.method(globalThis, 'fetch', async () => Response.json({ error: 'PI took too long to respond. Your CV is saved.' }, { status: 502 }));
  await assert.rejects(api('/jobs/analyze', 'POST'), /PI took too long.*CV is saved/);
  context.mock.restoreAll();
  const controller = new AbortController();
  context.mock.method(globalThis, 'fetch', async (_input: unknown, init: RequestInit) => untilAborted(init.signal as AbortSignal));
  const pending = api('/jobs', 'GET', undefined, { signal: controller.signal, timeoutMs: 1000 });
  controller.abort();
  await assert.rejects(pending, { name: 'AbortError' });
});
for (const succeeds of [true, false]) test(`JOB command ${succeeds ? 'success' : 'failure'} settles while its status refetch stalls`, async context => {
  const client = new QueryClient({ defaultOptions: { queries: { retry: false }, mutations: { retry: false } } });
  const initial: JobsResponse = { ...emptyJobs(randomUUID()),
    cv: { name: 'fixture.txt', bytes: cvText.length, text: cvText, uploadedAt: new Date().toISOString() }, activity: null, ai: await readyPI() };
  const { ai, activity, ...state } = initial;
  const analyzed = { ...state, revision: randomUUID(), profile };
  let statusRequests = 0;
  context.mock.method(globalThis, 'fetch', async (_input: unknown, init: RequestInit) => {
    if (init.method === 'POST') return succeeds ? Response.json(analyzed) : Response.json({ error: 'PI could not finish this fixture.' }, { status: 502 });
    statusRequests++;
    return untilAborted(init.signal as AbortSignal);
  });
  client.setQueryData(['jobs'], initial);
  const query = new QueryObserver(client, { ...jobsQueryOptions, retry: false });
  const unsubscribe = query.subscribe(() => {});
  try {
    const command = new MutationObserver(client, jobCommandOptions(client));
    const pending = command.mutate({ path: '/analyze', body: { expectedRevision: state.revision } });
    if (succeeds) assert.deepEqual(await pending, analyzed);
    else await assert.rejects(pending, /PI could not finish/);
    assert.equal(command.getCurrentResult().status, succeeds ? 'success' : 'error');
    assert.equal(client.isMutating({ mutationKey: ['jobs-command'] }), 0);
    assert.equal(statusRequests, 1); assert.equal(query.getCurrentResult().fetchStatus, 'fetching');
    const saved = client.getQueryData<JobsResponse>(['jobs'])!;
    assert.equal(saved.activity, null); assert.deepEqual(saved.ai, ai);
    assert.deepEqual(saved.profile, succeeds ? profile : null);
    assert.equal(saved.revision, succeeds ? analyzed.revision : initial.revision);
  } finally { unsubscribe(); client.clear(); }
});
