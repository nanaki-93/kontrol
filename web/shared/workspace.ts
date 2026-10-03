import { z } from 'zod';
import { instant, id as contentID, type Article, type Definition, type Layout, type Learning } from './schema';
import { jobMatchSchema, jobSourceSchema } from './jobs';

const line = z.string().trim().min(1).max(200);
export const safeURL = z.url().max(4096).refine(value => {
  const url = new URL(value);
  return ['http:', 'https:'].includes(url.protocol) && !url.username && !url.password;
}, 'Use an HTTP or HTTPS link without credentials.');
export const calendarDay = z.string().regex(/^\d{4}-\d{2}-\d{2}$/).refine(value => {
  const date = new Date(value + 'T12:00:00Z');
  return Number.isFinite(date.getTime()) && date.toISOString().slice(0, 10) === value;
}, 'Choose a valid date.');
export function canonicalURL(value: string): string {
  const url = new URL(value);
  url.hash = '';
  for (const key of [...url.searchParams.keys()]) if (/^(utm_.+|fbclid|gclid)$/i.test(key)) url.searchParams.delete(key);
  url.searchParams.sort();
  return url.href;
}
export const pathIDs = ['go-backend', 'java-backend', 'system-design'] as const;
export const workspaceProfileSchema = z.object({
  goal: z.string().trim().max(500), targetRoles: z.array(line).max(5), interests: z.array(line).max(12),
  topicIDs: z.array(line).max(20), weeklyTarget: z.number().int().min(1).max(14),
  pathID: z.enum(pathIDs).nullable(),
  timeZones: z.array(z.object({ label: line, zone: line.refine(value => {
    try { new Intl.DateTimeFormat('en', { timeZone: value }); return true; } catch { return false; }
  }, 'Use a time zone such as Asia/Tokyo.') })).max(3),
});
export const articleSnapshotSchema = z.object({
  title: z.string().min(1).max(2000), url: safeURL, source: z.string().max(2000), summary: z.string().max(50_000),
  publishedAt: instant.nullable(), fetchedAt: instant,
  summaryKind: z.enum(['source', 'ai-snippet']).default('source'),
});
export const savedArticleSchema = z.object({
  id: z.uuid(), article: articleSnapshotSchema, savedAt: instant.nullable(), readAt: instant.nullable(),
  notes: z.string().max(20_000), updatedAt: instant,
});
export const stages = ['saved', 'applied', 'interviewing', 'offer', 'archived'] as const;
export const stageLabels = { saved: 'Saved', applied: 'Applied', interviewing: 'Interviewing', offer: 'Offer', archived: 'Archived' };
export const skillDecisionSchema = z.object({ label: line, decision: z.enum(['unconfirmed', 'experienced', 'practice']) });
export const trackedJobSchema = z.object({
  id: z.uuid(), revision: z.uuid(), job: jobSourceSchema, fit: jobMatchSchema.pick({ score: true, reason: true, gaps: true }).nullable(),
  stage: z.enum(stages), notes: z.string().max(20_000), followUpOn: calendarDay.nullable(),
  savedAt: instant, updatedAt: instant,
  history: z.array(z.object({ stage: z.enum(stages), at: instant })).min(1).max(1000),
  skills: z.array(skillDecisionSchema).max(30).refine(items => new Set(items.map(i => i.label.toLowerCase())).size === items.length),
});
export const noteDraftSchema = z.object({
  title: line, body: z.string().max(20_000), url: safeURL.nullable(), kind: z.enum(['note', 'link', 'project']),
}).refine(note => note.kind !== 'link' || !!note.url, 'A pinned link needs a URL.');
export const noteSchema = noteDraftSchema.safeExtend({ id: z.uuid(), revision: z.uuid(), createdAt: instant, updatedAt: instant });
export const reviewRating = z.enum(['again', 'okay', 'confident']);
export const reviewSchema = z.object({
  lessonID: contentID, nextAt: instant,
  history: z.array(z.object({ at: instant, rating: reviewRating, response: z.string().max(20_000) })).min(1).max(1000),
});
export const workspaceSchema = z.object({
  schemaVersion: z.literal(1), revision: z.uuid(), profile: workspaceProfileSchema,
  articles: z.array(savedArticleSchema).max(1000), jobs: z.array(trackedJobSchema).max(500),
  notes: z.array(noteSchema).max(1000), savedLessons: z.array(contentID).max(1000), reviews: z.array(reviewSchema).max(1000),
}).superRefine((state, ctx) => {
  const unique = (values: string[], name: string) => {
    if (new Set(values).size !== values.length) ctx.addIssue({ code: 'custom', message: 'Duplicate ' + name + '.' });
  };
  for (const key of ['articles', 'jobs', 'notes'] as const) unique(state[key].map(item => item.id), key + ' IDs');
  unique(state.articles.map(a => canonicalURL(a.article.url)), 'article links');
  unique(state.jobs.map(j => canonicalURL(j.job.url)), 'job links');
  unique(state.savedLessons, 'saved lessons'); unique(state.reviews.map(r => r.lessonID), 'lesson reviews');
  if (new TextEncoder().encode(JSON.stringify(state)).byteLength > 8 * 1024 * 1024) ctx.addIssue({ code: 'custom', message: 'Your saved library exceeds 8 MB. Shorten large notes or remove unneeded items before saving.' });
});
export type Workspace = z.infer<typeof workspaceSchema>;
export type WorkspaceProfile = Workspace['profile'];
export type SavedArticle = z.infer<typeof savedArticleSchema>;
export type TrackedJob = z.infer<typeof trackedJobSchema>;
export type Note = z.infer<typeof noteSchema>;
export function emptyWorkspace(revision: string): Workspace {
  return { schemaVersion: 1, revision, profile: { goal: '', targetRoles: [], interests: [], topicIDs: [], weeklyTarget: 3, pathID: null, timeZones: [] },
    articles: [], jobs: [], notes: [], savedLessons: [], reviews: [] };
}
export function hasWorkspaceWork(state: Workspace): boolean {
  const baseline = emptyWorkspace(state.revision);
  return !!(state.articles.length || state.jobs.length || state.notes.length || state.savedLessons.length || state.reviews.length ||
    JSON.stringify(state.profile) !== JSON.stringify(baseline.profile));
}
export const layoutPresets: Record<'balanced' | 'learning' | 'job-search', Layout> = {
  balanced: [
    { id: 'learning', visible: true, width: 'normal' }, { id: 'news', visible: true, width: 'normal' },
    { id: 'jobs', visible: true, width: 'wide' }, { id: 'focus', visible: false, width: 'normal' }, { id: 'projects', visible: false, width: 'normal' },
  ],
  learning: [
    { id: 'learning', visible: true, width: 'wide' }, { id: 'focus', visible: true, width: 'normal' },
    { id: 'news', visible: true, width: 'normal' }, { id: 'jobs', visible: false, width: 'wide' }, { id: 'projects', visible: true, width: 'normal' },
  ],
  'job-search': [
    { id: 'jobs', visible: true, width: 'wide' }, { id: 'learning', visible: true, width: 'normal' },
    { id: 'news', visible: true, width: 'normal' }, { id: 'focus', visible: false, width: 'normal' }, { id: 'projects', visible: false, width: 'normal' },
  ],
};
export const learningPaths = [
  { id: 'go-backend', title: 'Prepare for Go backend interviews', description: 'Practice Go contracts, testing, concurrency, and reliable APIs.',
    objectives: ['go.interfaces.consumer-contract', 'go.testing.case-design', 'go.concurrency.cancel-work', 'go.network.deadline-boundaries', 'design.api.deduplicate-writes', 'security.api.object-access'],
    project: 'Design a small Go API with an idempotent write endpoint, cancellation, table-driven tests, and an authorization check. Record your design, tradeoffs, and a link to your implementation.' },
  { id: 'java-backend', title: 'Strengthen Java backend skills', description: 'Practice lifecycle management, tests, and transaction boundaries.',
    objectives: ['java.language.value-boundaries', 'java.testing.case-design', 'java.concurrency.task-lifecycle', 'java.spring.transaction-scope', 'design.queues.delivery-guarantees', 'perf.database.query-count'],
    project: 'Design an order service with a transactional outbox, duplicate-safe delivery, and parameterized tests. Record the failure cases you considered and a link to your implementation.' },
  { id: 'system-design', title: 'Improve system design', description: 'Work through consistency, throughput, and recovery decisions.',
    objectives: ['design.api.rate-limit-consistency', 'design.reliability.retry-budget', 'design.cache.freshness', 'design.queues.bounded-load', 'design.storage.partition-key', 'design.reliability.recovery-plan'],
    project: 'Design a notification service. Describe queue boundaries, retry budgets, backpressure, partition keys, and a recovery plan. Save your design and explain one tradeoff you would revisit at higher traffic.' },
] as const;
export function lessonDefinition(state: Learning, id: string): Definition | undefined {
  const status = state.progress.find(p => p.lessonID === id)?.status;
  if (status === 'completed') return state.attempts.filter(a => a.lessonID === id && a.completedAt)
    .sort((a, b) => b.completedAt!.localeCompare(a.completedAt!))[0]?.pinnedContent?.definition;
  if (status === 'dismissed') return state.attempts.find(a => a.lessonID === id && a.pinnedContent)?.pinnedContent?.definition ??
    state.terminalRecords.find(t => t.lessonID === id)?.dismissalTimeDefinition ?? undefined;
  return state.attempts.find(a => a.lessonID === id && !a.completedAt)?.pinnedContent?.definition ??
    state.definitions.find(d => d.id === id);
}
export function dueReviews(state: Learning, workspace: Workspace, now = Date.now()) {
  return state.progress.filter(p => p.status === 'completed' && p.completedAt && lessonDefinition(state, p.lessonID))
    .map(p => ({ lessonID: p.lessonID, dueAt: workspace.reviews.find(r => r.lessonID === p.lessonID)?.nextAt ?? new Date(Date.parse(p.completedAt!) + 86_400_000).toISOString() }))
    .filter(r => Date.parse(r.dueAt) <= now).sort((a, b) => a.dueAt.localeCompare(b.dueAt));
}
export function nextLesson(state: Learning, workspace?: Workspace): Definition | undefined {
  const started = state.progress.filter(p => p.status === 'started').sort((a, b) => (b.lastOpenedAt ?? '').localeCompare(a.lastOpenedAt ?? ''));
  for (const progress of started) { const definition = lessonDefinition(state, progress.lessonID); if (definition) return definition; }
  const path = learningPaths.find(p => p.id === workspace?.profile.pathID);
  const terminal = new Set(state.progress.filter(p => ['completed', 'dismissed'].includes(p.status)).map(p => p.lessonID));
  const eligible = state.slots.map(s => lessonDefinition(state, s.lessonID)).filter((d): d is Definition => !!d && !terminal.has(d.id));
  return path?.objectives.flatMap(objective => eligible.find(d => d.objectiveKey === objective) ?? [])[0] ?? eligible.find(d => workspace?.profile.topicIDs.includes(d.topicID)) ?? eligible[0];
}
const topicTerms: Record<string, RegExp> = {
  go: /\b(go|golang|goroutines?)\b/i, java: /\b(java|jvm|spring)\b/i,
  design: /\b(system design|distributed|idempotenc\w*|backpressure|rate limit\w*|queues?|retry|retries|partition\w*|cach\w*)\b/i,
  perf: /\b(performance|profil\w*|latency|benchmark\w*|load test\w*|n\+1|indexes|indexing)\b/i,
  security: /\b(security|authorization|authentication|jwt|threat|secrets?)\b/i,
};
export function relatedLessons(state: Learning, value: string): Definition[] {
  if (value.trim().toLowerCase() === 'sql') return state.definitions.filter(d => ['perf.database.query-count', 'perf.database.index-access'].includes(d.objectiveKey));
  const words = value.toLowerCase().match(/[a-z][a-z0-9+]{3,}/g) ?? [];
  return state.definitions.map(lesson => {
    const corpus = (lesson.title + ' ' + lesson.objective).toLowerCase();
    const specific = words.filter(word => !['experience', 'knowledge', 'skills', 'with', 'have', 'your', 'profile', 'evidenced'].includes(word) && corpus.includes(word)).length;
    const topicMatch = topicTerms[lesson.topicID]?.test(value) ?? false;
    return { lesson, score: specific >= 2 ? specific + 2 : topicMatch ? specific + 1 : 0 };
  }).filter(item => item.score > 0).sort((a, b) => b.score - a.score || a.lesson.id.localeCompare(b.lesson.id)).slice(0, 3).map(item => item.lesson);
}
export function jobSkillCandidates(job: TrackedJob): string[] {
  const source = job.job.title + ' ' + job.job.description;
  const skills: [string, RegExp][] = [['Go', /\b(go|golang)\b/i], ['Java', /\bjava\b/i], ['System design', /\b(system design|distributed systems)\b/i],
    ['Performance', /\b(performance|profiling|latency)\b/i], ['Security', /\b(security|authorization|authentication)\b/i],
    ['Kubernetes', /\bkubernetes\b/i], ['React', /\breact\b/i], ['Python', /\bpython\b/i], ['SQL', /\bsql\b/i]];
  return [...new Set([...job.skills.map(s => s.label), ...skills.filter(([, pattern]) => pattern.test(source)).map(([label]) => label)])].slice(0, 30);
}
export interface StoryGroup<T> { lead: T; related: T[] }
export function groupStories<T extends Pick<Article, 'title' | 'url' | 'publishedAt'>>(articles: T[], limit = Infinity): StoryGroup<T>[] {
  const groups: { story: StoryGroup<T>; url: string; urls: Set<string>; words: Set<string>; published: number | null }[] = [];
  const tokens = (title: string) => new Set((title.toLowerCase().match(/[\p{L}\p{N}]+/gu) ?? []).filter(w => w.length > 2 && !['the', 'and', 'for', 'with', 'from', 'that', 'this'].includes(w)));
  for (const article of articles) {
    const words = tokens(article.title), url = canonicalURL(article.url);
    const published = article.publishedAt ? Date.parse(article.publishedAt) : null;
    const existing = groups.find(group => {
      if (group.url === url) return true;
      if (published === null || group.published === null || Math.abs(published - group.published) > 3 * 86_400_000) return false;
      let shared = 0;
      for (const word of words) if (group.words.has(word)) shared++;
      return shared >= 4 && shared / (words.size + group.words.size - shared) >= 0.65;
    });
    if (existing) {
      if (!existing.urls.has(url)) { existing.story.related.push(article); existing.urls.add(url); }
    } else if (groups.length < limit) {
      groups.push({ story: { lead: article, related: [] }, url, urls: new Set([url]), words, published });
    }
  }
  return groups.map(group => group.story);
}
