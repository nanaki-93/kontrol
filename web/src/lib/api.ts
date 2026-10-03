import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';

export async function api<T>(path: string, method = 'GET', body?: unknown, options: { signal?: AbortSignal; timeoutMs?: number } = {}): Promise<T> {
  // News can process twelve interests or forty feeds in bounded batches.
  // Ordinary reads and writes should not wait indefinitely behind those jobs.
  const defaultTimeout = path === '/news/discover' ? 390_000 : path === '/news/refresh' ? 210_000 :
    path.startsWith('/settings/import') || path === '/settings/export' ? 120_000 : method === 'GET' ? 15_000 : 30_000;
  const timeout = AbortSignal.timeout(options.timeoutMs ?? defaultTimeout);
  const signal = options.signal ? AbortSignal.any([timeout, options.signal]) : timeout;
  let response: Response;
  let result: unknown;
  try {
    response = await fetch('/api' + path, { method, signal, headers: {
      'X-Kontrol-Client': 'web', ...(method !== 'GET' ? { 'Content-Type': 'application/json' } : {}),
    }, ...(body !== undefined ? { body: JSON.stringify(body) } : {}) });
    result = response.status === 204 ? undefined : await response.json();
  } catch (error) {
    if (timeout?.aborted) throw new Error('Kontrol took too long to respond. Refresh to check the result, then try again if needed.');
    if (options.signal?.aborted) throw error;
    if (error instanceof SyntaxError) throw new Error('Kontrol returned an unreadable response. Refresh and try again.');
    throw new Error('Cannot reach Kontrol. Make sure the local server is running, then try again.');
  }
  if (!response.ok) {
    throw new Error(result && typeof result === 'object' && 'error' in result && typeof result.error === 'string' ? result.error : 'The request failed. Please try again.');
  }
  return result as T;
}
export function useResource<T>(key: string, path: string, interval?: number) {
  return useQuery<T, Error>({
    queryKey: [key], queryFn: ({ signal }) => api<T>(path, 'GET', undefined, { signal }), refetchInterval: interval,
    staleTime: 5_000, retry: 1,
  });
}
export function useCommand<T = unknown>(keys: string[]) {
  const client = useQueryClient();
  return useMutation<T, Error, { path: string; method?: string; body?: unknown }>({
    mutationKey: ['command', ...keys],
    mutationFn: ({ path, method = 'POST', body = {} }) => api<T>(path, method, body),
    onSuccess: async () => { await Promise.all(keys.map(key => client.invalidateQueries({ queryKey: [key] }))); },
  });
}
export function navigate(route: string): void { window.location.hash = route; }
export function download(name: string, contents: unknown): void {
  const url = URL.createObjectURL(new Blob([JSON.stringify(contents, null, 2)], { type: 'application/json' }));
  const link = document.createElement('a');
  link.href = url; link.download = name; link.click();
  setTimeout(() => URL.revokeObjectURL(url), 1000);
}
