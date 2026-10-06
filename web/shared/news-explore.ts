import { z } from 'zod';
import {
  interestDraftSchema, interestSchema, interestWordCount, MIN_INTEREST_WORDS,
  type InterestDraft, type NewsInterest,
} from './news';
import { id as articleID, instant } from './schema';
import { articleSnapshotSchema, canonicalURL } from './workspace';

// Process-local policy: one live session, absolute expiry (reads never renew it).
// Successful generation atomically replaces it; failure retains the old session.
// Expiry/revocation removes evidence. Keep no unbounded expiry tombstones.
// At publication, trim whole trailing articles in retrieval order, or reject an
// oversized replacement without destroying the old session. Include submission
// bookkeeping in the byte budget; submissions expire no later than the session.
export const EXPLORE_MAX_SESSIONS = 1;
export const EXPLORE_SESSION_TTL_MS = 30 * 60_000;
export const EXPLORE_CLIENT_RETENTION_MS = EXPLORE_SESSION_TTL_MS;
export const EXPLORE_MAX_TOPICS = 3;
export const EXPLORE_MAX_ARTICLES_PER_TOPIC = 40;
export const EXPLORE_MAX_ARTICLES = EXPLORE_MAX_TOPICS * EXPLORE_MAX_ARTICLES_PER_TOPIC;
export const EXPLORE_MAX_RETAINED_BYTES = 8 * 1024 * 1024;
export const EXPLORE_MAX_FOLLOW_SUBMISSIONS = 64;
export const EXPLORE_MAX_GENERATIONS = 1;
export const EXPLORE_MAX_CONCURRENT_SEARCHES = 2;
export const EXPLORE_MAX_SEARCHES_PER_TOPIC = 1;
export const EXPLORE_MAX_TITLE_CHARS = 100;
export const EXPLORE_MAX_DESCRIPTION_CHARS = 280;
export const EXPLORE_MAX_CONNECTION_CHARS = 280;
export const EXPLORE_MAX_QUERY_CHARS = 600;
export const EXPLORE_MAX_MODEL_BYTES = 64 * 1024;
export const EXPLORE_MAX_MODEL_CANDIDATES = 12;
export const EXPLORE_AVAILABILITY_DEADLINE_MS = 5_000;
export const EXPLORE_IDEATION_DEADLINE_MS = 60_000;
// Covers availability AND inference, not two independent unbounded waits.
export const EXPLORE_GENERATION_DEADLINE_MS = EXPLORE_AVAILABILITY_DEADLINE_MS + EXPLORE_IDEATION_DEADLINE_MS;
export const EXPLORE_GENERATION_CLIENT_DEADLINE_MS = 75_000;
export const EXPLORE_SEARCH_DEADLINE_MS = 20_000;
export const EXPLORE_SEARCH_CLIENT_DEADLINE_MS = 30_000;
export const EXPLORE_RECOVERY_DEADLINE_MS = 5_000;
export const EXPLORE_RECOVERY_CLIENT_DEADLINE_MS = 10_000;
export const EXPLORE_FOLLOW_DEADLINE_MS = 10_000;
export const EXPLORE_FOLLOW_CLIENT_DEADLINE_MS = 15_000;

export function exploreBytes(value: unknown): number {
  return new TextEncoder().encode(JSON.stringify(value)).byteLength;
}
export function exploreExpired(expiresAt: string, now: number): boolean {
  return now >= Date.parse(expiresAt);
}

export const exploreIdentitySchema = z.strictObject({ id: z.uuid(), revision: z.uuid() });
export const exploreSourceSchema = z.strictObject({ id: z.uuid(), revision: z.uuid() });
export const exploreSourcesSchema = z.array(exploreSourceSchema).min(1).max(12)
  .refine(items => new Set(items.map(item => item.id)).size === items.length, 'Duplicate source interests.');
export type ExploreSource = z.infer<typeof exploreSourceSchema>;
export function exploreSourceCurrent(source: ExploreSource, interests: readonly NewsInterest[]): boolean {
  return interests.some(interest => interest.enabled && interest.id === source.id && interest.revision === source.revision);
}

// Reuse locale/query bounds, but ALWAYS apply the enabled-search word rule.
// No intent, filters, mode, article snapshots, or disabled-query escape hatch.
export const exploreSearchSchema = interestSchema.pick({ query: true, language: true, region: true, days: true }).strict()
  .refine(value => interestWordCount(value.query, value.language) >= MIN_INTEREST_WORDS,
    { path: ['query'], message: 'Describe your search in at least 5 words, including the topic and what you want to find.' });
