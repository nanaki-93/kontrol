import test from 'node:test';
import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { MutationObserver, QueryClient, QueryObserver } from '@tanstack/react-query';
import {
  EXPLORE_CLIENT_RETENTION_MS, EXPLORE_GENERATION_CLIENT_DEADLINE_MS, EXPLORE_RECOVERY_CLIENT_DEADLINE_MS,
  EXPLORE_SESSION_TTL_MS, EXPLORE_SEARCH_CLIENT_DEADLINE_MS, EXPLORE_FOLLOW_CLIENT_DEADLINE_MS, exploreSessionSchema,
  exploreSearchResponseSchema, type ExploreSession, type ExplorePreview, type ExploreSearch,
} from '../shared/news-explore';
import {
  clearExploreAfterImport, ExploreCommandError, exploreGenerationOptions, exploreRecoveryOptions,
  exploreStateKey, exploreStateOptions, readExploreState, reconcileExploreSources, selectExploreTopic, subscribeExploreMetadata,
  exploreSearchOptions, setExploreSearchDraft, beginExploreFollowReview, cancelExploreFollowReview, setExploreFollowDraft, exploreFollowOptions,
} from '../src/modules/news/explore-api';
import { acceptExploreSession, emptyExploreState, updateExplorePreview, retainedExploreResult, exploreFollowNextAction, type ExploreClientState, type ExploreStatus } from '../src/modules/news/explore-state';
import { interestDraftSchema, type InterestDraft, type NewsInterest, type NewsResponse } from '../shared/news';
import {
  createInterestEditorState, createInterestEditorSubmission, interestEditorIdentity,
  saveInterestEditor, validateInterestEditorDraft, type InterestEditorInput,
} from '../src/modules/news/interest-editor';

import { navigateNewsView, newsViewFromHash } from '../src/modules/news';
import { exploreGalleryModel } from '../src/modules/news/explore';
import { exploreReadingPreviewModel } from '../src/modules/news/explore-preview';

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

function followFixture(client: QueryClient, source = interest()) {
  const session = sessionFixture(source), topic = session.topics[0];
  topic.preview = searchResponse(session, topic.id).preview;
  const news: NewsResponse = { preferences: { selectedTopicIDs: [], feeds: [] }, articles: [], lastRefreshAt: null, errors: {},
    discovery: { preferences: { schemaVersion: 1, interests: [source] }, articles: [], runs: {} },
    ai: { configured: true, provider: 'pi', model: 'fixture', message: 'Fixture only.' }, activity: { discovering: false, refreshingFeeds: false } };
  client.setQueryData(['news'], news); seedSession(client, session);
  const review = beginExploreFollowReview(client, topic.id);
  return { source, session, topic, review };
}
function followOf(client: QueryClient, topicID: string) { return readExploreState(client).followReviews[topicID]; }

test('client-follow: review prefill uses reviewed search, news intent and empty filters; opening and cancel are local-only', context => {
  const client = sessionClient(context), source = interest(), session = sessionFixture(source), topic = session.topics[0];
  seedSession(client, session); cacheMetadata(client, [source]);
  const search: ExploreSearch = { query: 'my reviewed district heating policy community infrastructure news', language: 'en', region: 'GB', days: 7 };
  setExploreSearchDraft(client, topic.id, search);
  let calls = 0;
  context.mock.method(globalThis, 'fetch', async () => { calls++; throw new Error('No work allowed'); });
  const before = structuredClone(readExploreState(client).lifecycle), review = beginExploreFollowReview(client, topic.id);
  assert.deepEqual(review.draft, { name: topic.title, ...search, intent: 'news', enabled: true, requiredTerms: [], excludedTerms: [] });
  assert.equal(interestDraftSchema.safeParse(review.draft).success, true);
  assert.equal(review.outcome.state, 'idle'); assert.equal(review.submittedDraft, null);
  assert.notEqual(review.reviewID, review.submissionID);
  assert.deepEqual(beginExploreFollowReview(client, topic.id), review);
  assert.equal(cancelExploreFollowReview(client, review.reviewID), true);
  assert.equal(readExploreState(client).activeFollowTopicID, null);
  assert.deepEqual(readExploreState(client).lifecycle, before);
  assert.deepEqual(beginExploreFollowReview(client, topic.id), review); assert.equal(calls, 0);
});

test('client-follow: dirty fields and identity survive topic switching, remount and explicit local recovery', async context => {
  const client = sessionClient(context), { session, topic, review } = followFixture(client);
  const dirty = { ...review.draft, name: 'My chosen direction', enabled: false, intent: 'opportunities' as const,
    region: 'PH' as const, days: 1 as const, requiredTerms: ['reviewed|terms'], excludedTerms: ['unwanted'] };
  setExploreFollowDraft(client, review.reviewID, dirty);
  selectExploreTopic(client, session.topics[1].id); beginExploreFollowReview(client, session.topics[1].id);
  setExploreSearchDraft(client, topic.id, { ...topic.proposedSearch, query: 'changed search does not replace the reviewed interest draft' });
  let gets = 0;
  context.mock.method(globalThis, 'fetch', async (_url: unknown, init: RequestInit) => {
    gets++; assert.equal(init.method, 'GET'); return Response.json(status(session));
  });
  await new MutationObserver(client, exploreRecoveryOptions(client)).mutate();
  const observer = new QueryObserver(client, exploreStateOptions(client)), stop = observer.subscribe(() => {});
  try {
    const reopened = beginExploreFollowReview(client, topic.id);
    assert.equal(reopened.reviewID, review.reviewID); assert.equal(reopened.submissionID, review.submissionID);
    assert.deepEqual(reopened.draft, dirty); assert.equal(gets, 1);
  } finally { stop(); }
});

