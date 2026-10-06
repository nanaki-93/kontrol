import { createServer } from 'node:http';
import type { AddressInfo } from 'node:net';
import { Store } from '../server/store';
import { createApp, type AppOptions } from '../server/app';
import type { ExploreService } from '../server/news/explore';

export async function withAPI(run: (fixture: {
  store: Store;
  request: (path: string, method?: string, body?: unknown, headers?: Record<string, string>) => Promise<Response>;
  origin: string;
  explore: ExploreService;
}) => Promise<void>, options: Omit<AppOptions, 'origin'> = {}) {
  const store = new Store(':memory:');
  const server = createServer();
  await new Promise<void>(resolve => server.listen(0, '127.0.0.1', resolve));
  const origin = 'http://127.0.0.1:' + (server.address() as AddressInfo).port;
  let app: ReturnType<typeof createApp> | undefined;
  try {
    app = createApp(store, { origin, ...options, news: {
      aiStatus: async () => ({ configured: false, provider: 'pi', model: 'PI fixture', message: 'PI is disabled in this isolated test.' }),
      ...options.news,
    }, jobs: {
      aiStatus: async () => ({ configured: false, provider: 'pi', model: 'PI fixture', message: 'PI is disabled in this isolated test.' }),
      ...options.jobs,
    } });
    server.on('request', app);
    await run({ store, origin, explore: app.explore, request: (path, method = 'GET', body, headers = {}) =>
      fetch(origin + '/api' + path, { method, headers: {
        'X-Kontrol-Client': 'web', ...(method !== 'GET' ? { 'Content-Type': 'application/json' } : {}), ...headers,
      }, ...(body !== undefined ? { body: JSON.stringify(body) } : {}) }) });
  } finally {
    app?.dispose();
    server.closeAllConnections();
    try {
      await new Promise<void>((resolve, reject) => server.close(error => error ? reject(error) : resolve()));
    } finally { store.close(); }
  }
}
