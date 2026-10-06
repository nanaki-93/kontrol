import { createHash, randomUUID } from 'node:crypto';
import {
  interestPresets, matchesInterest, relevanceForInterest, discoveryPreferencesSchema, canBeNewsArticleURL,
  type DiscoveryState, type NewsInterest, type DiscoveredArticle, type SearchMode,
} from '../../shared/news';
import { Store } from '../store';
import { parseFeed, canonicalURL } from './feeds';
import { fetchFeed, NewsFetchError } from './transport';

export type Discover = (interest: NewsInterest, signal?: AbortSignal) => Promise<DiscoveredArticle[]>;
// A caller's longer deadline must not remove the transport's usual 20-second bound.
export const STANDARD_SEARCH_TIMEOUT_MS = 20_000;

function eligibleCandidate(article: Pick<DiscoveredArticle, 'url' | 'contentKind' | 'publishedAt'>, interest: NewsInterest, now: number): boolean {
  if (!canBeNewsArticleURL(article.url) || (article.contentKind !== undefined && article.contentKind !== 'article')) return false;
  if (!article.publishedAt) return true; // Keep genuinely unknown publication dates unknown.
  const published = Date.parse(article.publishedAt);
  return Number.isFinite(published) && published >= now - interest.days * 86_400_000 && published <= now + 86_400_000;
}

async function fetchStandard(fetcher: typeof fetchFeed, endpoint: string, signal: AbortSignal): Promise<string> {
  let abort = () => {};
  try {
    return await new Promise<string>((resolve, reject) => {
      abort = () => reject(new NewsFetchError('timeout', 'The source took too long to respond. Try again.'));
      signal.addEventListener('abort', abort, { once: true });
      if (signal.aborted) { abort(); return; }
      // The race also bounds injected fetchers which ignore cancellation. Observe
      // late rejection, but never parse or publish a late successful response.
      Promise.resolve().then(() => {
        signal.throwIfAborted();
        return fetcher(endpoint, 0, signal);
      }).then(resolve, reject);
    });
  } finally { signal.removeEventListener('abort', abort); }
}
export function initialDiscovery(): DiscoveryState {
  return { preferences: { schemaVersion: 1, interests: interestPresets.map(p => ({ ...p, id: randomUUID(), revision: randomUUID() })) },
    articles: [], runs: {} };
}
export function getDiscovery(store: Store): DiscoveryState {
  // An additive, separate document preserves every existing feed and cached item.
  if (!store.has('newsDiscovery')) store.set('newsDiscovery', initialDiscovery());
  const state = store.get<DiscoveryState>('newsDiscovery');
  discoveryPreferencesSchema.parse(state.preferences);
  return state;
}
export function searchURL(interest: NewsInterest): string {
  const url = new URL('https://news.google.com/rss/search');
  const exclusions = interest.excludedTerms.map(term => '-"' + term.replaceAll('"', '') + '"').join(' ');
  const language = interest.language === 'ja' ? 'ja' : 'en';
  url.search = new URLSearchParams({
    q: interest.query + (exclusions ? ' ' + exclusions : '') + ' when:' + interest.days + 'd',
    hl: language === 'ja' ? 'ja' : 'en-' + interest.region,
    gl: interest.region, ceid: interest.region + ':' + language,
  }).toString();
  return url.href;
}
export function searchDiscovery(fetcher = fetchFeed): Discover {
  return async (interest, signal) => {
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), STANDARD_SEARCH_TIMEOUT_MS);
    const boundedSignal = signal ? AbortSignal.any([signal, controller.signal]) : controller.signal;
    try {
      const endpoint = searchURL(interest), at = new Date().toISOString();
      const articles = parseFeed(await fetchStandard(fetcher, endpoint, boundedSignal), {
        id: interest.id, name: 'News search', endpoint, topicIDs: [], isEnabled: true,
      }, at);
      boundedSignal.throwIfAborted();
      return articles.filter(article => eligibleCandidate(article, interest, Date.parse(at)) && matchesInterest(article, interest))
        .map(article => ({ ...article, contentKind: 'article' as const, feedIDs: [], matches: [{
          interestID: interest.id, interestRevision: interest.revision, mode: 'search' as const,
          score: relevanceForInterest(article, interest),
          reason: interest.requiredTerms.length ? 'Matches your search and all required keyword groups.' : 'Found by your cross-source news search.',
        }] })).sort((a, b) => b.matches[0].score - a.matches[0].score).slice(0, 40);
    } finally { clearTimeout(timer); }
  };
}
export function mergeDiscovery(old: DiscoveredArticle[], incoming: DiscoveredArticle[], interest: NewsInterest, mode: SearchMode, now: number): DiscoveredArticle[] {
  // A successful run replaces this interest's matches; failed runs never call
  // this function. Other interests and their evidence remain independent.
  const map = new Map<string, DiscoveredArticle>();
  for (const article of old) {
    const matches = article.matches.filter(m => m.interestID !== interest.id);
    if (matches.length) map.set(article.id, { ...article, matches });
  }
  const oldByID = new Map(old.map(a => [a.id, a]));
  for (const candidate of incoming) {
    let url: string;
    try { url = canonicalURL(candidate.url); } catch { continue; }
    if (!eligibleCandidate({ ...candidate, url }, interest, now)) continue;
    const id = createHash('sha256').update(url).digest('hex');
    const before = map.get(id);
    const match = candidate.matches.find(m => m.interestID === interest.id && m.interestRevision === interest.revision && m.mode === mode);
    if (!match) continue;
    map.set(id, { ...candidate, ...(mode === 'search' ? { contentKind: 'article' as const } : {}),
      id, url, fetchedAt: oldByID.get(id)?.fetchedAt ?? new Date(now).toISOString(),
      matches: [...(before?.matches ?? []).filter(m => m.interestID !== interest.id), match] });
  }
  return [...map.values()].filter(a => Date.parse(a.publishedAt ?? a.fetchedAt) >= now - 30 * 86_400_000)
    .sort((a, b) => (b.publishedAt ?? b.fetchedAt).localeCompare(a.publishedAt ?? a.fetchedAt)).slice(0, 500);
}