for (const created of [true, false]) test(`client-follow: ${created ? 'created' : 'already-followed'} success reconciles metadata and exposes Discover without searches or preview changes`, async context => {
  const client = sessionClient(context), { session, topic, review } = followFixture(client);
  const saved = interest({ ...review.draft, name: created ? review.draft.name : 'Existing equivalent name' });
  const before = structuredClone(readExploreState(client).lifecycle), newsBefore = structuredClone(client.getQueryData<NewsResponse>(['news'])!);
  if (!created) client.setQueryData<NewsResponse>(['news'], { ...newsBefore, discovery: { ...newsBefore.discovery,
    preferences: { ...newsBefore.discovery.preferences, interests: [...newsBefore.discovery.preferences.interests, saved] } } });
  const captured: unknown[] = [];
  context.mock.method(client, 'invalidateQueries', () => { throw new Error('No automatic refetch'); });
  context.mock.method(globalThis, 'fetch', async (url: unknown, init: RequestInit) => {
    captured.push(url); assert.equal(url, `/api/news/explore/${session.id}/topics/${topic.id}/follow`);
    assert.equal(init.method, 'POST'); assert.deepEqual(init.headers, { 'X-Kontrol-Client': 'web', 'Content-Type': 'application/json' });
    assert.deepEqual(JSON.parse(init.body as string), { expectedSessionRevision: session.revision, submissionID: review.submissionID, draft: review.draft });
    return Response.json({ interest: saved, created });
  });
  const options = exploreFollowOptions(client);
  assert.equal(options.retry, false); assert.equal(options.gcTime, 0); assert.equal(options.networkMode, 'always');
  const command = new MutationObserver(client, options), variables = { topicID: topic.id, reviewID: review.reviewID, draft: review.draft };
  assert.deepEqual(await command.mutate(variables), { interest: saved, created });
  assert.deepEqual(await command.mutate(variables), { interest: saved, created });
  assert.equal(followOf(client, topic.id).outcome.state, 'successful');
  assert.deepEqual(readExploreState(client).lifecycle, before);
  const news = client.getQueryData<NewsResponse>(['news'])!;
  assert.equal(news.discovery.preferences.interests.filter(item => item.id === saved.id).length, 1);
  assert.deepEqual(news.discovery.articles, newsBefore.discovery.articles); assert.deepEqual(news.discovery.runs, newsBefore.discovery.runs);
  assert.deepEqual(news.articles, newsBefore.articles); assert.deepEqual(news.preferences, newsBefore.preferences);
  assert.deepEqual(exploreFollowNextAction, { href: '#/news?view=discover', label: 'Search this interest in Discover' });
  await assert.rejects(command.mutate({ ...variables, draft: { ...review.draft, name: 'Changed after success' } }), /already followed/);
  assert.equal(captured.length, 1); assert.equal(client.isMutating(), 0);
});

test('client-follow: synchronous admission gates observers and prevents cancel or draft changes during submission', async context => {
  const client = sessionClient(context), { topic, review } = followFixture(client), wait = deferred<Response>(), started = deferred<void>();
  let calls = 0;
  context.mock.method(globalThis, 'fetch', async () => { calls++; started.resolve(); return wait.promise; });
  const options = exploreFollowOptions(client), variables = { topicID: topic.id, reviewID: review.reviewID, draft: review.draft };
  const pending = new MutationObserver(client, options).mutate(variables);
  await assert.rejects(new MutationObserver(client, options).mutate(variables), /already running/);
  assert.equal(cancelExploreFollowReview(client, review.reviewID), false);
  setExploreFollowDraft(client, review.reviewID, { ...review.draft, name: 'Not approved yet' });
  assert.deepEqual(followOf(client, topic.id).draft, review.draft);
  await started.promise; assert.equal(calls, 1);
  wait.resolve(Response.json({ interest: interest(review.draft), created: true })); await pending;
  assert.equal(followOf(client, topic.id).outcome.state, 'successful'); assert.equal(calls, 1);
});

for (const statusCode of [400, 409, 410]) test(`client-follow: ${statusCode} capacity/conflict/expiry preserves approved draft without automatic retries`, async context => {
  const client = sessionClient(context), { topic, review } = followFixture(client);
  const dirty = { ...review.draft, name: 'My approved direction', requiredTerms: ['heat|district'] };
  let calls = 0;
  const before = structuredClone(client.getQueryData(['news']));
  context.mock.method(globalThis, 'fetch', async () => { calls++; return Response.json({ error: 'Fixture follow capacity, conflict or expiry.' }, { status: statusCode }); });
  await assert.rejects(new MutationObserver(client, exploreFollowOptions(client)).mutate({ topicID: topic.id, reviewID: review.reviewID, draft: dirty }),
    error => error instanceof ExploreCommandError && error.status === statusCode);
  const failed = followOf(client, topic.id);
  assert.deepEqual(failed.draft, dirty); assert.deepEqual(failed.submittedDraft, dirty); assert.equal(failed.submissionID, review.submissionID);
  assert.equal(failed.outcome.state, statusCode === 410 ? 'expired' : 'failed'); assert.equal(calls, 1);
  assert.deepEqual(client.getQueryData(['news']), before);
  if (statusCode === 410) {
    assert.equal(readExploreState(client).lifecycle.state, 'expired');
    await assert.rejects(new MutationObserver(client, exploreFollowOptions(client)).mutate({ topicID: topic.id, reviewID: review.reviewID, draft: dirty }), /superseded/);
    assert.equal(calls, 1);
  }
});

