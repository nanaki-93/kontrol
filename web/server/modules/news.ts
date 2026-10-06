import { Router } from 'express';
import { randomUUID } from 'node:crypto';
import { z } from 'zod';
import { feedSchema, type Feed, type Article, type NewsState } from '../../shared/schema';
import { interestDraftSchema, interestSchema, type NewsResponse } from '../../shared/news';
import { Store } from '../store';
import { HttpError, requireFound } from '../errors';
import { fetchFeed, safeWebURL, newsErrorMessage } from '../news/transport';
import { parseFeed, mergeArticles, initialNews } from '../news/feeds';
import { getDiscovery, mergeDiscovery, searchDiscovery, type Discover } from '../news/discovery';
import { aiDiscovery, aiSources } from '../news/ai';
import { piStatus, type PIOptions } from '../news/pi';
import type { ExploreService } from '../news/explore';
import { newsExploreModule, type ExploreRoutes } from './news-explore';

// Kept as exports for existing consumers of the original news module.
export { fetchFeed, safeWebURL, isPublicIP } from '../news/transport';
export { parseFeed, mergeArticles, canonicalURL, initialNews } from '../news/feeds';

export interface NewsOptions {
  search?: Discover;
  aiSearch?: Discover;
  aiStatus?: () => Promise<NewsResponse['ai']>;
  pi?: PIOptions;
}
export function newsModule(store: Store, fetcher = fetchFeed, options: NewsOptions = {},
  explore?: ExploreRoutes & Pick<ExploreService, 'invalidateSources'>): Router {
  const router = Router();
  let refreshing = false, discovering = false;
  const search = options.search ?? searchDiscovery(fetcher);
  const aiSearch = options.aiSearch ?? aiDiscovery({ pi: options.pi,
    sources: (interest, now, signal) => aiSources(interest, now, signal, fetcher) });
  const aiStatus = options.aiStatus ?? (() => piStatus(options.pi));
  store.init('news', initialNews());
  getDiscovery(store);
  if (explore) router.use('/explore', newsExploreModule(explore));
  async function snapshot(): Promise<NewsResponse> {
    return { ...store.get<NewsState>('news'), discovery: getDiscovery(store),
      ai: await aiStatus(),
      activity: { discovering, refreshingFeeds: refreshing } };
  }
  router.get('/', async (_req, res) => res.json(await snapshot()));
  router.post('/interests', (req, res) => {
    const draft = interestDraftSchema.parse(req.body);
    const interest = interestSchema.parse({ ...draft, id: randomUUID(), revision: randomUUID() });
    store.transaction(() => {
      const state = getDiscovery(store);
      if (state.preferences.interests.length >= 12) throw new HttpError(400, 'Keep up to 12 specific interests.');
      state.preferences.interests.push(interest);
      store.set('newsDiscovery', state);
    });
    res.status(201).json(interest);
  });
  router.put('/interests/:id', (req, res) => {
    const input = interestDraftSchema.extend({ expectedRevision: z.uuid() }).parse(req.body);
    const interest = store.transaction(() => {
      const state = getDiscovery(store);
      const previous = requireFound(state.preferences.interests.find(i => i.id === req.params.id));
      if (previous.revision !== input.expectedRevision) throw new HttpError(409, 'This interest changed in another tab. Reload it before saving.');
      const next = interestSchema.parse({ ...input, id: previous.id, revision: randomUUID() });
      state.preferences.interests = state.preferences.interests.map(i => i.id === next.id ? next : i);
      delete state.runs[next.id];
      store.set('newsDiscovery', state);
      return next;
    });
    // Revoke only after COMMIT; failed validation/conflicts/rollback leave the
    // previous valid exploration untouched, including in-flight requests.
    explore?.invalidateSources([interest.id]);
    res.json(interest);
  });
  router.delete('/interests/:id', (req, res) => {
    const { expectedRevision } = z.object({ expectedRevision: z.uuid() }).parse(req.body);
    store.transaction(() => {
      const state = getDiscovery(store);
      const interest = requireFound(state.preferences.interests.find(i => i.id === req.params.id));
      if (interest.revision !== expectedRevision) throw new HttpError(409, 'This interest changed. Reload it before removing it.');
      state.preferences.interests = state.preferences.interests.filter(i => i.id !== interest.id);
      state.articles = state.articles.map(a => ({ ...a, matches: a.matches.filter(m => m.interestID !== interest.id) })).filter(a => a.matches.length);
      delete state.runs[interest.id];
      store.set('newsDiscovery', state);
    });
    explore?.invalidateSources([String(req.params.id)]);
    res.status(204).end();
  });
  router.post('/discover', async (req, res) => {
    const input = z.object({ mode: z.enum(['search', 'ai']), interestID: z.uuid().optional() }).parse(req.body);
    if (discovering) throw new HttpError(409, 'A search is already running. Its results will appear when it finishes.');
    if (input.mode === 'ai') {
      const status = await aiStatus();
      if (!status.configured) throw new HttpError(400, status.message);
      if (discovering) throw new HttpError(409, 'A search is already running. Its results will appear when it finishes.');
    }
    const interests = getDiscovery(store).preferences.interests.filter(i => i.enabled && (!input.interestID || i.id === input.interestID));
    if (!interests.length) throw new HttpError(400, 'Enable at least one interest to search.');
    discovering = true;
    try {
      let cursor = 0;
      await Promise.all(Array.from({ length: Math.min(interests.length, input.mode === 'ai' ? 2 : 4) }, async () => {
        while (cursor < interests.length) {
          const interest = interests[cursor++];
          const attemptedAt = new Date().toISOString();
          let articles: Awaited<ReturnType<Discover>> = [], error: string | null = null;
          try { articles = await (input.mode === 'ai' ? aiSearch : search)(interest); }
          catch (failure) { error = newsErrorMessage(failure); }
          store.transaction(() => {
            const latest = getDiscovery(store);
            // Edits, disabling, deletion or import during a request revoke its
            // snapshot. Late responses must not resurrect removed preferences.
            if (!latest.preferences.interests.some(i => i.id === interest.id && i.revision === interest.revision && i.enabled)) return;
            if (!error) latest.articles = mergeDiscovery(latest.articles, articles, interest, input.mode, Date.now());
            latest.runs[interest.id] = {
              interestRevision: interest.revision, mode: input.mode, attemptedAt,
              succeededAt: error ? latest.runs[interest.id]?.succeededAt ?? null : new Date().toISOString(),
              count: error ? latest.runs[interest.id]?.count ?? 0 : latest.articles.filter(a => a.matches.some(m =>
                m.interestID === interest.id && m.interestRevision === interest.revision)).length, error,
            };
            store.set('newsDiscovery', latest);
          });
        }
      }));
      const state = await snapshot();
      state.activity.discovering = false;
      res.json(state);
    } finally { discovering = false; }
  });
  router.post('/feeds', (req, res) => {
    const feed = feedSchema.parse({ ...req.body, id: randomUUID() });
    safeWebURL(feed.endpoint);
    store.transaction(() => {
      const state = store.get<NewsState>('news');
      if (state.preferences.feeds.length >= 40) throw new HttpError(400, 'At most 40 feeds are supported.');
      if (state.preferences.feeds.some(f => f.endpoint === feed.endpoint)) throw new HttpError(409, 'This feed is already connected.');
      state.preferences.feeds.push(feed);
      state.preferences.selectedTopicIDs = [...new Set([...state.preferences.selectedTopicIDs, ...feed.topicIDs])];
      store.set('news', state);
    });
    res.status(201).json(feed);
  });
  router.patch('/feeds/:id', (req, res) => {
    const input = feedSchema.omit({ id: true }).partial().parse(req.body);
    if (input.endpoint) safeWebURL(input.endpoint);
    store.transaction(() => {
      const state = store.get<NewsState>('news');
      const feed = requireFound(state.preferences.feeds.find(f => f.id === req.params.id));
      Object.assign(feed, input);
      store.set('news', state);
    });
    res.json({ saved: true });
  });
  router.delete('/feeds/:id', (req, res) => {
    store.transaction(() => {
      const state = store.get<NewsState>('news');
      requireFound(state.preferences.feeds.find(f => f.id === req.params.id));
      state.preferences.feeds = state.preferences.feeds.filter(f => f.id !== req.params.id);
      delete state.errors[String(req.params.id)];
      state.articles = state.articles.filter(a => a.feedIDs.some(id => state.preferences.feeds.some(f => f.id === id)));
      store.set('news', state);
    });
    res.status(204).end();
  });
  router.put('/topics', (req, res) => {
    const topics = z.array(z.string().min(1).max(100)).max(50).parse(req.body);
    const state = store.get<NewsState>('news');
    state.preferences.selectedTopicIDs = [...new Set(topics)];
    store.set('news', state);
    res.json(state);
  });
  router.post('/refresh', async (_req, res) => {
    if (refreshing) throw new HttpError(409, 'A refresh is already running.');
    refreshing = true;
    try {
      const feeds = store.get<NewsState>('news').preferences.feeds.filter(f => f.isEnabled);
      const at = new Date().toISOString();
      const results: { feed: Feed; articles?: Article[]; error?: string }[] = [];
      let cursor = 0;
      await Promise.all(Array.from({ length: Math.min(feeds.length, 4) }, async () => {
        while (cursor < feeds.length) {
          const feed = feeds[cursor++];
          try { results.push({ feed, articles: parseFeed(await fetcher(feed.endpoint), feed, at) }); }
          catch (error) { results.push({ feed, error: newsErrorMessage(error) + ' Cached articles are retained.' }); }
        }
      }));
      const state = store.transaction(() => {
        const latest = store.get<NewsState>('news');
        const incoming: Article[] = [];
        for (const result of results) {
          const feed = latest.preferences.feeds.find(f => f.id === result.feed.id && f.endpoint === result.feed.endpoint && f.isEnabled);
          if (!feed) continue;
          if (result.error) latest.errors[feed.id] = result.error;
          else { delete latest.errors[feed.id]; incoming.push(...result.articles!.map(a => ({ ...a, topicIDs: feed.topicIDs }))); }
        }
        latest.articles = mergeArticles(latest.articles, incoming, Date.now());
        latest.lastRefreshAt = at;
        store.set('news', latest);
        return latest;
      });
      res.json(state);
    } finally { refreshing = false; }
  });
  return router;
}
