import express, { type ErrorRequestHandler, type Response } from 'express';
import { z } from 'zod';
import { Store } from './store';
import { HttpError } from './errors';
import { focusModule } from './modules/focus';
import { learningModule } from './modules/learning';
import { projectsModule } from './modules/projects';
import { newsModule, type NewsOptions } from './modules/news';
import { settingsModule } from './modules/settings';
import { jobsModule, type JobsOptions } from './modules/jobs';
import { workspaceModule } from './modules/workspace';
import { MAX_BACKUP_BYTES, BACKUP_LIMIT_LABEL } from '../shared/backup';
import type { fetchFeed } from './news/transport';
import { createExploreService, type ExploreDependencies } from './news/explore';
import { createExploreIdeation } from './news/explore-ideation';
import { getDiscovery, searchDiscovery } from './news/discovery';
import { piStatus } from './news/pi';

export interface AppOptions {
  origin: string;
  clock?: () => number;
  feedFetcher?: typeof fetchFeed;
  news?: NewsOptions;
  jobs?: JobsOptions;
  explore?: Omit<ExploreDependencies, 'readInterests' | 'discover'>;
}
export function createApp(store: Store, options: AppOptions) {
  // One process-local owner. Construction does not read context, invoke PI or
  // retrieve news. Modules receive only the capabilities they currently need.
  const explore = createExploreService({
    now: options.clock,
    ideate: createExploreIdeation(options.news?.pi),
    available: async () => (await (options.news?.aiStatus?.() ?? piStatus(options.news?.pi))).configured,
    ...options.explore,
    readInterests: () => getDiscovery(store).preferences.interests,
    discover: options.news?.search ?? searchDiscovery(options.feedFetcher),
  });
  const app = Object.assign(express(), { explore, dispose: () => explore.dispose() });
  app.disable('x-powered-by');
  const expected = new URL(options.origin);
  app.use((req, res, next) => {
    const host = req.headers.host;
    // Exact host/port validation also prevents DNS rebinding to loopback.
    if (host !== expected.host) { res.status(403).json({ error: 'Open Kontrol at ' + expected.origin + '.' }); return; }
    if (req.headers.origin && req.headers.origin !== expected.origin) { res.status(403).json({ error: 'Cross-origin requests are not allowed.' }); return; }
    res.setHeader('X-Content-Type-Options', 'nosniff');
    res.setHeader('Referrer-Policy', 'no-referrer');
    res.setHeader('X-Frame-Options', 'DENY');
    next();
  });
  app.use('/api', (req, res, next) => {
    res.setHeader('Cache-Control', 'no-store');
    if (req.headers['x-kontrol-client'] !== 'web' || req.headers['sec-fetch-site'] === 'cross-site') {
      res.status(403).json({ error: 'Use the local Kontrol dashboard to access this API.' }); return;
    }
    if (!['GET', 'HEAD'].includes(req.method) && req.headers['content-type']?.split(';')[0].trim().toLowerCase() !== 'application/json') {
      res.status(415).json({ error: 'Send application/json.' }); return;
    }
    next();
  });
  app.use('/api/settings/import', express.json({ limit: MAX_BACKUP_BYTES }));
  app.use(express.json({ limit: '16mb', verify: (_req, res, body) => {
    // express.json represents an empty wire body as {}. Preserve actual byte
    // presence for endpoints whose strict contract requires an explicit object.
    (res as Response).locals.jsonBodyBytes = body.length;
  } }));
  // Registration is explicit. Modules own their routes and persisted documents.
  app.use('/api/focus', focusModule(store, options.clock));
  app.use('/api/learning', learningModule(store));
  app.use('/api/projects', projectsModule(store));
  app.use('/api/news', newsModule(store, options.feedFetcher, options.news, explore));
  app.use('/api/jobs', jobsModule(store, options.jobs));
  app.use('/api/workspace', workspaceModule(store, options.clock, explore));
  app.use('/api/settings', settingsModule(store, explore));
  app.use('/api', (_req, res) => res.status(404).json({ error: 'Unknown API route.' }));
  const errors: ErrorRequestHandler = (error: unknown, req, res, _next) => {
    if (error instanceof z.ZodError) {
      res.status(400).json({ error: error.issues.slice(0, 5).map(i => (i.path.length ? i.path.join('.') + ': ' : '') + i.message).join(' · ') });
    } else if (error instanceof HttpError) res.status(error.status).json({ error: error.message });
    else if (error instanceof SyntaxError) res.status(400).json({ error: 'Invalid JSON. No data was changed.' });
    else if ((error as { type?: string })?.type === 'entity.too.large') res.status(413).json({ error:
      req.path.startsWith('/api/settings/import') ? 'The import exceeds ' + BACKUP_LIMIT_LABEL + '.' : 'The request exceeds 16 MB.' });
    else res.status(500).json({ error: 'The operation could not be saved or read. Check local disk space and folder permissions; your data has not been reset.' });
  };
  app.use(errors);
  return app;
}
