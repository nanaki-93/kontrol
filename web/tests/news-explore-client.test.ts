import test from 'node:test';
import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { MutationObserver, QueryClient, QueryObserver } from '@tanstack/react-query';
import {
  EXPLORE_CLIENT_RETENTION_MS, EXPLORE_GENERATION_CLIENT_DEADLINE_MS, EXPLORE_RECOVERY_CLIENT_DEADLINE_MS,
  EXPLORE_SESSION_TTL_MS, EXPLORE_SEARCH_CLIENT_DEADLINE_MS, exploreSessionSchema,
  exploreSearchResponseSchema, type ExploreSession, type ExplorePreview, type ExploreSearch,
} from '../shared/news-explore';
import {
  clearExploreAfterImport, ExploreCommandError, exploreGenerationOptions, exploreRecoveryOptions,
  exploreStateKey, exploreStateOptions, readExploreState, reconcileExploreSources, selectExploreTopic, subscribeExploreMetadata,
  exploreSearchOptions, setExploreSearchDraft,
} from '../src/modules/news/explore-api';
import { acceptExploreSession, retainedExploreResult, type ExploreClientState, type ExploreStatus } from '../src/modules/news/explore-state';
import { interestDraftSchema, type InterestDraft, type NewsInterest } from '../shared/news';
import {
  createInterestEditorState, createInterestEditorSubmission, interestEditorIdentity,
  saveInterestEditor, validateInterestEditorDraft, type InterestEditorInput,
} from '../src/modules/news/interest-editor';

// Pure editor/cache fixtures only: no DOM, application, listener or external request.
const draft: InterestDraft = {
  name: 'Computing infrastructure', query: 'AI data center power grid cooling infrastructure developments',
  language: 'ja', region: 'JP', days: 30, intent: 'news',
  requiredTerms: ['power|cooling'], excludedTerms: ['stock price'], enabled: true,
};
function interest(value = draft): NewsInterest { return { ...value, id: randomUUID(), revision: randomUUID() }; }
function deferred<T>() {
  let resolve!: (value: T) => void, reject!: (reason: Error) => void;
  const promise = new Promise<T>((yes, no) => { resolve = yes; reject = no; });
  return { promise, resolve, reject };
}

// Compiler assertions: a prefill or custom creation command cannot accompany an edit.
function exclusiveInputs(saved: NewsInterest) {
  // @ts-expect-error Mutually exclusive existing-interest and creation prefill.
  const mixed: InterestEditorInput = { interest: saved, initialDraft: draft };
  // @ts-expect-error Editing may not override the ordinary PUT command.
  const override: InterestEditorInput = { interest: saved, onCreate: async () => ({ interest: saved, created: false }) };
  return [mixed, override];
}

test('editor: blank creation and prefill copy only draft fields without edit authority', () => {
  const blank = createInterestEditorState({});
  assert.equal(blank.existing, null);
  assert.deepEqual(blank.draft, { name: '', query: '', language: 'en', region: 'US', days: 7,
    intent: 'news', requiredTerms: [], excludedTerms: [], enabled: true });
  const supplied = interest(); // Even a structurally wider draft does not confer edit authority.
  const prefilled = createInterestEditorState({ initialDraft: supplied });
  assert.equal(prefilled.existing, null);
  assert.deepEqual(prefilled.draft, draft);
  assert.equal('id' in prefilled.draft, false);
  assert.equal('revision' in prefilled.draft, false);
  prefilled.draft.requiredTerms.push('fixture');
  prefilled.draft.excludedTerms.push('fixture');
  assert.deepEqual(supplied.requiredTerms, draft.requiredTerms);
  assert.deepEqual(supplied.excludedTerms, draft.excludedTerms);
  blank.draft.requiredTerms.push('fixture');
  assert.deepEqual(createInterestEditorState({}).draft.requiredTerms, []);
});

test('editor: mixed creation/edit inputs are also rejected at runtime', () => {
  const mixed = exclusiveInputs(interest());
  for (const input of mixed) assert.throws(() => createInterestEditorState(input), /cannot be combined/);
});

test('editor: identity ignores metadata revisions and changing a suggestion creates a new identity', () => {
  const original = interest(), refreshed = { ...original, revision: randomUUID(), name: 'Remote edit' };
  assert.equal(interestEditorIdentity({ interest: original }), interestEditorIdentity({ interest: refreshed }));
  assert.notEqual(interestEditorIdentity({ interest: original }), interestEditorIdentity({ interest: interest() }));
  assert.equal(interestEditorIdentity({ initialDraft: draft }, 'topic-1'), interestEditorIdentity({ initialDraft: { ...draft, name: 'New metadata' } }, 'topic-1'));
  assert.notEqual(interestEditorIdentity({ initialDraft: draft }, 'topic-1'), interestEditorIdentity({ initialDraft: draft }, 'topic-2'));
  assert.notEqual(interestEditorIdentity({}), interestEditorIdentity({ interest: original }));
});

test('editor: normal creation is POST, editing is PUT with the original baseline revision', async () => {
  const saved = interest(), existing = createInterestEditorState({ interest: saved });
  const changed = { ...existing.draft, name: 'My unsaved name', query: draft.query + ' regional developments' };
  const calls: unknown[] = [];
  const execute: Parameters<typeof saveInterestEditor>[2] = async command => { calls.push(command); return { ...saved, ...changed }; };
  const created = await saveInterestEditor(createInterestEditorState({ initialDraft: draft }), draft, execute);
  assert.equal(created.created, true);
  const edited = await saveInterestEditor(existing, changed, execute);
  assert.equal(edited.created, false);
  assert.deepEqual(calls, [
    { path: '/news/interests', method: 'POST', body: draft },
    { path: '/news/interests/' + saved.id, method: 'PUT', body: { ...changed, expectedRevision: saved.revision } },
  ]);
  assert.deepEqual(existing.draft, draft);
  assert.deepEqual(existing.existing, { id: saved.id, revision: saved.revision });
});

test('editor: custom creation receives the validated draft and returns created/already-followed results without ordinary saves', async () => {
  let ordinaryCalls = 0, createCalls = 0;
  const execute = async () => { ordinaryCalls++; return interest(); };
  for (const created of [true, false]) {
    const expected = { interest: interest(), created };
    const result = await saveInterestEditor(createInterestEditorState({ initialDraft: draft }),
      { ...draft, name: '  Computing infrastructure  ' }, execute, async approved => {
        createCalls++; assert.deepEqual(approved, draft); return expected;
      });
    assert.equal(result, expected);
  }
  assert.equal(ordinaryCalls, 0);
  assert.equal(createCalls, 2);
});

test('editor: editing never dispatches through a creation override', async () => {
  const saved = interest();
  let ordinaryCalls = 0, createCalls = 0;
  await saveInterestEditor(createInterestEditorState({ interest: saved }), draft,
    async () => { ordinaryCalls++; return saved; }, async () => { createCalls++; return { interest: saved, created: true }; });
  assert.equal(ordinaryCalls, 1);
  assert.equal(createCalls, 0);
});