test('client-follow: corrected explicit retry after confirmed rejection changes token; unchanged retry keeps it', async context => {
  const client = sessionClient(context), { topic, review } = followFixture(client);
  const tokens: string[] = [], drafts: InterestDraft[] = [];
  context.mock.method(globalThis, 'fetch', async (_url: unknown, init: RequestInit) => {
    const body = JSON.parse(init.body as string); tokens.push(body.submissionID); drafts.push(body.draft);
    return tokens.length < 3 ? Response.json({ error: 'At capacity.' }, { status: 400 }) : Response.json({ interest: interest(body.draft), created: true });
  });
  const command = new MutationObserver(client, exploreFollowOptions(client)), variables = { topicID: topic.id, reviewID: review.reviewID, draft: review.draft };
  await assert.rejects(command.mutate(variables), /capacity/); await assert.rejects(command.mutate(variables), /capacity/);
  const edited = { ...review.draft, name: 'Corrected', enabled: false };
  await command.mutate({ ...variables, draft: edited });
  assert.equal(tokens[0], review.submissionID); assert.equal(tokens[1], tokens[0]); assert.notEqual(tokens[2], tokens[0]);
  assert.deepEqual(drafts, [review.draft, review.draft, edited]);
});

for (const failure of ['headers', 'body', 'lost', 'malformed', 'mismatch']) test(`client-follow: ${failure} uncertain outcome preserves receipt through cancel/recovery and explicit same-payload replay`, async context => {
  const client = sessionClient(context), { session, topic, review } = followFixture(client), wait = deferred<Response>();
  const saved = interest(review.draft), payloads: unknown[] = [];
  let posts = 0, gets = 0, signal: AbortSignal | null = null;
  context.mock.method(globalThis, 'fetch', async (_url: unknown, init: RequestInit) => {
    if (init.method === 'GET') { gets++; return Response.json(status(session)); }
    posts++; payloads.push(JSON.parse(init.body as string)); signal = init.signal as AbortSignal;
    if (posts > 1) return Response.json({ interest: saved, created: true });
    if (failure === 'lost') throw new Error('PRIVATE_PROVIDER_TOKEN');
    if (failure === 'malformed') return Response.json({ interest: 'PRIVATE_PROVIDER_TOKEN' });
    if (failure === 'mismatch') return Response.json({ interest: interest(draft), created: true });
    if (failure === 'headers') return wait.promise;
    const response = new Response(); response.json = () => wait.promise; return response;
  });
  const command = new MutationObserver(client, exploreFollowOptions(client, { followTimeoutMs: 15 }));
  const variables = { topicID: topic.id, reviewID: review.reviewID, draft: review.draft };
  await assert.rejects(command.mutate(variables), error => error instanceof ExploreCommandError && error.outcome === 'uncertain' && !error.message.includes('PRIVATE'));
  assert.equal((signal as AbortSignal | null)?.aborted, true);
  assert.equal(followOf(client, topic.id).outcome.state, 'uncertain');
  assert.equal(cancelExploreFollowReview(client, review.reviewID), true);
  assert.equal(beginExploreFollowReview(client, topic.id).submissionID, review.submissionID);
  await new MutationObserver(client, exploreRecoveryOptions(client)).mutate();
  // GET has no follow receipts: it cannot permit a new payload/token after response loss.
  assert.equal(followOf(client, topic.id).outcome.state, 'uncertain');
  await assert.rejects(command.mutate({ ...variables, draft: { ...review.draft, name: 'Changed' } }), /original approved draft/);
  assert.equal(posts, 1); assert.equal(gets, 1);
  await command.mutate(variables);
  assert.deepEqual(payloads[1], payloads[0]); assert.equal(followOf(client, topic.id).outcome.state, 'successful');
  const before = structuredClone(readExploreState(client));
  wait.resolve(Response.json({ interest: interest(review.draft), created: true })); await Promise.resolve();
  assert.deepEqual(readExploreState(client), before); assert.equal(posts, 2); assert.equal(gets, 1);
});

for (const change of ['replacement', 'revision', 'revocation', 'import', 'expiry', 'eviction']) test(`client-follow: ${change} rejects late follow without resurrecting metadata or preview context`, async context => {
  const client = sessionClient(context), { source, session, topic, review } = followFixture(client), wait = deferred<Response>(), started = deferred<void>();
  let now = Date.now();
  context.mock.method(globalThis, 'fetch', async () => { started.resolve(); return wait.promise; });
  const pending = new MutationObserver(client, exploreFollowOptions(client, { now: () => now })).mutate({ topicID: topic.id, reviewID: review.reviewID, draft: review.draft });
  await started.promise;
  if (change === 'replacement') seedSession(client, sessionFixture(source));
  if (change === 'revision') seedSession(client, { ...session, revision: randomUUID() });
  if (change === 'revocation') { reconcileExploreSources(client, []); reconcileExploreSources(client, [source]); }
  if (change === 'import') clearExploreAfterImport(client);
  if (change === 'expiry') now = Date.parse(session.expiresAt);
  if (change === 'eviction') client.removeQueries({ queryKey: exploreStateKey, exact: true });
  const before = structuredClone(readExploreState(client, now)), metadata = structuredClone(client.getQueryData(['news']));
  wait.resolve(Response.json({ interest: interest(review.draft), created: true }));
  await assert.rejects(pending, error => error instanceof ExploreCommandError && error.outcome === 'stale');
  assert.deepEqual(readExploreState(client, now), before); assert.deepEqual(client.getQueryData(['news']), metadata);
  if (change !== 'import' && change !== 'eviction') assert.deepEqual(followOf(client, topic.id).draft, review.draft);
});

