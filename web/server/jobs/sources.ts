import { createHash } from 'node:crypto';
import { isIP } from 'node:net';
import { jobSourceSchema, matchesJobFilters, type JobPreferences, type JobProfile, type JobSource } from '../../shared/jobs';
import { canonicalURL, parseFeed, plain } from '../news/feeds';
import { fetchFeed, isPublicIP } from '../news/transport';
import { HttpError } from '../errors';

export type JobFetcher = (url: string, signal: AbortSignal) => Promise<string>;
export const fetchJobText: JobFetcher = (url, signal) => fetchFeed(url, 0, signal, {
  accept: 'application/json, text/html, application/rss+xml, application/xml',
  maxBytes: url === 'https://www.arbeitnow.com/api/job-board-api' ? 8_000_000 : 2_000_000,
});
export function publicJobURL(value: string): string {
  const url = canonicalURL(value), host = new URL(url).hostname.replace(/^\[|\]$/g, '');
  if (host === 'localhost' || host.endsWith('.localhost') || host.endsWith('.local') || (isIP(host) && !isPublicIP(host))) throw new Error('Private URL');
  return url;
}
const sourceID = (url: string) => createHash('sha256').update(url).digest('hex');
const array = (value: unknown): unknown[] => value == null ? [] : Array.isArray(value) ? value : [value];
const record = (value: unknown): Record<string, unknown> => value && typeof value === 'object' && !Array.isArray(value) ? value as Record<string, unknown> : {};
const name = (value: unknown): string => plain(typeof value === 'string' ? value : record(value).name).slice(0, 200);
function date(value: unknown): string | null {
  if (typeof value !== 'string' || !value.trim()) return null;
  const timestamp = /^\d{4}-\d{2}-\d{2}T/.test(value) && !/(?:Z|[+-]\d{2}:?\d{2})$/i.test(value) ? value + 'Z' : value;
  const parsed = Date.parse(timestamp);
  return Number.isFinite(parsed) ? new Date(parsed).toISOString() : null;
}
function types(value: unknown): JobSource['employmentTypes'] {
  const raw = array(value).map(v => String(v).toLowerCase().replace(/[_-]/g, ' ')).join(' ');
  const result: JobSource['employmentTypes'] = [];
  if (/full\s*time|vollzeit/.test(raw)) result.push('full_time');
  if (/part\s*time|teilzeit/.test(raw)) result.push('part_time');
  if (/contract|contractor|temporary/.test(raw)) result.push('contract');
  if (/freelance/.test(raw)) result.push('freelance');
  if (/internship|intern\b|praktikum/.test(raw)) result.push('internship');
  return result;
}
function mode(value: string, remote: boolean): JobSource['workMode'] {
  if (/\bhybrid\b/i.test(value)) return 'hybrid';
  if (remote) return 'remote';
  if (/\b(fully remote|100% remote|remote only)\b/i.test(value)) return 'remote';
  if (/\b(on[ -]?site|office[ -]based|in[ -]office)\b/i.test(value)) return 'office';
  return 'unknown';
}