test('editor: validation and all editable fields retain existing domain rules', () => {
  const parsed = validateInterestEditorDraft({ ...draft, name: '  Edited  ', intent: 'opportunities', enabled: false,
    region: 'PH', days: 1, language: 'en' }, '  power|cooling  \n\n software ', ' stock price \n celebrity ');
  assert.equal(parsed.success, true);
  if (parsed.success) assert.deepEqual(parsed.data, { ...draft, name: 'Edited', intent: 'opportunities', enabled: false,
    region: 'PH', days: 1, language: 'en', requiredTerms: ['power|cooling', 'software'], excludedTerms: ['stock price', 'celebrity'] });
  for (const value of [draft, { ...draft, query: 'short query' }, { ...draft, query: 'short query', enabled: false },
    { ...draft, query: 'solar grid OR power -cooling site:example.org' },
    { ...draft, name: '' }, { ...draft, query: 'x'.repeat(601) },
    { ...draft, requiredTerms: Array(9).fill('power') }, { ...draft, excludedTerms: Array(13).fill('stock') }]) {
    const actual = validateInterestEditorDraft(value, value.requiredTerms.join('\n'), value.excludedTerms.join('\n'));
    const expected = interestDraftSchema.safeParse(value);
    assert.equal(actual.success, expected.success);
    if (!actual.success && !expected.success) assert.deepEqual(actual.error.issues, expected.error.issues);
  }
  assert.equal(validateInterestEditorDraft({ ...draft, language: 'en', query: 'short query' }, '', '').success, false);
  assert.equal(validateInterestEditorDraft(draft, '', '').success, true);
});

test('editor: invalid submissions issue no ordinary or injected creation command', async () => {
  let calls = 0;
  const invalid = { ...draft, language: 'en' as const, query: 'short query' };
  await assert.rejects(saveInterestEditor(createInterestEditorState({ initialDraft: invalid }), invalid,
    async () => { calls++; return interest(); }, async () => { calls++; return { interest: interest(), created: true }; }), /at least 5 words/);
  assert.equal(calls, 0);
  // Opening an existing legacy short query is allowed so it can be corrected.
  assert.equal(createInterestEditorState({ interest: interest(invalid) }).draft.query, 'short query');
});

test('editor: cancel closes without saving and is gated during a synchronous submission', async () => {
  const submission = createInterestEditorSubmission(), wait = deferred<void>();
  let saves = 0, closes = 0;
  assert.equal(submission.cancel(() => { closes++; }), true);
  assert.equal(saves, 0);
  assert.equal(closes, 1);
  const pending = submission.submit(async () => { saves++; await wait.promise; });
  assert.equal(submission.pending, true);
  assert.equal(submission.cancel(() => { closes++; }), false);
  wait.resolve();
  assert.equal(await pending, true);
  assert.equal(submission.pending, false);
  assert.equal(closes, 1);
});

test('editor: immediate duplicate submit is ignored until the original save finishes', async () => {
  const submission = createInterestEditorSubmission(), wait = deferred<NewsInterest>();
  const state = createInterestEditorState({ initialDraft: draft });
  let calls = 0;
  const save = async () => { await saveInterestEditor(state, draft, async () => { calls++; return wait.promise; }); };
  const first = submission.submit(save);
  assert.equal(await submission.submit(save), false);
  assert.equal(calls, 1);
  wait.resolve(interest());
  assert.equal(await first, true);
  assert.equal(submission.pending, false);
});

test('editor: rejected ordinary and follow saves preserve drafts, propagate errors and release admission for explicit retry', async () => {
  for (const custom of [false, true]) {
    const submission = createInterestEditorSubmission(), state = createInterestEditorState({ initialDraft: draft });
    const dirty = { ...state.draft, name: 'My corrected topic', requiredTerms: ['my|terms'], excludedTerms: ['unwanted'] };
    const before = structuredClone({ state, dirty });
    const wait = deferred<NewsInterest>();
    let ordinaryCalls = 0, customCalls = 0;
    const save = async () => {
      await saveInterestEditor(state, dirty, async () => { ordinaryCalls++; return wait.promise; },
        custom ? async () => { customCalls++; return { interest: await wait.promise, created: true }; } : undefined);
    };
    const pending = submission.submit(save);
    assert.equal(await submission.submit(save), false);
    wait.reject(new Error('Fixture capacity or revision conflict'));
    await assert.rejects(pending, /capacity or revision conflict/);
    assert.equal(submission.pending, false);
    assert.deepEqual({ state, dirty }, before);
    const approved = interest(dirty);
    let result: unknown;
    assert.equal(await submission.submit(async () => {
      result = await saveInterestEditor(state, dirty, async () => approved,
        custom ? async () => ({ interest: approved, created: false }) : undefined);
    }), true);
    assert.deepEqual(result, { interest: approved, created: !custom });
    assert.equal(ordinaryCalls, custom ? 0 : 1);
    assert.equal(customCalls, custom ? 1 : 0);
  }
});

function sessionFixture(source = interest(), at = Date.now()): ExploreSession {
  return exploreSessionSchema.parse({ id: randomUUID(), revision: randomUUID(),
    generatedAt: new Date(at).toISOString(), expiresAt: new Date(at + EXPLORE_SESSION_TTL_MS).toISOString(),
    sources: [{ id: source.id, revision: source.revision }], topics: [
      ['Cooling reuse', 'data center heat reuse district heating infrastructure news'],
      ['Grid storage', 'grid battery storage community resilience technology news'],
      ['Water stewardship', 'computing water stewardship community infrastructure policy news'],
    ].map(([title, query]) => ({ id: randomUUID(), title, description: 'An adjacent direction to investigate, not a report.',
      connection: 'Connected to computing infrastructure.', sourceInterestID: source.id, sourceInterestRevision: source.revision,
      proposedSearch: { query, language: source.language, region: source.region, days: source.days }, status: 'available', preview: { state: 'not-searched' } })) });
}
function cacheMetadata(client: QueryClient, interests: NewsInterest[]) {
  // The commands access only this local News metadata field, never workspace data.
  client.setQueryData(['news'], { discovery: { preferences: { interests } } });
}
function sessionClient(context: { after: (run: () => void | Promise<void>) => void }) {
  // Override hostile application defaults to prove our explicit options win.
  const client = new QueryClient({ defaultOptions: { queries: { retry: 3, gcTime: 0 }, mutations: { retry: 3, gcTime: 0 } } });
  context.after(async () => { await client.cancelQueries(); client.clear(); });
  return client;
}
function generated(session: ExploreSession) { return { session, partial: session.topics.length < 3 }; }
function status(session: ExploreSession): ExploreStatus { return { lifecycle: { state: 'available', session }, generation: { state: 'idle' } }; }

