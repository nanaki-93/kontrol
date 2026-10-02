import express, { type ErrorRequestHandler } from 'express';
import { z } from 'zod';
import { Store } from './store';
import { HttpError } from './errors';
import { tasksModule } from './modules/tasks';
import { scheduleModule } from './modules/schedule';
import { focusModule } from './modules/focus';
import { learningModule } from './modules/learning';
import { projectsModule } from './modules/projects';
import { newsModule, type NewsOptions } from './modules/news';
import { settingsModule } from './modules/settings';
import { jobsModule, type JobsOptions } from './modules/jobs';

export function createApp(store: Store, options: { origin: string; clock?: () => number; feedFetcher?: (url: string) => Promise<string>; news?: NewsOptions; jobs?: JobsOptions }) {
  const app = express();
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
  app.use(express.json({ limit: '16mb' }));
  // Registration is explicit. Modules own their routes and persisted documents.
  app.use('/api/tasks', tasksModule(store));
  app.use('/api/schedule', scheduleModule(store));
  app.use('/api/focus', focusModule(store, options.clock));
  app.use('/api/learning', learningModule(store));
  app.use('/api/projects', projectsModule(store));
  app.use('/api/news', newsModule(store, options.feedFetcher, options.news));
  app.use('/api/jobs', jobsModule(store, options.jobs));
  app.use('/api/settings', settingsModule(store));
  app.use('/api', (_req, res) => res.status(404).json({ error: 'Unknown API route.' }));
  const errors: ErrorRequestHandler = (error: unknown, _req, res, _next) => {
    if (error instanceof z.ZodError) {
      res.status(400).json({ error: error.issues.slice(0, 5).map(i => (i.path.length ? i.path.join('.') + ': ' : '') + i.message).join(' · ') });
    } else if (error instanceof HttpError) res.status(error.status).json({ error: error.message });
    else if (error instanceof SyntaxError) res.status(400).json({ error: 'Invalid JSON. No data was changed.' });
    else if ((error as { type?: string })?.type === 'entity.too.large') res.status(413).json({ error: 'The import exceeds 16 MB.' });
    else res.status(500).json({ error: 'The operation could not be saved or read. Check local disk space and folder permissions; your data has not been reset.' });
  };
  app.use(errors);
  return app;
}
