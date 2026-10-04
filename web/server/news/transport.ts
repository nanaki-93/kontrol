import { lookup } from 'node:dns/promises';
import type { LookupAddress } from 'node:dns';
import { isIP, type LookupFunction } from 'node:net';
import { request as httpRequest } from 'node:http';
import { request as httpsRequest } from 'node:https';
import { createGunzip, createInflate, createBrotliDecompress } from 'node:zlib';
import type { Readable, Transform } from 'node:stream';
import { HttpError } from '../errors';

export class NewsFetchError extends Error {
  constructor(public code: string, message: string) { super(message); }
}
export function safeWebURL(input: string): URL {
  let url: URL;
  try { url = new URL(input); } catch { throw new NewsFetchError('url', 'The source URL is invalid.'); }
  if (!['http:', 'https:'].includes(url.protocol) || url.username || url.password ||
    (url.port && !['80', '443'].includes(url.port))) throw new NewsFetchError('url', 'Use a public HTTP or HTTPS URL without credentials or a custom port.');
  return url;
}
export function isPublicIP(address: string): boolean {
  if (isIP(address) === 4) {
    const [a, b] = address.split('.').map(Number);
    return a > 0 && a < 224 && a !== 10 && a !== 127 && !(a === 169 && b === 254) &&
      !(a === 172 && b >= 16 && b <= 31) && !(a === 192 && [0, 168].includes(b)) &&
      !(a === 100 && b >= 64 && b <= 127) && !(a === 198 && [18, 19, 51].includes(b)) && !(a === 203 && b === 0);
  }
  return isIP(address) === 6 && /^[23]/i.test(address) && !/^(2001:db8|2001:0:|2002:)/i.test(address);
}
// Modern Node requests all addresses for Happy Eyeballs. Returning a string in
// that mode causes ERR_INVALID_IP_ADDRESS before any request leaves the Mac.
export function pinnedLookup(addresses: LookupAddress[]): LookupFunction {
  return (_hostname, options, callback) => {
    if (options.all) callback(null, addresses);
    else {
      const address = addresses.find(a => !options.family || a.family === options.family) ?? addresses[0];
      callback(null, address.address, address.family);
    }
  };
}
function abortable<T>(promise: Promise<T>, signal: AbortSignal): Promise<T> {
  return new Promise((resolve, reject) => {
    const abort = () => reject(new NewsFetchError('timeout', 'The source took too long to respond. Try again.'));
    signal.addEventListener('abort', abort, { once: true });
    if (signal.aborted) abort();
    promise.then(resolve, reject).finally(() => signal.removeEventListener('abort', abort));
  });
}
export interface FetchOptions {
  accept?: string;
  maxBytes?: number;
  userAgent?: string;
  acceptLanguage?: string;
  /** Redirect hops allowed for this request (default 3, at most 10). */
  maxRedirects?: number;
  /** Keep the first `maxBytes` decoded bytes instead of rejecting oversized bodies (default false). */
  truncate?: boolean;
}
export const DEFAULT_USER_AGENT = 'Kontrol-Web/0.2';
export const FEED_ACCEPT = 'application/rss+xml, application/atom+xml, application/xml, text/xml';
// News AI reads publisher article pages, many of which reject non-browser
// agents. Only the page profile uses this; feeds, search and Jobs keep
// DEFAULT_USER_AGENT.
export const PAGE_USER_AGENT = 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/129.0.0.0 Safari/537.36';
export const PAGE_ACCEPT = 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8';
export function pageRequestOptions(language: 'en' | 'ja'): Required<FetchOptions> {
  return {
    userAgent: PAGE_USER_AGENT, accept: PAGE_ACCEPT,
    acceptLanguage: language === 'ja' ? 'ja-JP,ja;q=0.9,en;q=0.8' : 'en-US,en;q=0.9',
    maxRedirects: 5, truncate: true, maxBytes: 2_000_000,
  };
}
export function requestHeaders(options: FetchOptions = {}): Record<string, string> {
  return {
    'User-Agent': options.userAgent ?? DEFAULT_USER_AGENT,
    Accept: options.accept ?? FEED_ACCEPT,
    ...(options.acceptLanguage ? { 'Accept-Language': options.acceptLanguage } : {}),
    'Accept-Encoding': 'gzip, deflate, br',
  };
}
export function redirectLimit(value: number | undefined): number {
  return value === undefined || !Number.isFinite(value) ? 3 : Math.max(0, Math.min(Math.floor(value), 10));
}
/**
 * Collects a response body while enforcing both the wire (compressed) and the
 * decoded size limit. Without truncation an oversized body rejects with the
 * `size` error; with truncation it resolves with the first `maxBytes` decoded
 * bytes. Either way the request, response and decoder are destroyed as soon as
 * the limit is reached. The promise settles exactly once.
 */