export type ExploreSearch = z.infer<typeof exploreSearchSchema>;
export function proposedExploreSearch(query: string, source: NewsInterest): ExploreSearch {
  return exploreSearchSchema.parse({ query, language: source.language, region: source.region, days: source.days });
}
/** For injected Standard retrieval only; never persist this synthetic interest. */
export function exploreSearchDescriptor(identity: z.infer<typeof exploreIdentitySchema>, title: string, search: ExploreSearch): NewsInterest {
  return { ...exploreIdentitySchema.parse(identity), ...interestDraftSchema.strict().parse({
    name: title, ...exploreSearchSchema.parse(search), intent: 'news', enabled: true, requiredTerms: [], excludedTerms: [],
  }) };
}

const ideaText = (max: number) => z.string().trim().min(1).max(max)
  .refine(value => !/(?:https?:\/\/|www\.)/i.test(value), 'Topic ideas must not contain article links.');
// A model may reference a source, but may NOT issue internal IDs/revisions or
// evidence. Query word validation needs the referenced source's language below.
export const exploreModelCandidateSchema = z.strictObject({
  sourceInterestID: z.uuid(), title: ideaText(EXPLORE_MAX_TITLE_CHARS),
  description: ideaText(EXPLORE_MAX_DESCRIPTION_CHARS), connection: ideaText(EXPLORE_MAX_CONNECTION_CHARS),
  query: ideaText(EXPLORE_MAX_QUERY_CHARS),
});
export const exploreModelEnvelopeSchema = z.strictObject({
  topics: z.array(z.unknown()).max(EXPLORE_MAX_MODEL_CANDIDATES),
});
export type ExploreModelCandidate = z.infer<typeof exploreModelCandidateSchema>;
export interface ValidatedExploreIdea extends Omit<ExploreModelCandidate, 'query'> {
  sourceInterestRevision: string;
  proposedSearch: ExploreSearch;
}
export type ExploreIdeaValidation =
  | { state: 'invalid-envelope' }
  | { state: 'no-valid-ideas'; rejectedCount: number }
  | { state: 'accepted'; ideas: ValidatedExploreIdea[]; rejectedCount: number; partial: boolean };

/** Obvious title duplicates only, not semantic novelty detection. */
export function normalizeExploreTitle(value: string): string {
  return value.normalize('NFKC').toLowerCase().replace(/[^\p{L}\p{N}]+/gu, ' ').trim();
}
/** Keep case, operators, quotes, exclusions and punctuation significant.
 * Standard search distinguishes Boolean OR from literal or; false negatives
 * are safer than merging distinct queries during duplicate-follow protection.
 */
export function normalizeExploreQuery(value: string): string {
  return value.normalize('NFKC').replace(/\s+/g, ' ').trim();
}
// Keyword filters use case-insensitive matching, unlike Standard query syntax.
function normalizeExploreFilter(value: string): string {
  return normalizeExploreQuery(value).toLowerCase();
}
/** Bounded envelope first, independent siblings next; no repair/filler/retry. */
export function validateExploreIdeas(text: string, sources: readonly NewsInterest[]): ExploreIdeaValidation {
  if (new TextEncoder().encode(text).byteLength > EXPLORE_MAX_MODEL_BYTES) return { state: 'invalid-envelope' };
  let raw: unknown;
  try { raw = JSON.parse(text); } catch { return { state: 'invalid-envelope' }; }
  const envelope = exploreModelEnvelopeSchema.safeParse(raw);
  if (!envelope.success) return { state: 'invalid-envelope' };
  const enabled = sources.filter(source => source.enabled);
  const titles = new Set(enabled.map(source => normalizeExploreTitle(source.name)));
  const queries = new Set(enabled.map(source => normalizeExploreQuery(source.query)));
  const ideas: ValidatedExploreIdea[] = [];
  let rejectedCount = 0;
  for (const rawCandidate of envelope.data.topics) {
    const parsed = exploreModelCandidateSchema.safeParse(rawCandidate);
    if (!parsed.success) { rejectedCount++; continue; }
    const candidate = parsed.data;
    const source = enabled.find(source => source.id === candidate.sourceInterestID);
    const search = source ? exploreSearchSchema.safeParse({ query: candidate.query, language: source.language, region: source.region, days: source.days }) : null;
    const titleKey = normalizeExploreTitle(candidate.title), queryKey = normalizeExploreQuery(candidate.query);
    if (!source || !search?.success || !titleKey || titles.has(titleKey) || queries.has(queryKey)) { rejectedCount++; continue; }
    titles.add(titleKey); queries.add(queryKey);
    if (ideas.length < EXPLORE_MAX_TOPICS) ideas.push({ sourceInterestID: source.id, sourceInterestRevision: source.revision,
      title: candidate.title, description: candidate.description, connection: candidate.connection, proposedSearch: search.data });
  }
  return ideas.length ? { state: 'accepted', ideas, rejectedCount, partial: ideas.length < EXPLORE_MAX_TOPICS } :
    { state: 'no-valid-ideas', rejectedCount };
}

