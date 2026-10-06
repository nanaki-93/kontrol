import { createServer } from 'node:http';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { readFileSync, existsSync } from 'node:fs';
import express from 'express';
import { loadEnvFile } from 'node:process';
import { Store } from './store';
import { createApp } from './app';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
// Optional local configuration; keys are never sent to the frontend or SQLite.
if (existsSync(resolve(root, '.env'))) loadEnvFile(resolve(root, '.env'));
const port = Number(process.env.KONTROL_PORT ?? 4310);
if (!Number.isInteger(port) || port < 1024 || port > 65535) throw new Error('KONTROL_PORT must be an integer between 1024 and 65535.');
const production = process.argv.includes('--production');
if (production && !existsSync(resolve(root, 'dist/index.html'))) throw new Error('Run npm run build before npm start.');
const store = new Store(resolve(process.env.KONTROL_DATA_DIR ?? resolve(root, '.data'), 'kontrol.sqlite'));
const origin = 'http://127.0.0.1:' + port;
const app = createApp(store, { origin });
const server = createServer(app);
if (production) {
  app.use((_req, res, next) => {
    res.setHeader('Content-Security-Policy', "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; connect-src 'self'; frame-ancestors 'none'; object-src 'none'; base-uri 'self'");
    next();
  });
  app.use(express.static(resolve(root, 'dist')));
  app.get('/', (_req, res) => res.sendFile(resolve(root, 'dist/index.html')));
} else {
  const { createServer: createViteServer } = await import('vite');
  const vite = await createViteServer({ root, server: { middlewareMode: true, hmr: { server } }, appType: 'custom' });
  app.use(vite.middlewares);
  app.get('/', async (req, res, next) => {
    try {
      const html = await vite.transformIndexHtml(req.originalUrl, readFileSync(resolve(root, 'index.html'), 'utf8'));
      res.type('html').send(html);
    } catch (error) { next(error); }
  });
}
server.on('error', error => { console.error(error.message); app.dispose(); store.close(); process.exitCode = 1; });
server.listen(port, '127.0.0.1', () => console.log('Kontrol is available at ' + origin));
function shutdown() { app.dispose(); server.close(() => { store.close(); process.exit(0); }); }
process.once('SIGINT', shutdown);
process.once('SIGTERM', shutdown);
