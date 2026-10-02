import { readFileSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { XMLParser, XMLValidator } from 'fast-xml-parser';
import { feedPreferencesSchema, type Feed, type Article, type NewsState } from '../../shared/schema';
import { safeWebURL, NewsFetchError } from './transport';

const array = <T>(value: T | T[] | undefined): T[] => value === undefined ? [] : Array.isArray(value) ? value : [value];
export function plain(value: unknown): string {
  const raw = typeof value === 'object' && value !== null ? (value as Record<string, unknown>)['#text'] : value;
  let text = String(raw ?? '');
  const entities: Record<string, string> = { amp: '&', lt: '<', gt: '>', quot: '"', apos: "'", nbsp: ' ' };
  // Search RSS escapes HTML inside XML text. Decode before removing markup so
  // links/attributes cannot pollute summaries or satisfy keyword filters.
  for (let pass = 0; pass < 3; pass++) {
    const decoded = text.replace(/&(amp|lt|gt|quot|apos|nbsp);|&#(\d+);|&#x([\da-f]+);/gi, (entity, named: string | undefined, decimal: string | undefined, hex: string | undefined) => {
      if (named) return entities[named.toLowerCase()] ?? entity;
      const code = decimal ? Number(decimal) : Number.parseInt(hex!, 16);
      return code > 0 && code <= 0x10ffff && !(code >= 0xd800 && code <= 0xdfff) ? String.fromCodePoint(code) : '�';
    });
    if (decoded === text) break;
    text = decoded;
  }
  return text.replace(/<(script|style)\b[^>]*>[\s\S]*?<\/\1>/gi, '').replace(/<[^>]*>/g, '')
    .replace(/\s+/g, ' ').trim().slice(0, 10_000);
}
export function canonicalURL(input: string): string {
  const url = safeWebURL(input);
  url.hash = '';
  for (const key of [...url.searchParams.keys()]) if (/^utm_/i.test(key) || ['fbclid', 'gclid'].includes(key)) url.searchParams.delete(key);
  return url.href;
}
export function parseFeed(xml: string, feed: Feed, at: string): Article[] {
  if (/<!DOCTYPE|<!ENTITY/i.test(xml) || XMLValidator.validate(xml) !== true) throw new NewsFetchError('xml', 'The source did not return valid RSS or Atom XML.');
  const parsed = new XMLParser({ ignoreAttributes: false, processEntities: false, parseTagValue: false }).parse(xml);
  const root = parsed.rss?.channel ?? parsed.feed;
  if (!root) throw new NewsFetchError('xml', 'The source is not an RSS or Atom feed.');
  const items: Record<string, unknown>[] = array(root.item ?? root.entry);
  const articles: Article[] = [];
  for (const item of items.slice(0, 500)) {
    const links = array(item.link) as (string | Record<string, unknown>)[];
    const link = links.find(l => typeof l === 'string' || !l['@_rel'] || l['@_rel'] === 'alternate');
    const rawLink = typeof link === 'string' ? link : link?.['@_href'];
    const publisher = plain(item.source) || feed.name;
    const rawTitle = plain(item.title);
    const title = rawTitle.endsWith(' - ' + publisher) ? rawTitle.slice(0, -(publisher.length + 3)) : rawTitle;
    if (!rawLink || !title) continue;
    let url: string;
    try { url = canonicalURL(new URL(plain(rawLink), feed.endpoint).href); } catch { continue; }
    const rawDate = item.pubDate ?? item.published ?? item.updated;
    const ms = rawDate ? Date.parse(String(rawDate)) : NaN;
    articles.push({
      id: createHash('sha256').update(url).digest('hex'), url, title,
      summary: plain(item.description ?? item.summary ?? item.content),
      publishedAt: Number.isFinite(ms) ? new Date(ms).toISOString() : null,
      fetchedAt: at, feedIDs: [feed.id], topicIDs: feed.topicIDs, source: publisher,
    });
  }
  return articles;
}
export function mergeArticles(old: Article[], incoming: Article[], now: number): Article[] {
  const map = new Map(old.map(a => [a.id, a]));
  for (const article of incoming) {
    const before = map.get(article.id);
    map.set(article.id, before ? { ...article, fetchedAt: before.fetchedAt,
      feedIDs: [...new Set([...before.feedIDs, ...article.feedIDs])],
      topicIDs: [...new Set([...before.topicIDs, ...article.topicIDs])] } : article);
  }
  return [...map.values()].filter(a => Date.parse(a.publishedAt ?? a.fetchedAt) >= now - 30 * 86_400_000)
    .sort((a, b) => (b.publishedAt ?? b.fetchedAt).localeCompare(a.publishedAt ?? a.fetchedAt)).slice(0, 500);
}
export function initialNews(): NewsState {
  const catalog = JSON.parse(readFileSync(new URL('../../resources/default-feeds.json', import.meta.url), 'utf8'));
  return { preferences: feedPreferencesSchema.parse({
    selectedTopicIDs: catalog.initialSelectedTopicIDs,
    feeds: catalog.feeds.map((f: { id: string; name: string; url: string; topicIDs: string[] }) => ({
      id: f.id, name: f.name, endpoint: f.url, topicIDs: f.topicIDs, isEnabled: true,
    })),
  }), articles: [], errors: {}, lastRefreshAt: null };
}