// Only structured JobPosting records are accepted from web pages. News stories,
// search/category pages and snippets alone cannot become invented job offers.
export function parseJobPostings(html: string, pageURL: string): JobSource[] {
  const url = publicJobURL(pageURL), found: Record<string, unknown>[] = [];
  function walk(value: unknown, depth = 0) {
    if (depth > 12 || found.length > 20) return;
    if (Array.isArray(value)) { for (const item of value.slice(0, 100)) walk(item, depth + 1); return; }
    const row = record(value);
    if (array(row['@type']).includes('JobPosting')) found.push(row);
    if (row['@graph']) walk(row['@graph'], depth + 1);
    if (row.mainEntity) walk(row.mainEntity, depth + 1);
  }
  for (const match of html.matchAll(/<script\b[^>]*\btype\s*=\s*["']application\/ld\+json["'][^>]*>([\s\S]*?)<\/script\s*>/gi)) {
    try { walk(JSON.parse(match[1])); } catch { /* A broken unrelated block is not a job. */ }
  }
  // A multi-job page is a directory, not a specific offer permalink.
  if (found.length !== 1) return [];
  const row = found[0];
  const cities = array(row.jobLocation).map(location => record(record(location).address)).map(address => ({
    name: name(address.addressLocality), country: name(address.addressCountry),
  })).filter(location => location.name || location.country).slice(0, 30);
  const description = plain(row.description), title = name(row.title), company = name(row.hiringOrganization);
  const remoteRegions = array(row.applicantLocationRequirements).map(name).filter(Boolean).slice(0, 30);
  const workMode = mode(title + ' ' + description, array(row.jobLocationType).some(value => value === 'TELECOMMUTE'));
  const parsed = jobSourceSchema.safeParse({ id: sourceID(url), url, title, company, description,
    cities, remoteRegions, workMode, employmentTypes: types(row.employmentType), salary: null,
    location: cities.map(city => [city.name, city.country].filter(Boolean).join(', ')).join(' · ').slice(0, 1000) ||
      (remoteRegions.join(', ').slice(0, 1000) || 'Location not specified'),
    publishedAt: date(row.datePosted), expiresAt: date(row.validThrough), source: new URL(url).hostname.replace(/^www\./, ''),
  });
  return parsed.success ? [parsed.data] : [];
}

export function parseRemotive(input: string): JobSource[] {
  const body = record(JSON.parse(input));
  if (!Array.isArray(body.jobs)) throw new Error('Invalid Remotive response');
  return body.jobs.slice(0, 100).flatMap(value => {
    const row = record(value);
    try {
      const url = publicJobURL(String(row.url));
      if (new URL(url).hostname !== 'remotive.com') return [];
      return [jobSourceSchema.parse({ id: sourceID(url), url, title: name(row.title), company: name(row.company_name),
        description: plain(row.description), location: plain(row.candidate_required_location).slice(0, 1000) || 'Remote · eligibility not specified',
        cities: [], remoteRegions: typeof row.candidate_required_location === 'string' ? row.candidate_required_location.split(/[,;]/).map(v => v.trim()).filter(Boolean).slice(0, 30) : [],
        workMode: 'remote', employmentTypes: types(row.job_type), salary: plain(row.salary).slice(0, 300) || null,
        publishedAt: date(row.publication_date), expiresAt: null, source: 'Remotive',
      })];
    } catch { return []; }
  });
}

export function parseArbeitnow(input: string): JobSource[] {
  const body = record(JSON.parse(input));
  if (!Array.isArray(body.data)) throw new Error('Invalid Arbeitnow response');
  return body.data.slice(0, 500).flatMap(value => {
    const row = record(value);
    try {
      const url = publicJobURL(String(row.url)), location = plain(row.location).slice(0, 1000);
      const parts = location.split(',').map(part => part.trim());
      const country = parts.length > 1 ? parts.at(-1)! : '';
      const cities = location && !/^(remote|worldwide|anywhere)$/i.test(location) ? [{ name: parts[0].slice(0, 200), country: country.slice(0, 200) }] : [];
      const title = name(row.title), description = plain(row.description);
      const inferredMode = mode(title + ' ' + description, row.remote === true);
      return [jobSourceSchema.parse({ id: sourceID(url), url, title, company: name(row.company_name), description,
        location: location || 'Location not specified', cities,
        remoteRegions: row.remote === true ? (country ? [country] : /^(worldwide|anywhere)$/i.test(location) ? ['Worldwide'] : []) : [],
        workMode: inferredMode === 'unknown' && row.remote === false ? 'office' : inferredMode,
        employmentTypes: types(row.job_types), salary: null, publishedAt: typeof row.created_at === 'number' && Number.isFinite(row.created_at) ? new Date(row.created_at * 1000).toISOString() : null,
        expiresAt: null, source: 'Arbeitnow',
      })];
    } catch { return []; }
  });
}

export function jobQueries(profile: JobProfile, preferences: JobPreferences): string[] {
  const locations = preferences.cities.length ? preferences.cities.map(city => city.name + ' ' + city.country) : [''];
  const arrangements = preferences.workModes.length === 3 ? '' : '(' + preferences.workModes.map(mode => mode === 'office' ? '"on site" OR office' : mode).join(' OR ') + ')';
  const employment = preferences.employmentTypes.length ? '(' + preferences.employmentTypes.map(type => '"' + type.replaceAll('_', ' ') + '"').join(' OR ') + ')' : '';
  return locations.flatMap(location => profile.roles.slice(0, 2).map(role =>
    [role.replaceAll('"', ''), 'job vacancy', location, arrangements, employment].filter(Boolean).join(' ').slice(0, 500)));
}
async function mapBounded<T, R>(items: T[], concurrency: number, action: (value: T) => Promise<R>): Promise<PromiseSettledResult<R>[]> {
  const results: PromiseSettledResult<R>[] = new Array(items.length);
  let next = 0;
  await Promise.all(Array.from({ length: Math.min(concurrency, items.length) }, async () => {
    while (next < items.length) {
      const index = next++;
      try { results[index] = { status: 'fulfilled', value: await action(items[index]) }; }
      catch (reason) { results[index] = { status: 'rejected', reason }; }
    }
  }));
  return results;
}
export interface JobSources { sources: JobSource[]; warnings: string[] }
export function createJobDiscovery(fetcher: JobFetcher = fetchJobText) {
  let remotiveCache: { at: number; jobs: JobSource[] } | null = null;
  let arbeitnowCache: { at: number; jobs: JobSource[] } | null = null;
  return async (profile: JobProfile, preferences: JobPreferences, now: number, signal: AbortSignal): Promise<JobSources> => {
    const deadline = AbortSignal.any([signal, AbortSignal.timeout(40_000)]);
    const warnings: string[] = [];
    const terms = [...profile.roles, ...profile.skills].map(value => value.toLowerCase());
    const relevance = (source: JobSource) => terms.reduce((score, term) => score +
      (source.title.toLowerCase().includes(term) ? 4 : source.description.toLowerCase().includes(term) ? 1 : 0), 0);
    const remote = async (): Promise<JobSource[]> => {
      if (!preferences.workModes.includes('remote')) return [];
      if (remotiveCache && now - remotiveCache.at < 6 * 3600_000) return remotiveCache.jobs;
      const jobs = parseRemotive(await fetcher('https://remotive.com/api/remote-jobs?limit=100', deadline));
      remotiveCache = { at: now, jobs }; return jobs;
    };
    const arbeitnow = async (): Promise<JobSource[]> => {
      if (!arbeitnowCache || now - arbeitnowCache.at >= 10 * 60_000) {
        const jobs = parseArbeitnow(await fetcher('https://www.arbeitnow.com/api/job-board-api', deadline));
        arbeitnowCache = { at: now, jobs };
      }
      // Some API records omit a country. Retrieve their structured posting
      // instead of guessing which city with the same name was intended.
      const jobs = [...arbeitnowCache.jobs];
      const incomplete = jobs.filter(job => preferences.cities.some(city =>
        job.cities.some(location => !location.country && location.name.toLowerCase() === city.name.toLowerCase())))
        .sort((a, b) => relevance(b) - relevance(a)).slice(0, 6);
      const enriched = await mapBounded(incomplete, 3, async job => {
        const [posting] = parseJobPostings(await fetcher(job.url, AbortSignal.any([deadline, AbortSignal.timeout(8_000)])), job.url);
        return posting ? { ...job, cities: posting.cities, remoteRegions: posting.remoteRegions.length ? posting.remoteRegions : job.remoteRegions,
          expiresAt: posting.expiresAt } : job;
      });
      for (const result of enriched) if (result.status === 'fulfilled') {
        const index = jobs.findIndex(job => job.id === result.value.id);
        if (index >= 0) jobs[index] = result.value;
      }
      return jobs;
    };
    const web = async (): Promise<JobSource[]> => {
      const pages = new Set<string>();
      const searches = await mapBounded(jobQueries(profile, preferences), 3, async query => {
        deadline.throwIfAborted();
        const endpoint = 'https://www.bing.com/search?' + new URLSearchParams({ q: query, format: 'rss' });
        const xml = await fetcher(endpoint, deadline);
        return parseFeed(xml, { id: 'jobs', name: 'Job search', endpoint, isEnabled: true, topicIDs: [] }, new Date(now).toISOString());
      });
      if (searches.every(result => result.status === 'rejected')) throw new Error('Web search unavailable');
      if (searches.some(result => result.status === 'rejected')) warnings.push('Some city or role searches could not be reached.');
      for (const search of searches) if (search.status === 'fulfilled') {
        for (const article of search.value.slice(0, 5)) {
          try { pages.add(publicJobURL(article.url)); } catch { /* Exclude private destinations before fetching. */ }
        }
      }
      const documents = await mapBounded([...pages].slice(0, 20), 4, async url => {
        deadline.throwIfAborted();
        return parseJobPostings(await fetcher(url, AbortSignal.any([deadline, AbortSignal.timeout(8_000)])), url);
      });
      if (documents.some(result => result.status === 'rejected')) warnings.push('Some web pages could not be read. Web results include only accessible structured job postings.');
      return documents.flatMap(result => result.status === 'fulfilled' ? result.value : []);
    };
    const results = await Promise.allSettled([web(), remote(), arbeitnow()]);
    signal.throwIfAborted();
    const failures = results.filter(result => result.status === 'rejected').length;
    if (failures === 3 || (results[0].status === 'rejected' && results[2].status === 'rejected' && !preferences.workModes.includes('remote'))) {
      throw new HttpError(502, 'Job sources could not be reached. Your previous matches are kept. Try again later.');
    }
    if (results[0].status === 'rejected') warnings.push('Web search is unavailable; only accessible job-board results are included.');
    if (results[1].status === 'rejected') warnings.push('Remotive is unavailable; other accessible sources are included.');
    if (results[2].status === 'rejected') warnings.push('Arbeitnow is unavailable; other accessible sources are included.');
    const sources = new Map<string, JobSource>();
    const retrieved = results.flatMap(result => result.status === 'fulfilled' ? result.value : []);
    const expired = new Set(retrieved.filter(job =>
      (job.expiresAt && Date.parse(job.expiresAt) <= now) ||
      (job.publishedAt && (Date.parse(job.publishedAt) < now - preferences.days * 86_400_000 || Date.parse(job.publishedAt) > now + 86_400_000)))
      .map(job => job.url));
    for (const job of retrieved) {
      // A duplicate board record with no expiry cannot revive a known expired
      // posting, or overwrite richer metadata from a directly retrieved page.
      if (!expired.has(job.url) && !sources.has(job.url) && matchesJobFilters(job, preferences, now)) sources.set(job.url, job);
    }
    return { sources: [...sources.values()].sort((a, b) => relevance(b) - relevance(a)).slice(0, 30), warnings };
  };
}
