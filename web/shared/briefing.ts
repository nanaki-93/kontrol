import { articleInterestFits, relevanceForInterest, visibleDiscoveries, type DiscoveredArticle, type NewsResponse } from './news';
import type { Article } from './schema';
import { canonicalURL, groupStories, type StoryGroup, type Workspace } from './workspace';

// Edition policy (SPEC B4). The weights are planning assumptions kept in one
// place so they can be tuned; tests fix the resulting orders.
/** Maximum story groups in the personal edition (News → Briefing). */
export const EDITION_LIMIT = 5;
/** Story groups previewed on Today: always the first groups of the same edition. */
export const EDITION_PREVIEW_LIMIT = 3;
/** Groups at or above this relevance (0–100) are used before any lower-relevance group. */
export const RELEVANCE_FLOOR = 50;
/** Maximum recency bonus, for a story published now. */
export const RECENCY_POINTS = 20;
/** The recency bonus falls linearly to 0 over this many days. A scoring horizon, not an eligibility cutoff. */
export const RECENCY_HORIZON_DAYS = 7;
/** Subtracted per already-selected group with the same interest or profile context. */
export const INTEREST_REPEAT_PENALTY = 25;
/** Subtracted per already-selected group from the same (heuristic) publisher. */
export const PUBLISHER_REPEAT_PENALTY = 15;

export type EditionArticle = Article | DiscoveredArticle;
/** Grounded selection context. Labels come from the user's own configuration, never generated text. */
export type EditionContext =
  | { kind: 'interest'; interestID: string; label: string }
  | { kind: 'profile-interest'; label: string }
  | { kind: 'target-role'; label: string }
  | { kind: 'recent' };
export interface EditionStory<T = EditionArticle> extends StoryGroup<T> { relevance: number; context: EditionContext }
export type EditionEmptyReason = 'no-interests' | 'no-matches' | 'not-searched';

const DAY = 86_400_000;
function normalizedText(value: string): string { return value.normalize('NFKC').toLowerCase().replace(/\s+/g, ' ').trim(); }
/** Locale-independent code point order, so results do not depend on the runtime locale. */
function codeOrder(a: string, b: string): number { return a < b ? -1 : a > b ? 1 : 0; }
/** Missing and unparsable dates are both undated; retrieval time is never used. */
function publishedTime(article: Pick<Article, 'publishedAt'>): number | null {
  const time = article.publishedAt ? Date.parse(article.publishedAt) : NaN;
  return Number.isFinite(time) ? time : null;
}
function recencyBonus(time: number | null, now: number): number {
  if (time === null) return 0;
  return RECENCY_POINTS * Math.max(0, 1 - Math.max(0, now - time) / DAY / RECENCY_HORIZON_DAYS);
}

/**
 * Heuristic publisher identity: the normalized source name, else the URL host.
 * Search placeholders and Google News redirect hosts are unknown (`null`) so
 * different publishers are never counted as one.
 */
export function publisherKey(article: Pick<Article, 'source' | 'url'>): string | null {
  const source = normalizedText(article.source).replace(/^www\./, '');
  if (source && source !== 'news search' && source !== 'news.google.com') return source;
  let host: string;
  try { host = new URL(article.url).hostname.toLowerCase().replace(/^www\./, ''); } catch { return null; }
  return host && host !== 'news.google.com' ? host : null;
}

interface Candidate {
  article: EditionArticle; url: string; time: number | null;
  relevance: number; context: EditionContext; interestKey: string | null;
}
/** relevance ↓ → dated before undated → publishedAt ↓ → canonical URL ↑ */
function compareCandidates(a: Candidate, b: Candidate): number {
  return b.relevance - a.relevance || (a.time === null ? 1 : 0) - (b.time === null ? 1 : 0) ||
    (b.time ?? 0) - (a.time ?? 0) || codeOrder(a.url, b.url);
}

/**
 * The personal edition: up to `EDITION_LIMIT` story groups chosen for relevance
 * and variety from the existing eligible candidates. Pure and deterministic:
 * depends only on news state, the workspace profile and `now`; never on saved,
 * read or notes records.
 */