// Non-DOM QueryClient/MutationObserver units: every fetch is an injected fixture.
test('client-session: disabled subscriptions and navigation remounts restore selection and drafts with zero network work', async context => {
  const client = sessionClient(context), session = sessionFixture();
  let calls = 0;
  context.mock.method(globalThis, 'fetch', async () => { calls++; throw new Error('No requests are allowed'); });
  const first = new QueryObserver(client, exploreStateOptions(client));
  const unsubscribe = first.subscribe(() => {});
  assert.equal(first.getCurrentResult().data?.lifecycle.state, 'absent');
  client.setQueryData<ExploreClientState>(exploreStateKey, { ...readExploreState(client), ...status(session),
    drafts: { [session.topics[1].id]: { ...session.topics[1].proposedSearch, query: 'my reviewed grid battery community resilience news' } } });
  selectExploreTopic(client, session.topics[1].id);
  const before = structuredClone(readExploreState(client));
  unsubscribe();
  const second = new QueryObserver(client, exploreStateOptions(client)), stop = second.subscribe(() => {});
  try {
    client.getQueryCache().onFocus(); client.getQueryCache().onOnline();
    await client.invalidateQueries();
    await second.refetch(); // Even manually refetching the subscription is local-only.
    assert.deepEqual(second.getCurrentResult().data, before);
    assert.equal(calls, 0);
    assert.equal(exploreStateOptions(client).gcTime, EXPLORE_CLIENT_RETENTION_MS);
    assert.equal(exploreStateOptions(client).refetchInterval, false);
  } finally { stop(); }
});

test('client-session: explicit generation makes one protected request, synchronously gates duplicates and never awaits broad refetches', async context => {
  const client = sessionClient(context), source = interest(), session = sessionFixture(source), wait = deferred<Response>();
  cacheMetadata(client, [source]);
  let calls = 0;
  context.mock.method(client, 'invalidateQueries', () => { throw new Error('No broad refetch allowed'); });
  context.mock.method(globalThis, 'fetch', async (url: unknown, init: RequestInit) => {
    calls++; assert.equal(url, '/api/news/explore/generate'); assert.equal(init.method, 'POST');
    assert.deepEqual(init.headers, { 'X-Kontrol-Client': 'web', 'Content-Type': 'application/json' });
    assert.equal(init.body, '{}'); return wait.promise;
  });
  const options = exploreGenerationOptions(client);
  assert.equal(options.retry, false); assert.equal(options.networkMode, 'always');
  const first = new MutationObserver(client, options), second = new MutationObserver(client, options);
  const pending = first.mutate();
  await assert.rejects(second.mutate(), error => error instanceof ExploreCommandError && error.outcome === 'busy');
  assert.equal(readExploreState(client).generation.state, 'pending');
  assert.equal(calls, 1);
  wait.resolve(Response.json(generated(session)));
  assert.deepEqual(await pending, generated(session));
  assert.equal(first.getCurrentResult().status, 'success');
  assert.equal(readExploreState(client).generation.state, 'idle');
  assert.equal(readExploreState(client).selectedTopicID, session.topics[0].id);
  assert.equal(client.isMutating(), 0);
  assert.equal(calls, 1);
});

test('client-session: a confirmed server failure retains previous ideas and releases the gate without automatic retries', async context => {
  const client = sessionClient(context), session = sessionFixture();
  client.setQueryData(exploreStateKey, { ...readExploreState(client), ...status(session) });
  let calls = 0;
  context.mock.method(globalThis, 'fetch', async () => { calls++; return Response.json({ error: 'PI returned no usable topic ideas.' }, { status: 502 }); });
  const mutation = new MutationObserver(client, exploreGenerationOptions(client));
  await assert.rejects(mutation.mutate(), error => error instanceof ExploreCommandError && error.outcome === 'confirmed' && error.status === 502);
  const state = readExploreState(client);
  assert.deepEqual(state.lifecycle, status(session).lifecycle);
  assert.equal(state.generation.state, 'failed');
  assert.equal(state.generationRequestID, null);
  assert.equal(calls, 1);
});

for (const stage of ['headers', 'body']) test(`client-session: ${stage} timeout is uncertain, retains ideas and requires explicit local recovery instead of another paid request`, async context => {
  const client = sessionClient(context), session = sessionFixture(), wait = deferred<Response>();
  client.setQueryData(exploreStateKey, { ...readExploreState(client), ...status(session) });
  let posts = 0, gets = 0, requestSignal: AbortSignal | null = null;
  context.mock.method(globalThis, 'fetch', async (_url: unknown, init: RequestInit) => {
    if (init.method === 'GET') { gets++; return Response.json(status(session)); }
    posts++; requestSignal = init.signal as AbortSignal;
    if (stage === 'headers') return wait.promise; // Deliberately ignores abort; ownership must still hold.
    const response = new Response(); response.json = () => wait.promise; return response;
  });
  const command = new MutationObserver(client, exploreGenerationOptions(client, { generationTimeoutMs: 15 }));
  await assert.rejects(command.mutate(), error => error instanceof ExploreCommandError && error.outcome === 'uncertain');
  assert.equal((requestSignal as AbortSignal | null)?.aborted, true);
  assert.equal(readExploreState(client).generation.state, 'uncertain');
  assert.deepEqual(readExploreState(client).lifecycle, status(session).lifecycle);
  await assert.rejects(command.mutate(), /Check local status/);
  assert.equal(posts, 1); assert.equal(gets, 0);
  const recovered = await new MutationObserver(client, exploreRecoveryOptions(client)).mutate();
  assert.deepEqual(recovered, status(session));
  assert.equal(readExploreState(client).generation.state, 'idle');
  assert.equal(gets, 1); assert.equal(posts, 1);
  wait.resolve(Response.json(generated(sessionFixture())));
  await Promise.resolve();
  assert.deepEqual(readExploreState(client).lifecycle, status(session).lifecycle);
});

test('client-session: lost and malformed responses are sanitized uncertain outcomes, not confirmed server failures', async context => {
  const client = sessionClient(context);
  for (const response of ['lost', 'malformed']) {
    clearExploreAfterImport(client);
    let calls = 0;
    context.mock.method(globalThis, 'fetch', async () => {
      calls++;
      if (response === 'lost') throw new Error('PRIVATE_PROVIDER_TOKEN');
      return Response.json({ session: { title: 'untrusted data' } });
    });
    await assert.rejects(new MutationObserver(client, exploreGenerationOptions(client)).mutate(), error =>
      error instanceof ExploreCommandError && error.outcome === 'uncertain' && !error.message.includes('PRIVATE'));
    assert.equal(readExploreState(client).generation.state, 'uncertain');
    assert.equal(calls, 1);
    context.mock.restoreAll();
  }
});

test('client-session: a stale status response cannot replace completed generation even when retrieval ignores cancellation', async context => {
  const client = sessionClient(context), old = sessionFixture(), replacement = sessionFixture(), wait = deferred<Response>();
  let gets = 0, posts = 0, signal: AbortSignal | null = null;
  context.mock.method(globalThis, 'fetch', async (_url: unknown, init: RequestInit) => {
    if (init.method === 'POST') { posts++; return Response.json(generated(replacement)); }
    gets++; signal = init.signal as AbortSignal; return wait.promise;
  });
  const recovery = new MutationObserver(client, exploreRecoveryOptions(client));
  const checking = recovery.mutate();
  const rejected = assert.rejects(checking);
  await Promise.resolve(); await Promise.resolve();
  await new MutationObserver(client, exploreGenerationOptions(client)).mutate();
  await rejected;
  assert.equal((signal as AbortSignal | null)?.aborted, true);
  wait.resolve(Response.json(status(old))); await Promise.resolve();
  const state = readExploreState(client);
  assert.deepEqual(state.lifecycle, status(replacement).lifecycle);
  assert.equal(state.recovery.state, 'idle');
  assert.equal(posts, 1); assert.equal(gets, 1);
});

