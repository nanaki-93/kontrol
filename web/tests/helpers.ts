import { createServer } from 'node:http';
import type { AddressInfo } from 'node:net';
import { Store } from '../server/store';
import { createApp } from '../server/app';
import type { NewsOptions } from '../server/modules/news';
import type { JobsOptions } from '../server/modules/jobs';
import type { fetchFeed } from '../server/news/transport';

export async function withAPI(run: (fixture: {
  store: Store;
  request: (path: string, method?: string, body?: unknown, headers?: Record<string, string>) => Promise<Response>;
  origin: string;
}) => Promise<void>, options: { clock?: () => number; feedFetcher?: typeof fetchFeed; news?: NewsOptions; jobs?: JobsOptions } = {}) {
  const store = new Store(':memory:');
  const server = createServer();
  await new Promise<void>(resolve => server.listen(0, '127.0.0.1', resolve));
  const origin = 'http://127.0.0.1:' + (server.address() as AddressInfo).port;
  try {
    const app = createApp(store, { origin, ...options, news: {
      aiStatus: async () => ({ configured: false, provider: 'pi', model: 'PI fixture', message: 'PI is disabled in this isolated test.' }),
      ...options.news,
    }, jobs: {
      aiStatus: async () => ({ configured: false, provider: 'pi', model: 'PI fixture', message: 'PI is disabled in this isolated test.' }),
      ...options.jobs,
    } });
    server.on('request', app);
    await run({ store, origin, request: (path, method = 'GET', body, headers = {}) =>
      fetch(origin + '/api' + path, { method, headers: {
        'X-Kontrol-Client': 'web', ...(method !== 'GET' ? { 'Content-Type': 'application/json' } : {}), ...headers,
      }, ...(body !== undefined ? { body: JSON.stringify(body) } : {}) }) });
  } finally {
    server.closeAllConnections();
    await new Promise<void>((resolve, reject) => server.close(error => error ? reject(error) : resolve()));
    store.close();
  }
}
