import { useEffect } from 'react';
import {
  mutationOptions, queryOptions, useMutation, useQuery, useQueryClient, type QueryClient,
} from '@tanstack/react-query';
import type { z } from 'zod';
import type { NewsInterest, NewsResponse } from '../../../shared/news';
import {
  EXPLORE_CLIENT_RETENTION_MS, EXPLORE_GENERATION_CLIENT_DEADLINE_MS, EXPLORE_RECOVERY_CLIENT_DEADLINE_MS,
  EXPLORE_SEARCH_CLIENT_DEADLINE_MS, EXPLORE_MAX_CONCURRENT_SEARCHES, EXPLORE_MAX_QUERY_CHARS,
  exploreGenerateResponseSchema, exploreStatusResponseSchema, exploreSearchRequestSchema, exploreSearchResponseSchema,
  type ExploreSearch, type ExplorePreview,
} from '../../../shared/news-explore';
import {
  acceptExploreSession, acceptExploreStatus, emptyExploreState, expireExploreState, reconcileExploreState,
  retainedExploreResult, updateExplorePreview,
  type ExploreClientState, type ExploreStatus,
} from './explore-state';

export const exploreStateKey = ['news-explore'] as const;
const recoveryKey = ['news-explore-recovery'] as const;
export function readExploreState(client: QueryClient, now = Date.now()): ExploreClientState {
  // Commands can precede the first observer, and navigation can unmount it.
  // Retention must not depend on the application's unrelated query defaults.
  client.setQueryDefaults(exploreStateKey, { gcTime: EXPLORE_CLIENT_RETENTION_MS });
  const saved = client.getQueryData<ExploreClientState>(exploreStateKey);
  const state = expireExploreState(saved ?? emptyExploreState(), now);
  if (saved !== state) client.setQueryData(exploreStateKey, state);
  return state;
}
/** Disabled observers subscribe to local state only. Even an explicit refetch
 * of this query can only read memory; it cannot generate or retrieve news.
 */
export function exploreStateOptions(client: QueryClient) {
  return queryOptions({ queryKey: exploreStateKey, queryFn: () => readExploreState(client),
    initialData: () => expireExploreState(client.getQueryData<ExploreClientState>(exploreStateKey) ?? emptyExploreState(), Date.now()),
    enabled: false, staleTime: Infinity,
    gcTime: EXPLORE_CLIENT_RETENTION_MS, retry: false, networkMode: 'always',
    refetchOnMount: false, refetchOnWindowFocus: false, refetchOnReconnect: false, refetchInterval: false });
}
export function reconcileExploreSources(client: QueryClient, interests: readonly NewsInterest[], now = Date.now()): void {
  const state = client.getQueryData<ExploreClientState>(exploreStateKey);
  if (!state) return;
  const next = reconcileExploreState(expireExploreState(state, now), interests);
  if (next !== state) client.setQueryData(exploreStateKey, next);
  if (next.owner !== state.owner) void client.cancelQueries({ queryKey: recoveryKey });
}
function reconcileCachedNews(client: QueryClient, now: number): void {
  const news = client.getQueryData<NewsResponse>(['news']);
  if (news) reconcileExploreSources(client, news.discovery.preferences.interests, now);
}
/** Subscribe to existing metadata, without adding a News read/poll/refetch. */
export function subscribeExploreMetadata(client: QueryClient, now = Date.now): () => void {
  reconcileCachedNews(client, now());
  return client.getQueryCache().subscribe(event => {
    if (event.type === 'updated' && event.query.queryKey.length === 1 && event.query.queryKey[0] === 'news') {
      reconcileCachedNews(client, now());
    }
  });
}
export function useExploreState() {
  const client = useQueryClient(), query = useQuery(exploreStateOptions(client));
  const expiresAt = query.data.lifecycle.state === 'available' ? query.data.lifecycle.session.expiresAt : null;
  useEffect(() => subscribeExploreMetadata(client), [client]);
  useEffect(() => {
    if (!expiresAt) return;
    const timer = setTimeout(() => { readExploreState(client); }, Math.max(0, Date.parse(expiresAt) - Date.now()));
    return () => clearTimeout(timer);
  }, [client, expiresAt]);
  return query;
}
export function selectExploreTopic(client: QueryClient, topicID: string): void {
  const state = readExploreState(client);
  if (state.lifecycle.state === 'available' && state.lifecycle.session.topics.some(topic => topic.id === topicID)) {
    client.setQueryData(exploreStateKey, { ...state, selectedTopicID: topicID });
  }
}
/** Editing and selection are local-only. Invalid short/empty queries can remain
 * drafts; the full shared search contract applies before command admission.
 */
