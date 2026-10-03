import { Router } from 'express';
import { randomUUID } from 'node:crypto';
import { z } from 'zod';
import { type Learning, type NewsState } from '../../shared/schema';
import { type DiscoveryState } from '../../shared/news';
import { jobSourceSchema, type JobsState } from '../../shared/jobs';
import {
  workspaceSchema, workspaceProfileSchema, emptyWorkspace, canonicalURL, safeURL, noteDraftSchema, calendarDay,
  stages, skillDecisionSchema, reviewRating, lessonDefinition, type Workspace,
} from '../../shared/workspace';
import { Store } from '../store';
import { HttpError, requireFound } from '../errors';

export function getWorkspace(store: Store): Workspace { return workspaceSchema.parse(store.get('workspace')); }
const revisionSchema = z.object({ expectedRevision: z.uuid() });
export function workspaceModule(store: Store, clock = Date.now): Router {
  const router = Router();
  const initial = emptyWorkspace(randomUUID());
  const jobs = store.get<JobsState>('jobs');
  if (jobs.profileConfirmed) initial.profile.targetRoles = jobs.profile?.roles ?? [];
  store.init('workspace', initial);
  getWorkspace(store);
  function update(body: unknown, change: (state: Workspace, at: string) => void): Workspace {
    const { expectedRevision } = revisionSchema.parse(body);
    return store.transaction(() => {
      const state = getWorkspace(store);
      if (state.revision !== expectedRevision) throw new HttpError(409, 'Your workspace changed in another tab. Your draft is kept. Refresh the saved data and try again.');
      change(state, new Date(clock()).toISOString());
      const keepURL = typeof body === 'object' && body !== null && 'url' in body && typeof body.url === 'string' ? canonicalURL(body.url) : null;
      // Read markers are a bounded cache. Explicit bookmarks and authored notes
      // are never evicted to make room for another result.
      while (state.articles.length > 1000 || new TextEncoder().encode(JSON.stringify(state)).byteLength > 8 * 1024 * 1024) {
        const disposable = state.articles.filter(a => !a.savedAt && !a.notes.trim() && canonicalURL(a.article.url) !== keepURL).sort((a, b) => a.updatedAt.localeCompare(b.updatedAt))[0];
        if (!disposable) break;
        state.articles = state.articles.filter(a => a.id !== disposable.id);
      }
      state.revision = randomUUID();
      const result = workspaceSchema.parse(state);
      store.set('workspace', result); return result;
    });
  }
  router.get('/', (_req, res) => res.json(getWorkspace(store)));
  router.put('/profile', (req, res) => {
    const profile = workspaceProfileSchema.parse(req.body.profile);
    res.json(update(req.body, state => {
      if (req.body.expectedProfile && JSON.stringify(workspaceProfileSchema.parse(req.body.expectedProfile)) !== JSON.stringify(state.profile)) {
        throw new HttpError(409, 'Your goals changed in another tab. Review the saved goals before replacing them.');
      }
      state.profile = profile;
    }));
  });
  router.put('/articles', (req, res) => {
    const input = z.object({ url: safeURL, saved: z.boolean().optional(), read: z.boolean().optional(), notes: z.string().max(20_000).optional() }).parse(req.body);
    res.json(update(req.body, (state, at) => {
      const url = canonicalURL(input.url);
      let record = state.articles.find(a => canonicalURL(a.article.url) === url);
      if (record && req.body.expectedNotes !== undefined && req.body.expectedNotes !== record.notes) throw new HttpError(409, 'These reading notes changed in another tab. Your draft is kept.');
      if (!record) {
        const discovered = store.get<DiscoveryState>('newsDiscovery').articles.find(a => canonicalURL(a.url) === url);
        const source = requireFound(discovered ?? store.get<NewsState>('news').articles.find(a => canonicalURL(a.url) === url));
        record = { id: randomUUID(), article: { title: source.title, url: source.url, source: source.source, summary: source.summary,
          publishedAt: source.publishedAt, fetchedAt: source.fetchedAt,
          summaryKind: discovered?.matches.some(m => m.mode === 'ai') ? 'ai-snippet' : 'source' }, savedAt: null, readAt: null, notes: '', updatedAt: at };
        state.articles.push(record);
      }
      if (input.saved !== undefined) record.savedAt = input.saved ? record.savedAt ?? at : null;
      if (input.read !== undefined) record.readAt = input.read ? record.readAt ?? at : null;
      if (input.notes !== undefined) { record.notes = input.notes; if (input.notes.trim()) record.savedAt ??= at; }
      record.updatedAt = at;
    }));
  });
  router.post('/jobs', (req, res) => {
    const input = z.object({ matchID: z.string().max(100).optional(), manual: z.object({
      title: z.string().trim().min(1).max(200), company: z.string().trim().min(1).max(200), url: safeURL,
      location: z.string().max(1000), description: z.string().max(12_000),
    }).optional() }).refine(value => !!value.matchID !== !!value.manual, 'Choose a match or enter a job.').parse(req.body);
    res.json(update(req.body, (state, at) => {
      const match = input.matchID ? requireFound(store.get<JobsState>('jobs').matches.find(j => j.id === input.matchID)) : null;
      const job = match ? jobSourceSchema.parse(match) : jobSourceSchema.parse({
        ...input.manual, id: randomUUID(), cities: [], remoteRegions: [], workMode: 'unknown', employmentTypes: [],
        salary: null, publishedAt: null, expiresAt: null, source: 'Added by you',
      });
      if (state.jobs.some(record => canonicalURL(record.job.url) === canonicalURL(job.url))) return;
      state.jobs.push({ id: randomUUID(), revision: randomUUID(), job, fit: match ? { score: match.score, reason: match.reason, gaps: match.gaps } : null,
        stage: 'saved', notes: '', followUpOn: null, savedAt: at, updatedAt: at, history: [{ stage: 'saved', at }], skills: [] });
    }));
  });
  router.patch('/jobs/:id', (req, res) => {
    const input = z.object({ stage: z.enum(stages).optional(), notes: z.string().max(20_000).optional(),
      followUpOn: calendarDay.nullable().optional(), skills: z.array(skillDecisionSchema).max(30).optional() }).parse(req.body);
    res.json(update(req.body, (state, at) => {
      const job = requireFound(state.jobs.find(j => j.id === req.params.id));
      if (req.body.expectedRecordRevision !== job.revision) throw new HttpError(409, 'This application changed in another tab. Review its saved details before replacing them.');
      if (input.stage && input.stage !== job.stage) job.history.push({ stage: input.stage, at });
      Object.assign(job, input, { updatedAt: at, revision: randomUUID() });
    }));
  });
  router.post('/notes', (req, res) => {
    const input = noteDraftSchema.parse(req.body);
    res.json(update(req.body, (state, at) => { state.notes.unshift({ ...input, id: randomUUID(), revision: randomUUID(), createdAt: at, updatedAt: at }); }));
  });
  router.put('/notes/:id', (req, res) => {
    const input = noteDraftSchema.parse(req.body);
    res.json(update(req.body, (state, at) => {
      const note = requireFound(state.notes.find(n => n.id === req.params.id));
      if (req.body.expectedRecordRevision !== note.revision) throw new HttpError(409, 'This note changed in another tab. Review the saved note before replacing it.');
      Object.assign(note, input, { updatedAt: at, revision: randomUUID() });
    }));
  });
  router.delete('/notes/:id', (req, res) => {
    res.json(update(req.body, state => {
      const note = requireFound(state.notes.find(n => n.id === req.params.id));
      if (req.body.expectedRecordRevision !== note.revision) throw new HttpError(409, 'This note changed. Review it before deleting.');
      state.notes = state.notes.filter(n => n.id !== req.params.id);
    }));
  });
  router.put('/lessons/:id', (req, res) => {
    const { saved } = z.object({ saved: z.boolean() }).parse(req.body);
    res.json(update(req.body, state => {
      const lessonID = String(req.params.id);
      if (saved) {
        const learning = store.get<Learning>('learning');
        requireFound(learning.definitions.find(d => d.id === lessonID) ?? learning.attempts.find(a => a.lessonID === lessonID) ?? learning.terminalRecords.find(t => t.lessonID === lessonID));
        if (!state.savedLessons.includes(lessonID)) state.savedLessons.push(lessonID);
      }
      else state.savedLessons = state.savedLessons.filter(id => id !== lessonID);
    }));
  });
  router.post('/reviews/:id', (req, res) => {
    const input = z.object({ rating: reviewRating, response: z.string().trim().min(1).max(20_000) }).parse(req.body);
    res.json(update(req.body, (state, at) => {
      const lessonID = String(req.params.id), learning = store.get<Learning>('learning');
      if (!learning.progress.some(p => p.lessonID === lessonID && p.status === 'completed') || !lessonDefinition(learning, lessonID)) {
        throw new HttpError(409, 'Complete a lesson with saved content before reviewing it.');
      }
      let review = state.reviews.find(r => r.lessonID === lessonID);
      const latest = review?.history.at(-1)?.at;
      if (latest && Date.parse(at) - Date.parse(latest) < 60_000) throw new HttpError(409, 'This review was just saved. Come back to it later.');
      const days = input.rating === 'again' ? 1 : input.rating === 'okay' ? 3 : Math.min(30, 7 * ((review?.history.length ?? 0) + 1));
      if (!review) { review = { lessonID, nextAt: at, history: [] }; state.reviews.push(review); }
      review.history.push({ ...input, at }); review.nextAt = new Date(Date.parse(at) + days * 86_400_000).toISOString();
    }));
  });
  return router;
}
