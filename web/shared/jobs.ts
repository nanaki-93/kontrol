import { z } from 'zod';
import { instant } from './schema';
import type { NewsResponse } from './news';

export const MAX_CV_BYTES = 5 * 1024 * 1024;
export const MAX_CV_TEXT = 60_000;
export const JOB_ANALYSIS_TIMEOUT_MS = 120_000;
export const JOB_SEARCH_TIMEOUT_MS = 110_000;
export const jobProfileLimits = { roles: 5, skills: 30, languages: 10 } as const;
export const workModes = ['remote', 'hybrid', 'office'] as const;
export const employmentTypes = ['full_time', 'part_time', 'contract', 'freelance', 'internship'] as const;
export const workModeLabels = { remote: 'Remote', hybrid: 'Hybrid', office: 'Office' };
export const employmentLabels = { full_time: 'Full-time', part_time: 'Part-time', contract: 'Contract', freelance: 'Freelance', internship: 'Internship' };
const line = z.string().trim().min(1).max(200);
const unique = <T>(values: T[]) => new Set(values).size === values.length;
export const citySchema = z.object({
  id: z.string().regex(/^(?:\d+|geo:[a-f0-9]{16})$/), name: line, country: line, countryCode: z.string().regex(/^[A-Z]{2}$/),
  region: z.string().max(200),
});
export const jobPreferencesSchema = z.object({
  workModes: z.array(z.enum(workModes)).min(1).max(3).refine(unique, 'Choose each work arrangement once.'),
  employmentTypes: z.array(z.enum(employmentTypes)).max(5).refine(unique),
  cities: z.array(citySchema).max(5).refine(values => unique(values.map(v => v.id)), 'This city is already selected.'),
  days: z.union([z.literal(7), z.literal(30), z.literal(90)]),
});
export const jobProfileSchema = z.object({
  headline: line, summary: z.string().trim().min(1).max(1500),
  roles: z.array(line).min(1).max(jobProfileLimits.roles), skills: z.array(line).min(1).max(jobProfileLimits.skills),
  experience: z.string().trim().max(1500), languages: z.array(line).max(jobProfileLimits.languages),
});
export const cvSchema = z.object({
  name: z.string().min(1).max(180), bytes: z.number().int().positive().max(MAX_CV_BYTES),
  uploadedAt: instant, text: z.string().min(80).max(MAX_CV_TEXT),
});
export const jobSourceSchema = z.object({
  id: z.string().min(1).max(100), url: z.url().max(4096).refine(value => {
    const url = new URL(value);
    return ['http:', 'https:'].includes(url.protocol) && !url.username && !url.password;
  }),
  title: line, company: line, description: z.string().max(12_000),
  location: z.string().max(1000),
  cities: z.array(z.object({ name: z.string().max(200), country: z.string().max(200) })).max(30),
  remoteRegions: z.array(z.string().max(200)).max(30),
  workMode: z.enum([...workModes, 'unknown']), employmentTypes: z.array(z.enum(employmentTypes)).max(5),
  salary: z.string().max(300).nullable(), publishedAt: instant.nullable(), expiresAt: instant.nullable(),
  source: line,
});
export const jobMatchSchema = jobSourceSchema.extend({
  score: z.number().int().min(0).max(100), reason: z.string().trim().min(1).max(1000),
  gaps: z.array(z.string().trim().min(1).max(300)).max(6),
});
export const jobsStateSchema = z.object({
  revision: z.uuid(), cv: cvSchema.nullable(), profile: jobProfileSchema.nullable(),
  profileConfirmed: z.boolean(), preferences: jobPreferencesSchema, matches: z.array(jobMatchSchema).max(20)
    .refine(matches => unique(matches.map(match => match.url)) && unique(matches.map(match => match.id)), 'Duplicate job matches.'),
  lastSearch: z.object({
    attemptedAt: instant, completedAt: instant.nullable(), sourceCount: z.number().int().nonnegative(),
    error: z.string().max(1000).nullable(), warnings: z.array(z.string().max(500)).max(10),
  }).nullable(),
}).superRefine((state, ctx) => {
  if ((!state.cv && state.profile) || (state.profileConfirmed && !state.profile) ||
      (state.matches.length && (!state.cv || !state.profileConfirmed))) {
    ctx.addIssue({ code: 'custom', message: 'Job matches require a CV and a reviewed profile.' });
  }
});
export type City = z.infer<typeof citySchema>;
export type JobPreferences = z.infer<typeof jobPreferencesSchema>;
export type JobProfile = z.infer<typeof jobProfileSchema>;
export type CV = z.infer<typeof cvSchema>;
export type JobSource = z.infer<typeof jobSourceSchema>;
export type JobMatch = z.infer<typeof jobMatchSchema>;
export type JobsState = z.infer<typeof jobsStateSchema>;
export type JobsResponse = JobsState & { activity: 'uploading' | 'analyzing' | 'searching' | null; ai: NewsResponse['ai'] };
export const defaultJobPreferences: JobPreferences = {
  workModes: ['remote', 'hybrid', 'office'], employmentTypes: [], cities: [], days: 30,
};
export function emptyJobs(revision: string): JobsState {
  return { revision, cv: null, profile: null, profileConfirmed: false, preferences: structuredClone(defaultJobPreferences), matches: [], lastSearch: null };
}
export function cityLabel(city: City): string { return [city.name, city.region !== city.name ? city.region : '', city.country].filter(Boolean).join(', '); }

const normalized = (value: string) => value.normalize('NFKD').replace(/\p{M}/gu, '').toLocaleLowerCase().replace(/[^\p{L}\p{N}]+/gu, ' ').trim();
function sameCountry(country: string, city: City) {
  const aliases: Record<string, string> = { usa: 'us', 'united states of america': 'us', 'united states': 'us',
    uk: 'gb', 'united kingdom': 'gb', deutschland: 'de', germany: 'de' };
  const canonical = (value: string) => aliases[normalized(value)] ?? normalized(value);
  return [city.country, city.countryCode].some(value => canonical(value) === canonical(country));
}
export function matchesJobFilters(job: JobSource, preferences: JobPreferences, now: number): boolean {
  if (job.expiresAt && Date.parse(job.expiresAt) <= now) return false;
  if (job.publishedAt && (Date.parse(job.publishedAt) > now + 86_400_000 || Date.parse(job.publishedAt) < now - preferences.days * 86_400_000)) return false;
  if (job.workMode === 'unknown' ? preferences.workModes.length !== 3 : !preferences.workModes.includes(job.workMode)) return false;
  if (preferences.employmentTypes.length && !job.employmentTypes.some(type => preferences.employmentTypes.includes(type))) return false;
  if (!preferences.cities.length) return true;
  if (job.workMode === 'remote') {
    // Never equate an unspecified remote restriction with worldwide eligibility.
    return job.remoteRegions.some(region => /^(worldwide|anywhere|global)$/i.test(region.trim()) ||
      preferences.cities.some(city => sameCountry(region, city) || normalized(region) === normalized(city.name + ', ' + city.country)));
  }
  return preferences.cities.some(city => job.cities.some(location =>
    normalized(location.name) === normalized(city.name) && sameCountry(location.country, city)));
}