// Runtime evidence validation reuses the durable snapshot boundary. Standard
// previews contain source excerpts and no synthetic saved-interest provenance.
export const exploreArticleSchema = articleSnapshotSchema.extend({
  id: articleID, summaryKind: z.literal('source'),
  feedIDs: z.array(articleID).max(0), topicIDs: z.array(articleID).max(0),
}).strict();
export type ExploreArticle = z.infer<typeof exploreArticleSchema>;
export const exploreResultSchema = z.strictObject({
  search: exploreSearchSchema, succeededAt: instant,
  articles: z.array(exploreArticleSchema).max(EXPLORE_MAX_ARTICLES_PER_TOPIC)
    .refine(articles => new Set(articles.map(article => canonicalURL(article.url))).size === articles.length, 'Duplicate article links.'),
});
export const exploreAttemptSchema = z.strictObject({ requestID: z.uuid(), search: exploreSearchSchema, startedAt: instant });
const publicMessage = z.string().trim().min(1).max(500);
export const exploreErrorCodeSchema = z.enum([
  'invalid-input', 'no-interests', 'pi-unavailable', 'no-valid-ideas', 'generation-failed', 'search-failed',
  'busy', 'obsolete-source', 'stale-revision', 'session-gone', 'follow-capacity', 'submission-conflict', 'capacity',
]);
export const exploreErrorSchema = z.strictObject({ error: publicMessage, code: exploreErrorCodeSchema });
export type ExploreErrorCode = z.infer<typeof exploreErrorCodeSchema>;
export const EXPLORE_ERROR_HTTP_STATUS: Record<ExploreErrorCode, number> = {
  'invalid-input': 400, 'no-interests': 400, 'pi-unavailable': 400, 'no-valid-ideas': 502,
  'generation-failed': 502, 'search-failed': 502, busy: 409, 'obsolete-source': 409,
  'stale-revision': 409, 'session-gone': 410, 'follow-capacity': 400, 'submission-conflict': 409, capacity: 400,
};

export const explorePreviewSchema = z.discriminatedUnion('state', [
  z.strictObject({ state: z.literal('not-searched') }),
  z.strictObject({ state: z.literal('pending'), attempt: exploreAttemptSchema, previous: exploreResultSchema.nullable() }),
  z.strictObject({ state: z.literal('successful'), result: exploreResultSchema.refine(value => value.articles.length > 0, 'Use successful-empty for no results.') }),
  z.strictObject({ state: z.literal('successful-empty'), result: exploreResultSchema.refine(value => value.articles.length === 0, 'Empty searches cannot contain articles.') }),
  z.strictObject({ state: z.literal('failed'), attempt: exploreAttemptSchema, error: exploreErrorSchema }),
  z.strictObject({ state: z.literal('failed-retained'), attempt: exploreAttemptSchema, error: exploreErrorSchema, previous: exploreResultSchema }),
  z.strictObject({ state: z.literal('uncertain'), attempt: exploreAttemptSchema, previous: exploreResultSchema.nullable() }),
  z.strictObject({ state: z.literal('obsolete') }),
  z.strictObject({ state: z.literal('expired') }),
]).superRefine((preview, ctx) => {
  if ('previous' in preview && preview.previous && preview.previous.succeededAt > preview.attempt.startedAt) {
    ctx.addIssue({ code: 'custom', message: 'Retained coverage must precede the current attempt.' });
  }
});
export type ExplorePreview = z.infer<typeof explorePreviewSchema>;
export const exploreTopicSchema = z.strictObject({
  id: z.uuid(), sourceInterestID: z.uuid(), sourceInterestRevision: z.uuid(),
  title: ideaText(EXPLORE_MAX_TITLE_CHARS), description: ideaText(EXPLORE_MAX_DESCRIPTION_CHARS),
  connection: ideaText(EXPLORE_MAX_CONNECTION_CHARS), proposedSearch: exploreSearchSchema,
  status: z.enum(['available', 'obsolete']), preview: explorePreviewSchema,
}).refine(topic => topic.status === 'obsolete' ? topic.preview.state === 'obsolete' : topic.preview.state !== 'obsolete',
  'Obsolete topics cannot expose usable evidence.');