test('client-session: a status admitted during generation cannot end activity or overwrite its eventual result', async context => {
  const client = sessionClient(context), old = sessionFixture(), replacement = sessionFixture(), generation = deferred<Response>(), recovery = deferred<Response>();
  context.mock.method(globalThis, 'fetch', async (_url: unknown, init: RequestInit) => init.method === 'POST' ? generation.promise : recovery.promise);
  const generating = new MutationObserver(client, exploreGenerationOptions(client)).mutate();
  await Promise.resolve(); await Promise.resolve();
  const checking = new MutationObserver(client, exploreRecoveryOptions(client)).mutate();
  recovery.resolve(Response.json(status(old))); await checking;
  assert.equal(readExploreState(client).generation.state, 'pending');
  generation.resolve(Response.json(generated(replacement))); await generating;
  assert.deepEqual(readExploreState(client).lifecycle, status(replacement).lifecycle);
});

test('client-session: absolute expiry clears temporary data without network work and restart recovery is explicit', async context => {
  const client = sessionClient(context), at = Date.now(), session = sessionFixture(interest(), at);
  client.setQueryData(exploreStateKey, { ...readExploreState(client), ...status(session), selectedTopicID: session.topics[0].id,
    drafts: { [session.topics[0].id]: session.topics[0].proposedSearch } });
  let gets = 0;
  context.mock.method(globalThis, 'fetch', async (_url: unknown, init: RequestInit) => {
    gets++; assert.equal(init.method, 'GET'); return Response.json({ lifecycle: { state: 'absent' }, generation: { state: 'idle' } });
  });
  assert.equal(readExploreState(client, at + EXPLORE_SESSION_TTL_MS - 1).lifecycle.state, 'available');
  const expired = readExploreState(client, at + EXPLORE_SESSION_TTL_MS);
  assert.equal(expired.lifecycle.state, 'expired'); assert.deepEqual(expired.drafts, {}); assert.equal(expired.selectedTopicID, null);
  assert.equal(gets, 0);
  await new MutationObserver(client, exploreRecoveryOptions(client)).mutate();
  assert.equal(readExploreState(client).lifecycle.state, 'expired');
  assert.equal(gets, 1);
  assert.ok(EXPLORE_CLIENT_RETENTION_MS <= EXPLORE_SESSION_TTL_MS);
});

test('client-session: metadata edit, disable or delete revokes cached topics and late generation cannot resurrect restored revisions', async context => {
  const client = sessionClient(context), source = interest(), session = sessionFixture(source);
  let calls = 0;
  const wait = deferred<Response>(), started = deferred<void>();
  context.mock.method(globalThis, 'fetch', async () => { calls++; started.resolve(); return wait.promise; });
  for (const current of [[{ ...source, revision: randomUUID() }], [{ ...source, enabled: false }], []]) {
    clearExploreAfterImport(client);
    client.setQueryData(exploreStateKey, { ...readExploreState(client), ...status(session) });
    reconcileExploreSources(client, current);
    const state = readExploreState(client);
    assert.equal(state.lifecycle.state, 'available');
    if (state.lifecycle.state === 'available') assert.ok(state.lifecycle.session.topics.every(topic => topic.status === 'obsolete' && topic.preview.state === 'obsolete'));
    reconcileExploreSources(client, [source]);
    assert.deepEqual(readExploreState(client).lifecycle, state.lifecycle); // Sticky, no resurrection.
  }
  assert.equal(calls, 0);
  cacheMetadata(client, [source]);
  const pending = new MutationObserver(client, exploreGenerationOptions(client)).mutate();
  await started.promise;
  cacheMetadata(client, []); reconcileExploreSources(client, []);
  cacheMetadata(client, [source]); reconcileExploreSources(client, [source]);
  wait.resolve(Response.json(generated(session)));
  await assert.rejects(pending, error => error instanceof ExploreCommandError && error.outcome === 'stale');
  assert.equal(readExploreState(client).generation.state, 'failed');
  const state = readExploreState(client);
  if (state.lifecycle.state === 'available') assert.ok(state.lifecycle.session.topics.every(topic => topic.status === 'obsolete'));
  assert.equal(calls, 1);
});

for (const operation of ['generate', 'recover']) test(`client-session: successful import advances ownership and rejects late ${operation} even with identical News revisions`, async context => {
  const client = sessionClient(context), source = interest(), session = sessionFixture(source), wait = deferred<Response>();
  cacheMetadata(client, [source]);
  client.setQueryData(exploreStateKey, { ...readExploreState(client), ...status(session) });
  context.mock.method(globalThis, 'fetch', async () => wait.promise);
  const before = readExploreState(client);
  const pending = operation === 'generate' ? new MutationObserver(client, exploreGenerationOptions(client)).mutate() :
    new MutationObserver(client, exploreRecoveryOptions(client)).mutate();
  const rejected = assert.rejects(pending);
  await Promise.resolve(); await Promise.resolve();
  clearExploreAfterImport(client);
  const imported = structuredClone(readExploreState(client));
  assert.notEqual(imported.owner, before.owner);
  assert.equal(imported.lifecycle.state, 'obsolete'); assert.deepEqual(imported.drafts, {});
  wait.resolve(Response.json(operation === 'generate' ? generated(session) : status(session)));
  await rejected;
  assert.deepEqual(readExploreState(client), imported);
});

test('client-session: recovery preserves dirty drafts and selection; failure retains state and never invokes generation', async context => {
  const client = sessionClient(context), session = sessionFixture(), selectedTopicID = session.topics[2].id;
  const dirty = { ...session.topics[2].proposedSearch, query: 'my adjusted water infrastructure policy local news' };
  client.setQueryData(exploreStateKey, { ...readExploreState(client), ...status(session), selectedTopicID, drafts: { [selectedTopicID]: dirty } });
  let gets = 0;
  context.mock.method(globalThis, 'fetch', async (_url: unknown, init: RequestInit) => {
    assert.equal(init.method, 'GET'); gets++;
    if (gets === 2) throw new Error('PRIVATE server details');
    return Response.json(status(session));
  });
  const recovery = new MutationObserver(client, exploreRecoveryOptions(client));
  assert.equal(exploreRecoveryOptions(client).retry, false);
  await recovery.mutate();
  const before = readExploreState(client);
  assert.deepEqual(before.drafts[selectedTopicID], dirty); assert.equal(before.selectedTopicID, selectedTopicID);
  await assert.rejects(recovery.mutate(), /outcome is unknown/);
  const after = readExploreState(client);
  assert.deepEqual(after.lifecycle, before.lifecycle); assert.deepEqual(after.drafts, before.drafts);
  assert.equal(after.recovery.state, 'failed'); assert.equal(after.selectedTopicID, selectedTopicID);
  assert.equal(gets, 2);
});