export function setExploreSearchDraft(client: QueryClient, topicID: string, search: ExploreSearch): void {
  const state = readExploreState(client);
  if (state.lifecycle.state !== 'available' || !state.lifecycle.session.topics.some(topic => topic.id === topicID && topic.status === 'available')) return;
  if (search.query.length > EXPLORE_MAX_QUERY_CHARS) return;
  client.setQueryData<ExploreClientState>(exploreStateKey, { ...state, drafts: { ...state.drafts, [topicID]: { ...search } } });
}
/** Call only after the import has committed, before broad metadata invalidation.
 * A fresh owner also rejects late responses if metadata revisions are unchanged.
 */
export function clearExploreAfterImport(client: QueryClient): void {
  client.setQueryDefaults(exploreStateKey, { gcTime: EXPLORE_CLIENT_RETENTION_MS });
  client.setQueryData(exploreStateKey, { ...emptyExploreState(), lifecycle: { state: 'obsolete' } });
  void client.cancelQueries({ queryKey: recoveryKey });
}

export class ExploreCommandError extends Error {
  constructor(readonly outcome: 'confirmed' | 'uncertain' | 'stale' | 'busy', message: string, readonly status?: number) {
    super(message);
  }
}
/** Explore needs an HTTP-versus-lost-response distinction which the generic api
 * helper intentionally does not expose. Keep its same-origin headers, but never
 * surface raw fetch exceptions, malformed responses or provider output.
 */