test('client-follow: named bounds, invalid drafts and stale editor identities reject commands before fetching', async context => {
  const client = sessionClient(context), { source, session, topic, review } = followFixture(client);
  let calls = 0;
  context.mock.method(globalThis, 'fetch', async () => { calls++; throw new Error('No work allowed'); });
  assert.equal(EXPLORE_FOLLOW_CLIENT_DEADLINE_MS, 15_000);
  assert.throws(() => exploreFollowOptions(client, { followTimeoutMs: 15_001 }), /deadline/);
  assert.throws(() => exploreFollowOptions(client, { followTimeoutMs: 0 }), /deadline/);
  const command = new MutationObserver(client, exploreFollowOptions(client));
  await assert.rejects(command.mutate({ topicID: topic.id, reviewID: review.reviewID, draft: { ...review.draft, language: 'en', query: 'too short' } }), /at least 5 words/);
  await assert.rejects(command.mutate({ topicID: topic.id, reviewID: randomUUID(), draft: review.draft }), /superseded/);
  for (const item of session.topics) beginExploreFollowReview(client, item.id);
  assert.equal(Object.keys(readExploreState(client).followReviews).length, 3);
  const replacement = sessionFixture(source); seedSession(client, replacement);
  beginExploreFollowReview(client, replacement.topics[0].id);
  assert.equal(Object.keys(readExploreState(client).followReviews).length, 1); assert.equal(calls, 0);
});

test('client-follow: a rejected uncertainty replay cannot unlock a new payload or erase the original receipt', async context => {
  const client = sessionClient(context), { topic, review } = followFixture(client);
  const payloads: unknown[] = [];
  context.mock.method(globalThis, 'fetch', async (_url: unknown, init: RequestInit) => {
    payloads.push(JSON.parse(init.body as string));
    if (payloads.length === 1) throw new Error('Lost response');
    if (payloads.length === 2) return Response.json({ error: 'Fixture conflict.' }, { status: 409 });
    if (payloads.length === 3) return Response.json({ error: 'Fixture capacity.' }, { status: 400 });
    return Response.json({ interest: interest(review.draft), created: true });
  });
  const command = new MutationObserver(client, exploreFollowOptions(client));
  const variables = { topicID: topic.id, reviewID: review.reviewID, draft: review.draft };
  await assert.rejects(command.mutate(variables), /original approved submission/);
  await assert.rejects(command.mutate(variables), error => error instanceof ExploreCommandError && error.outcome === 'uncertain' && error.status === 409);
  assert.equal(followOf(client, topic.id).outcome.state, 'uncertain');
  const edited = { ...review.draft, name: 'Unsent new draft' };
  setExploreFollowDraft(client, review.reviewID, edited);
  await assert.rejects(command.mutate({ ...variables, draft: edited }), /original approved draft/);
  assert.deepEqual(followOf(client, topic.id).draft, edited);
  assert.equal(payloads.length, 2);
  await assert.rejects(command.mutate(variables), error => error instanceof ExploreCommandError && error.outcome === 'uncertain' && error.status === 400);
  assert.deepEqual(followOf(client, topic.id).draft, edited);
  assert.equal(followOf(client, topic.id).submissionID, review.submissionID);
  await command.mutate(variables);
  assert.deepEqual(payloads, [payloads[0], payloads[0], payloads[0], payloads[0]]);
});

test('client-follow: recovery of an unaffected topic under a new session revision retains its uncertain receipt and dirty draft', async context => {
  const client = sessionClient(context), { session, topic, review } = followFixture(client), old = deferred<Response>(), started = deferred<void>();
  const recovered = { ...session, revision: randomUUID() }, saved = interest(review.draft);
  const requests: { submissionID: string; expectedSessionRevision: string }[] = [];
  context.mock.method(globalThis, 'fetch', async (_url: unknown, init: RequestInit) => {
    if (init.method === 'GET') return Response.json(status(recovered));
    requests.push(JSON.parse(init.body as string));
    if (requests.length === 1) { started.resolve(); return old.promise; }
    return Response.json({ interest: saved, created: true });
  });
  const command = new MutationObserver(client, exploreFollowOptions(client)), variables = { topicID: topic.id, reviewID: review.reviewID, draft: review.draft };
  const pending = command.mutate(variables); await started.promise;
  await new MutationObserver(client, exploreRecoveryOptions(client)).mutate();
  const kept = beginExploreFollowReview(client, topic.id);
  assert.equal(kept.outcome.state, 'uncertain'); assert.equal(kept.reviewID, review.reviewID);
  assert.equal(kept.submissionID, review.submissionID); assert.deepEqual(kept.draft, review.draft);
  assert.equal(kept.sessionRevision, recovered.revision);
  old.resolve(Response.json({ interest: saved, created: true }));
  await assert.rejects(pending, error => error instanceof ExploreCommandError && error.outcome === 'stale');
  assert.equal(followOf(client, topic.id).outcome.state, 'uncertain');
  await command.mutate(variables);
  assert.equal(requests[0].submissionID, requests[1].submissionID);
  assert.equal(requests[1].expectedSessionRevision, recovered.revision);
});

