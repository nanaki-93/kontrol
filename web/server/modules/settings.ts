import { Router } from 'express';
import { randomUUID } from 'node:crypto';
import { z } from 'zod';
import {
  nativeExportSchema, generalPreferencesSchema, layoutSchema, compatibleLayoutSchema, defaultLayout, defaultPreferences,
  type NativeExport, type Task, type Block, type Session, type Learning, type NewsState, type Preferences, type Layout,
} from '../../shared/schema';
import { Store } from '../store';
import { HttpError } from '../errors';
import { initialLearning, fillSlots } from './learning';
import { discoveryPreferencesSchema, type DiscoveryPreferences, type DiscoveryState } from '../../shared/news';
import { getDiscovery } from '../news/discovery';
import { jobsStateSchema, type JobsState } from '../../shared/jobs';
import { getJobs } from './jobs';
import { workspaceSchema, hasWorkspaceWork, type Workspace } from '../../shared/workspace';
import { getWorkspace } from './workspace';
import { MAX_BACKUP_BYTES, BACKUP_LIMIT_LABEL } from '../../shared/backup';
import type { ExploreService } from '../news/explore';

export function exportData(store: Store): NativeExport {
  return nativeExportSchema.parse({
    schemaVersion: 1, exportedAt: new Date().toISOString(), appVersion: 'kontrol-web/0.1.0',
    tasks: store.get('tasks'), blocks: store.get('schedule'), sessions: store.get('focus'),
    learning: store.get('learning'), feedPreferences: store.get<NewsState>('news').preferences,
    generalPreferences: store.get('preferences'),
  });
}
const webBackupSchema = z.discriminatedUnion('schemaVersion', [
  z.object({ format: z.literal('kontrol-web'), schemaVersion: z.literal(1), data: nativeExportSchema, layout: compatibleLayoutSchema }),
  z.object({ format: z.literal('kontrol-web'), schemaVersion: z.literal(2), data: nativeExportSchema,
    layout: compatibleLayoutSchema, newsDiscovery: discoveryPreferencesSchema }),
  z.object({ format: z.literal('kontrol-web'), schemaVersion: z.literal(3), data: nativeExportSchema,
    layout: compatibleLayoutSchema, newsDiscovery: discoveryPreferencesSchema, jobs: jobsStateSchema }),
  z.object({ format: z.literal('kontrol-web'), schemaVersion: z.literal(4), data: nativeExportSchema,
    layout: layoutSchema, newsDiscovery: discoveryPreferencesSchema, jobs: jobsStateSchema }),
  z.object({ format: z.literal('kontrol-web'), schemaVersion: z.literal(5), data: nativeExportSchema,
    layout: layoutSchema, newsDiscovery: discoveryPreferencesSchema, jobs: jobsStateSchema, workspace: workspaceSchema }),
]);
export function parseImport(input: unknown): { data: NativeExport; layout: Layout | null; discovery: DiscoveryPreferences | null; jobs: JobsState | null; workspace: Workspace | null } {
  if (typeof input === 'object' && input !== null && 'format' in input) {
    const backup = webBackupSchema.parse(input);
    return { data: backup.data, layout: backup.layout, discovery: backup.schemaVersion >= 2 && 'newsDiscovery' in backup ? backup.newsDiscovery : null,
      jobs: 'jobs' in backup ? backup.jobs : null, workspace: 'workspace' in backup ? backup.workspace : null };
  }
  return { data: nativeExportSchema.parse(input), layout: null, discovery: null, jobs: null, workspace: null };
}
export function importData(store: Store, input: unknown): void {
  const { data, layout, discovery, jobs, workspace } = parseImport(input);
  store.transaction(() => {
    const learning = store.get<Learning>('learning');
    if (store.has('imported') || store.get<Task[]>('tasks').length || store.get<Block[]>('schedule').length ||
      store.get<Session[]>('focus').length || learning.attempts.length ||
      learning.progress.some(p => p.status !== 'available') || learning.terminalRecords.length ||
      (store.has('jobs') && getJobs(store).cv) || (store.has('workspace') && hasWorkspaceWork(getWorkspace(store)))) {
      throw new HttpError(409, 'Import needs a fresh web database so it cannot overwrite your work. Use a new KONTROL_DATA_DIR, then import.');
    }
    // Preserve native historical records and pinned definitions exactly. Only an
    // entirely empty curriculum gets the bundled catalog; no history is invented.
    const importedLearning = data.learning.definitions.length || data.learning.attempts.length ||
      data.learning.progress.length || data.learning.terminalRecords.length ? data.learning : initialLearning();
    fillSlots(importedLearning, data.exportedAt);
    store.set('tasks', data.tasks); store.set('schedule', data.blocks); store.set('focus', data.sessions);
    store.set('learning', importedLearning); store.set('preferences', data.generalPreferences);
    store.set<NewsState>('news', { preferences: data.feedPreferences, articles: [], errors: {}, lastRefreshAt: null });
    if (layout) store.set('layout', layout);
    if (discovery) store.set<DiscoveryState>('newsDiscovery', {
      preferences: { ...discovery, interests: discovery.interests.map(i => ({ ...i, revision: randomUUID() })) },
      articles: [], runs: {},
    });
    if (jobs) store.set('jobs', { ...jobs, revision: randomUUID() });
    if (workspace) store.set('workspace', { ...workspace, revision: randomUUID() });
    else if (store.has('workspace') && jobs?.profileConfirmed && jobs.profile) {
      const current = getWorkspace(store); current.profile.targetRoles = jobs.profile.roles;
      store.set('workspace', { ...current, revision: randomUUID() });
    }
    store.set('imported', { at: new Date().toISOString(), sourceVersion: data.appVersion });
  });
}
export function settingsModule(store: Store, explore?: Pick<ExploreService, 'invalidate'>): Router {
  const router = Router();
  // Retired modules have no routes. Keep their saved records available to backup
  // and import so removing sections never deletes personal data.
  store.init<Task[]>('tasks', []);
  store.init<Block[]>('schedule', []);
  store.init('preferences', defaultPreferences);
  store.init('layout', defaultLayout);
  store.set('layout', compatibleLayoutSchema.parse(store.get('layout')));
  store.init('instanceID', randomUUID());
  router.get('/', (_req, res) => res.json({
    preferences: store.get<Preferences>('preferences'), layout: store.get<Layout>('layout'), instanceID: store.get<string>('instanceID'),
  }));
  router.put('/preferences', (req, res) => {
    const preferences = generalPreferencesSchema.parse(req.body);
    store.set('preferences', preferences);
    res.json(preferences);
  });
  router.put('/layout', (req, res) => {
    const layout = layoutSchema.parse(req.body);
    store.set('layout', layout);
    res.json(layout);
  });
  router.get('/export', (_req, res) => {
    const backup = { format: 'kontrol-web', schemaVersion: 5, data: exportData(store), layout: store.get<Layout>('layout'),
      newsDiscovery: getDiscovery(store).preferences, jobs: getJobs(store), workspace: getWorkspace(store) };
    const json = JSON.stringify(backup, null, 2);
    if (Buffer.byteLength(json, 'utf8') > MAX_BACKUP_BYTES) {
      throw new HttpError(413, 'This workspace exceeds the ' + BACKUP_LIMIT_LABEL + ' JSON backup limit. Stop Kontrol and copy its data directory for a full database backup. Your data has not changed.');
    }
    res.setHeader('Content-Disposition', 'attachment; filename="kontrol-web-backup.json"');
    res.type('json').send(json);
  });
  router.post('/import/preview', (req, res) => {
    const { data, discovery, jobs, workspace } = parseImport(req.body);
    res.json({ source: data.appVersion, sessions: data.sessions.length, lessons: data.learning.definitions.length, answers: data.learning.attempts.length,
      feeds: data.feedPreferences.feeds.length, interests: discovery?.interests.length ?? 0, cvs: jobs?.cv ? 1 : 0, jobMatches: jobs?.matches.length ?? 0,
      savedArticles: workspace?.articles.filter(a => a.savedAt).length ?? 0, applications: workspace?.jobs.length ?? 0,
      notes: workspace?.notes.length ?? 0, savedLessons: workspace?.savedLessons.length ?? 0, reviews: workspace?.reviews.length ?? 0 });
  });
  router.post('/import', (req, res) => {
    importData(store, req.body);
    // importData returns only after its transaction commits. Revoke even for
    // legacy imports that retain the same saved-interest IDs and revisions.
    // Preview, invalid input, fresh-database rejection and rollback never reach
    // this hook; temporary exploration is not part of either backup schema.
    explore?.invalidate();
    res.json({ imported: true });
  });
  return router;
}