test('client-session: named client deadlines cover server work and invalid higher bounds are rejected', context => {
  const client = sessionClient(context);
  assert.equal(EXPLORE_GENERATION_CLIENT_DEADLINE_MS, 75_000);
  assert.equal(EXPLORE_RECOVERY_CLIENT_DEADLINE_MS, 10_000);
  assert.throws(() => exploreGenerationOptions(client, { generationTimeoutMs: 75_001 }), /deadline/);
  assert.throws(() => exploreRecoveryOptions(client, { recoveryTimeoutMs: 10_001 }), /deadline/);
  assert.throws(() => exploreRecoveryOptions(client, { recoveryTimeoutMs: 0 }), /deadline/);
});

test('client-session: existing News metadata subscriptions revoke context without adding requests and unsubscribe cleanly', context => {
  const client = sessionClient(context), source = interest(), session = sessionFixture(source);
  cacheMetadata(client, [source]);
  client.setQueryData(exploreStateKey, { ...readExploreState(client), ...status(session) });
  let calls = 0;
  context.mock.method(globalThis, 'fetch', async () => { calls++; throw new Error('No network work'); });
  const unsubscribe = subscribeExploreMetadata(client);
  try {
    cacheMetadata(client, [{ ...source, revision: randomUUID() }]);
    const state = readExploreState(client);
    assert.equal(state.lifecycle.state, 'available');
    if (state.lifecycle.state === 'available') assert.ok(state.lifecycle.session.topics.every(topic => topic.status === 'obsolete'));
    assert.equal(calls, 0);
  } finally { unsubscribe(); }
  client.setQueryData(exploreStateKey, { ...readExploreState(client), ...status(session) });
  cacheMetadata(client, []);
  assert.deepEqual(readExploreState(client).lifecycle, status(session).lifecycle);
});

test('client-session: local recovery timeout retains ideas, releases its gate and issues no paid request or automatic retry', async context => {
  const client = sessionClient(context), session = sessionFixture(), wait = deferred<Response>();
  client.setQueryData(exploreStateKey, { ...readExploreState(client), ...status(session) });
  let calls = 0, signal: AbortSignal | null = null;
  context.mock.method(globalThis, 'fetch', async (_url: unknown, init: RequestInit) => {
    calls++; assert.equal(init.method, 'GET'); signal = init.signal as AbortSignal; return wait.promise;
  });
  const recovery = new MutationObserver(client, exploreRecoveryOptions(client, { recoveryTimeoutMs: 15 }));
  const pending = recovery.mutate();
  await assert.rejects(new MutationObserver(client, exploreRecoveryOptions(client)).mutate(), /already running/);
  await assert.rejects(pending, error => error instanceof ExploreCommandError && error.outcome === 'uncertain');
  assert.equal((signal as AbortSignal | null)?.aborted, true);
  const state = readExploreState(client);
  assert.equal(state.recovery.state, 'failed'); assert.deepEqual(state.lifecycle, status(session).lifecycle);
  assert.equal(calls, 1);
  assert.equal(client.getQueryCache().findAll({ queryKey: ['news-explore-recovery'] }).length, 0);
  wait.resolve(Response.json(status(session)));
});

test('client-session: obsolete recovery cleanup cannot abort a newer post-import local status check', async context => {
  const client = sessionClient(context), session = sessionFixture(), old = deferred<Response>(), fresh = deferred<Response>(), started = deferred<void>();
  let gets = 0, newSignal: AbortSignal | null = null;
  context.mock.method(globalThis, 'fetch', async (_url: unknown, init: RequestInit) => {
    if (++gets === 1) { started.resolve(); return old.promise; }
    newSignal = init.signal as AbortSignal; return fresh.promise;
  });
  const first = new MutationObserver(client, exploreRecoveryOptions(client)).mutate();
  const rejected = assert.rejects(first);
  await started.promise;
  clearExploreAfterImport(client);
  const second = new MutationObserver(client, exploreRecoveryOptions(client)).mutate();
  await rejected;
  assert.equal((newSignal as AbortSignal | null)?.aborted, false);
  fresh.resolve(Response.json(status(session))); await second;
  old.resolve(Response.json({ lifecycle: { state: 'absent' }, generation: { state: 'idle' } }));
  assert.deepEqual(readExploreState(client).lifecycle, status(session).lifecycle);
});

test('client-session: inactive navigation state is evicted at the named retention bound', context => {
  context.mock.timers.enable({ apis: ['setTimeout'] });
  const client = sessionClient(context), observer = new QueryObserver(client, exploreStateOptions(client));
  const unsubscribe = observer.subscribe(() => {});
  unsubscribe();
  context.mock.timers.tick(EXPLORE_CLIENT_RETENTION_MS - 1);
  assert.ok(client.getQueryData(exploreStateKey));
  context.mock.timers.tick(1);
  assert.equal(client.getQueryData(exploreStateKey), undefined);
  context.mock.timers.reset();
});

test('client-session: metadata revocation cancels stale recovery and restoring a revision cannot revive its different-session response', async context => {
  const client = sessionClient(context), source = interest(), session = sessionFixture(source), replacement = sessionFixture(source);
  const wait = deferred<Response>(), started = deferred<void>();
  cacheMetadata(client, [source]);
  client.setQueryData(exploreStateKey, { ...readExploreState(client), ...status(session) });
  const unsubscribe = subscribeExploreMetadata(client);
  context.mock.method(globalThis, 'fetch', async () => { started.resolve(); return wait.promise; });
  try {
    const checking = new MutationObserver(client, exploreRecoveryOptions(client)).mutate();
    const rejected = assert.rejects(checking);
    await started.promise;
    cacheMetadata(client, []);
    cacheMetadata(client, [source]);
    await rejected;
    wait.resolve(Response.json(status(replacement))); await Promise.resolve();
    const state = readExploreState(client);
    assert.equal(state.lifecycle.state, 'available');
    if (state.lifecycle.state === 'available') {
      assert.equal(state.lifecycle.session.id, session.id);
      assert.ok(state.lifecycle.session.topics.every(topic => topic.status === 'obsolete'));
    }
  } finally { unsubscribe(); }
});

function previewOf(client: QueryClient, topicID: string): ExplorePreview {
  const state = readExploreState(client);
  assert.equal(state.lifecycle.state, 'available');
  if (state.lifecycle.state !== 'available') throw new Error('Expected available session');
  const topic = state.lifecycle.session.topics.find(topic => topic.id === topicID);
  assert.ok(topic);
  return topic.preview;
}
function searchResponse(session: ExploreSession, topicID: string, search?: ExploreSearch, empty = false) {
  const topic = session.topics.find(topic => topic.id === topicID)!;
  return exploreSearchResponseSchema.parse({ sessionID: session.id, sessionRevision: session.revision, topicID,
    preview: { state: empty ? 'successful-empty' : 'successful', result: {
      search: search ?? topic.proposedSearch, succeededAt: session.generatedAt,
      articles: empty ? [] : [{ id: 'fixture-' + topicID, title: topic.title + ' source report',
        url: 'https://example.org/news/' + topicID, source: 'Fixture publisher', summary: 'Retrieved source excerpt.',
        publishedAt: null, fetchedAt: session.generatedAt, summaryKind: 'source', feedIDs: [], topicIDs: [] }],
    } },
  });
}
function seedSession(client: QueryClient, session: ExploreSession) {
  client.setQueryData(exploreStateKey, acceptExploreSession(readExploreState(client), session, Date.now()));
}