test('client-follow: expiry learned from a preview command also revokes reviews while preserving drafts', async context => {
  const client = sessionClient(context), { topic, review } = followFixture(client);
  context.mock.method(globalThis, 'fetch', async () => Response.json({ error: 'Session gone.' }, { status: 410 }));
  await assert.rejects(new MutationObserver(client, exploreSearchOptions(client)).mutate({ topicID: topic.id }), /Session gone/);
  assert.equal(followOf(client, topic.id).outcome.state, 'expired');
  assert.deepEqual(followOf(client, topic.id).draft, review.draft);
});

test('client-follow: an old News poll is cancelled so it cannot roll back the returned interest', async context => {
  const client = sessionClient(context), { source, topic, review } = followFixture(client), staleNews = deferred<NewsResponse>();
  const old = structuredClone(client.getQueryData<NewsResponse>(['news'])!), saved = interest(review.draft);
  let pollSignal: AbortSignal | null = null;
  const polling = client.fetchQuery({ queryKey: ['news'], queryFn: ({ signal }) => { pollSignal = signal; return staleNews.promise; } });
  assert.equal(client.getQueryState(['news'])?.fetchStatus, 'fetching');
  context.mock.method(globalThis, 'fetch', async () => Response.json({ interest: saved, created: true }));
  await new MutationObserver(client, exploreFollowOptions(client)).mutate({ topicID: topic.id, reviewID: review.reviewID, draft: review.draft });
  await polling; // Silent query cancellation resolves cached data, not a mutation failure.
  assert.equal((pollSignal as AbortSignal | null)?.aborted, true);
  staleNews.resolve(old); await Promise.resolve();
  assert.deepEqual(client.getQueryData<NewsResponse>(['news'])!.discovery.preferences.interests, [source, saved]);
});

function galleryNews(interests: NewsInterest[], configured = true): NewsResponse {
  return { preferences: { selectedTopicIDs: [], feeds: [] }, articles: [], lastRefreshAt: null, errors: {},
    discovery: { preferences: { schemaVersion: 1, interests }, articles: [], runs: {} },
    ai: { configured, provider: 'pi', model: 'fixture', message: 'Fixture only.' },
    activity: { discovering: false, refreshingFeeds: false } };
}

test('gallery: Explore route is supported without changing existing routes or briefing fallback', () => {
  for (const view of ['discover', 'feeds', 'saved', 'explore'] as const) {
    assert.equal(newsViewFromHash('#/news?view=' + view), view);
    assert.equal(newsViewFromHash('#/news?other=value&view=' + view), view);
  }
  for (const hash of ['#/news', '#/news?view=briefing', '#/news?view=unknown', '#/news?view=Explore', '#/news?view=']) {
    assert.equal(newsViewFromHash(hash), 'briefing');
  }
});

test('gallery: Discover to Explore updates the hash so Discover recovery is not a same-URL no-op', context => {
  const client = sessionClient(context), source = interest(), session = sessionFixture(source);
  client.setQueryData(exploreStateKey, acceptExploreSession(readExploreState(client), session, Date.now()));
  selectExploreTopic(client, session.topics[1].id);
  const before = structuredClone(readExploreState(client));
  let calls = 0;
  context.mock.method(globalThis, 'fetch', async () => { calls++; throw new Error('Navigation must not request news or PI'); });
  // A location-shaped value exercises the same tab command without a DOM or app.
  const location = { hash: '#/news?view=discover' };
  navigateNewsView('explore', location);
  assert.equal(location.hash, '#/news?view=explore');
  assert.equal(newsViewFromHash(location.hash), 'explore');
  const discoverRecoveryHref = '#/news?view=discover'; // Both Explore recovery links.
  assert.notEqual(location.hash, discoverRecoveryHref);
  location.hash = discoverRecoveryHref;
  assert.equal(newsViewFromHash(location.hash), 'discover');
  for (const view of ['briefing', 'discover', 'explore', 'saved', 'feeds'] as const) {
    navigateNewsView(view, location);
    assert.equal(location.hash, view === 'briefing' ? '#/news' : '#/news?view=' + view);
    assert.equal(newsViewFromHash(location.hash), view);
  }
  assert.deepEqual(readExploreState(client), before);
  assert.equal(calls, 0);
});

test('gallery: three or fewer cards show source connections and never invent filler', context => {
  const client = sessionClient(context), source = interest(), news = galleryNews([source]);
  const session = sessionFixture(source);
  for (const count of [1, 2, 3]) {
    const partial = { ...session, topics: session.topics.slice(0, count) };
    const state = acceptExploreSession(readExploreState(client), partial, Date.now());
    const model = exploreGalleryModel(state, news);
    assert.equal(model.cards.length, count);
    assert.deepEqual(model.cards.map(card => card.title), partial.topics.map(topic => topic.title));
    assert.ok(model.cards.every(card => card.sourceLabel === source.name && card.connection === 'Connected to computing infrastructure.'));
    assert.equal(model.cards.filter(card => card.selected).length, 1);
    assert.equal(model.notices.some(notice => /No filler/.test(notice)), count < 3);
  }
});

