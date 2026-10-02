import { z } from 'zod';
import type { Article, NewsState } from './schema';

export const interestDraftSchema = z.object({
  name: z.string().trim().min(1).max(100),
  query: z.string().trim().min(3).max(600),
  language: z.enum(['en', 'ja']),
  region: z.enum(['US', 'JP', 'GB', 'PH']),
  days: z.union([z.literal(1), z.literal(7), z.literal(30)]),
  intent: z.enum(['news', 'opportunities']),
  // Each entry is a required concept; "|" separates alternatives in that group.
  requiredTerms: z.array(z.string().trim().min(1).max(120)).max(8),
  excludedTerms: z.array(z.string().trim().min(1).max(100)).max(12),
  enabled: z.boolean(),
});
export const interestSchema = interestDraftSchema.extend({ id: z.uuid(), revision: z.uuid() });
export type NewsInterest = z.infer<typeof interestSchema>;
export type InterestDraft = z.infer<typeof interestDraftSchema>;
export const discoveryPreferencesSchema = z.object({
  schemaVersion: z.literal(1), interests: z.array(interestSchema).max(12),
}).refine(value => new Set(value.interests.map(i => i.id)).size === value.interests.length, 'Duplicate interests.');
export type DiscoveryPreferences = z.infer<typeof discoveryPreferencesSchema>;
export type SearchMode = 'search' | 'ai';
export interface DiscoveryMatch {
  interestID: string; interestRevision: string; mode: SearchMode; score: number; reason: string;
}
export interface DiscoveredArticle extends Article { matches: DiscoveryMatch[] }
export interface DiscoveryRun {
  interestRevision: string; attemptedAt: string; succeededAt: string | null;
  mode: SearchMode; count: number; error: string | null;
}
export interface DiscoveryState {
  preferences: DiscoveryPreferences;
  articles: DiscoveredArticle[];
  runs: Record<string, DiscoveryRun>;
}
export interface NewsResponse extends NewsState {
  discovery: DiscoveryState;
  ai: { configured: boolean; provider: 'pi'; model: string; message: string };
  activity: { discovering: boolean; refreshingFeeds: boolean };
}
export const interestPresets: InterestDraft[] = [
  {
    name: 'Programming jobs in Japan',
    query: 'Japan (developer OR "software engineer" OR programming) (jobs OR hiring OR recruitment)',
    language: 'en', region: 'JP', days: 30, intent: 'opportunities',
    requiredTerms: ['Japan|Tokyo|Osaka|Japanese', 'software|developer|programming|engineer', 'job|jobs|hiring|career|recruitment'],
    excludedTerms: [], enabled: true,
  },
  {
    name: 'AI models & releases',
    query: '("AI model" OR "language model" OR LLM) (release OR launch OR benchmark OR "open weights")',
    language: 'en', region: 'US', days: 7, intent: 'news',
    requiredTerms: ['AI|LLM|language model|artificial intelligence', 'model|models', 'release|launch|benchmark|weights|introduces|unveils|announces'],
    excludedTerms: ['stock price'], enabled: true,
  },
];

function normalized(value: string): string { return value.normalize('NFKC').toLocaleLowerCase().replace(/\s+/g, ' ').trim(); }
function hasTerm(text: string, term: string): boolean {
  const escaped = normalized(term).replace(/[.*+?^$(){}[\]\\]/g, '\\$&');
  if (!escaped) return false;
  // Latin keywords respect word boundaries; CJK phrases use substring matching.
  return /[\u3040-\u30ff\u3400-\u9fff]/u.test(term) ? text.includes(normalized(term)) :
    new RegExp('(?:^|[^\\p{L}\\p{N}])' + escaped + '(?=$|[^\\p{L}\\p{N}])', 'u').test(text);
}
export function matchesInterest(article: Pick<Article, 'title' | 'summary'>, interest: NewsInterest): boolean {
  const text = normalized(article.title + ' ' + article.summary);
  return !interest.excludedTerms.some(term => hasTerm(text, term)) &&
    interest.requiredTerms.every(group => group.split('|').some(term => hasTerm(text, term)));
}
export function rankForInterest(article: Article, interest: NewsInterest, at: number): number {
  const terms = normalized(interest.query).split(/[^\p{L}\p{N}]+/u).filter(t => t.length > 2);
  const title = normalized(article.title), body = normalized(article.summary);
  const relevance = terms.length ? terms.reduce((n, t) => n + (hasTerm(title, t) ? 2 : hasTerm(body, t) ? 1 : 0), 0) / (2 * terms.length) : 0;
  const age = article.publishedAt ? Math.max(0, at - Date.parse(article.publishedAt)) / 86_400_000 : interest.days;
  return Math.round(70 * relevance + 30 * Math.max(0, 1 - age / interest.days));
}
export function visibleDiscoveries(state: DiscoveryState, interestID?: string, now = Date.now()): DiscoveredArticle[] {
  const enabled = state.preferences.interests.filter(i => i.enabled && (!interestID || i.id === interestID));
  return state.articles.map(article => ({ ...article, matches: article.matches.filter(match => enabled.some(i =>
    i.id === match.interestID && i.revision === match.interestRevision &&
    Date.parse(article.publishedAt ?? article.fetchedAt) >= now - i.days * 86_400_000)) }))
    .filter(a => a.matches.length > 0)
    .sort((a, b) => Math.max(...b.matches.map(m => m.score)) - Math.max(...a.matches.map(m => m.score)) ||
      (b.publishedAt ?? b.fetchedAt).localeCompare(a.publishedAt ?? a.fetchedAt));
}