export function collectBody(response: Readable, decoder: Transform | null, maxBytes: number, truncate: boolean,
  request?: { destroy(): unknown }): Promise<string> {
  return new Promise<string>((resolve, reject) => {
    let settled = false, size = 0, wireSize = 0;
    const chunks: Buffer[] = [];
    const stop = () => { request?.destroy(); response.destroy(); decoder?.destroy(); };
    const fail = (error: unknown) => { if (settled) return; settled = true; reject(error); };
    const finish = () => { if (settled) return; settled = true; resolve(Buffer.concat(chunks).toString('utf8')); };
    const limitReached = () => {
      if (settled) return;
      if (truncate) finish();
      else fail(new NewsFetchError('size', 'The source exceeds the ' + Math.ceil(maxBytes / 1_000_000) + ' MB limit.'));
      stop();
    };
    // Plain bodies have identical wire and decoded sizes, so a single counter
    // keeps the truncated prefix exact.
    if (decoder) response.on('data', (chunk: Buffer) => { if (settled) return; wireSize += chunk.length; if (wireSize > maxBytes) limitReached(); });
    const stream = decoder ? response.pipe(decoder) : response;
    stream.on('data', (chunk: Buffer) => {
      if (settled) return;
      const before = size;
      size += chunk.length;
      if (size > maxBytes) {
        if (truncate) chunks.push(chunk.subarray(0, maxBytes - before));
        limitReached();
      } else chunks.push(chunk);
    });
    response.on('error', fail);
    if (decoder) decoder.on('error', fail);
    stream.on('end', finish);
  });
}
export async function fetchFeed(endpoint: string, redirects = 0, signal = AbortSignal.timeout(20_000), options: FetchOptions = {}): Promise<string> {
  const url = safeWebURL(endpoint), host = url.hostname.replace(/^\[|\]$/g, '');
  const maxBytes = Math.min(options.maxBytes ?? 2_000_000, 8_000_000);
  const maxRedirects = redirectLimit(options.maxRedirects);
  const addresses = await abortable(lookup(host, { all: true }), signal);
  if (!addresses.length || addresses.some(a => !isPublicIP(a.address))) throw new NewsFetchError('private-address', 'Sources must resolve to public internet addresses.');
  return new Promise<string>((resolve, reject) => {
    const request = (url.protocol === 'https:' ? httpsRequest : httpRequest)(url, {
      lookup: pinnedLookup(addresses),
      headers: requestHeaders(options),
      signal,
    }, response => {
      const status = response.statusCode ?? 500;
      if (status >= 300 && status < 400 && response.headers.location) {
        response.destroy();
        if (redirects >= maxRedirects) reject(new NewsFetchError('redirect', 'The source redirected too many times.'));
        else {
          try { fetchFeed(new URL(response.headers.location, url).href, redirects + 1, signal, options).then(resolve, reject); }
          catch { reject(new NewsFetchError('redirect', 'The source returned an invalid redirect.')); }
        }
        return;
      }
      if (status !== 200) {
        response.destroy();
        reject(new NewsFetchError('http-' + status, status === 429 ? 'The source is rate limiting requests. Try again later.' : 'The source returned HTTP ' + status + '.'));
        return;
      }
      const encoding = response.headers['content-encoding'];
      const decoder = encoding === 'gzip' ? createGunzip() : encoding === 'deflate' ? createInflate() :
        encoding === 'br' ? createBrotliDecompress() : null;
      if (encoding && encoding !== 'identity' && !decoder) { response.destroy(); reject(new NewsFetchError('encoding', 'Unsupported source compression.')); return; }
      collectBody(response, decoder, maxBytes, options.truncate ?? false, request).then(resolve, reject);
    });
    request.on('error', reject);
    request.end();
  });
}
export function newsErrorMessage(error: unknown): string {
  if (error instanceof NewsFetchError || error instanceof HttpError) return error.message;
  const code = (error as NodeJS.ErrnoException)?.code;
  if (['ENOTFOUND', 'EAI_AGAIN'].includes(code ?? '')) return 'The source address could not be resolved. Check your connection and URL.';
  if (['ABORT_ERR', 'ETIMEDOUT'].includes(code ?? '')) return 'The source took too long to respond. Try again.';
  if (code?.includes('CERT') || code?.includes('TLS')) return 'The source’s secure connection could not be verified.';
  return 'The source could not be reached or parsed. Saved results are retained.';
}
