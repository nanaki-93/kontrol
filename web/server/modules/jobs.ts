import { Router, type Response } from 'express';
import { randomUUID } from 'node:crypto';
import { z } from 'zod';
import { JOB_ANALYSIS_TIMEOUT_MS, JOB_SEARCH_TIMEOUT_MS, emptyJobs, jobsStateSchema, jobPreferencesSchema, jobProfileSchema, type JobsState, type JobsResponse } from '../../shared/jobs';
import { Store } from '../store';
import { HttpError } from '../errors';
import { NewsFetchError } from '../news/transport';
import { piStatus, type PIOptions } from '../news/pi';
import { extractCV } from '../jobs/cv';
import { jobAI } from '../jobs/ai';
import { createJobDiscovery } from '../jobs/sources';
import { searchCities } from '../jobs/cities';

export interface JobsOptions {
  clock?: () => number; pi?: PIOptions;
  aiStatus?: typeof piStatus; analyze?: ReturnType<typeof jobAI>['analyze']; rank?: ReturnType<typeof jobAI>['rank'];
  sources?: ReturnType<typeof createJobDiscovery>; cities?: typeof searchCities; extract?: typeof extractCV;
}
const revisionSchema = z.object({ expectedRevision: z.uuid() });
export function getJobs(store: Store): JobsState { return jobsStateSchema.parse(store.get('jobs')); }
function message(error: unknown): string {
  if (error instanceof HttpError) return error.message;
  if (error instanceof NewsFetchError) return error.message;
  return 'The job request failed or timed out. Your saved data is kept. Try again.';
}
export function jobsModule(store: Store, options: JobsOptions = {}): Router {
  const router = Router(), now = options.clock ?? Date.now, ai = jobAI({ pi: options.pi });
  const discover = options.sources ?? createJobDiscovery();
  store.init('jobs', emptyJobs(randomUUID()));
  getJobs(store); // Reject malformed persisted records rather than resetting them.
  let activity: JobsResponse['activity'] = null, controller: AbortController | null = null;
  function current(body: unknown, allowBusy = false) {
    if (activity && !allowBusy) throw new HttpError(409, 'A JOB request is already running. Wait for it to finish.');
    const { expectedRevision } = revisionSchema.parse(body), state = getJobs(store);
    if (state.revision !== expectedRevision) throw new HttpError(409, 'Your job profile changed in another tab. Refresh before trying again.');
    return state;
  }
  function changed(state: JobsState) {
    const value = jobsStateSchema.parse({ ...state, revision: randomUUID(), matches: [], lastSearch: null });
    store.set('jobs', value); return value;
  }
  function assertCurrent(state: JobsState) {
    if (getJobs(store).revision !== state.revision) throw new HttpError(409, 'The CV or profile changed while this request was running. This result was discarded.');
  }
  function start(kind: JobsResponse['activity'], res: Response, milliseconds: number) {
    activity = kind; controller = new AbortController();
    const running = controller;
    const onClose = () => { if (!res.writableEnded) running.abort(); };
    res.once('close', onClose);
    return { signal: AbortSignal.any([running.signal, AbortSignal.timeout(milliseconds)]), finish: () => {
      res.off('close', onClose); activity = null; controller = null;
    } };
  }
  router.get('/', async (_req, res) => res.json({ ...getJobs(store), activity, ai: await (options.aiStatus ?? piStatus)(options.pi) }));
  router.get('/cities', async (req, res) => {
    const query = z.string().trim().min(2).max(100).parse(req.query.q);
    res.json(await (options.cities ?? searchCities)(query));
  });
  router.post('/cv', async (req, res) => {
    const state = current(req.body), run = start('uploading', res, 30_000);
    try {
      const cv = await (options.extract ?? extractCV)(req.body, now());
      run.signal.throwIfAborted(); assertCurrent(state);
      res.json(changed({ ...state, cv, profile: null, profileConfirmed: false }));
    } catch (error) {
      if (error instanceof z.ZodError || error instanceof HttpError) throw error;
      throw new HttpError(400, 'The CV upload could not finish. Your previous CV is kept. Try a smaller file.');
    } finally { run.finish(); }
  });
  router.delete('/cv', (req, res) => {
    const state = current(req.body, true);
    controller?.abort();
    res.json(changed({ ...emptyJobs(state.revision), preferences: state.preferences }));
  });
  router.put('/preferences', (req, res) => {
    const state = current(req.body), preferences = jobPreferencesSchema.parse(req.body.preferences);
    res.json(changed({ ...state, preferences }));
  });
  router.put('/profile', (req, res) => {
    const state = current(req.body);
    if (!state.cv || !state.profile) throw new HttpError(409, 'Upload and analyze your CV before reviewing the profile.');
    const profile = jobProfileSchema.parse(req.body.profile);
    res.json(changed({ ...state, profile, profileConfirmed: true }));
  });
  router.post('/analyze', async (req, res) => {
    const state = current(req.body);
    if (!state.cv) throw new HttpError(409, 'Upload your CV before analyzing it.');
    const run = start('analyzing', res, JOB_ANALYSIS_TIMEOUT_MS);
    try {
      const profile = jobProfileSchema.parse(await (options.analyze ?? ai.analyze)(state.cv.text, run.signal));
      run.signal.throwIfAborted(); assertCurrent(state);
      res.json(changed({ ...state, profile, profileConfirmed: false }));
    } catch (error) { throw new HttpError(error instanceof HttpError ? error.status : 502, message(error)); }
    finally { run.finish(); }
  });
  router.post('/search', async (req, res) => {
    const state = current(req.body);
    if (!state.cv || !state.profile || !state.profileConfirmed) throw new HttpError(409, 'Upload your CV, analyze it and confirm your profile before searching.');
    const run = start('searching', res, JOB_SEARCH_TIMEOUT_MS), attemptedAt = new Date(now()).toISOString();
    try {
      const { sources, warnings } = await discover(state.profile, state.preferences, now(), run.signal);
      run.signal.throwIfAborted();
      const matches = sources.length ? await (options.rank ?? ai.rank)(state.profile, state.preferences, sources, now(), run.signal) : [];
      run.signal.throwIfAborted(); assertCurrent(state);
      const value = jobsStateSchema.parse({ ...state, matches, lastSearch: { attemptedAt,
        completedAt: new Date(now()).toISOString(), sourceCount: sources.length, warnings, error: null } });
      store.set('jobs', value); res.json(value);
    } catch (error) {
      const errorMessage = message(error);
      if (getJobs(store).revision === state.revision) store.set('jobs', { ...state,
        lastSearch: { attemptedAt, completedAt: state.lastSearch?.completedAt ?? null, sourceCount: state.lastSearch?.sourceCount ?? 0, warnings: [], error: errorMessage } });
      throw new HttpError(error instanceof HttpError ? error.status : 502, errorMessage);
    } finally { run.finish(); }
  });
  return router;
}
