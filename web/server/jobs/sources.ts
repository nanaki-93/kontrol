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
    ...(name(address.addressRegion) ? { region: name(address.addressRegion) } : {}),
  })).filter(location => location.name || location.country).slice(0, 30);
  const description = plain(row.description), title = name(row.title), company = name(row.hiringOrganization);
  const remoteRegions = array(row.applicantLocationRequirements).map(name).filter(Boolean).slice(0, 30);
  const workMode = mode(title + ' ' + description, array(row.jobLocationType).some(value => value === 'TELECOMMUTE'));
  const parsed = jobSourceSchema.safeParse({ id: sourceID(url), url, title, company, description,
    cities, remoteRegions, workMode, employmentTypes: types(row.employmentType), salary: null,
    location: cities.map(city => [...new Set([city.name, city.region, city.country].filter(Boolean))].join(', ')).join(' · ').slice(0, 1000) ||
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
export interface JobLink { url: string; title: string }
export type JobWebSearch = (profile: JobProfile, preferences: JobPreferences, now: number, signal: AbortSignal) => Promise<JobLink[]>;
export function jobBoardIndexes(profile: JobProfile, preferences: JobPreferences): JobLink[] {
  const terms = [...profile.roles, ...profile.skills].join(' ').toLowerCase();
  if (!/\b(software|backend|back.end|frontend|front.end|developer|java|kotlin|spring|javascript|typescript|python|golang)\b/.test(terms)) return [];
  const indexes: JobLink[] = [];
  if (preferences.cities.some(city => city.countryCode === 'JP')) indexes.push({
    url: 'https://www.tokyodev.com/jobs' + (/\b(backend|back.end|java|kotlin|spring)\b/.test(terms) ? '/backend' : ''),
    title: 'TokyoDev software engineering jobs in Japan',
  });
  if (preferences.cities.some(city => city.countryCode === 'IT' && /^(milan|milano)$/i.test(city.name))) indexes.push({
    url: 'https://reteinformaticalavoro.it/offerte-di-lavoro/milano' + (/\bspring\b/.test(terms) ? '/spring' : ''),
    title: 'Reteinformaticalavoro software jobs in Milan',
  });
  return indexes;
}
function attribute(attributes: string, key: string): string {
  return plain(attributes.match(new RegExp('(?:^|\\s)' + key + '\\s*=\\s*["\']([^"\']*)["\']', 'i'))?.[1]);
}
function anchors(html: string): { attributes: string; title: string }[] {
  return [...html.matchAll(/<a\b([^>]*)>([\s\S]*?)<\/a\s*>/gi)].slice(0, 3000)
    .map(match => ({ attributes: match[1], title: plain(match[2]).slice(0, 200) }));
}
export function parseJobSearchLinks(html: string, endpoint: string): JobLink[] {
  if (/anomaly-modal|challenge-form/i.test(html)) throw new Error('Search challenge');
  const links = new Map<string, JobLink>();
  for (const anchor of anchors(html)) {
    if (!attribute(anchor.attributes, 'class').split(/\s+/).includes('result__a')) continue;
    try {
      const link = new URL(attribute(anchor.attributes, 'href'), endpoint);
      const isSearchHost = (host: string) => host === 'duckduckgo.com' || host.endsWith('.duckduckgo.com');
      const destination = isSearchHost(link.hostname) && link.pathname === '/l/' ? link.searchParams.get('uddg') : link.href;
      const url = publicJobURL(destination ?? '');
      // Never follow ads, tracking links or internal search navigation.
      if (isSearchHost(new URL(url).hostname)) continue;
      links.set(url, { url, title: anchor.title });
    } catch { /* Search links are untrusted, including redirect destinations. */ }
  }
  return [...links.values()];
}
const words = (text: string) => text.toLowerCase().replace(/back[ -]end/g, 'backend').replace(/front[ -]end/g, 'frontend').match(/[\p{L}\p{N}+#.]+/gu) ?? [];
function linkRelevance(link: JobLink, profile: JobProfile): number {
  const title = new Set(words(link.title));
  const roles = new Set(profile.roles.flatMap(words).filter(word => !['senior', 'junior', 'lead', 'staff', 'principal', 'of', 'and', 'the'].includes(word)));
  return [...roles].filter(word => title.has(word)).length * 4 + profile.skills.filter(skill => title.has(skill.toLowerCase())).length;
}
export function jobListingLinks(html: string, pageURL: string, profile: JobProfile): JobLink[] {
  const origin = new URL(publicJobURL(pageURL)).origin, links = new Map<string, JobLink>();
  for (const anchor of anchors(html)) {
    try {
      const url = publicJobURL(new URL(attribute(anchor.attributes, 'href'), pageURL).href), parsed = new URL(url);
      const link = { url, title: anchor.title };
      // Follow one level of same-origin job links, never arbitrary site navigation.
      if (parsed.origin !== origin || url === pageURL || !/\/(?:jobs?|careers?|positions?|openings?|vacancies|requisitions?|lavoro)[/-].+/i.test(parsed.pathname) || !linkRelevance(link, profile)) continue;
      if (!links.has(url) || linkRelevance(link, profile) > linkRelevance(links.get(url)!, profile)) links.set(url, link);
    } catch { /* Ignore private or malformed destinations. */ }
  }
  return [...links.values()].sort((a, b) => linkRelevance(b, profile) - linkRelevance(a, profile)).slice(0, 20);
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
export function createJobDiscovery(fetcher: JobFetcher = fetchJobText, nativeSearch?: JobWebSearch) {
  let remotiveCache: { at: number; jobs: JobSource[] } | null = null;
  let arbeitnowCache: { at: number; jobs: JobSource[] } | null = null;
  return async (profile: JobProfile, preferences: JobPreferences, now: number, signal: AbortSignal): Promise<JobSources> => {
    const deadline = AbortSignal.any([signal, AbortSignal.timeout(nativeSearch ? 110_000 : 40_000)]);
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
      const visited = new Set<string>(), jobs: JobSource[] = [];
      let responsiveProviders = 0;
      const warn = (message: string) => { if (!warnings.includes(message)) warnings.push(message); };
      const read = async (links: JobLink[], providerSignal: AbortSignal) => {
        const pages = links.filter(link => {
          if (visited.has(link.url)) return false;
          visited.add(link.url); return true;
        });
        const documents = await mapBounded(pages, 4, async ({ url }) => {
          providerSignal.throwIfAborted();
          const html = await fetcher(url, AbortSignal.any([providerSignal, AbortSignal.timeout(8_000)]));
          const postings = parseJobPostings(html, url);
          return { postings, links: postings.length ? [] : jobListingLinks(html, url, profile) };
        });
        if (documents.some(result => result.status === 'rejected')) warn('Some web pages could not be read. Web results include only accessible structured job postings.');
        return documents.flatMap(result => result.status === 'fulfilled' ? [result.value] : []);
      };
      const collect = async (links: JobLink[], providerSignal: AbortSignal) => {
        const documents = await read(links.slice(0, 20), providerSignal);
        jobs.push(...documents.flatMap(document => document.postings));
        const candidates = new Map<string, JobLink>();
        for (const link of documents.flatMap(document => document.links)) if (!visited.has(link.url)) candidates.set(link.url, link);
        const perSite = new Map<string, number>();
        const details = [...candidates.values()].sort((a, b) => linkRelevance(b, profile) - linkRelevance(a, profile)).filter(link => {
          const host = new URL(link.url).hostname, count = perSite.get(host) ?? 0;
          perSite.set(host, count + 1); return count < 10;
        }).slice(0, 20);
        // A search result often points to a board. Retrieve the linked offer
        // before accepting it; directory text and snippets never become jobs.
        const offers = await read(details, providerSignal);
        jobs.push(...offers.flatMap(document => document.postings));
        return documents.length + offers.length;
      };
      const hasRelevantJobs = () => jobs.some(job => matchesJobFilters(job, preferences, now) && linkRelevance(job, profile) > 0);
      // Read known, relevant board indexes independently of search-engine
      // ranking. Every offer still needs its own fetched JobPosting record.
      const indexes = jobBoardIndexes(profile, preferences);
      const boards = indexes.length ? collect(indexes, AbortSignal.any([deadline, AbortSignal.timeout(30_000)]))
        .then(read => { if (read) responsiveProviders++; })
        .catch(() => { warn('Some direct job boards could not be read. Other sources are still used.'); }) : Promise.resolve();
      if (nativeSearch) {
        const providerSignal = AbortSignal.any([deadline, AbortSignal.timeout(80_000)]);
        try {
          const links = await nativeSearch(profile, preferences, now, providerSignal);
          responsiveProviders++;
          await collect(links, providerSignal);
        } catch {
          warn('PI web search could not finish. Public search and job-board sources are being used.');
        }
      }
      await boards;
      if (hasRelevantJobs()) return jobs;
      for (const provider of ['Bing', 'DuckDuckGo'] as const) {
        // Slow primary results must leave time for the fallback provider.
        const providerSignal = AbortSignal.any([deadline, AbortSignal.timeout(provider === 'Bing' ? 15_000 : 25_000)]);
        try {
          const searches = await mapBounded(jobQueries(profile, preferences), 2, async query => {
            providerSignal.throwIfAborted();
            const endpoint = provider === 'Bing' ? 'https://www.bing.com/search?' + new URLSearchParams({ q: query, format: 'rss' }) :
              'https://html.duckduckgo.com/html/?' + new URLSearchParams({ q: query });
            const body = await fetcher(endpoint, AbortSignal.any([providerSignal, AbortSignal.timeout(8_000)]));
            return provider === 'Bing' ? parseFeed(body, { id: 'jobs', name: 'Job search', endpoint, isEnabled: true, topicIDs: [] }, new Date(now).toISOString()) :
              parseJobSearchLinks(body, endpoint);
          });
          if (searches.every(result => result.status === 'rejected')) throw new Error('Search unavailable');
          responsiveProviders++;
          if (searches.some(result => result.status === 'rejected')) warn('Some city or role searches could not be reached.');
          const links = new Map<string, JobLink>();
          for (const search of searches) if (search.status === 'fulfilled') {
            for (const link of search.value.slice(0, 8)) {
              try { const url = publicJobURL(link.url); links.set(url, { ...link, url }); } catch { /* Ignore unsafe results. */ }
            }
          }
          await collect([...links.values()], providerSignal);
          if (hasRelevantJobs()) break;
        } catch {
          warn(provider + ' search is unavailable; results may be limited.');
        }
      }
      if (!responsiveProviders) throw new Error('Web search unavailable');
      if (!jobs.some(job => matchesJobFilters(job, preferences, now))) warn('Web search found no readable job postings matching your filters. Job-board coverage may be limited.');
      return jobs;
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
