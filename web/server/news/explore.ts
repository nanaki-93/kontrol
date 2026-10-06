import { createHash, randomUUID } from 'node:crypto';
import { discoveryPreferencesSchema, type DiscoveredArticle, type InterestDraft, type NewsInterest } from '../../shared/news';
import { articleSnapshotSchema, canonicalURL, safeURL } from '../../shared/workspace';
import {
  EXPLORE_AVAILABILITY_DEADLINE_MS, EXPLORE_GENERATION_DEADLINE_MS,
  EXPLORE_MAX_RETAINED_BYTES, EXPLORE_MAX_TOPICS, EXPLORE_SESSION_TTL_MS,
  exploreBytes, exploreExpired, exploreSessionSchema, exploreSourceCurrent,
  exploreStatusResponseSchema, exploreArticleSchema, exploreSearchDescriptor, exploreSearchRequestSchema,
  exploreTopicParamsSchema, exploreSearchResponseSchema, EXPLORE_SEARCH_DEADLINE_MS,
  exploreFollowRequestSchema, exploreFollowResponseSchema, EXPLORE_MAX_FOLLOW_SUBMISSIONS,
  EXPLORE_MAX_CONCURRENT_SEARCHES, EXPLORE_MAX_ARTICLES_PER_TOPIC,
  type ExploreArticle, type ExplorePreview, type ExploreTopic,
  type ExploreErrorCode, type ExploreSession, type IdeateExploreTopics,
} from '../../shared/news-explore';
import { createExploreIdeation, ExploreIdeationError, requestExploreIdeas } from './explore-ideation';
import { piStatus } from './pi';
import { mergeDiscovery, searchDiscovery, type Discover } from './discovery';