export function briefingStories(news: NewsResponse, workspace?: Workspace, now = Date.now()): EditionStory[] {
  // B1: eligibility rules are unchanged.
  const enabled = new Set(news.preferences.feeds.filter(f => f.isEnabled).map(f => f.id));
  const eligible: EditionArticle[] = [...visibleDiscoveries(news.discovery, undefined, now), ...news.articles.filter(a =>
    a.feedIDs.some(id => enabled.has(id)) && a.topicIDs.some(id => news.preferences.selectedTopicIDs.includes(id)))];
  const interests = news.discovery.preferences.interests;
  const profile = [...(workspace?.profile.interests ?? []).map(label => ({ kind: 'profile-interest' as const, label })),
    ...(workspace?.profile.targetRoles ?? []).map(label => ({ kind: 'target-role' as const, label }))];

  // B3: per-article relevance and grounded context.
  const candidates: Candidate[] = [];
  for (const article of eligible) {
    let url: string;
    try { url = canonicalURL(article.url); } catch { continue; }
    const fit = articleInterestFits(article, interests)[0];
    const interestScore = fit?.score ?? 0;
    let profileScore = 0, profileMatch: (typeof profile)[number] | undefined;
    for (const term of profile) {
      const score = relevanceForInterest(article, { query: term.label, language: 'en', requiredTerms: [], excludedTerms: [] });
      if (score > profileScore) { profileScore = score; profileMatch = term; }
    }
    const relevance = Math.max(0, interestScore, profileScore);
    let context: EditionContext = { kind: 'recent' }, interestKey: string | null = null;
    if (fit && interestScore >= RELEVANCE_FLOOR && interestScore >= profileScore) {
      context = { kind: 'interest', interestID: fit.interest.id, label: fit.interest.name };
      interestKey = 'interest:' + fit.interest.id;
    } else if (profileMatch && profileScore >= RELEVANCE_FLOOR && profileScore > interestScore) {
      context = { kind: profileMatch.kind, label: profileMatch.label };
      interestKey = 'profile:' + normalizedText(profileMatch.label);
    }
    candidates.push({ article, url, time: publishedTime(article), relevance, context, interestKey });
  }

  // B2: deterministic order, so each group's lead is its most relevant member.
  // Extra tie-breaks make exact URL duplicates independent of input order.
  candidates.sort((a, b) => compareCandidates(a, b) || codeOrder(a.article.id, b.article.id) ||
    codeOrder(a.article.url, b.article.url) || codeOrder(JSON.stringify(a.article), JSON.stringify(b.article)));
  const byArticle = new Map(candidates.map(candidate => [candidate.article, candidate]));
  // Group every eligible candidate (no limit) so related coverage ranked after
  // the selected leads is retained and variety is not limited to a truncated pool.
  const pool = groupStories(candidates.map(candidate => candidate.article)).map(group => {
    const candidate = byArticle.get(group.lead)!;
    return { group, candidate, recency: recencyBonus(candidate.time, now), publisher: publisherKey(group.lead) };
  });

  // B4: floor-tiered greedy selection with soft repeat penalties.
  const interestCounts = new Map<string, number>(), publisherCounts = new Map<string, number>();
  const count = (counts: Map<string, number>, key: string | null) => key === null ? 0 : counts.get(key) ?? 0;
  const edition: EditionStory[] = [];
  while (edition.length < EDITION_LIMIT && pool.length) {
    const relevantTier = pool.some(item => item.candidate.relevance >= RELEVANCE_FLOOR);
    let best = -1, bestScore = -Infinity;
    pool.forEach((item, index) => {
      if (relevantTier && item.candidate.relevance < RELEVANCE_FLOOR) return;
      const raw = item.candidate.relevance + item.recency - INTEREST_REPEAT_PENALTY * count(interestCounts, item.candidate.interestKey) -
        PUBLISHER_REPEAT_PENALTY * count(publisherCounts, item.publisher);
      // Round away floating-point noise so equal scores reach the documented tie-breaks.
      const score = Math.round(raw * 1e6) / 1e6;
      if (best < 0 || score > bestScore || (score === bestScore && compareCandidates(item.candidate, pool[best].candidate) < 0)) {
        best = index; bestScore = score;
      }
    });
    const [pick] = pool.splice(best, 1);
    const { interestKey } = pick.candidate;
    if (interestKey !== null) interestCounts.set(interestKey, count(interestCounts, interestKey) + 1);
    if (pick.publisher !== null) publisherCounts.set(pick.publisher, count(publisherCounts, pick.publisher) + 1);
    edition.push({ lead: pick.group.lead, related: pick.group.related, relevance: pick.candidate.relevance, context: pick.candidate.context });
  }
  return edition;
}

/** Selected leads that have a workspace record marked read, matched by canonical URL. */
export function editionReadCount(groups: readonly StoryGroup<Pick<Article, 'url'>>[], workspace?: Pick<Workspace, 'articles'>): number {
  if (!workspace) return 0;
  const read = new Set<string>();
  for (const record of workspace.articles) {
    if (!record.readAt) continue;
    try { read.add(canonicalURL(record.article.url)); } catch { /* Unparsable records cannot match a lead. */ }
  }
  return groups.filter(group => { try { return read.has(canonicalURL(group.lead.url)); } catch { return false; } }).length;
}

/** Why the edition is empty, derived from existing state without any request. */
export function editionEmptyReason(news: Pick<NewsResponse, 'discovery'>): EditionEmptyReason {
  const enabled = news.discovery.preferences.interests.filter(interest => interest.enabled);
  if (!enabled.length) return 'no-interests';
  // A run belongs to the interest's current revision; editing an interest clears it on the server.
  return enabled.some(interest => {
    const run = news.discovery.runs[interest.id];
    return !!run && run.interestRevision === interest.revision && run.error === null;
  }) ? 'no-matches' : 'not-searched';
}