test('client-preview: selection, draft editing, remount and metadata focus are local-only; invalid queries never fetch', async context => {
  const client = sessionClient(context), session = sessionFixture(), topic = session.topics[1];
  seedSession(client, session);
  let calls = 0;
  context.mock.method(globalThis, 'fetch', async () => { calls++; throw new Error('No network work'); });
  selectExploreTopic(client, topic.id);
  setExploreSearchDraft(client, topic.id, { ...topic.proposedSearch, language: 'en', query: '' });
  const observer = new QueryObserver(client, exploreStateOptions(client)), stop = observer.subscribe(() => {});
  try {
    client.getQueryCache().onFocus(); client.getQueryCache().onOnline(); await observer.refetch();
    const options = exploreSearchOptions(client);
    assert.equal(options.retry, false); assert.equal(options.gcTime, 0);
    await assert.rejects(new MutationObserver(client, options).mutate({ topicID: topic.id }), /at least 5 words|Too small/);
    assert.equal(readExploreState(client).selectedTopicID, topic.id);
    assert.equal(readExploreState(client).drafts[topic.id].query, '');
    assert.equal(previewOf(client, topic.id).state, 'not-searched');
    assert.deepEqual(readExploreState(client).searchRequestIDs, {}); assert.equal(calls, 0);
  } finally { stop(); }
});

test('client-preview: switching topics and out-of-order completion keep captured searches in their owning entries', async context => {
  const client = sessionClient(context), session = sessionFixture(), [a, b, c] = session.topics;
  seedSession(client, session);
  const waits = [deferred<Response>(), deferred<Response>()], started = deferred<void>();
  const captured: { url: unknown; body: unknown }[] = [];
  context.mock.method(client, 'invalidateQueries', () => { throw new Error('No broad refetch'); });
  context.mock.method(globalThis, 'fetch', async (url: unknown, init: RequestInit) => {
    assert.equal(init.method, 'POST');
    assert.deepEqual(init.headers, { 'X-Kontrol-Client': 'web', 'Content-Type': 'application/json' });
    captured.push({ url, body: JSON.parse(init.body as string) });
    if (captured.length === 2) started.resolve();
    return waits[captured.length - 1].promise;
  });
  const aSearch = { ...a.proposedSearch, query: 'district heating reuse local community policy news', language: 'en' as const, region: 'GB' as const, days: 7 as const };
  setExploreSearchDraft(client, a.id, aSearch);
  const aPending = new MutationObserver(client, exploreSearchOptions(client)).mutate({ topicID: a.id });
  selectExploreTopic(client, b.id);
  const bPending = new MutationObserver(client, exploreSearchOptions(client)).mutate({ topicID: b.id });
  await started.promise;
  await assert.rejects(new MutationObserver(client, exploreSearchOptions(client)).mutate({ topicID: c.id }), /Two topic searches/);
  setExploreSearchDraft(client, a.id, { ...aSearch, query: 'different draft while retrieved coverage is still pending' });
  waits[1].resolve(Response.json(searchResponse(session, b.id))); await bPending;
  assert.equal(previewOf(client, a.id).state, 'pending');
  assert.equal(previewOf(client, b.id).state, 'successful');
  waits[0].resolve(Response.json(searchResponse(session, a.id, aSearch))); await aPending;
  assert.equal(readExploreState(client).selectedTopicID, b.id);
  assert.deepEqual(retainedExploreResult(previewOf(client, a.id))?.search, aSearch);
  assert.deepEqual(retainedExploreResult(previewOf(client, b.id))?.search, b.proposedSearch);
  assert.equal(previewOf(client, c.id).state, 'not-searched');
  assert.deepEqual(captured, [
    { url: `/api/news/explore/${session.id}/topics/${a.id}/search`, body: { expectedSessionRevision: session.revision, search: aSearch } },
    { url: `/api/news/explore/${session.id}/topics/${b.id}/search`, body: { expectedSessionRevision: session.revision, search: b.proposedSearch } },
  ]);
  assert.deepEqual(readExploreState(client).searchRequestIDs, {});
});

test('client-preview: changed-query failure retains original producing parameters and timestamp; successful empty replaces coverage', async context => {
  const client = sessionClient(context), session = sessionFixture(), topic = session.topics[0];
  topic.preview = searchResponse(session, topic.id).preview;
  seedSession(client, session);
  const original = structuredClone(retainedExploreResult(topic.preview));
  const changed = { ...topic.proposedSearch, query: 'new district heat policy municipal technology news', region: 'GB' as const };
  setExploreSearchDraft(client, topic.id, changed);
  const wait = deferred<Response>(), started = deferred<void>();
  let calls = 0;
  context.mock.method(globalThis, 'fetch', async () => {
    calls++;
    if (calls === 1) { started.resolve(); return wait.promise; }
    return Response.json(searchResponse(session, topic.id, changed, true));
  });
  const command = new MutationObserver(client, exploreSearchOptions(client));
  const pending = command.mutate({ topicID: topic.id }); await started.promise;
  assert.deepEqual(retainedExploreResult(previewOf(client, topic.id)), original);
  wait.resolve(Response.json({ error: 'Standard search could not retrieve coverage.' }, { status: 502 }));
  await assert.rejects(pending, error => error instanceof ExploreCommandError && error.status === 502);
  const failed = previewOf(client, topic.id);
  assert.equal(failed.state, 'failed-retained');
  if (failed.state === 'failed-retained') { assert.deepEqual(failed.attempt.search, changed); assert.deepEqual(failed.previous, original); }
  assert.deepEqual(readExploreState(client).drafts[topic.id], changed);
  assert.deepEqual(readExploreState(client).searchRequestIDs, {});
  await command.mutate({ topicID: topic.id });
  const empty = previewOf(client, topic.id);
  assert.equal(empty.state, 'successful-empty'); assert.deepEqual(retainedExploreResult(empty)?.articles, []);
  assert.deepEqual(retainedExploreResult(empty)?.search, changed); assert.equal(calls, 2);
});

test('client-preview: duplicate submissions are synchronously gated across independent observers', async context => {
  const client = sessionClient(context), session = sessionFixture(), topic = session.topics[0], wait = deferred<Response>(), started = deferred<void>();
  seedSession(client, session);
  let calls = 0;
  context.mock.method(globalThis, 'fetch', async () => { calls++; started.resolve(); return wait.promise; });
  const options = exploreSearchOptions(client);
  const pending = new MutationObserver(client, options).mutate({ topicID: topic.id });
  await assert.rejects(new MutationObserver(client, options).mutate({ topicID: topic.id }), /Check local status/);
  await started.promise;
  assert.equal(calls, 1);
  wait.resolve(Response.json(searchResponse(session, topic.id))); await pending;
  assert.deepEqual(readExploreState(client).searchRequestIDs, {}); assert.equal(client.isMutating(), 0);
});

