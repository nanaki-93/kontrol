import { lookup } from 'node:dns/promises';
import type { LookupAddress } from 'node:dns';
import { isIP, type LookupFunction } from 'node:net';
import { request as httpRequest } from 'node:http';
import { request as httpsRequest } from 'node:https';
import { createGunzip, createInflate, createBrotliDecompress } from 'node:zlib';
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
export async function fetchFeed(endpoint: string, redirects = 0, signal = AbortSignal.timeout(20_000), options: { accept?: string; maxBytes?: number } = {}): Promise<string> {
  const url = safeWebURL(endpoint), host = url.hostname.replace(/^\[|\]$/g, '');
  const maxBytes = Math.min(options.maxBytes ?? 2_000_000, 8_000_000);
  const addresses = await abortable(lookup(host, { all: true }), signal);
  if (!addresses.length || addresses.some(a => !isPublicIP(a.address))) throw new NewsFetchError('private-address', 'Sources must resolve to public internet addresses.');
  return new Promise<string>((resolve, reject) => {
    const request = (url.protocol === 'https:' ? httpsRequest : httpRequest)(url, {
      lookup: pinnedLookup(addresses),
      headers: {
        'User-Agent': 'Kontrol-Web/0.2', Accept: options.accept ?? 'application/rss+xml, application/atom+xml, application/xml, text/xml',
        'Accept-Encoding': 'gzip, deflate, br',
      },
      signal,
    }, response => {
      const status = response.statusCode ?? 500;
      if (status >= 300 && status < 400 && response.headers.location) {
        response.destroy();
        if (redirects >= 3) reject(new NewsFetchError('redirect', 'The source redirected too many times.'));
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
      const stream = decoder ? response.pipe(decoder) : response;
      let size = 0, wireSize = 0;
      const chunks: Buffer[] = [];
      const tooLarge = () => {
        reject(new NewsFetchError('size', 'The source exceeds the ' + Math.ceil(maxBytes / 1_000_000) + ' MB limit.'));
        request.destroy(); response.destroy(); decoder?.destroy();
      };
      response.on('data', (chunk: Buffer) => { wireSize += chunk.length; if (wireSize > maxBytes) tooLarge(); });
      stream.on('data', (chunk: Buffer) => {
        size += chunk.length;
        if (size > maxBytes) tooLarge(); else chunks.push(chunk);
      });
      response.on('error', reject);
      stream.on('error', reject);
      stream.on('end', () => resolve(Buffer.concat(chunks).toString('utf8')));
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