test('gallery: restoring and selecting cards changes only cached selection, with zero requests', context => {
  const client = sessionClient(context), source = interest(), news = galleryNews([source]), session = sessionFixture(source);
  let calls = 0;
  context.mock.method(globalThis, 'fetch', async () => { calls++; throw new Error('No gallery network work'); });
  assert.equal(exploreGalleryModel(readExploreState(client), news).cards.length, 0);
  client.setQueryData(exploreStateKey, acceptExploreSession(readExploreState(client), session, Date.now()));
  const before = structuredClone(readExploreState(client));
  selectExploreTopic(client, session.topics[2].id);
  const after = readExploreState(client), model = exploreGalleryModel(after, news);
  assert.equal(model.cards[2].selected, true);
  assert.equal(model.cards[0].selected, false);
  assert.deepEqual(after.lifecycle, before.lifecycle);
  assert.deepEqual(after.drafts, before.drafts);
  assert.deepEqual(after.generation, before.generation);
  assert.equal(calls, 0);
});

test('gallery: local settings, no interests and PI setup map to deliberate actions', context => {
  const state = readExploreState(sessionClient(context)), source = interest();
  const loading = exploreGalleryModel(state);
  assert.equal(loading.canGenerate, false); assert.equal(loading.canRecover, true);
  assert.equal(loading.needsInterests, false); assert.equal(loading.needsPI, false);
  const none = exploreGalleryModel(state, galleryNews([interest({ ...draft, enabled: false })]));
  assert.equal(none.needsInterests, true); assert.equal(none.canGenerate, false);
  assert.deepEqual(none.enabledNames, []);
  const setup = exploreGalleryModel(state, galleryNews([source], false));
  assert.equal(setup.needsPI, true); assert.equal(setup.canGenerate, false);
  const ready = exploreGalleryModel(state, galleryNews([source, interest({ ...draft, name: 'Paused', enabled: false })]));
  assert.equal(ready.canGenerate, true); assert.deepEqual(ready.enabledNames, [source.name]);
});

test('gallery: generation pending, no-valid failure and uncertainty retain cards and expose recovery', context => {
  const client = sessionClient(context), source = interest(), news = galleryNews([source]);
  const state = acceptExploreSession(readExploreState(client), sessionFixture(source), Date.now());
  const pending = exploreGalleryModel({ ...state, generation: { state: 'pending', requestID: randomUUID(), startedAt: new Date().toISOString() } }, news);
  assert.equal(pending.canGenerate, false); assert.equal(pending.canRecover, true);
  assert.match(pending.generationLabel, /Suggesting/); assert.equal(pending.cards.length, 3);
  assert.ok(pending.notices.some(notice => /Previous ideas remain visible/.test(notice)));
  const failed = exploreGalleryModel({ ...state, generation: { state: 'failed', error: { code: 'no-valid-ideas', error: 'No usable distinct topic ideas.' } } }, news);
  assert.equal(failed.canGenerate, true); assert.equal(failed.cards.length, 3);
  assert.equal(failed.generationError, 'No usable distinct topic ideas.');
  assert.ok(failed.notices.some(notice => /new request failed/.test(notice)));
  const uncertain = exploreGalleryModel({ ...state, generation: { state: 'uncertain' } }, news);
  assert.equal(uncertain.canGenerate, false); assert.equal(uncertain.canRecover, true);
  assert.ok(uncertain.notices.some(notice => /outcome is unknown/.test(notice)));
  const recovering = exploreGalleryModel({ ...state, recovery: { state: 'pending', requestID: randomUUID() } }, news);
  assert.equal(recovering.canGenerate, false); assert.equal(recovering.canRecover, false);
  const recoveryFailed = exploreGalleryModel({ ...state, recovery: { state: 'failed', error: 'Local status unavailable.' } }, news);
  assert.equal(recoveryFailed.recoveryError, 'Local status unavailable.'); assert.equal(recoveryFailed.canRecover, true);
});

test('gallery: obsolete source labels never borrow edited interest context; expiry offers explicit recovery', context => {
  const client = sessionClient(context), source = interest(), session = sessionFixture(source);
  const state = acceptExploreSession(readExploreState(client), session, Date.now());
  const changed = galleryNews([{ ...source, revision: randomUUID(), name: 'Unrelated replacement' }]);
  const beforeReconciliation = exploreGalleryModel(state, changed);
  assert.ok(beforeReconciliation.cards.every(card => !card.selectable && !card.sourceLabel.includes('Unrelated')));
  for (const lifecycle of [{ state: 'expired' }, { state: 'obsolete' }] as const) {
    const model = exploreGalleryModel({ ...state, lifecycle }, galleryNews([source]));
    assert.equal(model.cards.length, 0); assert.equal(model.canRecover, true); assert.equal(model.canGenerate, true);
    assert.ok(model.notices.some(notice => /explicitly/.test(notice)));
  }
});

