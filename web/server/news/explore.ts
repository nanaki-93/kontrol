import { randomUUID } from 'node:crypto';
import { discoveryPreferencesSchema, type NewsInterest } from '../../shared/news';
import {
  EXPLORE_AVAILABILITY_DEADLINE_MS, EXPLORE_GENERATION_DEADLINE_MS,
  EXPLORE_MAX_RETAINED_BYTES, EXPLORE_MAX_TOPICS, EXPLORE_SESSION_TTL_MS,
  exploreBytes, exploreExpired, exploreSessionSchema, exploreSourceCurrent,
  exploreStatusResponseSchema, type ExploreErrorCode, type ExploreSession, type IdeateExploreTopics,
} from '../../shared/news-explore';
import { createExploreIdeation, ExploreIdeationError, requestExploreIdeas } from './explore-ideation';
import { piStatus } from './pi';

const messages = {
  'invalid-input': 'The saved News interests could not be used. Review them in Discover, then try again.',
  'no-interests': 'Enable a saved News interest in Discover before requesting topic ideas.',
  'pi-unavailable': 'PI is unavailable. Check its setup before requesting topic ideas. Standard News search remains available.',
  'generation-failed': 'The topic request failed or was interrupted. Previous valid ideas are retained. Try again explicitly.',
  'no-valid-ideas': 'PI returned no usable distinct topic ideas. Try again explicitly or review your saved interests.',
  busy: 'A topic request is already running. Wait for it to finish before trying again.',
  'obsolete-source': 'The saved interests changed. Request new topic ideas explicitly.',
  'session-gone': 'This exploration has expired or is unavailable. Request new topic ideas explicitly.',
  capacity: 'The topic request exceeded the temporary memory limit. Previous valid ideas are retained.',
} satisfies Partial<Record<ExploreErrorCode, string>>;
export class ExploreServiceError extends Error {
  constructor(readonly code: keyof typeof messages) { super(messages[code]); }
}

export type ExploreStatus = ReturnType<typeof exploreStatusResponseSchema.parse>;
type Lifecycle = ExploreStatus['lifecycle'];
type Generation = ExploreStatus['generation'];
/** A scheduler returns an exact cancellation function. Tests can use a fake
 * clock/scheduler; production timers are owned, cancellable and unref'ed. */
export type ExploreSchedule = (callback: () => void, delayMs: number) => () => void;
const scheduleTimer: ExploreSchedule = (callback, delayMs) => {
  const timer = setTimeout(callback, delayMs);
  timer.unref();
  return () => clearTimeout(timer);
};
// Includes status discriminants and the largest bounded generation error or
// pending record. Follow bookkeeping will share the remaining session budget.
export const EXPLORE_GENERATION_BOOKKEEPING_BYTES = 2048;
export interface ExploreDependencies {
  readInterests: () => readonly NewsInterest[];
  ideate?: IdeateExploreTopics;
  available?: (signal: AbortSignal) => Promise<boolean>;
  now?: () => number;
  schedule?: ExploreSchedule;
  // Injectable LOWER bounds for fixture deadlines and publication budgets only.
  generationDeadlineMs?: number;
  availabilityDeadlineMs?: number;
  maxRetainedBytes?: number;
}
interface GenerationOperation {
  id: string;
  epoch: number;
  controller: AbortController;
  sources: NewsInterest[];
  expiresAt: number;
}
function lowerBound(value: number | undefined, maximum: number, minimum = 1): number {
  const bound = value ?? maximum;
  if (!Number.isSafeInteger(bound) || bound < minimum || bound > maximum) throw new ExploreServiceError('invalid-input');
  return bound;
}
function bounded<T>(work: () => Promise<T>, signal: AbortSignal): Promise<T> {
  return new Promise((resolve, reject) => {
    const abort = () => reject(signal.reason);
    if (signal.aborted) { abort(); return; }
    signal.addEventListener('abort', abort, { once: true });
    // Consume late rejection as well as success, even if an injected adapter
    // ignores cancellation. Neither can publish after the race has settled.
    Promise.resolve().then(() => { signal.throwIfAborted(); return work(); }).then(resolve, reject)
      .finally(() => signal.removeEventListener('abort', abort));
  });
}

