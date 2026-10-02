import { Router } from 'express';
import { readFileSync } from 'node:fs';
import { randomUUID } from 'node:crypto';
import { z } from 'zod';
import { learningSchema, definitionSchema, completedContentSchema, type Learning, type Definition, type Attempt } from '../../shared/schema';
import { Store } from '../store';
import { HttpError, requireFound } from '../errors';

export function practicedConcepts(state: Learning): Set<string> {
  return new Set(state.attempts.filter(a => a.completedAt).flatMap(a =>
    a.pinnedContent?.definition.conceptIDs ?? a.completedContentSnapshot?.conceptIDs ?? [])
    .concat(state.terminalRecords.filter(t => state.progress.some(p => p.lessonID === t.lessonID && p.status === 'completed'))
      .flatMap(t => t.conceptIDs ?? [])));
}
function duplicate(a: Pick<Definition, 'objectiveKey' | 'conceptIDs' | 'normalizedContentHash'>,
  b: Pick<Definition, 'objectiveKey' | 'conceptIDs' | 'normalizedContentHash'>): boolean {
  if (a.normalizedContentHash === b.normalizedContentHash) return true;
  const union = new Set([...a.conceptIDs, ...b.conceptIDs]);
  const intersection = a.conceptIDs.filter(id => b.conceptIDs.includes(id)).length;
  return a.objectiveKey.trim().toLowerCase() === b.objectiveKey.trim().toLowerCase() && intersection / union.size >= 0.8;
}
export function fillSlots(state: Learning, at: string): void {
  const practiced = practicedConcepts(state);
  const terminal = new Set(state.progress.filter(p => ['completed', 'dismissed'].includes(p.status)).map(p => p.lessonID));
  state.slots = state.slots.filter(slot => !terminal.has(slot.lessonID));
  for (const topic of state.topics) for (let index = 0; index < 4; index++) {
    if (state.slots.some(s => s.topicID === topic.id && s.slotIndex === index)) continue;
    const used = new Set([...terminal, ...state.slots.map(s => s.lessonID)]);
    const evidence = [
      ...state.definitions.filter(d => used.has(d.id)),
      ...state.attempts.filter(a => used.has(a.lessonID) && a.pinnedContent).map(a => a.pinnedContent!.definition),
      ...state.terminalRecords.filter(t => used.has(t.lessonID) && t.objectiveKey && t.conceptIDs && t.normalizedContentHash)
        .map(t => ({ objectiveKey: t.objectiveKey!, conceptIDs: t.conceptIDs!, normalizedContentHash: t.normalizedContentHash! })),
    ];
    const candidates = state.definitions.filter(d => d.topicID === topic.id && !used.has(d.id) &&
      d.prerequisiteConceptIDs.every(c => practiced.has(c)) && !evidence.some(e => duplicate(d, e)));
    const activeFormats = state.slots.filter(s => s.topicID === topic.id)
      .map(s => state.definitions.find(d => d.id === s.lessonID)?.format);
    candidates.sort((a, b) =>
      a.conceptIDs.filter(c => practiced.has(c)).length - b.conceptIDs.filter(c => practiced.has(c)).length ||
      Number(activeFormats.includes(a.format)) - Number(activeFormats.includes(b.format)) ||
      ['basic', 'intermediate', 'advanced'].indexOf(a.difficulty) - ['basic', 'intermediate', 'advanced'].indexOf(b.difficulty) ||
      a.id.localeCompare(b.id));
    const chosen = candidates[0];
    if (chosen) state.slots.push({ key: Buffer.byteLength(topic.id, 'utf8') + ':' + topic.id + ':' + index,
      topicID: topic.id, slotIndex: index, lessonID: chosen.id, assignedAt: at });
  }
}
export function initialLearning(): Learning {
  const catalog = JSON.parse(readFileSync(new URL('../../resources/starter-catalog.json', import.meta.url), 'utf8'));
  const definitions = catalog.lessons.map((d: Record<string, unknown>) => definitionSchema.parse({
    ...d, provenance: { schemaVersion: 1, attribution: d.provenance, generation: null },
  }));
  const state = learningSchema.parse({
    topics: catalog.topics, subtopics: catalog.subtopics, concepts: catalog.concepts, definitions,
    progress: [], attempts: [], slots: [], terminalRecords: [],
    catalogMembership: [{ schemaVersion: 1, catalogID: catalog.catalogID, catalogVersion: catalog.version,
      topicIDs: catalog.topics.map((x: { id: string }) => x.id),
      subtopicIDs: catalog.subtopics.map((x: { id: string }) => x.id),
      conceptIDs: catalog.concepts.map((x: { id: string }) => x.id),
      seededLessonIDs: definitions.map((x: Definition) => x.id) }],
  });
  fillSlots(state, new Date().toISOString());
  return state;
}
function openAttempt(state: Learning, lessonID: string, at: string): Attempt {
  const progress = state.progress.find(p => p.lessonID === lessonID);
  if (progress?.status === 'completed' || progress?.status === 'dismissed') throw new HttpError(409, 'This lesson is in history. Restore a dismissed lesson to continue.');
  let attempt = state.attempts.find(a => a.lessonID === lessonID && !a.completedAt);
  if (!attempt) {
    const definition = requireFound(state.definitions.find(d => d.id === lessonID));
    attempt = { id: randomUUID(), lessonID, contentVersion: definition.contentVersion, answerDraft: '', revision: 0,
      solutionRevealedAt: null, selfCheckAcknowledgedAt: null, completedAt: null,
      pinnedContent: { envelopeVersion: 1, definition }, completedContentSnapshot: null };
    state.attempts.push(attempt);
  }
  if (progress) { progress.status = 'started'; progress.startedAt ??= at; progress.lastOpenedAt = at; }
  else state.progress.push({ lessonID, status: 'started', firstShownAt: at, startedAt: at, completedAt: null, dismissedAt: null, lastOpenedAt: at });
  return attempt;
}
export function learningModule(store: Store): Router {
  const router = Router();
  if (!store.has('learning')) store.set('learning', initialLearning());
  router.get('/', (_req, res) => res.json(store.get<Learning>('learning')));
  router.post('/:id/open', (req, res) => {
    const attempt = store.transaction(() => {
      const state = store.get<Learning>('learning');
      const attempt = openAttempt(state, String(req.params.id), new Date().toISOString());
      store.set('learning', state);
      return attempt;
    });
    res.json(attempt);
  });
  router.patch('/:id/answer', (req, res) => {
    const input = z.object({ answer: z.string().max(500_000), revision: z.number().int().nonnegative() }).parse(req.body);
    const attempt = store.transaction(() => {
      const state = store.get<Learning>('learning');
      const attempt = openAttempt(state, String(req.params.id), new Date().toISOString());
      if (attempt.revision !== input.revision) throw new HttpError(409, 'This answer changed in another tab. Keep your draft, then reload the saved answer.');
      attempt.answerDraft = input.answer;
      attempt.revision++;
      store.set('learning', state);
      return attempt;
    });
    res.json(attempt);
  });
  router.post('/:id/:action', (req, res) => {
    const action = z.enum(['reveal', 'complete', 'dismiss', 'restore']).parse(req.params.action);
    const result = store.transaction(() => {
      const state = store.get<Learning>('learning'), lessonID = String(req.params.id), at = new Date().toISOString();
      let progress = state.progress.find(p => p.lessonID === lessonID);
      if (action === 'restore') {
        if (progress?.status !== 'dismissed') throw new HttpError(409, 'Only dismissed lessons can be restored.');
        progress.status = progress.startedAt ? 'started' : 'available'; progress.dismissedAt = null;
        state.terminalRecords = state.terminalRecords.filter(t => t.lessonID !== lessonID);
      } else if (action === 'complete' && progress?.status === 'completed') {
        return state; // Retrying completion never records a second attempt.
      } else {
        const attempt = openAttempt(state, lessonID, at);
        progress = state.progress.find(p => p.lessonID === lessonID)!;
        if (action === 'reveal') attempt.solutionRevealedAt ??= at;
        if (action === 'complete') {
          const input = z.object({ acknowledged: z.literal(true) }).parse(req.body);
          if (!input.acknowledged || !attempt.solutionRevealedAt) throw new HttpError(409, 'Reveal the solution and acknowledge the self-check first.');
          if (!attempt.pinnedContent) throw new HttpError(409, 'This legacy attempt has no saved lesson content. Its response is retained, but a new completion cannot be recorded.');
          attempt.selfCheckAcknowledgedAt = at; attempt.completedAt = at;
          attempt.completedContentSnapshot = completedContentSchema.parse(attempt.pinnedContent.definition);
          progress.status = 'completed'; progress.completedAt = at;
        }
        if (action === 'dismiss') { progress.status = 'dismissed'; progress.dismissedAt = at; }
      }
      fillSlots(state, at);
      store.set('learning', state);
      return state;
    });
    res.json(result);
  });
  return router;
}
