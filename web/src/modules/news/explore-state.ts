import type { z } from 'zod';
import type { NewsInterest } from '../../../shared/news';
import {
  exploreExpired, exploreSourceCurrent, type ExploreSearch, type ExploreSource,
  type ExploreSession, type exploreStatusResponseSchema,
} from '../../../shared/news-explore';

export type ExploreStatus = z.infer<typeof exploreStatusResponseSchema>;
export type ExploreRecovery = { state: 'idle' } | { state: 'pending'; requestID: string } | { state: 'failed'; error: string };
/** One finite, local QueryClient entry, not a persisted workspace document.
 * Ownership is deliberately separate from the server's lifecycle revision.
 */
export interface ExploreClientState extends ExploreStatus {
  owner: string;
  selectedTopicID: string | null;
  drafts: Record<string, ExploreSearch>;
  generationRequestID: string | null;
  generationSources: ExploreSource[] | null;
  recovery: ExploreRecovery;
}
export function emptyExploreState(): ExploreClientState {
  return { owner: crypto.randomUUID(), lifecycle: { state: 'absent' }, generation: { state: 'idle' },
    selectedTopicID: null, drafts: {}, generationRequestID: null, generationSources: null, recovery: { state: 'idle' } };
}
export function expireExploreState(state: ExploreClientState, now: number): ExploreClientState {
  if (state.lifecycle.state !== 'available' || !exploreExpired(state.lifecycle.session.expiresAt, now)) return state;
  return { ...state, lifecycle: { state: 'expired' }, selectedTopicID: null, drafts: {} };
}
export function reconcileExploreState(state: ExploreClientState, interests: readonly NewsInterest[]): ExploreClientState {
  let next = state;
  if (state.generationRequestID && state.generationSources?.some(source => !exploreSourceCurrent(source, interests))) {
    // Revocation is sticky: even restoring the old revision cannot admit the old completion.
    next = { ...next, owner: crypto.randomUUID(), generationRequestID: null, generationSources: null,
      generation: { state: 'failed', error: { code: 'obsolete-source', error: 'Saved interests changed. Request new ideas explicitly.' } },
      recovery: { state: 'idle' } };
  }
  if (next.lifecycle.state !== 'available') return next;
  const session = next.lifecycle.session;
  const revoked = session.topics.filter(topic => topic.status === 'available' && !exploreSourceCurrent({
    id: topic.sourceInterestID, revision: topic.sourceInterestRevision,
  }, interests));
  if (!revoked.length) return next;
  const ids = new Set(revoked.map(topic => topic.id));
  const drafts = Object.fromEntries(Object.entries(next.drafts).filter(([id]) => !ids.has(id)));
  return { ...next, owner: crypto.randomUUID(), recovery: { state: 'idle' },
    generation: next.generationRequestID ? { state: 'failed', error: { code: 'obsolete-source', error: 'Saved interests changed. Request new ideas explicitly.' } } : next.generation,
    generationRequestID: null, generationSources: null,
    lifecycle: { state: 'available', session: { ...session,
      topics: session.topics.map(topic => ids.has(topic.id) ? { ...topic, status: 'obsolete', preview: { state: 'obsolete' } } : topic),
    } }, drafts };
}
/** Same-session recovery must not erase dirty drafts/selection or undo a local
 * source revocation. A replacement has its own bounded topic entries.
 */
export function acceptExploreSession(state: ExploreClientState, supplied: ExploreSession, now: number): ExploreClientState {
  const previous = state.lifecycle.state === 'available' ? state.lifecycle.session : null;
  const same = previous?.id === supplied.id;
  const session = { ...supplied, topics: supplied.topics.map(topic => same && previous.topics.some(old => old.id === topic.id && old.status === 'obsolete') ?
    { ...topic, status: 'obsolete' as const, preview: { state: 'obsolete' as const } } : topic) };
  const drafts = Object.fromEntries(session.topics.filter(topic => topic.status === 'available').map(topic => [topic.id,
    same && state.drafts[topic.id] ? state.drafts[topic.id] : { ...topic.proposedSearch }]));
  const selectedTopicID = same && session.topics.some(topic => topic.id === state.selectedTopicID) ? state.selectedTopicID : session.topics[0].id;
  return expireExploreState({ ...state, lifecycle: { state: 'available', session }, drafts, selectedTopicID }, now);
}
export function acceptExploreStatus(state: ExploreClientState, status: ExploreStatus, now: number): ExploreClientState {
  let next = status.lifecycle.state === 'available' ? acceptExploreSession(state, status.lifecycle.session, now) :
    { ...state, lifecycle: status.lifecycle.state === 'absent' && state.lifecycle.state !== 'absent' ? { state: 'expired' as const } : status.lifecycle,
      drafts: {}, selectedTopicID: null };
  // Status is only a snapshot. It cannot end an in-flight client generation.
  next = { ...next, generation: state.generationRequestID ? state.generation : status.generation, recovery: { state: 'idle' } };
  return next;
}
