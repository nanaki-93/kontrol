import { z } from 'zod';
import type { Article, NewsState } from './schema';

export const MIN_INTEREST_WORDS = 5;
/** Interest-prefixed run error that states the retained-results guarantee exactly once. */
export function discoveryRunError(interestName: string, error: string): string {
  return interestName + ': ' + error + (/saved results are retained|saved data is kept/i.test(error) ? '' : ' Saved results are retained.');
}
export function newsSearchQuery(value: string): string {
  return value.replace(/\b(?:don['’]t|do not)\s+(?:get|show|give|send|return|find)\s+(?:me\s+)?(?:any\s+)?job\s+(?:offers?|listings?)[.!?]*/gi, ' ')
    .replace(/\)\s*\(/g, ') (').replace(/\s+/g, ' ').trim();
}
/** Reject obvious landing pages and listings; retrieved page evidence decides the rest. */
export function canBeNewsArticleURL(value: string): boolean {
  try {
    const url = new URL(value);
    if (!['http:', 'https:'].includes(url.protocol) || url.username || url.password) return false;
    const parts = decodeURIComponent(url.pathname).toLowerCase().split('/').filter(Boolean);
    if (/^(?:en|ja|jp)(?:-[a-z]{2})?$/.test(parts[0] ?? '')) parts.shift();
    if (!parts.length || (parts.length === 1 && /^(?:index\.(?:html?|php)|home|about|search|news|blog|articles|insights|press|research|updates|releases)$/.test(parts[0]))) return false;
    const editorial = parts.some(part => ['blog', 'news', 'articles', 'insights'].includes(part));
    if (!editorial && parts.some(part => ['jobs', 'job', 'job-listings', 'job-offers', 'careers', 'vacancies', 'positions', 'openings', 'apply', 'companies', 'employers'].includes(part))) return false;
    if (['tags', 'tag', 'category', 'categories', 'search'].includes(parts[0])) return false;
    return true;
  } catch { return false; }
}
function searchText(value: string): string {
  return newsSearchQuery(value).normalize('NFKC')
    .replace(/(?:^|\s)-(?:"[^"]*"|[^\s)]+)/g, ' ')
    .replace(/\b(?:site|intitle|inurl|when|before|after):(?:"[^"]*"|[^\s)]+)/gi, ' ');
}
function searchWords(query: string, language: 'en' | 'ja'): string[] {
  return [...new Intl.Segmenter(language, { granularity: 'word' }).segment(searchText(query))]
    .filter(part => part.isWordLike && /\p{L}/u.test(part.segment) && !/^(?:AND|OR|NOT)$/i.test(part.segment))
    .map(part => part.segment.toLocaleLowerCase());
}
export function interestWordCount(query: string, language: 'en' | 'ja' = 'en'): number {
  return searchWords(query, language).length;
}
const interestFieldsSchema = z.object({
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
export const interestDraftSchema = interestFieldsSchema.refine(value => interestWordCount(value.query, value.language) >= MIN_INTEREST_WORDS,
  { path: ['query'], message: 'Describe your search in at least 5 words, including the topic and what you want to find.' });
// Stored preferences and backups remain readable; short legacy queries need
// editing before another search, rather than being rewritten or discarded.
export const interestSchema = interestFieldsSchema.extend({ id: z.uuid(), revision: z.uuid() });
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
export interface DiscoveredArticle extends Article { matches: DiscoveryMatch[]; contentKind?: 'article' | 'job' | 'generic' }
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
  const value = normalized(term);
  let escaped = value.replace(/[.*+?^$(){}[\]\\]/g, '\\$&');
  if (!escaped) return false;
  // Regular English forms such as release/releases/released and developer/developers.
  if (/^[a-z]{4,}$/.test(value) && !/(?:s|ed|ing)$/.test(value)) escaped = value.endsWith('e') ?
    '(?:' + escaped + '(?:s|d)?|' + escaped.slice(0, -1) + 'ing)' : escaped + '(?:s|es|ed|ing)?';
  // Latin keywords respect word boundaries; CJK phrases use substring matching.
  return /[\u3040-\u30ff\u3400-\u9fff]/u.test(term) ? text.includes(normalized(term)) :
    new RegExp('(?:^|[^\\p{L}\\p{N}])' + escaped + '(?=$|[^\\p{L}\\p{N}])', 'u').test(text);
}
export function matchesInterest(article: Pick<Article, 'title' | 'summary'>, interest: NewsInterest): boolean {
  const text = normalized(article.title + ' ' + article.summary);
  return !interest.excludedTerms.some(term => hasTerm(text, term)) &&
    interest.requiredTerms.every(group => group.split('|').some(term => hasTerm(text, term)));
}
const fillerWords = new Set(['a', 'an', 'the', 'of', 'for', 'in', 'on', 'to', 'with', 'by', 'at', 'from', 'as', 'is', 'are',
  'be', 'my', 'about', 'latest', 'news', 'updates']);
type InterestKeywords = Pick<NewsInterest, 'query' | 'language' | 'requiredTerms' | 'excludedTerms'>;
function keywordFit(article: Pick<Article, 'title' | 'summary'>, interest: InterestKeywords) {
  const text = normalized(article.title + ' ' + article.summary);
  const terms = [...new Set(searchWords(interest.query, interest.language).filter(term => !fillerWords.has(term)))];
  const words = terms.filter(term => hasTerm(text, term)).length;
  const groups = interest.requiredTerms.filter(group => group.split('|').some(term => hasTerm(text, term))).length;
  const queryFit = terms.length ? words / terms.length : 0;
  const coverage = interest.requiredTerms.length ? .7 * groups / interest.requiredTerms.length + .3 * queryFit : queryFit;
  const excluded = interest.excludedTerms.some(term => hasTerm(text, term));
  return { score: excluded ? 0 : Math.round(100 * coverage), reason: excluded ? 'Contains a phrase you excluded.' :
    `${words} of ${terms.length} search keywords match` + (interest.requiredTerms.length ? `; ${groups} of ${interest.requiredTerms.length} required concepts match.` : '.') };
}
/** Content fit only. Publication age is handled by the date window and ordering. */
export function relevanceForInterest(article: Pick<Article, 'title' | 'summary'>, interest: InterestKeywords): number {
  return keywordFit(article, interest).score;
}
export interface InterestFit {
  interest: NewsInterest; score: number; reason: string; method: 'keywords' | 'ai';
}
export function articleInterestFits(article: Pick<Article, 'title' | 'summary'> & { matches?: DiscoveryMatch[] }, interests: NewsInterest[]): InterestFit[] {
  return interests.filter(interest => interest.enabled).map(interest => {
    const match = article.matches?.find(match => match.interestID === interest.id && match.interestRevision === interest.revision &&
      match.mode === 'ai' && Number.isFinite(match.score) && match.score >= 0 && match.score <= 100);
    if (match) return { interest, score: Math.round(match.score), reason: match.reason, method: 'ai' as const };
    return { interest, ...keywordFit(article, interest), method: 'keywords' as const };
  }).sort((a, b) => b.score - a.score);
}
export function visibleDiscoveries(state: DiscoveryState, interestID?: string, now = Date.now()): DiscoveredArticle[] {
  const enabled = state.preferences.interests.filter(i => i.enabled && (!interestID || i.id === interestID));
  return state.articles.map(article => ({ ...article, matches: article.matches.filter(match => enabled.some(i =>
    i.id === match.interestID && i.revision === match.interestRevision &&
    Date.parse(article.publishedAt ?? article.fetchedAt) >= now - i.days * 86_400_000)) }))
    .filter(a => a.matches.length > 0 && canBeNewsArticleURL(a.url) && (!a.contentKind || a.contentKind === 'article'))
    .sort((a, b) => (b.publishedAt ? Date.parse(b.publishedAt) : -Infinity) - (a.publishedAt ? Date.parse(a.publishedAt) : -Infinity) ||
      Math.max(...b.matches.map(m => m.score)) - Math.max(...a.matches.map(m => m.score)));
}