function readingFixture() {
  const source = interest(), session = sessionFixture(source);
  const state = acceptExploreSession(emptyExploreState(), session, Date.now());
  const topic = session.topics[0];
  const preview = searchResponse(session, topic.id).preview;
  const result = retainedExploreResult(preview)!;
  const attempt = { requestID: randomUUID(), startedAt: new Date(Date.parse(result.succeededAt) + 1_000).toISOString(),
    search: { query: 'regional water cooling infrastructure policy coverage developments', language: 'en' as const, region: 'US' as const, days: 7 as const } };
  return { source, session, state, topic, result, attempt, news: galleryNews([source]) };
}

test('reading-preview: never searched shows reviewable defaults without PI requirements or any requests', context => {
  const { state, topic, news } = readingFixture();
  context.mock.method(globalThis, 'fetch', () => { throw new Error('Presentation must not request anything'); });
  const model = exploreReadingPreviewModel(state, { ...news, ai: { ...news.ai, configured: false } });
  assert.equal(model.topic?.id, topic.id);
  assert.deepEqual(model.search, topic.proposedSearch);
  assert.equal(model.previewState, 'not-searched');
  assert.match(model.message!, /No search yet/);
  assert.equal(model.canSearch, true); assert.equal(model.editable, true);
  assert.equal(model.result, null); assert.equal(model.attempt, null);
  assert.deepEqual(model.groups, []);
  assert.match(model.searchLabel, /Standard/);
  assert.equal(model.sourceLabel, news.discovery.preferences.interests[0].name);
});

test('reading-preview: producing query, locale and exact last-success time stay separate from edited draft and failed attempt', () => {
  const { state, topic, result, attempt, news } = readingFixture();
  const failed = updateExplorePreview({ ...state, drafts: { ...state.drafts, [topic.id]: { ...attempt.search, days: 1 } } }, topic.id,
    { state: 'failed-retained', previous: result, attempt, error: { code: 'search-failed', error: 'Standard search failed.' } }, null);
  const model = exploreReadingPreviewModel(failed, news);
  assert.equal(model.previewState, 'failed-retained');
  assert.equal(model.retained, true); assert.equal(model.canSearch, true);
  assert.equal(model.result, result); assert.equal(model.result?.succeededAt, result.succeededAt);
  assert.deepEqual(model.result?.search, topic.proposedSearch);
  assert.deepEqual(model.attempt?.search, attempt.search);
  assert.equal(model.attempt?.startedAt, attempt.startedAt);
  assert.equal(model.search?.days, 1); assert.equal(model.draftDiffers, true);
  assert.equal(model.error, 'Standard search failed.');
  assert.match(model.message!, /Previous same-topic coverage is retained/);
  assert.match(model.message!, /not the failed attempt/);
});

test('reading-preview: pending, failed and uncertain searches are distinct and recovery never silently retries', () => {
  const { state, topic, result, attempt, news } = readingFixture();
  for (const preview of [
    { state: 'pending', attempt, previous: result },
    { state: 'failed', attempt, error: { code: 'search-failed', error: 'No connection.' } },
    { state: 'uncertain', attempt, previous: result },
  ] satisfies ExplorePreview[]) {
    const model = exploreReadingPreviewModel(updateExplorePreview(state, topic.id, preview, null), news);
    assert.equal(model.previewState, preview.state);
    assert.equal(model.canSearch, preview.state === 'failed');
    assert.equal(model.canRecover, true);
    assert.equal(model.result, preview.state === 'failed' ? null : result);
    assert.equal(model.retained, preview.state !== 'failed');
    assert.equal(model.error, preview.state === 'failed' ? 'No connection.' : null);
    assert.match(model.message!, preview.state === 'pending' ? /Searching this topic/ : preview.state === 'failed' ? /No coverage has been retrieved/ : /outcome is unknown/);
    const recovery = exploreReadingPreviewModel({ ...updateExplorePreview(state, topic.id, preview, null),
      recovery: { state: 'pending', requestID: randomUUID() } }, news);
    assert.equal(recovery.canRecover, false); assert.equal(recovery.canSearch, false);
  }
});

test('reading-preview: successful-empty replaces old coverage and retained empty success is not mislabeled as current', () => {
  const { state, topic, result, attempt, news } = readingFixture();
  const empty = { ...result, articles: [], search: attempt.search, succeededAt: attempt.startedAt };
  const populated = updateExplorePreview(state, topic.id, { state: 'successful', result }, null);
  const model = exploreReadingPreviewModel(updateExplorePreview(populated, topic.id, { state: 'successful-empty', result: empty }, null), news);
  assert.equal(model.previewState, 'successful-empty'); assert.equal(model.retained, false);
  assert.equal(model.result, empty); assert.deepEqual(model.groups, []);
  assert.equal(model.error, null); assert.equal(model.attempt, null);
  assert.match(model.message!, /succeeded with zero results/);
  const retained = exploreReadingPreviewModel(updateExplorePreview(state, topic.id,
    { state: 'failed-retained', previous: { ...result, articles: [] }, attempt, error: { code: 'search-failed', error: 'Search failed.' } }, null), news);
  assert.equal(retained.retained, true); assert.deepEqual(retained.groups, []);
  assert.equal(retained.previewState, 'failed-retained'); assert.equal(retained.result?.succeededAt, result.succeededAt);
});