const messages = {
  'invalid-input': 'Review the search fields and enabled saved News interests in Discover, then try again.',
  'no-interests': 'Enable a saved News interest in Discover before requesting topic ideas.',
  'pi-unavailable': 'PI is unavailable. Check its setup before requesting topic ideas. Standard News search remains available.',
  'generation-failed': 'The topic request failed or was interrupted. Previous valid ideas are retained. Try again explicitly.',
  'no-valid-ideas': 'PI returned no usable distinct topic ideas. Try again explicitly or review your saved interests.',
  busy: 'An exploration operation is already running or the preview limit is reached. Wait before trying again.',
  'search-failed': 'The Standard search failed or was interrupted. Previous same-topic coverage is retained, if available. Search again explicitly.',
  'stale-revision': 'This exploration changed. Recover its local status before trying again.',
  'obsolete-source': 'The saved interests changed. Request new topic ideas explicitly.',
  'session-gone': 'This exploration has expired or is unavailable. Request new topic ideas explicitly.',
  capacity: 'This request exceeded the temporary memory limit. Previous valid exploration is retained.',
  'follow-capacity': 'Keep up to 12 specific interests. Remove an interest in Discover before following another topic.',
  'submission-conflict': 'This follow submission was already used for a different review. Recover the previous outcome or start a new review.',
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
// Reserve room for two bounded descriptors/attempts/controllers and failed-state
// transitions. Publication trims whole trailing articles in retrieval order;
// never evict another topic's retained coverage to admit a refresh.
export const EXPLORE_SEARCH_BOOKKEEPING_BYTES = 8192;
// Same input ceiling as the shared RSS parser, even for an injected adapter.
export const EXPLORE_MAX_RETRIEVED_CANDIDATES = 500;
// One validated interest contains at most 2,860 text code units. Even JSON's
// worst-case six-byte escaping plus identities/keys fits this reservation.
// Reserve BEFORE persistence, so successful commits never fail bookkeeping.
export const EXPLORE_FOLLOW_RECORD_BYTES = 32 * 1024;
type FollowResult = ReturnType<typeof exploreFollowResponseSchema.parse>;
interface FollowSubmission {
  submissionID: string;
  topicID: string;
  draftHash: string;
  result: FollowResult;
}
export interface ExploreDependencies {
  readInterests: () => readonly NewsInterest[];
  ideate?: IdeateExploreTopics;
  discover?: Discover;
  available?: (signal: AbortSignal) => Promise<boolean>;
  now?: () => number;
  schedule?: ExploreSchedule;
  // Injectable LOWER bounds for fixture deadlines and publication budgets only.
  generationDeadlineMs?: number;
  availabilityDeadlineMs?: number;
  searchDeadlineMs?: number;
  maxRetainedBytes?: number;
}
interface GenerationOperation {
  id: string;
  epoch: number;
  controller: AbortController;
  sources: NewsInterest[];
  expiresAt: number;
}
interface SearchOperation {
  sessionID: string;
  sessionRevision: string;
  topicID: string;
  epoch: number;
  controller: AbortController;
}
function previousResult(preview: ExplorePreview) {
  return 'result' in preview ? preview.result : 'previous' in preview ? preview.previous : null;
}
/** Validate the injected retrieval boundary before handing it to shared merge
 * rules. Only a current Standard descriptor match qualifies. Do not copy model
 * provenance, arbitrary extra fields or adapter-issued article identities.
 */
function normalizeResults(incoming: DiscoveredArticle[], descriptor: NewsInterest, at: number): ExploreArticle[] {
  if (!Array.isArray(incoming)) throw new ExploreServiceError('search-failed');
  const results: ExploreArticle[] = [];
  const seen = new Set<string>();
  for (const raw of incoming.slice(0, EXPLORE_MAX_RETRIEVED_CANDIDATES)) {
    if (!raw || typeof raw !== 'object' || (raw.contentKind !== undefined && raw.contentKind !== 'article') ||
        !Array.isArray(raw.matches) || !raw.matches.some(match => match && match.interestID === descriptor.id &&
          match.interestRevision === descriptor.revision && match.mode === 'search')) continue;
    let snapshot: ReturnType<typeof articleSnapshotSchema.parse>, url: string;
    try {
      snapshot = articleSnapshotSchema.parse(raw);
      if (snapshot.summaryKind !== 'source' || !snapshot.title.trim()) continue;
      url = canonicalURL(snapshot.url);
    } catch { continue; }
    if (seen.has(url)) continue;
    const candidate: DiscoveredArticle = { ...snapshot, url, id: url, fetchedAt: new Date(at).toISOString(), feedIDs: [], topicIDs: [],
      matches: [{ interestID: descriptor.id, interestRevision: descriptor.revision, mode: 'search', score: 0, reason: 'Standard topic preview.' }] };
    // Shared eligibility, canonicalization, hash identity and freshness rules.
    // Normalize one candidate at a time, retaining at most 40, not 500 large
    // intermediate snapshots. Invalid duplicates cannot hide valid evidence.
    const [article] = mergeDiscovery([], [candidate], descriptor, 'search', at);
    if (!article) continue;
    const parsed = exploreArticleSchema.safeParse({ id: article.id, title: article.title, url: article.url,
      source: article.source, summary: article.summary, publishedAt: article.publishedAt, fetchedAt: article.fetchedAt,
      summaryKind: 'source', feedIDs: [], topicIDs: [] });
    if (parsed.success) { results.push(parsed.data); seen.add(url); }
    if (results.length === EXPLORE_MAX_ARTICLES_PER_TOPIC) break;
  }
  return results;
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
  const discover = dependencies.discover ?? searchDiscovery();
  const searchDeadline = lowerBound(dependencies.searchDeadlineMs, EXPLORE_SEARCH_DEADLINE_MS);
  const available = dependencies.available ?? (async () => (await piStatus()).configured);
  const generationDeadline = lowerBound(dependencies.generationDeadlineMs, EXPLORE_GENERATION_DEADLINE_MS);
  const availabilityDeadline = lowerBound(dependencies.availabilityDeadlineMs, EXPLORE_AVAILABILITY_DEADLINE_MS);
  const byteLimit = lowerBound(dependencies.maxRetainedBytes, EXPLORE_MAX_RETAINED_BYTES, EXPLORE_GENERATION_BOOKKEEPING_BYTES);
  let lifecycle: Lifecycle = { state: 'absent' };
  let generation: Generation = { state: 'idle' };
  let operation: GenerationOperation | undefined;
  const searches = new Map<string, SearchOperation>();
  let submissions: FollowSubmission[] = []; // FIFO; never renewed by retries.
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
      abortSearches('invalid-input');
      failPendingPreviews('invalid-input');
      throw new ExploreServiceError('invalid-input');
    }
  }
  function sourcesCurrent(op: GenerationOperation, current: readonly NewsInterest[]): boolean {
    return op.sources.length === current.length && op.sources.every(source => exploreSourceCurrent(source, current));
  }
  function abortOperation(code: keyof typeof messages) {
    operation?.controller.abort(new ExploreServiceError(code));
  }
  function abortSearches(code: keyof typeof messages) {
    for (const op of searches.values()) op.controller.abort(new ExploreServiceError(code));
  }
  function failPendingPreviews(code: keyof typeof messages) {
    if (lifecycle.state !== 'available') return;
    for (const topic of lifecycle.session.topics) {
      if (topic.preview.state !== 'pending') continue;
      const { attempt, previous } = topic.preview;
      const error = { code, error: messages[code] };
      topic.preview = previous ? { state: 'failed-retained', attempt, previous, error } : { state: 'failed', attempt, error };
    }
  }
  function dropSession(state: 'obsolete' | 'expired') {
    abortSearches(state === 'obsolete' ? 'obsolete-source' : 'session-gone');
    cancelExpiry?.(); cancelExpiry = undefined;
    lifecycle = { state };
    submissions = [];
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
    if (changed) {
      const revokedTopics = new Set(lifecycle.session.topics.filter(topic => topic.status === 'obsolete').map(topic => topic.id));
      submissions = submissions.filter(record => !revokedTopics.has(record.topicID));
      lifecycle.session.revision = randomUUID();
      // Revision is lifecycle identity. Unrelated topics remain usable, but an
      // already admitted request must recover before using the new revision.
      abortSearches('obsolete-source');
      failPendingPreviews('stale-revision');
    }
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
      abortSearches('session-gone');
      lifecycle = { state: 'available', session };
      submissions = [];
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
  function requireTopic(sessionID: string, topicID: string, revision: string): { session: ExploreSession; topic: ExploreTopic } {
    if (disposed) throw new ExploreServiceError('session-gone');
    reconcile();
    if (lifecycle.state !== 'available') throw new ExploreServiceError(lifecycle.state === 'obsolete' ? 'obsolete-source' : 'session-gone');
    const session = lifecycle.session;
    if (session.id !== sessionID) throw new ExploreServiceError('session-gone');
    const topic = session.topics.find(item => item.id === topicID);
    if (!topic) throw new ExploreServiceError('session-gone');
    if (topic.status !== 'available') throw new ExploreServiceError('obsolete-source');
    if (session.revision !== revision) throw new ExploreServiceError('stale-revision');
    return { session, topic };
  }
  function previewFits(session: ExploreSession, topicID: string, preview: ExplorePreview): boolean {
    const replacement = { ...session, topics: session.topics.map(topic => topic.id === topicID ? { ...topic, preview } : topic) };
    return exploreBytes(replacement) + exploreBytes(submissions) +
      EXPLORE_GENERATION_BOOKKEEPING_BYTES + EXPLORE_SEARCH_BOOKKEEPING_BYTES <= byteLimit;
  }
  async function search(sessionID: string, topicID: string, request: unknown, externalSignal?: AbortSignal) {
    const params = exploreTopicParamsSchema.safeParse({ sessionID, topicID });
    const validated = exploreSearchRequestSchema.safeParse(request);
    if (!params.success || !validated.success) throw new ExploreServiceError('invalid-input');
    const { expectedSessionRevision, search: specification } = validated.data;
    const { session, topic } = requireTopic(sessionID, topicID, expectedSessionRevision);
    if (searches.has(topicID) || searches.size >= EXPLORE_MAX_CONCURRENT_SEARCHES) throw new ExploreServiceError('busy');
    const startedAt = now();
    const attempt = { requestID: randomUUID(), search: specification, startedAt: new Date(startedAt).toISOString() };
    const pending: ExplorePreview = { state: 'pending', attempt, previous: previousResult(topic.preview) };
    if (!previewFits(session, topicID, pending)) throw new ExploreServiceError('capacity');
    const descriptor = exploreSearchDescriptor({ id: topic.id, revision: randomUUID() }, topic.title, specification);
    const op: SearchOperation = { sessionID, sessionRevision: expectedSessionRevision, topicID, epoch, controller: new AbortController() };
    // Synchronous admission: no duplicate, queue, inference or persistent owner.
    searches.set(topicID, op);
    topic.preview = pending;
    let cancelDeadline: (() => void) | undefined;
    const clearTimer = () => { cancelDeadline?.(); cancelDeadline = undefined; };
    const externalAbort = () => op.controller.abort(new ExploreServiceError('search-failed'));
    op.controller.signal.addEventListener('abort', clearTimer, { once: true });
    externalSignal?.addEventListener('abort', externalAbort, { once: true });
    const current = () => {
      const owner = requireTopic(op.sessionID, op.topicID, op.sessionRevision);
      if (now() >= startedAt + searchDeadline) externalAbort();
      op.controller.signal.throwIfAborted();
      if (epoch !== op.epoch || searches.get(topicID) !== op || owner.topic.preview.state !== 'pending' ||
          owner.topic.preview.attempt.requestID !== attempt.requestID) throw new ExploreServiceError('session-gone');
      return owner;
    };
    try {
      if (externalSignal?.aborted) externalAbort();
      op.controller.signal.throwIfAborted();
      cancelDeadline = schedule(externalAbort, searchDeadline);
      const incoming = await bounded(() => discover(descriptor, op.controller.signal), op.controller.signal);
      current();
      const succeededAt = now();
      const articles = normalizeResults(incoming, descriptor, succeededAt);
      const result = { search: specification, succeededAt: new Date(succeededAt).toISOString(), articles };
      const preview: ExplorePreview = { state: articles.length ? 'successful' : 'successful-empty', result };
      const owner = current();
      // Deterministically discard whole trailing results only. Never destroy
      // retained coverage if even the empty result cannot fit.
      const hadResults = articles.length > 0;
      while (!previewFits(owner.session, topicID, preview) && articles.length) articles.pop();
      // Retrieved evidence that cannot fit is a capacity failure, not an honest
      // zero-result search. Preserve any original same-topic coverage instead.
      if (hadResults && !articles.length) throw new ExploreServiceError('capacity');
      preview.state = articles.length ? 'successful' : 'successful-empty';
      if (!previewFits(owner.session, topicID, preview)) throw new ExploreServiceError('capacity');
      const response = exploreSearchResponseSchema.parse({ sessionID, sessionRevision: owner.session.revision, topicID, preview });
      current(); // Validation/normalization may consume deadline time too.
      owner.topic.preview = response.preview;
      return exploreSearchResponseSchema.parse(response);
    } catch (error) {
      const failure = error instanceof ExploreServiceError ? error : new ExploreServiceError('search-failed');
      // Record failures only into the still-owning pending entry, not a revoked,
      // replaced or expired topic. The pending reservation covers this record.
      try {
        const owner = requireTopic(sessionID, topicID, expectedSessionRevision);
        if (epoch === op.epoch && owner.topic.preview.state === 'pending' && owner.topic.preview.attempt.requestID === attempt.requestID) {
          const previous = owner.topic.preview.previous;
          owner.topic.preview = previous ? { state: 'failed-retained', attempt, previous, error: { code: failure.code, error: failure.message } } :
            { state: 'failed', attempt, error: { code: failure.code, error: failure.message } };
        }
      } catch { /* Fail closed; revoked context is never restored. */ }
      throw failure;
    } finally {
      clearTimer();
      op.controller.signal.removeEventListener('abort', clearTimer);
      externalSignal?.removeEventListener('abort', externalAbort);
      op.controller.abort(new ExploreServiceError('search-failed'));
      if (searches.get(topicID) === op) searches.delete(topicID);
    }
  }
  /** Synchronous admission AND persistence: no await/queue can split source
   * checks from the store transaction. The callback validates its result inside
   * that transaction. Only after COMMIT do we publish completed bookkeeping.
   * Tokens bind the exact validated draft (including cosmetic name) and topic;
   * search equivalence is a separate concern owned by the persistence callback.
   */
  function follow(sessionID: string, topicID: string, request: unknown,
    persist: (draft: InterestDraft) => FollowResult): FollowResult {
    const params = exploreTopicParamsSchema.safeParse({ sessionID, topicID });
    const validated = exploreFollowRequestSchema.safeParse(request);
    if (!params.success || !validated.success) throw new ExploreServiceError('invalid-input');
    const { expectedSessionRevision, submissionID, draft } = validated.data;
    const { session } = requireTopic(sessionID, topicID, expectedSessionRevision);
    const draftHash = createHash('sha256').update(JSON.stringify(draft)).digest('hex');
    const completed = submissions.find(record => record.submissionID === submissionID);
    if (completed) {
      if (completed.topicID !== topicID || completed.draftHash !== draftHash) throw new ExploreServiceError('submission-conflict');
      return exploreFollowResponseSchema.parse(completed.result);
    }
    // Plan FIFO eviction without changing old receipts on persistence failure.
    // Existing-interest equivalence still prevents duplicates after eviction.
    const retained = submissions.slice(-(EXPLORE_MAX_FOLLOW_SUBMISSIONS - 1));
    const baseBytes = exploreBytes(session) + EXPLORE_GENERATION_BOOKKEEPING_BYTES + EXPLORE_SEARCH_BOOKKEEPING_BYTES;
    while (retained.length && baseBytes + exploreBytes(retained) + EXPLORE_FOLLOW_RECORD_BYTES > byteLimit) retained.shift();
    if (baseBytes + exploreBytes(retained) + EXPLORE_FOLLOW_RECORD_BYTES > byteLimit) throw new ExploreServiceError('capacity');
    const result = exploreFollowResponseSchema.parse(persist(draft));
    submissions = [...retained, { submissionID, topicID, draftHash, result }];
    return exploreFollowResponseSchema.parse(result);
  }
  /** Current validated evidence only. Newest successful preview wins; ties use
   * stable gallery order, then retrieval order. Pending/failed refreshes resolve
   * their ORIGINAL retained result, never the attempted search's identity. */
  function resolve(url: string): { article: ExploreArticle; summaryKind: 'source' } | undefined {
    if (disposed) return undefined;
    let key: string;
    try { key = canonicalURL(safeURL.parse(url)); } catch { return undefined; }
    reconcile();
    if (lifecycle.state !== 'available') return undefined;
    const results = lifecycle.session.topics.filter(topic => topic.status === 'available')
      .map(topic => previousResult(topic.preview)).filter(result => result !== null)
      .sort((a, b) => b.succeededAt.localeCompare(a.succeededAt));
    for (const result of results) {
      const article = result.articles.find(item => canonicalURL(item.url) === key);
      if (article) return { article: exploreArticleSchema.parse(article), summaryKind: 'source' };
    }
    return undefined;
  }
  return { snapshot, generate, search, follow, resolve, invalidate, invalidateSources, dispose };
}
export type ExploreService = ReturnType<typeof createExploreService>;