for (const stage of ['headers', 'body']) test(`client-preview: ${stage} deadline retains coverage as uncertain and requires explicit local recovery`, async context => {
  const client = sessionClient(context), session = sessionFixture(), topic = session.topics[0], wait = deferred<Response>();
  topic.preview = searchResponse(session, topic.id).preview; seedSession(client, session);
  const changed = { ...topic.proposedSearch, query: 'revised local heating infrastructure community technology news' };
  setExploreSearchDraft(client, topic.id, changed);
  let posts = 0, gets = 0, signal: AbortSignal | null = null;
  context.mock.method(globalThis, 'fetch', async (_url: unknown, init: RequestInit) => {
    if (init.method === 'GET') { gets++; return Response.json(status(session)); }
    posts++; signal = init.signal as AbortSignal;
    if (stage === 'headers') return wait.promise;
    const response = new Response(); response.json = () => wait.promise; return response;
  });
  const command = new MutationObserver(client, exploreSearchOptions(client, { searchTimeoutMs: 15 }));
  await assert.rejects(command.mutate({ topicID: topic.id }), error => error instanceof ExploreCommandError && error.outcome === 'uncertain');
  assert.equal((signal as AbortSignal | null)?.aborted, true);
  assert.equal(previewOf(client, topic.id).state, 'uncertain');
  assert.deepEqual(retainedExploreResult(previewOf(client, topic.id)), retainedExploreResult(topic.preview));
  await assert.rejects(command.mutate({ topicID: topic.id }), /Check local status/);
  assert.equal(posts, 1); assert.equal(gets, 0);
  await new MutationObserver(client, exploreRecoveryOptions(client)).mutate();
  assert.equal(previewOf(client, topic.id).state, 'successful');
  assert.deepEqual(readExploreState(client).drafts[topic.id], changed);
  const before = structuredClone(readExploreState(client));
  wait.resolve(Response.json(searchResponse(session, topic.id, changed, true))); await Promise.resolve();
  assert.deepEqual(readExploreState(client), before); assert.equal(posts, 1); assert.equal(gets, 1);
});

for (const change of ['replacement', 'revision', 'import', 'revocation', 'expiry', 'eviction']) test(`client-preview: ${change} rejects late search without resurrecting context`, async context => {
  const client = sessionClient(context), source = interest(), session = sessionFixture(source), topic = session.topics[0];
  cacheMetadata(client, [source]); seedSession(client, session);
  const wait = deferred<Response>(), started = deferred<void>();
  let now = Date.now(), calls = 0;
  context.mock.method(globalThis, 'fetch', async () => { calls++; started.resolve(); return wait.promise; });
  const pending = new MutationObserver(client, exploreSearchOptions(client, { now: () => now })).mutate({ topicID: topic.id });
  await started.promise;
  if (change === 'replacement') seedSession(client, sessionFixture(source));
  if (change === 'revision') seedSession(client, { ...session, revision: randomUUID() });
  if (change === 'import') clearExploreAfterImport(client);
  if (change === 'revocation') { reconcileExploreSources(client, []); reconcileExploreSources(client, [source]); }
  if (change === 'expiry') now = Date.parse(session.expiresAt);
  if (change === 'eviction') client.removeQueries({ queryKey: exploreStateKey, exact: true });
  const before = structuredClone(readExploreState(client, now));
  wait.resolve(Response.json(searchResponse(session, topic.id)));
  await assert.rejects(pending, error => error instanceof ExploreCommandError && error.outcome === 'stale');
  assert.deepEqual(readExploreState(client, now), before); assert.equal(calls, 1);
});

for (const mismatch of ['topic', 'session', 'revision', 'query', 'malformed', 'lost']) test(`client-preview: ${mismatch} response is uncertain and never becomes trusted coverage`, async context => {
  const client = sessionClient(context), session = sessionFixture(), topic = session.topics[0];
  seedSession(client, session);
  let calls = 0;
  context.mock.method(globalThis, 'fetch', async () => {
    calls++;
    const result = searchResponse(session, topic.id);
    if (mismatch === 'topic') result.topicID = session.topics[1].id;
    if (mismatch === 'session') result.sessionID = randomUUID();
    if (mismatch === 'revision') result.sessionRevision = randomUUID();
    if (mismatch === 'query' && 'result' in result.preview) result.preview.result.search = session.topics[1].proposedSearch;
    if (mismatch === 'lost') throw new Error('PRIVATE_TOKEN');
    return Response.json(mismatch === 'malformed' ? { ...result, arbitraryArticle: 'PRIVATE_TOKEN' } : result);
  });
  await assert.rejects(new MutationObserver(client, exploreSearchOptions(client)).mutate({ topicID: topic.id }), error =>
    error instanceof ExploreCommandError && error.outcome === 'uncertain' && !error.message.includes('PRIVATE_TOKEN'));
  assert.equal(previewOf(client, topic.id).state, 'uncertain');
  assert.equal(retainedExploreResult(previewOf(client, topic.id)), null); assert.equal(calls, 1);
});

test('client-preview: recovery snapshots during search cannot overwrite active preview or dirty drafts', async context => {
  const client = sessionClient(context), session = sessionFixture(), topic = session.topics[0], search = deferred<Response>(), started = deferred<void>();
  seedSession(client, session);
  let gets = 0, posts = 0;
  context.mock.method(globalThis, 'fetch', async (_url: unknown, init: RequestInit) => {
    if (init.method === 'GET') { gets++; return Response.json(status(session)); }
    posts++; started.resolve(); return search.promise;
  });
  const pending = new MutationObserver(client, exploreSearchOptions(client)).mutate({ topicID: topic.id }); await started.promise;
  const before = structuredClone(previewOf(client, topic.id));
  const dirty = { ...topic.proposedSearch, query: 'my newly edited regional heating infrastructure policy news' };
  setExploreSearchDraft(client, topic.id, dirty);
  await new MutationObserver(client, exploreRecoveryOptions(client)).mutate();
  assert.deepEqual(previewOf(client, topic.id), before);
  assert.deepEqual(readExploreState(client).drafts[topic.id], dirty);
  search.resolve(Response.json(searchResponse(session, topic.id))); await pending;
  assert.equal(previewOf(client, topic.id).state, 'successful'); assert.equal(gets, 1); assert.equal(posts, 1);
});

for (const timing of ['before admission', 'before completion']) test(`client-preview: stale recovery admitted ${timing} cannot roll back a search`, async context => {
  const client = sessionClient(context), session = sessionFixture(), topic = session.topics[0];
  seedSession(client, session);
  const search = deferred<Response>(), recovery = deferred<Response>(), searching = deferred<void>(), checking = deferred<void>();
  context.mock.method(globalThis, 'fetch', async (_url: unknown, init: RequestInit) => {
    if (init.method === 'GET') { checking.resolve(); return recovery.promise; }
    searching.resolve(); return search.promise;
  });
  let pending!: Promise<unknown>, check!: Promise<unknown>, rejected!: Promise<void>;
  if (timing === 'before admission') {
    check = new MutationObserver(client, exploreRecoveryOptions(client)).mutate(); rejected = assert.rejects(check); await checking.promise;
  }
  pending = new MutationObserver(client, exploreSearchOptions(client)).mutate({ topicID: topic.id }); await searching.promise;
  if (timing === 'before completion') {
    check = new MutationObserver(client, exploreRecoveryOptions(client)).mutate(); rejected = assert.rejects(check); await checking.promise;
  }
  search.resolve(Response.json(searchResponse(session, topic.id))); await pending; await rejected;
  recovery.resolve(Response.json(status(session))); await Promise.resolve();
  assert.equal(previewOf(client, topic.id).state, 'successful'); assert.equal(readExploreState(client).recovery.state, 'idle');
});