export type ExploreTopic = z.infer<typeof exploreTopicSchema>;
export const exploreSessionSchema = z.strictObject({
  id: z.uuid(), revision: z.uuid(), generatedAt: instant, expiresAt: instant,
  sources: exploreSourcesSchema, topics: z.array(exploreTopicSchema).min(1).max(EXPLORE_MAX_TOPICS),
}).superRefine((session, ctx) => {
  const lifetime = Date.parse(session.expiresAt) - Date.parse(session.generatedAt);
  if (lifetime <= 0 || lifetime > EXPLORE_SESSION_TTL_MS) ctx.addIssue({ code: 'custom', message: 'Invalid absolute session lifetime.' });
  if (new Set(session.topics.map(topic => topic.id)).size !== session.topics.length) ctx.addIssue({ code: 'custom', message: 'Duplicate topic IDs.' });
  if (new Set(session.topics.map(topic => normalizeExploreTitle(topic.title))).size !== session.topics.length ||
      new Set(session.topics.map(topic => normalizeExploreQuery(topic.proposedSearch.query))).size !== session.topics.length) {
    ctx.addIssue({ code: 'custom', message: 'Duplicate topic ideas.' });
  }
  for (const topic of session.topics) {
    if (!session.sources.some(source => source.id === topic.sourceInterestID && source.revision === topic.sourceInterestRevision)) {
      ctx.addIssue({ code: 'custom', message: 'Unknown source snapshot.' });
    }
  }
  if (exploreBytes(session) > EXPLORE_MAX_RETAINED_BYTES) ctx.addIssue({ code: 'custom', message: 'Exploration byte limit exceeded.' });
});
export type ExploreSession = z.infer<typeof exploreSessionSchema>;
export const exploreLifecycleSchema = z.discriminatedUnion('state', [
  z.strictObject({ state: z.literal('absent') }),
  z.strictObject({ state: z.literal('available'), session: exploreSessionSchema }),
  z.strictObject({ state: z.literal('obsolete') }),
  z.strictObject({ state: z.literal('expired') }),
]);
export const exploreGenerationSchema = z.discriminatedUnion('state', [
  z.strictObject({ state: z.literal('idle') }),
  z.strictObject({ state: z.literal('pending'), requestID: z.uuid(), startedAt: instant }),
  z.strictObject({ state: z.literal('failed'), error: exploreErrorSchema }),
  z.strictObject({ state: z.literal('uncertain') }),
]);
export const exploreStatusResponseSchema = z.strictObject({ lifecycle: exploreLifecycleSchema, generation: exploreGenerationSchema });
export const exploreGenerateResponseSchema = z.strictObject({ session: exploreSessionSchema, partial: z.boolean() })
  .refine(value => value.partial === (value.session.topics.length < EXPLORE_MAX_TOPICS), 'Partial notice must match the topic count.');
export const exploreSearchResponseSchema = z.strictObject({ sessionID: z.uuid(), sessionRevision: z.uuid(), topicID: z.uuid(), preview: explorePreviewSchema });
export const exploreFollowResponseSchema = z.strictObject({ interest: interestSchema.strict(), created: z.boolean() });

export const exploreGenerateRequestSchema = z.strictObject({});
export const exploreTopicParamsSchema = z.strictObject({ sessionID: z.uuid(), topicID: z.uuid() });
export const exploreSearchRequestSchema = z.strictObject({ expectedSessionRevision: z.uuid(), search: exploreSearchSchema });
export const exploreFollowRequestSchema = z.strictObject({
  expectedSessionRevision: z.uuid(), submissionID: z.uuid(), draft: interestDraftSchema.strict(),
});

/** Conservative equivalence, not fuzzy topic matching. Title is cosmetic.
 * Filter order is irrelevant, but group/alternative text is deliberately kept
 * significant (false negatives are safer than conflating different searches).
 */
export function exploreFollowKey(draft: InterestDraft): string {
  const validated = interestDraftSchema.strict().parse(draft);
  return JSON.stringify({ query: normalizeExploreQuery(validated.query), language: validated.language,
    region: validated.region, days: validated.days, intent: validated.intent, enabled: validated.enabled,
    requiredTerms: validated.requiredTerms.map(normalizeExploreFilter).sort(),
    excludedTerms: validated.excludedTerms.map(normalizeExploreFilter).sort(),
  });
}
export function equivalentExploreInterest(draft: InterestDraft, interest: NewsInterest): boolean {
  const { id: _id, revision: _revision, ...fields } = interestSchema.strict().parse(interest);
  // Short stored legacy queries remain readable but are not newly followable.
  const validated = interestDraftSchema.strict().safeParse(fields);
  return validated.success && exploreFollowKey(draft) === exploreFollowKey(validated.data);
}
export type IdeateExploreTopics = (enabledInterests: readonly NewsInterest[], signal: AbortSignal) => Promise<string>;
export interface TemporaryArticleResolver {
  resolve(url: string): { article: ExploreArticle; summaryKind: 'source' | 'ai-snippet' } | undefined;
}