export async function exploreRequest<T>(path: string, method: 'GET' | 'POST', schema: z.ZodType<T>,
  timeoutMs: number, signal?: AbortSignal, body?: unknown): Promise<T> {
  const controller = new AbortController();
  let rejectAbort!: (error: Error) => void;
  const interrupted = new Promise<never>((_, reject) => { rejectAbort = reject; });
  const abort = () => {
    controller.abort();
    rejectAbort(new ExploreCommandError('stale', 'This local status request was superseded.'));
  };
  signal?.addEventListener('abort', abort, { once: true });
  const timer = setTimeout(() => {
    // Reject with the deliberate uncertainty message, before fetch's AbortError.
    rejectAbort(new ExploreCommandError('uncertain', 'Kontrol took too long to respond. The outcome is unknown; check local status before trying again.'));
    controller.abort();
  }, timeoutMs);
  try {
    if (signal?.aborted) abort();
    return await Promise.race([interrupted, (async () => {
      try {
        controller.signal.throwIfAborted();
        const response = await fetch('/api' + path, { method, signal: controller.signal,
          headers: { 'X-Kontrol-Client': 'web', ...(method === 'POST' ? { 'Content-Type': 'application/json' } : {}) },
          ...(method === 'POST' ? { body: JSON.stringify(body ?? {}) } : {}) });
        const raw: unknown = await response.json();
        if (!response.ok) {
          // Our protected server returns public { error } messages, not raw errors.
          const error = raw && typeof raw === 'object' && 'error' in raw && typeof raw.error === 'string' && raw.error.length <= 500 ?
            raw.error : 'The topic request failed. Check local status before trying again.';
          throw new ExploreCommandError('confirmed', error, response.status);
        }
        const parsed = schema.safeParse(raw);
        if (!parsed.success) throw new ExploreCommandError('uncertain', 'Kontrol returned an unreadable exploration response. Check local status before trying again.');
        return parsed.data;
      } catch (error) {
        if (error instanceof ExploreCommandError) throw error;
        throw new ExploreCommandError('uncertain', 'Cannot read Kontrol’s response. The outcome is unknown; check local status before trying again.');
      }
    })()]);
  } finally { clearTimeout(timer); signal?.removeEventListener('abort', abort); controller.abort(); }
}
interface ExploreCommandDependencies {
  now?: () => number;
  // Only lower fixture deadlines are permitted; production retains named bounds.
  generationTimeoutMs?: number;
  recoveryTimeoutMs?: number;
  searchTimeoutMs?: number;
}
function deadline(override: number | undefined, maximum: number): number {
  if (override === undefined) return maximum;
  if (!Number.isFinite(override) || override <= 0 || override > maximum) throw new Error('Invalid Explore deadline.');
  return override;
}
function staleResponse(): ExploreCommandError { return new ExploreCommandError('stale', 'This exploration request was superseded. Check local status explicitly.'); }
export function exploreGenerationOptions(client: QueryClient, dependencies: ExploreCommandDependencies = {}) {
  const now = dependencies.now ?? Date.now;
  const timeoutMs = deadline(dependencies.generationTimeoutMs, EXPLORE_GENERATION_CLIENT_DEADLINE_MS);
  return mutationOptions<z.infer<typeof exploreGenerateResponseSchema>, Error, void>({
    mutationKey: ['news-explore-generate'], retry: false, networkMode: 'always', gcTime: 0,
    mutationFn: async () => {
      reconcileCachedNews(client, now());
      const state = readExploreState(client, now());
      if (state.generation.state === 'pending' || state.generation.state === 'uncertain') {
        throw new ExploreCommandError('busy', 'Check local status before requesting more ideas.');
      }
      const requestID = crypto.randomUUID(), owner = state.owner;
      const news = client.getQueryData<NewsResponse>(['news']);
      // Admission is synchronous, before any await; independent mutation observers
      // cannot submit a second paid request in the same event turn.
      client.setQueryData<ExploreClientState>(exploreStateKey, { ...state, generationRequestID: requestID,
        generationSources: news ? news.discovery.preferences.interests.filter(interest => interest.enabled).map(({ id, revision }) => ({ id, revision })) : null,
        generation: { state: 'pending', requestID, startedAt: new Date(now()).toISOString() }, recovery: { state: 'idle' } });
      const owns = () => {
        reconcileCachedNews(client, now());
        const current = client.getQueryData<ExploreClientState>(exploreStateKey);
        return current?.owner === owner && current.generationRequestID === requestID;
      };
      try {
        await client.cancelQueries({ queryKey: recoveryKey });
        if (!owns()) throw staleResponse();
        const result = await exploreRequest('/news/explore/generate', 'POST', exploreGenerateResponseSchema, timeoutMs);
        if (!owns()) throw staleResponse();
        const current = readExploreState(client, now());
        const next = acceptExploreSession(current, result.session, now());
        client.setQueryData<ExploreClientState>(exploreStateKey, { ...next, generation: { state: 'idle' },
          generationRequestID: null, generationSources: null, recovery: { state: 'idle' } });
        reconcileCachedNews(client, now());
        // Invalidate any status admitted while generation was still in flight.
        void client.cancelQueries({ queryKey: recoveryKey });
        return result;
      } catch (error) {
        if (owns()) {
          const failure = error instanceof ExploreCommandError ? error : new ExploreCommandError('uncertain', 'The topic request outcome is unknown. Check local status.');
          const current = readExploreState(client, now());
          client.setQueryData<ExploreClientState>(exploreStateKey, { ...current, generationRequestID: null, generationSources: null,
            generation: failure.outcome === 'uncertain' ? { state: 'uncertain' } :
              { state: 'failed', error: { code: 'generation-failed', error: failure.message } }, recovery: { state: 'idle' } });
          void client.cancelQueries({ queryKey: recoveryKey });
        }
        throw error;
      }
    },
  });
}
export function exploreRecoveryOptions(client: QueryClient, dependencies: ExploreCommandDependencies = {}) {
  const now = dependencies.now ?? Date.now;
  const timeoutMs = deadline(dependencies.recoveryTimeoutMs, EXPLORE_RECOVERY_CLIENT_DEADLINE_MS);
  return mutationOptions<ExploreStatus, Error, void>({
    mutationKey: ['news-explore-recover'], retry: false, networkMode: 'always', gcTime: 0,
    mutationFn: async () => {
      const state = readExploreState(client, now());
      if (state.recovery.state === 'pending') throw new ExploreCommandError('busy', 'A local status check is already running.');
      const requestID = crypto.randomUUID(), owner = state.owner, requestKey = [...recoveryKey, requestID];
      client.setQueryData<ExploreClientState>(exploreStateKey, { ...state, recovery: { state: 'pending', requestID } });
      const owns = () => {
        const current = client.getQueryData<ExploreClientState>(exploreStateKey);
        return current?.owner === owner && current.recovery.state === 'pending' && current.recovery.requestID === requestID;
      };
      try {
        const status = await client.fetchQuery({ queryKey: requestKey, queryFn: ({ signal }) =>
          exploreRequest('/news/explore', 'GET', exploreStatusResponseSchema, timeoutMs, signal),
          retry: false, networkMode: 'always', staleTime: 0, gcTime: 0 });
        if (!owns()) throw staleResponse();
        client.setQueryData(exploreStateKey, acceptExploreStatus(readExploreState(client, now()), status, now()));
        reconcileCachedNews(client, now());
        return status;
      } catch (error) {
        if (owns()) client.setQueryData<ExploreClientState>(exploreStateKey, {
          ...readExploreState(client, now()), recovery: { state: 'failed', error: error instanceof ExploreCommandError ? error.message : 'Local status is unavailable. Check again explicitly.' },
        });
        throw error;
      } finally { client.removeQueries({ queryKey: requestKey, exact: true }); }
    },
  });
}
export function exploreSearchOptions(client: QueryClient, dependencies: ExploreCommandDependencies = {}) {
  const now = dependencies.now ?? Date.now;
  const timeoutMs = deadline(dependencies.searchTimeoutMs, EXPLORE_SEARCH_CLIENT_DEADLINE_MS);
  return mutationOptions<z.infer<typeof exploreSearchResponseSchema>, Error, { topicID: string }>({
    mutationKey: ['news-explore-search'], retry: false, networkMode: 'always', gcTime: 0,
    mutationFn: async ({ topicID }) => {
      reconcileCachedNews(client, now());
      const state = readExploreState(client, now());
      if (state.lifecycle.state !== 'available') throw new ExploreCommandError('stale', 'This exploration session is unavailable. Check local status or request new ideas explicitly.');
      const session = state.lifecycle.session, topic = session.topics.find(topic => topic.id === topicID);
      if (!topic || topic.status === 'obsolete' || topic.preview.state === 'expired') {
        throw new ExploreCommandError('stale', 'This topic is obsolete or expired. Request new ideas explicitly.');
      }
      if (state.searchRequestIDs[topicID] || topic.preview.state === 'pending' || topic.preview.state === 'uncertain') {
        throw new ExploreCommandError('busy', 'Check local status before searching this topic again.');
      }
      if (session.topics.filter(topic => topic.preview.state === 'pending').length >= EXPLORE_MAX_CONCURRENT_SEARCHES) {
        throw new ExploreCommandError('busy', 'Two topic searches are already running. Wait or check local status.');
      }
      const validated = exploreSearchRequestSchema.safeParse({ expectedSessionRevision: session.revision,
        search: state.drafts[topicID] ?? topic.proposedSearch });
      if (!validated.success) throw new ExploreCommandError('confirmed', validated.error.issues[0]?.message ?? 'Review the topic search.');
      const request = validated.data, requestID = crypto.randomUUID();
      const attempt = { requestID, search: request.search, startedAt: new Date(now()).toISOString() };
      const previous = retainedExploreResult(topic.preview);
      // Reserve synchronously before cancellation/fetch. The captured request is
      // independent of subsequent selection or draft edits, with no AI mode.
      client.setQueryData(exploreStateKey, updateExplorePreview(state, topicID, { state: 'pending', attempt, previous }, requestID));
      const owns = () => {
        reconcileCachedNews(client, now());
        const current = readExploreState(client, now());
        return current.lifecycle.state === 'available' && current.lifecycle.session.id === session.id &&
          current.lifecycle.session.revision === session.revision && current.searchRequestIDs[topicID] === requestID &&
          current.lifecycle.session.topics.some(topic => topic.id === topicID && topic.status === 'available');
      };
      const cancelRecovery = () => {
        const current = readExploreState(client, now());
        if (current.recovery.state === 'pending') client.setQueryData(exploreStateKey, { ...current, recovery: { state: 'idle' } });
        return client.cancelQueries({ queryKey: recoveryKey });
      };
      try {
        await cancelRecovery();
        if (!owns()) throw staleResponse();
        const result = await exploreRequest(`/news/explore/${session.id}/topics/${topicID}/search`, 'POST',
          exploreSearchResponseSchema, timeoutMs, undefined, request);
        if (!owns()) throw staleResponse();
        // Strict runtime DTO validation is not sufficient: it must identify this
        // command and its exact producing specification, not another topic/query.
        if (result.sessionID !== session.id || result.sessionRevision !== session.revision || result.topicID !== topicID ||
          !('result' in result.preview) || JSON.stringify(result.preview.result.search) !== JSON.stringify(request.search)) {
          throw new ExploreCommandError('uncertain', 'The search response did not match this topic and query. Check local status.');
        }
        client.setQueryData(exploreStateKey, updateExplorePreview(readExploreState(client, now()), topicID, result.preview, null));
        void cancelRecovery();
        return result;
      } catch (error) {
        if (owns()) {
          const failure = error instanceof ExploreCommandError ? error : new ExploreCommandError('uncertain', 'The search outcome is unknown. Check local status.');
          const current = readExploreState(client, now());
          if (failure.status === 410) {
            client.setQueryData<ExploreClientState>(exploreStateKey, { ...current, lifecycle: { state: 'expired' },
              drafts: {}, selectedTopicID: null, searchRequestIDs: {} });
          } else {
            // A 409 may mean revoked context, revision conflict or an earlier
            // server operation still running. Only local recovery can disambiguate.
            const preview: ExplorePreview = failure.outcome === 'uncertain' || failure.status === 409 ? { state: 'uncertain', attempt, previous } :
              previous ? { state: 'failed-retained', attempt, previous, error: { code: 'search-failed', error: failure.message } } :
                { state: 'failed', attempt, error: { code: 'search-failed', error: failure.message } };
            client.setQueryData(exploreStateKey, updateExplorePreview(current, topicID, preview, null));
          }
          void cancelRecovery();
        }
        throw error;
      }
    },
  });
}
export function useExploreSearch() { return useMutation(exploreSearchOptions(useQueryClient())); }
export function useExploreGeneration() { return useMutation(exploreGenerationOptions(useQueryClient())); }
export function useExploreRecovery() { return useMutation(exploreRecoveryOptions(useQueryClient())); }