test('client-preview: conflict requires recovery; missing server session expires all entries with no automatic retry', async context => {
  const client = sessionClient(context), session = sessionFixture(), topic = session.topics[0];
  seedSession(client, session);
  let calls = 0;
  context.mock.method(globalThis, 'fetch', async (_url: unknown, init: RequestInit) => {
    calls++;
    if (init.method === 'GET') return Response.json(status(session));
    return Response.json({ error: calls === 1 ? 'Topic context changed. Check local status.' : 'Session expired. Request new ideas explicitly.' }, { status: calls === 1 ? 409 : 410 });
  });
  const command = new MutationObserver(client, exploreSearchOptions(client));
  await assert.rejects(command.mutate({ topicID: topic.id }), error => error instanceof ExploreCommandError && error.status === 409);
  assert.equal(previewOf(client, topic.id).state, 'uncertain');
  await assert.rejects(command.mutate({ topicID: topic.id }), /Check local status/); assert.equal(calls, 1);
  await new MutationObserver(client, exploreRecoveryOptions(client)).mutate();
  await assert.rejects(command.mutate({ topicID: topic.id }), error => error instanceof ExploreCommandError && error.status === 410);
  const state = readExploreState(client);
  assert.equal(state.lifecycle.state, 'expired'); assert.deepEqual(state.drafts, {}); assert.deepEqual(state.searchRequestIDs, {});
  await assert.rejects(command.mutate({ topicID: topic.id }), /session is unavailable/); assert.equal(calls, 3);
});

test('client-preview: named deadline, obsolete topics and expired sessions reject work locally', async context => {
  const client = sessionClient(context), session = sessionFixture();
  seedSession(client, session);
  let calls = 0;
  context.mock.method(globalThis, 'fetch', async () => { calls++; throw new Error('No network'); });
  assert.equal(EXPLORE_SEARCH_CLIENT_DEADLINE_MS, 30_000);
  assert.throws(() => exploreSearchOptions(client, { searchTimeoutMs: 30_001 }), /deadline/);
  assert.throws(() => exploreSearchOptions(client, { searchTimeoutMs: 0 }), /deadline/);
  reconcileExploreSources(client, []);
  await assert.rejects(new MutationObserver(client, exploreSearchOptions(client)).mutate({ topicID: session.topics[0].id }), /obsolete/);
  const now = Date.parse(session.expiresAt);
  await assert.rejects(new MutationObserver(client, exploreSearchOptions(client, { now: () => now })).mutate({ topicID: session.topics[0].id }), /session is unavailable/);
  assert.equal(readExploreState(client).lifecycle.state, 'expired'); assert.equal(calls, 0);
});

test('client-preview: local recovery of a changed lifecycle revision preserves unaffected dirty drafts and selection', async context => {
  const client = sessionClient(context), source = interest(), other = interest({ ...draft, name: 'Other source' });
  const session = sessionFixture(source), [revoked, kept] = session.topics;
  session.sources.push({ id: other.id, revision: other.revision });
  kept.sourceInterestID = other.id; kept.sourceInterestRevision = other.revision;
  seedSession(client, session); cacheMetadata(client, [source, other]);
  const dirty = { ...kept.proposedSearch, query: 'my reviewed regional grid storage infrastructure news' };
  setExploreSearchDraft(client, kept.id, dirty); selectExploreTopic(client, kept.id);
  const search = deferred<Response>(), started = deferred<void>();
  const recovered = structuredClone(session);
  recovered.revision = randomUUID();
  recovered.topics = recovered.topics.map(topic => topic.sourceInterestID === source.id ?
    { ...topic, status: 'obsolete', preview: { state: 'obsolete' } } : topic);
  let posts = 0, gets = 0;
  context.mock.method(globalThis, 'fetch', async (_url: unknown, init: RequestInit) => {
    if (init.method === 'GET') { gets++; return Response.json(status(recovered)); }
    posts++; started.resolve(); return search.promise;
  });
  const pending = new MutationObserver(client, exploreSearchOptions(client)).mutate({ topicID: kept.id }); await started.promise;
  cacheMetadata(client, [other]); reconcileExploreSources(client, [other]);
  await new MutationObserver(client, exploreRecoveryOptions(client)).mutate();
  assert.deepEqual(readExploreState(client).drafts[kept.id], dirty);
  assert.equal(readExploreState(client).selectedTopicID, kept.id);
  assert.equal(previewOf(client, revoked.id).state, 'obsolete');
  assert.equal(previewOf(client, kept.id).state, 'not-searched');
  assert.deepEqual(readExploreState(client).searchRequestIDs, {});
  search.resolve(Response.json(searchResponse(session, kept.id, dirty)));
  await assert.rejects(pending, error => error instanceof ExploreCommandError && error.outcome === 'stale');
  assert.equal(previewOf(client, kept.id).state, 'not-searched'); assert.equal(posts, 1); assert.equal(gets, 1);
});

test('client-preview: recovered server-pending search stays gated until a later explicit terminal status', async context => {
  const client = sessionClient(context), session = sessionFixture(), topic = session.topics[0];
  const attempted = { ...topic.proposedSearch, query: 'reviewed heating recovery regional infrastructure technology news' };
  const previous = retainedExploreResult(searchResponse(session, topic.id).preview);
  topic.preview = { state: 'uncertain', attempt: { requestID: randomUUID(), search: attempted, startedAt: session.generatedAt }, previous };
  seedSession(client, session);
  setExploreSearchDraft(client, topic.id, { ...attempted, query: 'my unsent new draft for local heating developments' });
  let gets = 0;
  context.mock.method(globalThis, 'fetch', async (_url: unknown, init: RequestInit) => {
    assert.equal(init.method, 'GET'); gets++;
    const recovered = structuredClone(session);
    if (gets === 1 && topic.preview.state === 'uncertain') recovered.topics[0].preview = { ...topic.preview, state: 'pending' };
    else recovered.topics[0].preview = searchResponse(session, topic.id, attempted, true).preview;
    return Response.json(status(recovered));
  });
  await new MutationObserver(client, exploreRecoveryOptions(client)).mutate();
  assert.equal(previewOf(client, topic.id).state, 'pending');
  await assert.rejects(new MutationObserver(client, exploreSearchOptions(client)).mutate({ topicID: topic.id }), /Check local status/);
  assert.equal(gets, 1);
  await new MutationObserver(client, exploreRecoveryOptions(client)).mutate();
  assert.equal(previewOf(client, topic.id).state, 'successful-empty');
  assert.deepEqual(retainedExploreResult(previewOf(client, topic.id))?.search, attempted);
  assert.notEqual(readExploreState(client).drafts[topic.id].query, attempted.query);
  assert.equal(gets, 2);
});