test('reading-preview: only selected-topic coverage is grouped; switching cannot relabel another result or attempt', () => {
  const { state, session, topic, result, attempt, news } = readingFixture();
  const first = updateExplorePreview(state, topic.id, { state: 'failed-retained', previous: result, attempt,
    error: { code: 'search-failed', error: 'First topic failed.' } }, null);
  const second = session.topics[1], secondPreview = searchResponse(session, second.id).preview;
  const selected = { ...updateExplorePreview(first, second.id, secondPreview, null), selectedTopicID: second.id };
  const model = exploreReadingPreviewModel(selected, news);
  assert.equal(model.topic?.id, second.id); assert.equal(model.previewState, 'successful');
  assert.deepEqual(model.result, retainedExploreResult(secondPreview));
  assert.equal(model.attempt, null); assert.equal(model.error, null);
  assert.equal(model.groups[0].lead.title, second.title + ' source report');
  assert.equal(exploreReadingPreviewModel({ ...selected, selectedTopicID: session.topics[2].id }, news).result, null);
  assert.equal(exploreReadingPreviewModel({ ...selected, selectedTopicID: randomUUID() }, news).previewState, null);
});

test('reading-preview: retrieved excerpts stay source-labeled, unknown dates remain unknown and heuristic groups have no five-story cap', () => {
  const { state, topic, result, news } = readingFixture();
  const article = result.articles[0];
  const articles = [
    { ...article, title: 'Regional cooling infrastructure district heating energy policy', url: 'https://example.org/news/lead', publishedAt: result.succeededAt },
    { ...article, title: 'Regional cooling infrastructure district heating energy policy update', url: 'https://other.example/news/related', publishedAt: result.succeededAt },
    ...Array.from({ length: 7 }, (_, i) => ({ ...article, url: 'https://example.org/news/unknown-' + i,
      title: 'Source report ' + i, publishedAt: null })),
  ];
  const model = exploreReadingPreviewModel(updateExplorePreview(state, topic.id, { state: 'successful', result: { ...result, articles } }, null), news);
  assert.equal(model.groups.length, 8);
  assert.equal(model.groups[0].lead, articles[0]); assert.deepEqual(model.groups[0].related, [articles[1]]);
  assert.equal(model.groups.flatMap(group => [group.lead, ...group.related]).length, articles.length);
  assert.equal(model.groups[1].lead.publishedAt, null);
  // ArticleList already labels these as source excerpts: no AI-summary kind
  // or saved-interest matches. Assert the contract without refactor-only helpers.
  assert.ok(model.groups.every(group => [group.lead, ...group.related].every(item => item.summaryKind === 'source' &&
    !('matches' in item) && item.summary === 'Retrieved source excerpt.')));
  assert.match(model.message!, /source excerpts, not AI-written/);
});

test('reading-preview: expired, imported or revoked context hides evidence and disables editing while retaining explicit recovery', () => {
  const { state, session, topic, result, news, source } = readingFixture();
  const populated = updateExplorePreview(state, topic.id, { state: 'successful', result }, null);
  const cases: [ExploreClientState, NewsResponse, number, 'expired' | 'obsolete'][] = [
    [populated, news, Date.parse(session.expiresAt), 'expired'],
    [{ ...populated, lifecycle: { state: 'expired' } }, news, Date.now(), 'expired'],
    [{ ...populated, lifecycle: { state: 'obsolete' } }, news, Date.now(), 'obsolete'],
    [updateExplorePreview(populated, topic.id, { state: 'obsolete' }, null), news, Date.now(), 'obsolete'],
    [populated, galleryNews([{ ...source, revision: randomUUID(), name: 'Replacement context' }]), Date.now(), 'obsolete'],
    [populated, galleryNews([{ ...source, enabled: false }]), Date.now(), 'obsolete'],
    [populated, galleryNews([]), Date.now(), 'obsolete'],
  ];
  for (const [supplied, metadata, now, expected] of cases) {
    const model = exploreReadingPreviewModel(supplied, metadata, now);
    assert.equal(model.previewState, expected); assert.equal(model.result, null); assert.equal(model.attempt, null);
    assert.deepEqual(model.groups, []); assert.equal(model.editable, false); assert.equal(model.canSearch, false);
    assert.equal(model.canRecover, true); assert.match(model.message!, /Saved reading is unaffected|Nothing reruns automatically/);
    assert.doesNotMatch(model.sourceLabel, /Replacement/);
  }
  assert.equal(exploreReadingPreviewModel(emptyExploreState(), news).previewState, null);
});

test('reading-preview: invalid drafts and concurrency disable submission without altering original coverage', () => {
  const { state, session, topic, result, attempt, news } = readingFixture();
  const populated = updateExplorePreview(state, topic.id, { state: 'successful', result }, null);
  const invalid = exploreReadingPreviewModel({ ...populated, drafts: { ...state.drafts, [topic.id]: { ...attempt.search, query: 'short query' } } }, news);
  assert.equal(invalid.canSearch, false); assert.match(invalid.validationError!, /at least 5 words/);
  assert.equal(invalid.result, result); assert.equal(invalid.draftDiffers, true);
  const concurrent = session.topics.slice(1).reduce((current, other) => updateExplorePreview(current, other.id,
    { state: 'pending', attempt: { ...attempt, search: other.proposedSearch }, previous: null }, randomUUID()), populated);
  const capacity = exploreReadingPreviewModel(concurrent, news);
  assert.equal(capacity.atSearchCapacity, true); assert.equal(capacity.canSearch, false);
  assert.equal(capacity.result, result); assert.equal(capacity.editable, true);
});
