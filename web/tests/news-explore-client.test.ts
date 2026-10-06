import test from 'node:test';
import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { interestDraftSchema, type InterestDraft, type NewsInterest } from '../shared/news';
import {
  createInterestEditorState, createInterestEditorSubmission, interestEditorIdentity,
  saveInterestEditor, validateInterestEditorDraft, type InterestEditorInput,
} from '../src/modules/news/interest-editor';

// Pure editor helpers only: no DOM, application, listener or external request.
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