/** One owner per app; no storage, HTTP listeners, global Maps or request queues.
 * One live session replaces its predecessor atomically. Absolute expiry drops
 * evidence and keeps only a bounded lifecycle discriminant, not tombstone IDs.
 * Failed/oversized generation retains the prior CURRENT session. Snapshot reads
 * are local-only, detached copies and never renew lifetime or request work.
 */
export function createExploreService(dependencies: ExploreDependencies) {
  const now = dependencies.now ?? Date.now;
  const schedule = dependencies.schedule ?? scheduleTimer;
  const ideate = dependencies.ideate ?? createExploreIdeation();
  const available = dependencies.available ?? (async () => (await piStatus()).configured);
  const generationDeadline = lowerBound(dependencies.generationDeadlineMs, EXPLORE_GENERATION_DEADLINE_MS);
  const availabilityDeadline = lowerBound(dependencies.availabilityDeadlineMs, EXPLORE_AVAILABILITY_DEADLINE_MS);
  const byteLimit = lowerBound(dependencies.maxRetainedBytes, EXPLORE_MAX_RETAINED_BYTES, EXPLORE_GENERATION_BOOKKEEPING_BYTES);
  let lifecycle: Lifecycle = { state: 'absent' };
  let generation: Generation = { state: 'idle' };
  let operation: GenerationOperation | undefined;
  let epoch = 0;
  let disposed = false;
  let cancelExpiry: (() => void) | undefined;

  function readEnabled(): NewsInterest[] {
    try {
      const parsed = discoveryPreferencesSchema.safeParse({ schemaVersion: 1,
        interests: dependencies.readInterests().filter(interest => interest.enabled) });
      if (!parsed.success) throw new ExploreServiceError('invalid-input');
      return parsed.data.interests;
    } catch {
      abortOperation('invalid-input');
      throw new ExploreServiceError('invalid-input');
    }
  }
  function sourcesCurrent(op: GenerationOperation, current: readonly NewsInterest[]): boolean {
    return op.sources.length === current.length && op.sources.every(source => exploreSourceCurrent(source, current));
  }
  function abortOperation(code: keyof typeof messages) {
    operation?.controller.abort(new ExploreServiceError(code));
  }
  function dropSession(state: 'obsolete' | 'expired') {
    cancelExpiry?.(); cancelExpiry = undefined;
    lifecycle = { state };
  }
  function revokeTopics(ids: ReadonlySet<string>) {
    if (lifecycle.state !== 'available') return;
    let changed = false;
    for (const topic of lifecycle.session.topics) {
      if (ids.has(topic.sourceInterestID) && topic.status !== 'obsolete') {
        topic.status = 'obsolete'; topic.preview = { state: 'obsolete' }; changed = true;
      }
    }
    // Revocation is sticky, even if a caller later restores the same revision.
    if (changed) lifecycle.session.revision = randomUUID();
  }
  function reconcile() {
    if (disposed) return;
    if (lifecycle.state === 'available' && exploreExpired(lifecycle.session.expiresAt, now())) dropSession('expired');
    const current = readEnabled();
    if (operation) {
      if (now() >= operation.expiresAt) abortOperation('session-gone');
      else if (!sourcesCurrent(operation, current)) abortOperation('obsolete-source');
    }
    if (lifecycle.state === 'available') {
      revokeTopics(new Set(lifecycle.session.sources.filter(source => !exploreSourceCurrent(source, current)).map(source => source.id)));
    }
  }
  function snapshot(): ExploreStatus {
    reconcile();
    return exploreStatusResponseSchema.parse({ lifecycle, generation });
  }
  function invalidate() {
    if (disposed) return;
    epoch++;
    abortOperation('obsolete-source');
    dropSession('obsolete');
  }
  function invalidateSources(ids: readonly string[]) {
    if (disposed || !ids.length) return;
    const revoked = new Set(ids);
    if (operation?.sources.some(source => revoked.has(source.id))) abortOperation('obsolete-source');
    revokeTopics(revoked);
  }
  function dispose() {
    if (disposed) return;
    disposed = true; epoch++;
    abortOperation('session-gone');
    dropSession('expired');
    generation = { state: 'idle' };
  }

  async function generate(externalSignal?: AbortSignal): Promise<{ session: ExploreSession; partial: boolean }> {
    if (disposed) throw new ExploreServiceError('session-gone');
    // Admission is synchronous, BEFORE availability or any other awaited work.
    if (operation) throw new ExploreServiceError('busy');
    const startedAt = now();
    const op: GenerationOperation = { id: randomUUID(), epoch, controller: new AbortController(),
      sources: [], expiresAt: startedAt + EXPLORE_SESSION_TTL_MS };
    operation = op;
    generation = { state: 'pending', requestID: op.id, startedAt: new Date(startedAt).toISOString() };
    const externalAbort = () => op.controller.abort(new ExploreServiceError('generation-failed'));
    externalSignal?.addEventListener('abort', externalAbort, { once: true });
    let cancelDeadline: (() => void) | undefined;
    let cancelAvailability: (() => void) | undefined;
    const clearOperationTimers = () => {
      cancelDeadline?.(); cancelDeadline = undefined;
      cancelAvailability?.(); cancelAvailability = undefined;
    };
    op.controller.signal.addEventListener('abort', clearOperationTimers, { once: true });
    const checkDeadline = () => {
      if (now() >= startedAt + generationDeadline) op.controller.abort(new ExploreServiceError('generation-failed'));
      op.controller.signal.throwIfAborted();
    };
    try {
      op.sources = readEnabled();
      if (!op.sources.length) throw new ExploreServiceError('no-interests');
      reconcile();
      if (externalSignal?.aborted) externalAbort();
      op.controller.signal.throwIfAborted();
      cancelDeadline = schedule(() => op.controller.abort(new ExploreServiceError('generation-failed')), generationDeadline);
      cancelAvailability = schedule(() => op.controller.abort(new ExploreServiceError('generation-failed')), availabilityDeadline);
      const configured = await bounded(() => available(op.controller.signal), op.controller.signal);
      cancelAvailability?.(); cancelAvailability = undefined;
      if (now() >= startedAt + availabilityDeadline) op.controller.abort(new ExploreServiceError('generation-failed'));
      checkDeadline();
      if (!configured) throw new ExploreServiceError('pi-unavailable');
      reconcile(); checkDeadline();
      const result = await bounded(() => requestExploreIdeas(op.sources, op.controller.signal, ideate), op.controller.signal);
      reconcile(); checkDeadline();
      if (operation !== op || epoch !== op.epoch || disposed) throw new ExploreServiceError('obsolete-source');
      const session = exploreSessionSchema.parse({ id: randomUUID(), revision: randomUUID(),
        generatedAt: new Date(startedAt).toISOString(), expiresAt: new Date(op.expiresAt).toISOString(),
        sources: op.sources.map(source => ({ id: source.id, revision: source.revision })),
        topics: result.ideas.map(idea => ({ ...idea, id: randomUUID(), status: 'available', preview: { state: 'not-searched' } })),
      });
      if (exploreBytes(session) + EXPLORE_GENERATION_BOOKKEEPING_BYTES > byteLimit) throw new ExploreServiceError('capacity');
      checkDeadline();
      // Schedule before replacing, so a scheduler failure cannot lose valid ideas.
      const nextExpiry = schedule(() => {
        if (lifecycle.state === 'available' && lifecycle.session.id === session.id) dropSession('expired');
      }, op.expiresAt - now());
      cancelExpiry?.(); cancelExpiry = nextExpiry;
      lifecycle = { state: 'available', session };
      generation = { state: 'idle' };
      return { session: exploreSessionSchema.parse(session), partial: session.topics.length < EXPLORE_MAX_TOPICS };
    } catch (error) {
      const failure = error instanceof ExploreServiceError ? error : error instanceof ExploreIdeationError ?
        new ExploreServiceError(error.code) : new ExploreServiceError('generation-failed');
      if (!disposed && operation === op) generation = { state: 'failed', error: { code: failure.code, error: failure.message } };
      throw failure;
    } finally {
      clearOperationTimers();
      op.controller.signal.removeEventListener('abort', clearOperationTimers);
      externalSignal?.removeEventListener('abort', externalAbort);
      // Also revoke any adapter still settling after the bounded wait.
      op.controller.abort(new ExploreServiceError('generation-failed'));
      if (operation === op) operation = undefined;
    }
  }
  return { snapshot, generate, invalidate, invalidateSources, dispose };
}
export type ExploreService = ReturnType<typeof createExploreService>;
